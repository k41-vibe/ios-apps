import SwiftUI
import MetalKit
import IOSurface
import QuartzCore
import Darwin

// iosc の画面をそのまま出す側。native/xsurface.c が ddx ソケットを喋り、ここは
// 「DIRTY が来たらその IOSurface を MTLTexture として貼って present し、フェンスを
// 返す」だけを受け持つ。経路(IOSurface -> MTLTexture -> MTKView)は LCProbe で
// 実測済み(G0: 60 fps)。プロトコルの根拠は tools/xios/iosc-host-protocol.md の 2〜5 節。

// libLCsys.dylib(Runner が RTLD_GLOBAL で dlopen 済み)から xs_* を引く。
// 1 つでも欠けたら古い dylib なので、まとめて失敗させる。
struct XSurfaceAPI {
    typealias ConnectFn   = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    typealias PollFn      = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?,
                                            UnsafeMutablePointer<UInt64>?, UnsafeMutablePointer<UInt64>?) -> Int32
    typealias SurfaceFn   = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> UnsafeMutableRawPointer?
    typealias CountFn     = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    typealias InfoFn      = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Int32>?,
                                            UnsafeMutablePointer<Int32>?, UnsafeMutablePointer<Int32>?) -> Void
    typealias ReleaseFn   = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt64) -> Int32
    typealias PresentedFn = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt32, Int32) -> Int32
    typealias CloseFn     = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias TokenFn     = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<UInt8>?
    typealias EventFn     = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, Int) -> UnsafeMutableRawPointer?

    let connect: ConnectFn
    let poll: PollFn
    let surface: SurfaceFn
    let count: CountFn
    let info: InfoFn
    let release: ReleaseFn
    let presented: PresentedFn
    let close: CloseFn
    let releaseToken: TokenFn
    let lastFenceToken: TokenFn
    let eventForToken: EventFn

    init?(handle: UnsafeMutableRawPointer, log: ConsoleLog) {
        var missing: [String] = []
        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            guard let p = dlsym(handle, name) else { missing.append(name); return nil }
            return p
        }
        let c = sym("xs_connect"), p = sym("xs_poll"), s = sym("xs_surface"), n = sym("xs_count")
        let i = sym("xs_info"), r = sym("xs_release"), pr = sym("xs_presented"), cl = sym("xs_close")
        let rt = sym("xs_release_token"), ft = sym("xs_last_fence_token")
        let ev = sym("lcsys_shared_event_for_token")
        guard missing.isEmpty, let c = c, let p = p, let s = s, let n = n, let i = i, let r = r,
              let pr = pr, let cl = cl, let rt = rt, let ft = ft, let ev = ev else {
            log.log("画面: libLCsys.dylib に \(missing.joined(separator: ", ")) が無い ← 古い dylib")
            return nil
        }
        connect = unsafeBitCast(c, to: ConnectFn.self)
        poll = unsafeBitCast(p, to: PollFn.self)
        surface = unsafeBitCast(s, to: SurfaceFn.self)
        count = unsafeBitCast(n, to: CountFn.self)
        info = unsafeBitCast(i, to: InfoFn.self)
        release = unsafeBitCast(r, to: ReleaseFn.self)
        presented = unsafeBitCast(pr, to: PresentedFn.self)
        close = unsafeBitCast(cl, to: CloseFn.self)
        releaseToken = unsafeBitCast(rt, to: TokenFn.self)
        lastFenceToken = unsafeBitCast(ft, to: TokenFn.self)
        eventForToken = unsafeBitCast(ev, to: EventFn.self)
    }
}

final class ScreenClient: NSObject, MTKViewDelegate {
    // 1 フレーム分の ack 対象。DIRTY 1 回につき RELEASED 1 回(まとめない)
    private struct Frame {
        let id: UInt32
        let seq: UInt64
        let fence: UInt64
    }

    let log: ConsoleLog
    let api: XSurfaceAPI
    let device: MTLDevice
    private let queue: MTLCommandQueue

    // conn は接続後に一度だけ入り、以後 nil に戻さない(Metal の完了ハンドラから
    // xs_release を呼ぶので、描画スレッド側で解放すると use-after-free になる)
    private var conn: UnsafeMutableRawPointer?
    private var pipeline: MTLRenderPipelineState?
    private var textures: [UInt32: MTLTexture] = [:]   // 面 id ごとに 1 枚だけ作って使い回す
    private var current: MTLTexture?
    private var currentId: UInt32 = 0
    private var fbWidth = 0, fbHeight = 0
    private var flipY: Float = 0

    private var releaseEvent: MTLSharedEvent?
    private var eventCache: [Data: MTLSharedEvent] = [:]
    private var pendingWait: (event: MTLSharedEvent, value: UInt64)?

    private var frames = 0
    private var dirtyTotal = 0
    private var lastReport = Date()
    private var disconnected = false
    private var firstFrameLogged = false
    private var releaseErrors = 0
    // DIRTY が 1 件も来ないまま空回りした draw の回数。黙って黒いままになるのを防ぐ
    private var idleDraws = 0
    // finish() は描画スレッド(描けなかったとき)と Metal の完了ハンドラの両方から
    // 呼ばれるので、その中身だけは直列化する
    private let finishLock = NSLock()

    init?(log: ConsoleLog, api: XSurfaceAPI) {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            log.log("画面: Metal デバイスが取れない")
            return nil
        }
        self.log = log
        self.api = api
        self.device = dev
        self.queue = q
        super.init()
    }

    // ------------------------------------------------------------ 接続(別スレッド)

    // バックグラウンドから呼ぶこと。握手の中で最大 3 秒ブロックする。
    func connect(path: String) -> Bool {
        log.log("画面: xs_connect \(path) (\(path.utf8.count) B)")
        guard let c = path.withCString({ api.connect($0) }) else {
            log.log("画面: xs_connect 失敗 errno \(errno) (\(String(cString: strerror(errno))))")
            return false
        }
        conn = c
        var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
        api.info(c, &w, &h, &stride)
        fbWidth = Int(w); fbHeight = Int(h)
        log.log("画面: 接続 output \(w)x\(h) stride \(stride), 面 \(api.count(c)) 枚")
        // 解放タイムラインは STREAM_INFO の 32 バイトトークン 1 本(第 4 節)
        if let t = api.releaseToken(c) {
            releaseEvent = sharedEvent(token: t)
            log.log("画面: 解放イベント \(releaseEvent == nil ? "取れず ← フェンス無しで進む" : "ok")")
        } else {
            log.log("画面: STREAM_INFO 無し(caps=0)。解放フェンスは送らない")
        }
        return true
    }

    // G2 では切らない(iosc も落とさない)。API の対称性のために残す。
    func stop() {
        guard let c = conn else { return }
        conn = nil
        api.close(c)
    }

    // トークン -> MTLSharedEvent。ブローカー代替(xpcshim.m)を通す。同じトークンなら
    // 毎フレーム作り直さない。
    private func sharedEvent(token: UnsafePointer<UInt8>) -> MTLSharedEvent? {
        let key = Data(bytes: token, count: 32)
        if let e = eventCache[key] { return e }
        let dev = Unmanaged.passUnretained(device as AnyObject).toOpaque()
        guard let p = api.eventForToken(dev, token, 32) else { return nil }
        // lcsys_shared_event_for_token は +1 で返す(newSharedEventWithHandle:)
        let obj = Unmanaged<AnyObject>.fromOpaque(p).takeRetainedValue()
        guard let ev = obj as? MTLSharedEvent else {
            log.log("画面: 返ってきたのが MTLSharedEvent ではない (\(type(of: obj)))")
            return nil
        }
        eventCache[key] = ev
        return ev
    }

    // ------------------------------------------------------------------ 描画の支度

    func attach(view: MTKView) {
        view.device = device
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        lastReport = Date()
        seedFirstSurface()
        // コンソールと画面を行き来すると makeUIView がもう一度呼ばれる。シェーダの
        // 実行時コンパイルは安くないので、一度作れていたら作り直さない。
        if pipeline != nil { return }
        var lib = device.makeDefaultLibrary()
        var how = "default.metallib"
        if lib == nil {
            how = "runtime source compile"
            lib = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        }
        guard let library = lib else {
            log.log("画面: Metal ライブラリが作れない(両方の道とも失敗)")
            return
        }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "xios_vertex")
        pd.fragmentFunction = library.makeFunction(name: "xios_fragment")
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
            log.log("画面: pipeline ok via \(how)")
        } catch {
            log.log("画面: pipeline 失敗 via \(how): \(error)")
        }
    }

    // 面 id ごとに MTLTexture を 1 枚だけ作る。IOSurface は接続の寿命の間ずっと
    // 同じものなので、毎フレーム makeTexture すると無駄なだけでなく重い。
    private func texture(for id: UInt32) -> MTLTexture? {
        if let t = textures[id] { return t }
        guard let conn = conn, let raw = api.surface(conn, id) else {
            log.log("画面: 面 id \(id) の IOSurface が無い")
            return nil
        }
        let surface = unsafeBitCast(raw, to: IOSurfaceRef.self)
        let w = IOSurfaceGetWidth(surface), h = IOSurfaceGetHeight(surface)
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                                                            width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else {
            log.log("画面: makeTexture(iosurface:) 失敗 id \(id) \(w)x\(h)")
            return nil
        }
        textures[id] = tex
        log.log("画面: 面 id \(id) を \(w)x\(h) のテクスチャにした(以後使い回す)")
        return tex
    }

    // DIRTY を待たずに、握手で受け取った面をそのまま 1 枚貼っておく。
    // iosc は自分の表側のバッファに描き続けているので、フェンス無しで読むと
    // 破れて見えることはあるが、「何も出ない」と「出るが通知が来ない」を
    // 実機で切り分けられる。DIRTY が 1 件来た時点で普通の経路に上書きされる。
    private func seedFirstSurface() {
        guard current == nil, let conn = conn else { return }
        for id in UInt32(1)...UInt32(3) where api.surface(conn, id) != nil {
            if let t = texture(for: id) {
                current = t
                currentId = id
                log.log("画面: DIRTY 待ちの間、面 id \(id) をそのまま貼っておく")
                return
            }
        }
    }

    // ---------------------------------------------------------------- MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let conn = conn, !disconnected else { return }

        // 1 回の draw で溜まっている DIRTY を全部引き取る。描くのは一番新しい 1 枚だけ
        // だが、引き取った分は全部 RELEASED を返す(返さないと 3 枚とも pending になって
        // iosc が repaint_retry_soon() で回り続け、画面が止まる。第 5 節)。
        var batch: [Frame] = []
        while batch.count < 8 {
            var sid: UInt32 = 0, seq: UInt64 = 0, fence: UInt64 = 0
            let r = api.poll(conn, &sid, &seq, &fence)
            if r == 1 {
                batch.append(Frame(id: sid, seq: seq, fence: fence))
            } else if r == 0 {
                break
            } else {
                disconnected = true
                log.log("画面: xs_poll が切断を返した errno \(errno)。描画を止める")
                break
            }
        }
        dirtyTotal += batch.count

        var newest: MTLTexture?
        if let last = batch.last {
            newest = texture(for: last.id)
            // 待つのは最新のフェンス値だけでよい(同じタイムラインの単調増加値)
            if let tp = api.lastFenceToken(conn), let ev = sharedEvent(token: tp) {
                pendingWait = (ev, last.fence)
            } else if pendingWait == nil && !firstFrameLogged {
                log.log("画面: 提示フェンスのイベントが取れない(待たずに描く)")
            }
        }

        guard let pipeline = pipeline, let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor, let tex = newest ?? current,
              let cb = queue.makeCommandBuffer() else {
            // 描けなかったフレームも ack は返す
            finish(batch)
            // 何も出ないまま黙るのが一番困る(実機 2026-09-12)。理由を 1 度だけ書く
            idleDraws += 1
            if idleDraws == 120 || idleDraws == 1800 {
                // currentDrawable は読むたびに取りに行くので、ここでは触らない
                let why = pipeline == nil ? "pipeline が無い"
                    : (newest ?? current) == nil ? "DIRTY が 1 件も来ていない(クライアントは居る?)"
                    : "drawable か command buffer が取れない"
                log.log("画面: \(idleDraws) 回空回り: \(why) dirty 累計 \(dirtyTotal) 面 \(api.count(conn)) 枚")
            }
            return
        }
        idleDraws = 0
        // フェンス: iosc の描き込みが終わるまで GPU を待たせる(第 4 節)。
        // encodeWaitForEvent はエンコーダを開く**前**に積むこと(開いている最中に
        // 呼ぶと Metal が落とす)。
        if let w = pendingWait {
            cb.encodeWaitForEvent(w.event, value: w.value)
            pendingWait = nil
        }
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            cb.commit()          // wait だけ積んだバッファを置き去りにしない
            finish(batch)
            return
        }
        if let t = newest, let last = batch.last {
            current = t
            currentId = last.id
        }
        let vp = Self.aspectFit(content: CGSize(width: tex.width, height: tex.height),
                                into: view.drawableSize)
        enc.setViewport(vp)
        enc.setRenderPipelineState(pipeline)
        var flip = flipY
        enc.setVertexBytes(&flip, length: MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)

        let seq = batch.last?.seq
        if seq != nil {
            drawable.addPresentedHandler { [weak self] d in self?.reportPresented(seq, d) }
        }
        cb.addCompletedHandler { [weak self] _ in self?.finish(batch) }
        cb.commit()

        if !firstFrameLogged, !batch.isEmpty {
            firstFrameLogged = true
            log.log("画面: 最初のフレームを描いた id=\(currentId) seq=\(batch[0].seq) "
                    + "fence=\(batch[0].fence) \(tex.width)x\(tex.height)")
        }
        frames += 1
        if frames % 60 == 0 {
            let now = Date()
            let el = now.timeIntervalSince(lastReport)
            lastReport = now
            let fps = String(format: "%.1f", el > 0 ? 60.0 / el : 0)
            log.log("画面: \(fps) fps 面 id=\(currentId) dirty 累計 \(dirtyTotal) "
                    + "footprint \(footprintMB()) MB")
        }
    }

    // 提示が終わったら「解放イベントに signal した command buffer を commit してから」
    // RELEASED を送る。この順番が第 4/5 節の要求そのもの。
    // Metal の完了ハンドラ(内部キュー)から呼ばれるので、UI には一切触らない。
    private func finish(_ batch: [Frame]) {
        guard !batch.isEmpty, let conn = conn else { return }
        finishLock.lock()
        defer { finishLock.unlock() }
        if let ev = releaseEvent, let cb = queue.makeCommandBuffer() {
            for f in batch { cb.encodeSignalEvent(ev, value: f.seq) }
            cb.commit()          // ここで commit 済みにしてから下の RELEASED を出す
        }
        for f in batch {
            guard api.release(conn, f.id, f.seq) != 0 else { continue }
            releaseErrors += 1
            if releaseErrors <= 3 {
                log.log("画面: xs_release(id \(f.id), seq \(f.seq)) 失敗 errno \(errno)")
            }
        }
    }

    private func reportPresented(_ seq: UInt64?, _ drawable: MTLDrawable) {
        guard let seq = seq, let conn = conn else { return }
        let t = drawable.presentedTime
        if t > 0 {
            let us = max(0.0, (CACurrentMediaTime() - t) * 1_000_000)
            _ = api.presented(conn, seq, UInt32(min(us, 4_000_000)), 1)
        } else {
            _ = api.presented(conn, seq, 0, 0)   // 実測値が無い: measured=0
        }
    }

    // 出力(1179x2556 = 実機の画面そのもの)を縦横比を保ったまま中央に置く。
    // 等倍のときはちょうど 1:1 で埋まる。
    static func aspectFit(content: CGSize, into target: CGSize) -> MTLViewport {
        guard content.width > 0, content.height > 0, target.width > 0, target.height > 0 else {
            return MTLViewport(originX: 0, originY: 0,
                               width: Double(target.width), height: Double(target.height),
                               znear: 0, zfar: 1)
        }
        let s = min(target.width / content.width, target.height / content.height)
        let w = content.width * s, h = content.height * s
        return MTLViewport(originX: Double((target.width - w) / 2), originY: Double((target.height - h) / 2),
                           width: Double(w), height: Double(h), znear: 0, zfar: 1)
    }

    // .metal ファイルを増やすと XcodeGen/Xcode のビルド設定に依存が増えるので、
    // default.metallib が無ければその場でコンパイルする(LCProbe と同じ二段構え)。
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut xios_vertex(uint vid [[vertex_id]], constant float &flip [[buffer(0)]]) {
        float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        VOut o;
        o.pos = float4(p[vid], 0, 1);
        float t = (p[vid].y + 1) / 2;
        o.uv = float2((p[vid].x + 1) / 2, flip > 0.5 ? t : 1 - t);
        return o;
    }
    fragment float4 xios_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear);
        return tex.sample(s, in.uv);
    }
    """
}

struct ScreenView: UIViewRepresentable {
    let client: ScreenClient

    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        client.attach(view: v)
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

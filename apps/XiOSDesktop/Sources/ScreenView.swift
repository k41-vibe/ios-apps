import SwiftUI
import UIKit
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
    typealias PacingFn    = @convention(c) (UnsafeMutableRawPointer?, Int32, UInt32, Int32, Int32) -> Int32

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
    let pacing: PacingFn
    typealias FdFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    let fd: FdFn

    init?(handle: UnsafeMutableRawPointer, log: ConsoleLog) {
        var missing: [String] = []
        func sym(_ name: String) -> UnsafeMutableRawPointer? {
            guard let p = dlsym(handle, name) else { missing.append(name); return nil }
            return p
        }
        let c = sym("xs_connect"), p = sym("xs_poll"), s = sym("xs_surface"), n = sym("xs_count")
        let i = sym("xs_info"), r = sym("xs_release"), pr = sym("xs_presented"), cl = sym("xs_close")
        let rt = sym("xs_release_token"), ft = sym("xs_last_fence_token")
        let ev = sym("lcsys_shared_event_for_token"), pc = sym("xs_pacing"), fdp = sym("xs_fd")
        guard missing.isEmpty, let c = c, let p = p, let s = s, let n = n, let i = i, let r = r,
              let pr = pr, let cl = cl, let rt = rt, let ft = ft, let ev = ev, let pc = pc, let fdp = fdp else {
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
        pacing = unsafeBitCast(pc, to: PacingFn.self)
        fd = unsafeBitCast(fdp, to: FdFn.self)
    }
}

// 入力ソケット側の窓口(native/xinput.c)。画面が無くても成立するので別の struct にする。
struct XInputAPI {
    typealias ConnectFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
    typealias TouchFn   = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Int32
    typealias OutputFn  = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Int32
    typealias MotionFn  = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Int32
    typealias ButtonFn  = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32, Int32) -> Int32
    typealias TextFn    = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Int32
    typealias KeyFn     = @convention(c) (UnsafeMutableRawPointer?, Int32, Int32, Int32) -> Int32
    typealias SentFn    = @convention(c) (UnsafeMutableRawPointer?) -> UInt
    typealias TraitsFn  = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?,
                                          UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> UInt

    let connect: ConnectFn
    let touch: TouchFn
    let motion: MotionFn
    let button: ButtonFn
    let text: TextFn
    let key: KeyFn
    let sent: SentFn
    let traits: TraitsFn
    let output: OutputFn

    init?(handle: UnsafeMutableRawPointer, log: ConsoleLog) {
        var missing: [String] = []
        func sym(_ n: String) -> UnsafeMutableRawPointer? {
            guard let p = dlsym(handle, n) else { missing.append(n); return nil }
            return p
        }
        let c = sym("xi_connect"), t = sym("xi_touch"), m = sym("xi_motion")
        let x = sym("xi_text"), k = sym("xi_key"), n = sym("xi_sent"), tr = sym("xi_traits")
        let ou = sym("xi_output"), bt = sym("xi_button")
        guard missing.isEmpty, let c = c, let t = t, let m = m, let x = x, let k = k, let n = n,
              let tr = tr, let ou = ou, let bt = bt else {
            log.log("入力: libLCsys.dylib に \(missing.joined(separator: ", ")) が無い ← 古い dylib")
            return nil
        }
        connect = unsafeBitCast(c, to: ConnectFn.self)
        touch = unsafeBitCast(t, to: TouchFn.self)
        motion = unsafeBitCast(m, to: MotionFn.self)
        button = unsafeBitCast(bt, to: ButtonFn.self)
        text = unsafeBitCast(x, to: TextFn.self)
        key = unsafeBitCast(k, to: KeyFn.self)
        sent = unsafeBitCast(n, to: SentFn.self)
        traits = unsafeBitCast(tr, to: TraitsFn.self)
        output = unsafeBitCast(ou, to: OutputFn.self)
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
    private var screenPath = ""          // 繋ぎ直し用(ddx ソケット)
    private var reconnecting = false
    private var firstFrameLogged = false
    private var releaseErrors = 0
    // DIRTY が 1 件も来ないまま空回りした draw の回数。黙って黒いままになるのを防ぐ
    private var idleDraws = 0

    // ---- 入力(第 6 節)。画面と同じ 32 バイトのレコードを別のソケットに流す
    var xin: XInputAPI?
    private var inputConn: UnsafeMutableRawPointer?   // 指も文字も iosc の入力ソケットへ
    private var slots: [ObjectIdentifier: Int32] = [:]   // UITouch -> スロット 0..9
    private var lastViewport: MTLViewport?
    private var touchesSent = 0

    // ---- 自動キーボード(osk-plan.md「責任者の方針」)。コンポジタが TRAITS で
    // 「文字を受け取る欄が選ばれた/外れた」を教えてくるので、それでキーボードを出し入れする。
    //   - enable で出す、disable で 0.2 秒待ってから下げる(欄から欄への移動で上下させない)
    //   - 使う人が自分で下げたキーボードは、その欄を離れるまで自動では出さない
    private var traitsSeq: UInt = 0
    /// 最後に指が触れた時刻。欄の焦点がこの直後に動いたときだけキーボードを出す
    private var lastTapAt: CFTimeInterval = 0
    static let oskAfterTapSeconds: CFTimeInterval = 1.5
    private var oskAutoShown = false
    private var oskUserDismissed = false
    private var oskProgrammaticResign = false
    private var oskHideWork: DispatchWorkItem?
    private var lastTraitsEnabled: UInt32 = 0
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
        screenPath = path
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
        startReader()
        return true
    }

    // ------------------------------------------------------------ 読み取りスレッド
    //
    // DIRTY を垂直同期と無関係に受け取り、面を自前のテクスチャへ複写して、その完了で
    // RELEASED と PRESENTED を返す。iosc はクライアントの次のフレームを PRESENTED で待つ
    // (present_ack_timer_cb)ので、ack が垂直同期に縛られると 1 周が 2 回分(約 33ms)になる
    // (実機 2026-09-14: 合成 25〜34 回/秒で頭打ち)。画面への提示は draw(in:) が 60fps で
    // 最新の複写を貼るだけ。複写先は 2 枚交互(同じ queue なので GPU の順序で守られる)。
    private var readerGen = 0
    private let latestLock = NSLock()
    private var latest: (tex: MTLTexture, id: UInt32, seq: UInt64)?
    private var lastPresentedSeq: UInt64 = 0
    private var stage: [MTLTexture] = []
    private var stageIndex = 0

    private func startReader() {
        readerGen += 1
        let gen = readerGen
        let t = Thread { [weak self] in self?.readerLoop(gen) }
        t.name = "xs-reader"
        t.qualityOfService = .userInteractive
        t.start()
    }

    private func readerLoop(_ gen: Int) {
        // 条件は世代番号だけ。繋ぎ直しの途中は disconnected が true のままなので、それを見ると
        // 起きた直後に抜けてしまう(実機 2026-09-14 build 59: 回転後に dirty 累計 0 のまま)
        log.log("画面: 読み取りスレッド開始(世代 \(gen))")
        defer { log.log("画面: 読み取りスレッド終了(世代 \(gen))") }
        while gen == readerGen, let conn = conn {
            var pfd = pollfd(fd: api.fd(conn), events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, 100)   // C の poll(2)。api.poll とは別物
            var batch: [Frame] = []
            var broken = false
            while batch.count < 8 {
                var sid: UInt32 = 0, seq: UInt64 = 0, fence: UInt64 = 0
                let r = api.poll(conn, &sid, &seq, &fence)
                if r == 1 { batch.append(Frame(id: sid, seq: seq, fence: fence)) }
                else if r == 0 { break }
                else { broken = true; break }
            }
            if broken {
                DispatchQueue.main.async { [weak self] in self?.scheduleReconnect() }
                return
            }
            if batch.isEmpty { continue }
            dirtyTotal += batch.count
            stageFrame(batch, conn: conn)
        }
    }

    /// 一番新しい面をフェンス待ちつきで複写し、完了で latest を差し替えて ack
    private func stageFrame(_ batch: [Frame], conn: UnsafeMutableRawPointer) {
        guard let last = batch.last, let src = texture(for: last.id), let cb = queue.makeCommandBuffer() else {
            finish(batch)
            return
        }
        if stage.count < 2 || stage[0].width != src.width || stage[0].height != src.height {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: src.pixelFormat,
                                                             width: src.width, height: src.height, mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = .private
            stage = (0..<2).compactMap { _ in device.makeTexture(descriptor: d) }
            guard stage.count == 2 else { finish(batch); return }
            log.log("画面: 複写先 \(src.width)x\(src.height) を 2 枚用意")
        }
        stageIndex = (stageIndex + 1) % 2
        let dst = stage[stageIndex]
        if let tp = api.lastFenceToken(conn), let ev = sharedEvent(token: tp) {
            cb.encodeWaitForEvent(ev, value: last.fence)   // iosc の描き込み完了を GPU で待つ
        }
        guard let blit = cb.makeBlitCommandEncoder() else { cb.commit(); finish(batch); return }
        blit.copy(from: src, to: dst)
        blit.endEncoding()
        cb.addCompletedHandler { [weak self] _ in
            guard let self = self else { return }
            self.latestLock.lock()
            self.latest = (dst, last.id, last.seq)
            self.latestLock.unlock()
            self.finish(batch)   // 解放イベント + RELEASED + 早い PRESENTED
        }
        cb.commit()
    }

    /// iosc が出力を作り直すと(回転、XIOS_IN_OUTPUT)表示クライアントは切られる
    /// (xios_surface.c: 世代が上がって古い握手は閉じられる)。少し待って ddx に繋ぎ直す。
    private func scheduleReconnect() {
        guard !reconnecting else { return }
        reconnecting = true
        disconnected = true
        log.log("画面: xs_poll が切断を返した errno \(errno)。ddx に繋ぎ直す")
        let path = screenPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var ok = false
            for attempt in 1...20 {
                usleep(250_000)
                self.readerGen += 1
                if let c = self.conn { self.conn = nil; self.api.close(c) }
                if self.connect(path: path) {
                    ok = true
                    self.log.log("画面: 繋ぎ直し \(attempt) 回目で成功")
                    break
                }
            }
            DispatchQueue.main.async {
                self.cacheLock.lock()
                self.textures.removeAll()      // 面 id は新しい IOSurface を指す
                self.cacheLock.unlock()
                self.latestLock.lock()
                self.latest = nil              // 古い大きさの複写は貼らない
                self.latestLock.unlock()
                self.stage.removeAll()
                self.pendingWait = nil
                self.reconnecting = false
                self.disconnected = !ok
                if !ok { self.readerGen += 1; self.log.log("画面: 繋ぎ直しに失敗。描画を止める") }
            }
        }
    }

    /// 画面の大きさ(向き)が変わった。論理サイズを測り直して iosc に送る。
    /// iosc は IOSurface を作り直し、こちらの接続を切るので、上の繋ぎ直しに続く
    func outputChanged() {
        let before = Runner.logicalPoints
        let info = Runner.measureScreen()
        guard Runner.logicalPoints != before else { return }
        log.log("画面: 向きが変わった → \(info)")
        guard let ic = inputConn, let xin = xin else { return }
        let w = Int32(Runner.logicalPoints.width.rounded()), h = Int32(Runner.logicalPoints.height.rounded())
        let rc = xin.output(ic, w, h, 0)
        log.log("画面: OUTPUT \(w)x\(h) を iosc へ送った rc=\(rc)")
    }

    // G2 では切らない(iosc も落とさない)。API の対称性のために残す。
    func stop() {
        readerGen += 1
        guard let c = conn else { return }
        conn = nil
        api.close(c)
    }

    // トークン -> MTLSharedEvent。ブローカー代替(xpcshim.m)を通す。同じトークンなら
    // 毎フレーム作り直さない。
    private let cacheLock = NSLock()   // textures / eventCache は読み取りスレッドと主スレッドが触る

    private func sharedEvent(token: UnsafePointer<UInt8>) -> MTLSharedEvent? {
        let key = Data(bytes: token, count: 32)
        cacheLock.lock(); defer { cacheLock.unlock() }
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
        cacheLock.lock(); defer { cacheLock.unlock() }
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

    // ------------------------------------------------------------ 入力

    func connectInput(path: String) {
        guard inputConn == nil, let xin = xin else { return }
        guard let c = path.withCString({ xin.connect($0) }) else {
            log.log("入力: 繋がらない \(path) errno \(errno)")
            return
        }
        inputConn = c
        log.log("入力: 接続 \(path)")
    }

    /// TRAITS(code=hint, state=purpose, mods=enabled)を毎フレーム見て、
    /// 変化があればキーボードを出し入れする。draw(in:) から主スレッドで呼ぶ。
    private func serviceTraits() {
        guard let conn = inputConn, let xin = xin, let v = view else { return }
        var hint: UInt32 = 0, purpose: UInt32 = 0, enabled: UInt32 = 0
        let seq = xin.traits(conn, &hint, &purpose, &enabled)
        guard seq != traitsSeq else { return }
        traitsSeq = seq
        if enabled != lastTraitsEnabled {
            log.log("入力: 欄が\(enabled != 0 ? "選ばれた" : "外れた") hint=0x\(String(hint, radix: 16)) purpose=\(purpose)")
        }
        lastTraitsEnabled = enabled
        if enabled != 0 {
            oskHideWork?.cancel(); oskHideWork = nil
            let tapped = CACurrentMediaTime() - lastTapAt < Self.oskAfterTapSeconds
            if !v.isFirstResponder && !oskUserDismissed && tapped {
                if v.becomeFirstResponder() { oskAutoShown = true }
            }
        } else {
            oskUserDismissed = false
            guard oskAutoShown, oskHideWork == nil else { return }
            let w = DispatchWorkItem { [weak self] in
                guard let self = self, let v = self.view else { return }
                self.oskHideWork = nil
                guard self.oskAutoShown else { return }
                self.oskProgrammaticResign = true
                _ = v.resignFirstResponder()
                self.oskProgrammaticResign = false
                self.oskAutoShown = false
            }
            oskHideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: w)
        }
    }

    /// ScreenMTKView から: 使う人が自分でキーボードを閉じた(こちらの resign ではない)
    func userResignedKeyboard() {
        if !oskProgrammaticResign {
            if lastTraitsEnabled != 0 { oskUserDismissed = true }
            oskAutoShown = false
        }
    }
    func userOpenedKeyboard() { oskUserDismissed = false }

    /// 画面上の点(ポイント)を出力(IOSurface)のピクセルに戻す。範囲外は nil。
    /// 逆変換は描画と同じ aspectFit を使う。ビューポートは drawableSize と同じ
    /// ピクセル系なので、点の方を contentScaleFactor で揃えてから引く。
    private func fbPoint(_ p: CGPoint, in view: MTKView) -> (Int32, Int32)? {
        guard fbWidth > 0, fbHeight > 0 else { return nil }
        let vp = lastViewport ?? Self.aspectFit(content: CGSize(width: fbWidth, height: fbHeight),
                                                into: view.drawableSize)
        guard vp.width > 0, vp.height > 0 else { return nil }
        let sx = p.x * view.contentScaleFactor, sy = p.y * view.contentScaleFactor
        let fx = (Double(sx) - vp.originX) / vp.width * Double(fbWidth)
        let fy = (Double(sy) - vp.originY) / vp.height * Double(fbHeight)
        guard fx >= 0, fy >= 0, fx < Double(fbWidth), fy < Double(fbHeight) else { return nil }
        return (Int32(fx), Int32(fy))
    }

    // ---------------------------------------------------------------- 指の扱い
    //
    // 本家 Xios アプリ(XScreen.swift touchesBegan/Moved/Ended、classic iosc セッション)と同じ:
    //   指 1 本 = ポインタ。押下は遅らせる(静止した長押し 0.55 秒は右クリック、動いたら
    //            起点で左押下、静止タップは離した時に押下+解放)。TOUCH は送らない
    //   指 2 本以上 = 全部 TOUCH(ピンチ等)。保留中のポインタ押下は捨てる
    // iosc の窓の移動・リサイズ(interactive_update)はポインタでしか進まず、GTK も iosc 上では
    // この経路で検証済み(docs/handoff/xios-app.md、gnome-touch-ux.md)。
    // ボタン番号は X 流(1=左 2=中 3=右、iosc handle_button)。
    private enum FingerMode { case idle, pointer, touch }
    private var fingerMode: FingerMode = .idle
    private var pendingPress: (fb: (Int32, Int32), view: CGPoint)?
    private var pressSent = false
    private var longPressFired = false
    private var longPressWork: DispatchWorkItem?
    private var lastPointerPt: (Int32, Int32)?
    static let longPressSeconds = 0.55
    static let longPressSlopPt: CGFloat = 12
    /// 既定は false = 全部 wl_touch を GTK に渡す(iPad 流)。GTK4 が慣性スクロール・ピンチ・
    /// 長押しメニュー・文字選択を自前でやる(docs/gnome-touch-ux.md「wl_touch alone」)。
    /// true にすると指 1 本をマウスのポインタにする(長押し右クリック、窓の移動・リサイズ用。
    /// iosc の interactive_update はポインタの MOTION でしか進まないため、窓移動はこちら)
    static var singleFingerIsPointer = false

    // ------------------------------------------------------------ ホーム操作
    /// 下端から上へ払うと一覧(ホーム画面 + 開いている窓)を出す。iPadOS のホーム操作。
    /// iOS 自身のホームインジケータはビューの外(下の安全領域)に居るので取り合いにならない
    /// (ContentView は .ignoresSafeArea(edges: .horizontal) だけを指定している)。
    static var homeGestureEnabled = true
    static let homeStripPt: CGFloat = 30      // 下端からこの範囲で始めた指だけを見る
    static let homeTravelPt: CGFloat = 60     // これだけ上へ動いたら成立
    private var homeTouch: ObjectIdentifier?
    private var homeStart: CGPoint = .zero
    private var homeFiredAt: CFTimeInterval = 0
    /// 一覧を起こすのに要る。ContentView が画面を開くときに入れる
    weak var runner: Runner?

    /// 戻り値 true = ホーム操作として使ったので、この呼び出しはアプリへ送らない
    private func homeGesture(_ touches: Set<UITouch>, phase: Int32, in view: MTKView, total: Int) -> Bool {
        guard Self.homeGestureEnabled else { return false }
        switch phase {
        case 1:
            homeTouch = nil
            guard total == 1, let t = touches.first else { return false }
            let p = t.location(in: view)
            if p.y >= view.bounds.height - Self.homeStripPt {
                homeTouch = ObjectIdentifier(t)
                homeStart = p
            }
            return false
        case 2:
            guard let h = homeTouch,
                  let t = touches.first(where: { ObjectIdentifier($0) == h }) else { return false }
            let p = t.location(in: view)
            let up = homeStart.y - p.y
            guard up >= Self.homeTravelPt, up > abs(p.x - homeStart.x) else { return false }
            homeTouch = nil
            // 送り始めた分を取り消す。GTK は wl_touch.cancel を受けて途中の操作を戻す
            if Self.singleFingerIsPointer { endPointer() }
            else { sendTouch([t], phase: 3, view: view, newOnly: false) }
            openHome()
            return true
        default:
            if let h = homeTouch, touches.contains(where: { ObjectIdentifier($0) == h }) { homeTouch = nil }
            return false
        }
    }

    private func openHome() {
        let now = CACurrentMediaTime()
        guard now - homeFiredAt > 1.0 else { return }   // 連続で払っても 1 本だけ起こす
        homeFiredAt = now
        guard let r = runner else { log.log("操作: 一覧を開けない(Runner が無い)"); return }
        log.log("操作: 下端から上へ払った。一覧を開く")
        Thread { r.startOverview() }.start()   // startClient は 1.5 秒眠るので主スレッドでは呼ばない
    }

    private func cancelLongPress() { longPressWork?.cancel(); longPressWork = nil }

    private func fireLongPress() {
        guard let conn = inputConn, let xin = xin, let p = pendingPress, fingerMode == .pointer else { return }
        pendingPress = nil
        longPressFired = true
        _ = xin.motion(conn, p.fb.0, p.fb.1)
        _ = xin.button(conn, p.fb.0, p.fb.1, 3, 1)
        _ = xin.button(conn, p.fb.0, p.fb.1, 3, 0)
        log.log("入力: 長押し → 右クリック (\(p.fb.0),\(p.fb.1))")
    }

    /// 保留していた左押下を起点で出す(動き始めた、または静止タップの確定)
    private func flushPendingPress() {
        guard let conn = inputConn, let xin = xin, let p = pendingPress else { return }
        pendingPress = nil
        cancelLongPress()
        _ = xin.motion(conn, p.fb.0, p.fb.1)
        _ = xin.button(conn, p.fb.0, p.fb.1, 1, 1)
        pressSent = true
        lastPointerPt = p.fb
    }

    private func endPointer() {
        guard let conn = inputConn, let xin = xin else { return }
        cancelLongPress()
        if longPressFired {
            longPressFired = false
        } else if pendingPress != nil {
            flushPendingPress()                              // 静止タップ = クリック
            if let p = lastPointerPt { _ = xin.button(conn, p.0, p.1, 1, 0) }
        } else if pressSent, let p = lastPointerPt {
            _ = xin.button(conn, p.0, p.1, 1, 0)             // ドラッグの終わり(interactive_end)
        }
        pressSent = false
        pendingPress = nil
        fingerMode = .idle
    }

    /// phase: 0=離 1=触 2=移動 3=取消(第 6 節)
    func send(touches: Set<UITouch>, phase: Int32, in view: MTKView, event: UIEvent?) {
        guard let conn = inputConn, let xin = xin else { return }
        let all = event?.allTouches ?? touches
        let total = all.count
        if homeGesture(touches, phase: phase, in: view, total: total) { return }
        if phase == 1 { lastTapAt = CACurrentMediaTime() }
        // 欄に触ったのにキーボードが出ていない(自分で閉じたあと)なら、この指で出し直す
        if phase == 0, lastTraitsEnabled != 0, let v = self.view, !v.isFirstResponder {
            oskUserDismissed = false
            if v.becomeFirstResponder() { oskAutoShown = true }
        }
        guard Self.singleFingerIsPointer else {
            sendTouch(touches, phase: phase, view: view, newOnly: false)
            return
        }
        if fingerMode == .idle && phase == 1 { fingerMode = total >= 2 ? .touch : .pointer }
        switch fingerMode {
        case .pointer:
            if total >= 2 {
                // 2 本目が来た: クリックにはしない。ここからは全部 TOUCH
                cancelLongPress(); pendingPress = nil; longPressFired = false
                if pressSent, let p = lastPointerPt { _ = xin.button(conn, p.0, p.1, 1, 0) }
                pressSent = false
                fingerMode = .touch
                sendTouch(all, phase: 1, view: view, newOnly: true)   // まだスロットの無い指を触り始めとして送る
                return
            }
            guard let t = touches.first, let (x, y) = fbPoint(t.location(in: view), in: view) else {
                if phase == 0 || phase == 3 { endPointer() }
                return
            }
            switch phase {
            case 1:
                pendingPress = ((x, y), t.location(in: view)); pressSent = false; longPressFired = false
                lastPointerPt = (x, y)
                cancelLongPress()
                let w = DispatchWorkItem { [weak self] in self?.fireLongPress() }
                longPressWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressSeconds, execute: w)
            case 2:
                if longPressFired { return }
                if let p = pendingPress {
                    let l = t.location(in: view)
                    if hypot(l.x - p.view.x, l.y - p.view.y) < Self.longPressSlopPt { return }
                    flushPendingPress()
                }
                lastPointerPt = (x, y)
                _ = xin.motion(conn, x, y)
            default:
                if pressSent { lastPointerPt = (x, y) }
                endPointer()
            }
        case .touch:
            sendTouch(touches, phase: phase, view: view, newOnly: false)
            if (phase == 0 || phase == 3) && slots.isEmpty { fingerMode = .idle }
        case .idle:
            break   // 触り始めを見ていない指(ポインタ経路の終了後など)は無視
        }
    }

    /// TOUCH 記録を送る(2 本以上の指)。newOnly: スロットを持たない指だけ送る
    private func sendTouch(_ touches: Set<UITouch>, phase: Int32, view: MTKView, newOnly: Bool) {
        guard let conn = inputConn, let xin = xin else { return }
        for t in touches {
            let key = ObjectIdentifier(t)
            let slot: Int32
            if let s = slots[key] {
                if newOnly { continue }
                slot = s
            } else if phase == 1 {
                let used = Set(slots.values)
                guard let free = (Int32(0)..<Int32(10)).first(where: { !used.contains($0) }) else { continue }
                slot = free
                slots[key] = free
            } else {
                continue   // 触り始めを見ていない指は無視する
            }
            if let (x, y) = fbPoint(t.location(in: view), in: view) {
                _ = xin.touch(conn, x, y, slot, phase)
                touchesSent += 1
                if touchesSent <= 3 || touchesSent % 200 == 0 {
                    log.log("入力: touch slot=\(slot) phase=\(phase) (\(x),\(y)) 累計 \(touchesSent)")
                }
            }
            if phase == 0 || phase == 3 { slots.removeValue(forKey: key) }
        }
    }

    // iOS のキーボードを出し入れする。表示中のビューを覚えておいて first responder にする。
    weak var view: ScreenMTKView?
    func toggleKeyboard() {
        guard let v = view else { return }
        if v.isFirstResponder { v.resignFirstResponder() } else { v.becomeFirstResponder() }
    }

    /// X の keysym を押して離す。改行 0xff0d、後退 0xff08。
    func sendKey(_ keysym: Int32) {
        guard let conn = inputConn, let xin = xin else { return }
        _ = xin.key(conn, keysym, 1, 0)
        _ = xin.key(conn, keysym, 0, 0)
    }

    func send(text: String) {
        guard let conn = inputConn, let xin = xin, !text.isEmpty else { return }
        _ = text.withCString { xin.text(conn, $0) }
        log.log("入力: text \(text.count) 文字")
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

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        DispatchQueue.main.async { [weak self] in self?.outputChanged() }
    }

    func draw(in view: MTKView) {
        guard let conn = conn, !disconnected else { return }
        serviceTraits()
        // 表示の時計をコンポジタに渡す(XIOS_MSG_PACING)。iosc はこれで
        // pacing=event-loop から vblank に切り替わる。記録は 250 ms で古くなる
        // (xios_surface.c XIOS_VBLANK_STALE_MS)ので毎フレーム送る。a は「送った時点から
        // 次の垂直同期までの µs」: draw は垂直同期で呼ばれるので、次までは 1 周期
        // (実機 2026-09-13: 60 フレームに 1 回 + 半周期では 1 秒ごとに event-loop へ落ちていた)
        do {
            let fps = max(view.preferredFramesPerSecond, 1)
            let interval = UInt32(1_000_000 / fps)
            _ = api.pacing(conn, Int32(interval), interval, 30_000, Int32(fps) * 1000)
        }

        // 面の読み取りと ack は読み取りスレッド(readerLoop / stageFrame)。ここは最新の複写を貼るだけ
        latestLock.lock()
        let l = latest
        latestLock.unlock()
        guard let pipeline = pipeline, let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor, let tex = l?.tex ?? current,
              let cb = queue.makeCommandBuffer() else {
            // 何も出ないまま黙るのが一番困る(実機 2026-09-12)。理由を 1 度だけ書く
            idleDraws += 1
            if idleDraws == 120 || idleDraws == 1800 {
                let why = pipeline == nil ? "pipeline が無い"
                    : (l?.tex ?? current) == nil ? "DIRTY が 1 件も来ていない(クライアントは居る?)"
                    : "drawable か command buffer が取れない"
                log.log("画面: \(idleDraws) 回空回り: \(why) dirty 累計 \(dirtyTotal) 面 \(api.count(conn)) 枚")
            }
            return
        }
        idleDraws = 0
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else {
            cb.commit()
            return
        }
        if let l = l {
            current = l.tex
            currentId = l.id
        }
        let vp = Self.aspectFit(content: CGSize(width: tex.width, height: tex.height),
                                into: view.drawableSize)
        lastViewport = vp   // タッチ座標を出力ピクセルに戻すのに使う
        enc.setViewport(vp)
        enc.setRenderPipelineState(pipeline)
        var flip = flipY
        enc.setVertexBytes(&flip, length: MemoryLayout<Float>.size, index: 0)
        enc.setFragmentTexture(tex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        // 実測時刻つきの PRESENTED(measured=1)は、新しい複写を初めて画面に出したときだけ
        if let l = l, l.seq != lastPresentedSeq {
            lastPresentedSeq = l.seq
            let seq = l.seq
            drawable.addPresentedHandler { [weak self] d in self?.reportPresented(seq, d) }
        }
        cb.commit()
        if !firstFrameLogged, let l = l {
            firstFrameLogged = true
            log.log("画面: 最初のフレームを描いた id=\(l.id) seq=\(l.seq) \(tex.width)x\(tex.height)")
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
        // 早い ack: iosc は「こちらが PRESENTED を返すまで」クライアントに次のフレームを描かせない
        // (wayland_iosc.c present_ack_timer_cb、100ms で諦める)。画面に出た瞬間(addPresentedHandler、
        // 垂直同期 1 回分あと)まで待って返すと 1 周が 45〜50ms になり、合成が毎秒 20 回で頭打ちだった
        // (実機 2026-09-14)。GPU がこの面の読み取りを終えた時点で返せば、その 1 回分が消える。
        // 実測時刻つきの ack(measured=1)は従来どおり表示後に別途送る(同じ seq の上書きは無害)
        if let last = batch.last {
            _ = api.presented(conn, last.seq, 0, 0)
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

/// タッチを拾って入力ソケットに流す MTKView。SwiftUI のジェスチャだと
/// 複数の指の追跡とスロットの対応が取りにくいので、素の touchesXxx を使う。
final class ScreenMTKView: MTKView, UIKeyInput {
    weak var client: ScreenClient?

    // iOS のキーボードの受け皿。文字は TEXT、改行と後退だけ KEY で送る
    // (keysym への対応表を持たずに済ませるため。第 6 節)
    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var keyboardType: UIKeyboardType {
        get { .asciiCapable }
        set { }
    }
    // osk-plan.md「Return と Tab は key、text ではない」: TEXT で送ると欄に改行の文字が
    // 入るだけで、決定にならない。塊ごとに TEXT と KEY に分けて送る
    func insertText(_ text: String) {
        var run = ""
        func flush() { if !run.isEmpty { client?.send(text: run); run = "" } }
        for ch in text {
            if ch.isNewline { flush(); client?.sendKey(0xff0d) }        // XK_Return
            else if ch == "\t" { flush(); client?.sendKey(0xff09) }      // XK_Tab
            else { run.append(ch) }
        }
        flush()
    }
    func deleteBackward() { client?.sendKey(0xff08) }                    // XK_BackSpace

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { client?.userOpenedKeyboard() }
        return ok
    }
    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { client?.userResignedKeyboard() }
        return ok
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        client?.send(touches: touches, phase: 1, in: self, event: event)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        client?.send(touches: touches, phase: 2, in: self, event: event)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        client?.send(touches: touches, phase: 0, in: self, event: event)
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        client?.send(touches: touches, phase: 3, in: self, event: event)
    }
}

struct ScreenView: UIViewRepresentable {
    let client: ScreenClient

    func makeUIView(context: Context) -> MTKView {
        let v = ScreenMTKView()
        v.client = client
        client.view = v
        v.isMultipleTouchEnabled = true
        client.attach(view: v)
        return v
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}

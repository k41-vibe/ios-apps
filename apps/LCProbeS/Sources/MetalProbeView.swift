import SwiftUI
import MetalKit
import IOSurface

// iosc と同じ経路の最小版: 別スレッドが IOSurface に絵を書き、Metal がそれをテクスチャとして画面に出す。
final class SurfaceProbe: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let surface: IOSurface
    let texture: MTLTexture
    var pipeline: MTLRenderPipelineState?
    let width = 512, height = 512
    private var frames = 0
    private var start = Date()
    private var reported = 0
    private var writerRunning = true
    private var writes = 0
    let log: ProbeLog

    init?(log: ProbeLog) {
        self.log = log
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            log.log("Metal device unavailable"); return nil
        }
        device = dev; queue = q
        let props: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: width * 4,
            .pixelFormat: UInt32(0x4247_5241) // 'BGRA'
        ]
        guard let s = IOSurface(properties: props) else { log.log("IOSurface create failed"); return nil }
        surface = s
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let tex = dev.makeTexture(descriptor: desc, iosurface: s, plane: 0) else {
            log.log("makeTexture(iosurface:) failed"); return nil
        }
        texture = tex
        super.init()
        let sid = IOSurfaceGetID(unsafeBitCast(s, to: IOSurfaceRef.self))
        log.log("IOSurface \(width)x\(height) ok, id \(sid), MTLTexture from IOSurface ok")
        startWriter()
    }

    private func startWriter() {
        let t = Thread { [weak self] in
            var tick: UInt32 = 0
            while let self = self, self.writerRunning {
                self.surface.lock(options: [], seed: nil)
                let stride = self.surface.bytesPerRow / 4
                let base = self.surface.baseAddress.assumingMemoryBound(to: UInt32.self)
                for y in 0..<self.height {
                    let g = UInt32((y * 255) / self.height)
                    for x in 0..<self.width {
                        let r = UInt32((x * 255) / self.width)
                        let b = (tick &* 3) & 0xff
                        base[y * stride + x] = 0xff00_0000 | (r << 16) | (g << 8) | b
                    }
                }
                self.surface.unlock(options: [], seed: nil)
                self.writes += 1
                tick &+= 1
                usleep(8000)
            }
        }
        t.name = "surface-writer"
        t.start()
    }

    func attach(view: MTKView) {
        view.device = device
        view.delegate = self
        view.preferredFramesPerSecond = 120
        view.colorPixelFormat = .bgra8Unorm
        var lib = device.makeDefaultLibrary()
        var how = "default.metallib"
        if lib == nil {
            how = "runtime source compile"
            lib = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        }
        guard let library = lib else { log.log("no Metal library (both paths failed)"); return }
        let pd = MTLRenderPipelineDescriptor()
        pd.vertexFunction = library.makeFunction(name: "probe_vertex")
        pd.fragmentFunction = library.makeFunction(name: "probe_fragment")
        pd.colorAttachments[0].pixelFormat = view.colorPixelFormat
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pd)
            log.log("pipeline ok via \(how)")
        } catch {
            log.log("pipeline failed via \(how): \(error)")
        }
        start = Date()
    }

    func stop() { writerRunning = false }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = pipeline, let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor, let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
        frames += 1
        let el = Date().timeIntervalSince(start)
        if el >= 3, reported == 0 || (el >= 6 && reported == 1) {
            reported += 1
            log.log("present \(String(format: "%.1f", Double(frames) / el)) fps, writer \(String(format: "%.1f", Double(writes) / el)) writes/s over \(Int(el)) s")
        }
    }

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 pos [[position]]; float2 uv; };
    vertex VOut probe_vertex(uint vid [[vertex_id]]) {
        float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
        VOut o; o.pos = float4(p[vid],0,1); o.uv = float2((p[vid].x+1)/2, 1-(p[vid].y+1)/2); return o;
    }
    fragment float4 probe_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear); return tex.sample(s, in.uv);
    }
    """
}

struct MetalProbeView: UIViewRepresentable {
    let probe: SurfaceProbe
    func makeUIView(context: Context) -> MTKView {
        let v = MTKView()
        probe.attach(view: v)
        return v
    }
    func updateUIView(_ uiView: MTKView, context: Context) {}
}

import Cocoa
import Metal
import MetalKit
import QuartzCore

// Native 120Hz Metal GPU Stress & Latency Benchmark for HyperDisplay
// Keys:
//   1 = High-Entropy Bandwidth Max-Out (Dynamic Noise + Fast Shader)
//   2 = UFO 120Hz vs 60Hz vs 30Hz Motion Clarity Test
//   3 = 120Hz High-Speed Game Simulation + 4:2:2 Chroma Text Sharpness Grid
//   4 = Glass-to-Glass Millisecond Latency Sync Stopwatch (Dual-Screen)
//   Space = Cycle modes, ESC / Q = Quit

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float time;
    uint frameIndex;
    uint mode;
    float aspect;
    float2 resolution;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut vertex_main(uint vid [[vertex_id]]) {
    float2 pos[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = (pos[vid] + 1.0) * 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

static inline uint pcg_hash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

static inline float3 hash3(uint2 p, uint frame) {
    uint h1 = pcg_hash(p.x ^ pcg_hash(p.y ^ pcg_hash(frame * 374761393u)));
    uint h2 = pcg_hash(h1 + 1013904223u);
    uint h3 = pcg_hash(h2 + 1664525u);
    return float3(float(h1 & 0xFFFFu), float(h2 & 0xFFFFu), float(h3 & 0xFFFFu)) / 65535.0;
}

fragment float4 fragment_main(VertexOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
    float2 uv = in.uv;
    uint2 px = uint2(uv * u.resolution);

    if (u.mode == 1) {
        // MODE 1: Extreme High-Entropy Bandwidth Saturator
        // Fine dynamic grain + moving interference waves so HEVC cannot compress across frames or space.
        uint2 cell = px / 2u; // 2x2 pixel grain survives scaling & maximally stresses HEVC encoder
        float3 n = hash3(cell, u.frameIndex);

        float wave1 = sin(uv.x * 90.0 + u.time * 18.0) * cos(uv.y * 70.0 - u.time * 14.0);
        float wave2 = sin((uv.x * u.aspect - 0.5) * 40.0 + u.time * 22.0);
        float3 rainbow = 0.5 + 0.5 * cos(float3(0.0, 2.094, 4.188) + u.time * 4.0 + wave1 * 2.5 + wave2);

        // Mix 70% temporal high-entropy color grain + 30% fast vivid waves
        float3 col = mix(rainbow, n, 0.72);

        // Moving 120Hz vertical tear/sync bar so you can also verify smooth 120fps motion
        float barX = fract(u.time * 0.9);
        if (abs(uv.x - barX) < 0.008) {
            col = float3(1.0, 1.0, 1.0);
        }
        return float4(col, 1.0);
    }

    if (u.mode == 2) {
        // MODE 2: Blur Busters Style 120Hz vs 60Hz vs 30Hz Comparison
        float3 bg = float3(0.06, 0.08, 0.12);
        // Subtle vertical grid lines every 40px
        if ((px.x % 40u) == 0u) bg += 0.05;

        // 3 lanes: top=120Hz (every frame), mid=60Hz (step 2), bot=30Hz (step 4)
        float lane = floor(uv.y * 3.0);
        float laneY = fract(uv.y * 3.0);

        // Separator lines
        if (laneY < 0.01 || laneY > 0.99) return float4(0.3, 0.35, 0.45, 1.0);

        uint effFrame = u.frameIndex;
        float3 accent = float3(0.15, 0.95, 0.45); // Green = 120Hz
        if (lane == 1.0) {
            effFrame = (u.frameIndex / 2u) * 2u;
            accent = float3(1.0, 0.75, 0.1); // Yellow = 60Hz
        } else if (lane == 2.0) {
            effFrame = (u.frameIndex / 4u) * 4u;
            accent = float3(1.0, 0.25, 0.3); // Red = 30Hz
        }

        // Fast horizontal motion: 1200 px/sec (10 px per 120Hz frame)
        float xPos = fract(float(effFrame) * 0.0065);
        float dx = uv.x - xPos;
        if (dx < -0.5) dx += 1.0;
        if (dx > 0.5) dx -= 1.0;

        float2 p = float2(dx * u.aspect, (laneY - 0.5) * 0.33);
        float dist = length(p);

        float3 col = bg;
        // High-contrast saucer + sharp vertical spokes inside to expose motion blur/judder
        if (dist < 0.095) {
            col = accent;
            // Crisp black/white checkerboard stripes inside target
            uint stripe = (uint(abs((p.x + 0.1) * 400.0)) / 4u) % 2u;
            if (abs(p.y) < 0.025) {
                col = stripe == 0u ? float3(1.0) : float3(0.02);
            }
            if (dist > 0.082) col = float3(1.0);
        }

        // Frame parity flash strip on the far right (toggles every single 120Hz frame)
        if (uv.x > 0.965 && lane == 0.0) {
            col = (u.frameIndex % 2u == 0u) ? float3(1.0, 1.0, 1.0) : float3(0.0, 0.0, 0.0);
        }
        return float4(col, 1.0);
    }

    if (u.mode == 3) {
        // MODE 3: 120Hz Fast Arcade/3D Tunnel Shader + Chroma 4:2:2 Sharpness Test Bar at bottom
        if (uv.y > 0.80) {
            // Bottom 20%: Chroma subsampling sharpness checker (Red/Blue & Magenta/Green 1px & 2px lines)
            float subX = uv.x;
            if (subX < 0.33) {
                bool odd = (px.x % 2u) == 0u;
                return float4(odd ? float3(1.0, 0.0, 0.0) : float3(0.0, 0.0, 1.0), 1.0);
            } else if (subX < 0.66) {
                bool odd = ((px.x + px.y) % 2u) == 0u;
                return float4(odd ? float3(1.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0), 1.0);
            } else {
                // Fine diagonal high-contrast moving lines
                bool line = ((px.x + px.y + u.frameIndex * 2u) % 6u) < 2u;
                return float4(line ? float3(1.0, 0.95, 0.2) : float3(0.08, 0.05, 0.25), 1.0);
            }
        }

        // Fast 120Hz pseudo-3D neon tunnel + orbiting glowing spheres
        float2 p = (uv - float2(0.5, 0.40)) * float2(u.aspect, 1.0) * 2.0;
        float r = max(0.02, length(p));
        float a = atan2(p.y, p.x);

        float tunnelZ = 1.2 / r + u.time * 4.5;
        float tunnelA = a * 6.0 / 3.14159265 + sin(u.time * 2.0) * 0.8;

        float grid = step(0.88, fract(tunnelZ)) + step(0.88, fract(tunnelA));
        float3 baseCol = 0.5 + 0.5 * cos(float3(0.0, 2.1, 4.2) + tunnelZ * 0.6 + u.time);
        float3 col = baseCol * (0.18 + 0.82 * clamp(grid, 0.0, 1.0)) * smoothstep(0.03, 0.25, r);

        // Add 6 fast orbiting neon orbs + high-frequency detail
        for (int i = 0; i < 6; i++) {
            float fi = float(i);
            float ang = u.time * (2.8 + fi * 0.45) + fi * 1.047;
            float rad = 0.25 + 0.28 * sin(u.time * 1.9 + fi);
            float2 center = float2(cos(ang), sin(ang)) * rad;
            float d = length(p - center);
            float glow = 0.014 / (d * d + 0.002);
            float3 orbCol = 0.5 + 0.5 * cos(float3(0.5, 2.5, 4.5) + fi * 1.2);
            col += orbCol * glow * 0.16;
        }
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // MODE 4: Glass-to-Glass Latency Visual Sweep + Frame Grid
    float3 col = float3(0.04, 0.05, 0.08);
    uint boxIdx = (u.frameIndex % 24u);
    float2 gridUV = float2(uv.x * 6.0, uv.y * 4.0);
    uint gx = uint(floor(gridUV.x));
    uint gy = uint(floor(gridUV.y));
    uint cellIdx = gy * 6u + gx;
    float2 local = fract(gridUV);
    if (local.x < 0.03 || local.x > 0.97 || local.y < 0.04 || local.y > 0.96) {
        return float4(0.25, 0.28, 0.35, 1.0);
    }
    if (cellIdx == boxIdx) {
        col = float3(0.1, 1.0, 0.45);
    } else if (((cellIdx + 24u - boxIdx) % 24u) == 23u) {
        col = float3(0.05, 0.35, 0.18);
    }
    return float4(col, 1.0);
}
"""

struct Uniforms {
    var time: Float
    var frameIndex: UInt32
    var mode: UInt32
    var aspect: Float
    var resolution: SIMD2<Float>
}

final class StressRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let pipelineState: MTLRenderPipelineState

    var mode: UInt32 = 1
    var startTime = CACurrentMediaTime()
    var frameIndex: UInt32 = 0
    var fpsCounter = 0
    var fpsLastCheck = CACurrentMediaTime()
    var currentFPS: Double = 0
    var onHUDUpdate: ((String) -> Void)?

    init?(mtkView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        mtkView.device = device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = 120
        mtkView.enableSetNeedsDisplay = false
        mtkView.isPaused = false

        do {
            let lib = try device.makeLibrary(source: metalShaderSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vertex_main")
            desc.fragmentFunction = lib.makeFunction(name: "fragment_main")
            desc.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
            self.pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            print("Metal compile error:", error)
            return nil
        }
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = commandQueue.makeCommandBuffer(),
              let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }

        let now = CACurrentMediaTime()
        let elapsed = now - startTime
        frameIndex &+= 1
        fpsCounter += 1

        let sz = view.drawableSize
        var uniforms = Uniforms(
            time: Float(elapsed),
            frameIndex: frameIndex,
            mode: mode,
            aspect: Float(sz.width / max(1.0, sz.height)),
            resolution: SIMD2<Float>(Float(sz.width), Float(sz.height))
        )

        enc.setRenderPipelineState(pipelineState)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()

        cmd.present(drawable)
        cmd.commit()

        if now - fpsLastCheck >= 0.25 {
            currentFPS = Double(fpsCounter) / (now - fpsLastCheck)
            fpsCounter = 0
            fpsLastCheck = now
            let ms = Int64(elapsed * 1000.0)
            let modeName: String
            switch mode {
            case 1: modeName = "[1] 极限高熵满带宽压测 (噪点+波形)"
            case 2: modeName = "[2] 120Hz(绿) vs 60Hz(黄) vs 30Hz(红) 流畅度对比"
            case 3: modeName = "[3] 120Hz 高速游戏场景 + 底部 4:2:2 彩字锐度"
            default: modeName = "[4] 毫秒级帧号同步延迟测试 (120Hz 24格扫频)"
            }
            let text = String(format: "%@  |  Render: %.1f FPS  |  Frame #%u  |  T = %02lld:%02lld.%03lld  |  [1-4切模式 / 空格 / ESC退出]",
                              modeName, currentFPS, frameIndex, (ms / 60000) % 60, (ms / 1000) % 60, ms % 1000)
            DispatchQueue.main.async { [weak self] in
                self?.onHUDUpdate?(text)
            }
        }
    }
}

final class StressWindow: NSWindow {
    var onKey: ((UInt16, String) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        onKey?(event.keyCode, event.charactersIgnoringModifiers ?? "")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windows: [StressWindow] = []
    var renderers: [StressRenderer] = []
    var labels: [NSTextField] = []
    var modeButtons: [[NSButton]] = []
    var currentMode: UInt32 = 1
    var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let screens = NSScreen.screens
        let dualMode = CommandLine.arguments.contains("--dual")
        var targetScreens: [NSScreen] = []

        if let hyper = screens.first(where: { $0.localizedName.contains("HyperDisplay") }) {
            targetScreens.append(hyper)
            if dualMode, let main = screens.first(where: { $0 != hyper }) {
                targetScreens.append(main)
            }
        } else if let main = screens.first {
            targetScreens.append(main)
        }

        if let modeArg = CommandLine.arguments.first(where: { $0.hasPrefix("--mode=") }),
           let m = UInt32(modeArg.replacingOccurrences(of: "--mode=", with: "")),
           (1...4).contains(m) {
            currentMode = m
        }

        for screen in targetScreens {
            createWindow(on: screen)
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            self?.handleKey(keyCode: ev.keyCode, chars: ev.charactersIgnoringModifiers ?? "")
            return nil
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow(on screen: NSScreen) {
        let win = StressWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        win.level = .floating
        win.setFrame(screen.frame, display: true)
        win.backgroundColor = .black

        let mtk = MTKView(frame: CGRect(origin: .zero, size: screen.frame.size))
        mtk.autoresizingMask = [.width, .height]

        guard let renderer = StressRenderer(mtkView: mtk) else { return }
        renderer.mode = currentMode
        mtk.delegate = renderer

        let hud = NSTextField(labelWithString: "Starting 120Hz Metal Stress Test...")
        hud.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
        hud.textColor = .white
        hud.backgroundColor = NSColor.black.withAlphaComponent(0.78)
        hud.drawsBackground = true
        hud.translatesAutoresizingMaskIntoConstraints = false

        // Clickable control bar (works with mouse or iPad touch directly)
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
        bar.layer?.cornerRadius = 10
        bar.translatesAutoresizingMaskIntoConstraints = false

        let titles: [(String, Int)] = [
            ("1: 极限满带宽", 1),
            ("2: 120Hz对比", 2),
            ("3: 3D游戏+锐度", 3),
            ("4: 延迟扫频", 4),
            ("退出测试", 99)
        ]
        var btns: [NSButton] = []
        for (title, tag) in titles {
            let b = NSButton(title: title, target: self, action: #selector(onButtonTap(_:)))
            b.tag = tag
            b.bezelStyle = .rounded
            b.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            bar.addArrangedSubview(b)
            if tag <= 4 { btns.append(b) }
        }
        modeButtons.append(btns)

        let container = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        container.addSubview(mtk)
        container.addSubview(hud)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            hud.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            hud.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            bar.topAnchor.constraint(equalTo: hud.bottomAnchor, constant: 10),
            bar.centerXAnchor.constraint(equalTo: container.centerXAnchor)
        ])

        renderer.onHUDUpdate = { [weak hud] text in
            hud?.stringValue = "  \(text)  "
        }

        win.contentView = container
        win.onKey = { [weak self] keyCode, chars in
            self?.handleKey(keyCode: keyCode, chars: chars)
        }
        win.makeKeyAndOrderFront(nil)

        windows.append(win)
        renderers.append(renderer)
        labels.append(hud)
        updateButtonHighlights()
    }

    @objc private func onButtonTap(_ sender: NSButton) {
        if sender.tag == 99 {
            NSApp.terminate(nil)
            return
        }
        setMode(UInt32(sender.tag))
    }

    private func handleKey(keyCode: UInt16, chars: String) {
        if keyCode == 53 || chars.lowercased() == "q" {
            NSApp.terminate(nil)
            return
        }
        switch chars {
        case "1": setMode(1)
        case "2": setMode(2)
        case "3": setMode(3)
        case "4": setMode(4)
        case " ": setMode((currentMode % 4) + 1)
        default: break
        }
    }

    private func setMode(_ m: UInt32) {
        currentMode = m
        for r in renderers { r.mode = m }
        updateButtonHighlights()
    }

    private func updateButtonHighlights() {
        for group in modeButtons {
            for b in group {
                b.contentTintColor = (UInt32(b.tag) == currentMode) ? .systemGreen : .white
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

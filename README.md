# HyperDisplay

**120Hz High-Bitrate USB-C Wired Extended Display for Mac → iPad Pro (M4 / M2 / M1)**

Turn your iPad Pro into a true **120Hz ProMotion**, **Display P3**, **HEVC 4:2:2 10-bit** wired secondary monitor over a single USB-C cable—bypassing Apple Sidecar's 60Hz cap without Wi-Fi, routers, or capture cards.

把 iPad Pro 通过一根 USB-C 数据线扩展为 Mac 的 **真 120Hz ProMotion 高刷、HEVC 4:2:2 10-bit、Display P3 广色域、超低延迟有线副屏**——无需 Wi-Fi、无需采集卡、无需关闭 SIP。

---

## Highlights / 核心特性

- **True 120Hz ProMotion over Single USB-C (`usbmuxd`)**: Connects directly through macOS `/var/run/usbmuxd` USB tunnel (`TCP_NODELAY`, zero-queueing latest-frame-wins scheduler with instant HEVC IDR recovery). Measured USB round-trip latency **0.6–1.8 ms** (~0.3–0.9 ms one-way).
- **M4 & M1 Auto-Adaptive Hardware Codecs**:
  - **M4 iPad Pro (`iPad16,*`)**: Automatically negotiates native resolution (e.g. `2420 × 1668 @ 120Hz`) with **HEVC 4:2:2 10-bit** (`kVTProfileLevel_HEVC_Main42210_AutoLevel`) for razor-sharp HiDPI text.
  - **M1 / M2 iPad Pro (`iPad13,*`, `iPad14,*`)**: Automatically negotiates native resolution (e.g. `2732 × 2048 @ 120Hz`) with **HEVC 4:2:0 10-bit** hardware decode.
- **Zero-Copy Display Pipeline**: `CGVirtualDisplay` → `ScreenCaptureKit` → `VideoToolbox` (M-series dedicated Media Engine) → `usbmuxd` → iPad `AVSampleBufferDisplayLayer` (`DisplayImmediately`, zero extra GPU shader copy).
- **macOS 27 Touchscreen Ergonomics + Apple Pencil Pro**:
  - Single-finger swipe = 120Hz inertia pixel-smooth scrolling; dwell-and-drag = window/text drag; long-press / 2-finger tap = right click; 2-finger pinch = zoom; 3-finger swipe up/left/right = Mission Control / Spaces.
  - Apple Pencil hover moves macOS cursor without mis-clicks; pen down/drag sends hardware pressure (`tabletEventPointPressure`); Apple Pencil Pro squeeze / Pencil 2 double-tap fires right click.
- **Native macOS Console & Menu Bar App**: Live FPS / Mbps / P50 & P95 encode latency / USB RTT / sparkline trends, one-click presets, and configurable HiDPI scaling (`1.0× / 1.15× / 1.30×`) and bitrate (`60–1000 Mbps`).

---

## Architecture / 架构总览

```text
[Mac - HyperDisplayMac (Swift / AppKit / SwiftUI)]
  1. CGVirtualDisplay       -> Registers 120Hz Display P3 HiDPI virtual monitor matching iPad pixels
  2. ScreenCaptureKit       -> Captures 120fps frames (10-bit ARGB2101010 / BGRA)
  3. VideoToolbox           -> Real-time hardware HEVC 4:2:2 10-bit / Main10 (no B-frames, speed priority)
  4. USBMuxClient           -> Direct /var/run/usbmuxd tunnel, latest-frame-wins + instant IDR recovery
          │
          ▼  Single USB-C 3.2 Gen 2 (10Gbps) Cable (RTT ~0.6–1.8 ms)
          │
[iPad Pro - HyperDisplayiPad (Swift / UIKit / AVFoundation)]
  5. USBServer              -> Local TCP listener (port 24120), reports model/pixels/120Hz/4:2:2 capability
  6. VideoDisplayView       -> AVSampleBufferDisplayLayer + DisplayImmediately + 120Hz CADisplayLink
  7. TouchOverlayView       -> Direct-touch gestures + Apple Pencil hover/pressure -> Mac CGEvent
```

---

## Measured Benchmarks / 真机实测数据

Tested on **Apple M4 Max MacBook Pro + M4 iPad Pro 11" (`2420 × 1668 @ 120Hz`)** over a 10Gbps USB-C cable using the bundled native Metal stress suite (`StressTest/HyperStress120.swift` & `StressTest/run_benchmark.py`):

| Scenario & Profile | Actual FPS | Throughput | Encode P50 / P95 | USB RTT | Dropped |
| :--- | :---: | :---: | :---: | :---: | :---: |
| 3D High-Speed Scene · `4:2:2 10b` · `260M` · Speed | **110.0 FPS** | **265.8 Mbps** | **9.30 / 9.88 ms** | 1.85 ms | **0** |
| Max-Entropy Noise · `4:2:0 10b` · `220M` · Speed | 83.0 FPS | 140.0 Mbps | **8.68 / 9.54 ms** | 1.06 ms | **0** |
| Max-Entropy Noise · `4:2:2 10b` · `220M` · Quality | 89.7 FPS | 147.9 Mbps | 30.59 / 32.19 ms | 0.77 ms | **0** |
| **14-Core CPU 100% Load** · `4:2:2 10b` · `400M` · Speed | 93.8 FPS | **300.7 Mbps** | **8.44 / 12.98 ms** | **0.63 ms** | **0** |
| **14-Core CPU 100% Load** · `4:2:2 10b` · `600M` · Speed | 81.2 FPS | **388.0 Mbps** | **9.26 / 13.60 ms** | 2.84 ms | **0** |

> Because Apple Silicon's VideoToolbox Media Engine is independent from CPU cores, even under **100% 14-core CPU saturation**, HyperDisplay sustains **300–388 Mbps**, **~8–9 ms encode latency**, and **zero dropped frames**.

---

## Quick Start / 编译与安装

### Requirements / 环境要求
- macOS 15.0+ (Apple Silicon recommended) with Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- iPad Pro with USB-C (iPadOS 17.0+, Developer Mode enabled)
- High-speed USB-C data cable (**USB 3.2 10Gbps / USB4 / Thunderbolt** recommended; avoid 480Mbps USB 2.0 charging cables)

### Build & Run / 步骤

1. **Configure local signing**
   ```bash
   cp Config/LocalSigning.xcconfig.example Config/LocalSigning.xcconfig
   # Edit Config/LocalSigning.xcconfig with your own Apple Team ID & Bundle ID prefix
   ```

2. **Generate Xcode project**
   ```bash
   xcodegen generate
   ```

3. **Install iPad app (`HyperDisplayiPad`)**
   - Open `HyperDisplay.xcodeproj` in Xcode.
   - Select scheme **`HyperDisplayiPad`** and your connected iPad Pro, then press **Cmd + R**.
   - On first install with a Personal Team, trust the profile on iPad under **Settings → General → VPN & Device Management**.

4. **Build & launch Mac app (`HyperDisplayMac`)**
   - Select scheme **`HyperDisplayMac`** and press **Cmd + R** (or copy the Release build to `/Applications/HyperDisplayMac.app`).
   - Grant **Screen Recording** (required) and **Accessibility** (for touch & Apple Pencil input) when prompted.
   - Disconnect Apple Sidecar if active, open **HyperDisplay** on iPad, and it will connect automatically.

---

## Touch & Apple Pencil Controls / 触控与笔手势

| Input | Action |
| :--- | :--- |
| Single tap / Double tap / Triple tap | Left click / Select word / Select paragraph |
| Single-finger slide | Natural pixel-smooth scroll with 120Hz inertia |
| Hold 0.22s (cyan ring) then drag / Double-tap-hold drag | Left-button drag (move windows, select text) |
| Long-press 0.55s (orange ring) or Two-finger tap | Right-click context menu |
| Two-finger pinch | Zoom (`Cmd +` / `Cmd -`) |
| Three-finger swipe up / left / right | Mission Control / Switch Desktop Spaces |
| Three-finger tap | Show / Hide floating telemetry pill HUD |
| Apple Pencil hover (M2/M4) | Move macOS cursor without clicking |
| Apple Pencil touch / drag | Precision click & drag with hardware pressure |
| Apple Pencil Pro squeeze / Pencil 2 double-tap | Right-click at hover position |

---

## Built-in 120Hz Metal Benchmark / 内置压测工具

```bash
swiftc -O -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
  StressTest/HyperStress120.swift -o StressTest/HyperStress120
./StressTest/HyperStress120 --mode=1

# Automated latency, bitrate, and CPU-load benchmark (via localhost:24121 API)
python3 StressTest/run_benchmark.py
```

---

## License

[MIT License](LICENSE)

import SwiftUI
import AppKit

@main
struct HyperDisplayMacApp: App {
    @StateObject private var controller = DisplayController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("HyperDisplay", id: "main") {
            ContentView(controller: controller)
                .frame(width: 580, height: 660)
                .onAppear {
                    controller.startService()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                if controller.isStreaming, let hello = controller.connectedHello {
                    Text("\(hello.chipLabel) · \(controller.activeResolutionLabel)")
                        .font(.headline)
                    Text(String(format: "%.0f FPS · %.1f Mbps · 编码 %.1f ms · RTT %.2f ms",
                                controller.actualFPS, controller.actualMbps, controller.p50EncodeMs, controller.usbRttMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text(controller.connectionStatus)
                }

                Divider()

                Button("⚡ 极速日常 (4:2:2 10b · 260M · 120Hz)") {
                    controller.applyPreset(codec: .hevc42210, bitrate: 260, fps: 120, speed: true)
                }
                Button("💎 极致画质 (4:2:2 10b · 420M · 120Hz)") {
                    controller.applyPreset(codec: .hevc42210, bitrate: 420, fps: 120, speed: true)
                }
                Button("🪶 M1 / 轻量 (4:2:0 10b · 180M · 120Hz)") {
                    controller.applyPreset(codec: .hevc10, bitrate: 180, fps: 120, speed: true)
                }

                Divider()

                Button("打开主控制台") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "main")
                }
                Button("系统显示器排列设置…") {
                    controller.openDisplaySettings()
                }

                Divider()

                Button("退出 HyperDisplay") {
                    controller.stopService()
                    NSApp.terminate(nil)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: controller.isStreaming ? "ipad.landscape" : "ipad.landscape.slash")
                if controller.isStreaming && controller.actualFPS > 0 {
                    Text("\(Int(controller.actualFPS))Hz")
                        .font(.caption.monospacedDigit())
                }
            }
        }
    }
}

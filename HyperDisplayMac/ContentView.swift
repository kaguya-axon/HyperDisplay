import SwiftUI

struct ContentView: View {
    @ObservedObject var controller: DisplayController
    @State private var showLogs = false
    @State private var showGestureGuide = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    heroHeaderCard

                    if !controller.screenRecordingGranted || !controller.accessibilityGranted {
                        permissionsCard
                    }

                    telemetrySection
                    presetsRow
                    settingsCard
                    collapsibleSections
                }
                .padding(.horizontal, 18)
                .padding(.top, 26)
                .padding(.bottom, 18)
            }
        }
    }

    // MARK: - Hero Status Card

    private var heroHeaderCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(statusColor.opacity(0.14))
                    .frame(width: 52, height: 52)
                Image(systemName: controller.isStreaming ? "ipad.landscape" : "cable.connector")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("HyperDisplay")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    statusPill
                }
                if let hello = controller.connectedHello, controller.isStreaming {
                    Text("\(hello.chipLabel) (\(hello.modelIdentifier)) · \(controller.activeResolutionLabel) · \(controller.activeCodecLabel)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(controller.connectionStatus)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                Button {
                    controller.openDisplaySettings()
                } label: {
                    Image(systemName: "rectangle.3.group")
                }
                .buttonStyle(.bordered)
                .help("打开 macOS 显示器排列设置")

                if controller.isStreaming {
                    Button {
                        controller.applySettingsAndRestartStream()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("重新应用并重连")
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(statusColor.opacity(0.28), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        if controller.isStreaming { return .green }
        if controller.usbDeviceCount > 0 { return .orange }
        return .secondary
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(controller.isStreaming ? "10Gbps USB 在线" : (controller.usbDeviceCount > 0 ? "等待 iPad 端" : "未连接"))
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(statusColor.opacity(0.14), in: Capsule())
        .foregroundStyle(statusColor)
    }

    // MARK: - Permissions Banner

    private var permissionsCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要系统权限才能开始投屏与触控")
                    .font(.subheadline.weight(.semibold))
                Text("首次授权屏幕录制后如未生效，请退出并重新打开应用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !controller.screenRecordingGranted {
                Button("授权屏幕录制") { controller.requestScreenRecordingPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if !controller.accessibilityGranted {
                Button("授权辅助功能") { controller.requestAccessibilityPermission() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Button { controller.refreshPermissions() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Telemetry Dashboard + Sparkline

    private var telemetrySection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                metricCard(
                    title: "实际帧率",
                    value: String(format: "%.0f", controller.actualFPS),
                    unit: "FPS",
                    tint: controller.actualFPS >= 100 ? .green : (controller.actualFPS > 0 ? .cyan : .secondary)
                )
                metricCard(
                    title: "USB 实时码率",
                    value: String(format: "%.1f", controller.actualMbps),
                    unit: "Mbps",
                    tint: .blue
                )
                metricCard(
                    title: "编码 P50 / P95",
                    value: String(format: "%.1f / %.1f", controller.p50EncodeMs, controller.p95EncodeMs),
                    unit: "ms",
                    tint: controller.p50EncodeMs <= 12 ? .green : (controller.p50EncodeMs <= 20 ? .orange : .red)
                )
                metricCard(
                    title: "USB 往返 RTT",
                    value: String(format: "%.2f", controller.usbRttMs),
                    unit: "ms",
                    tint: controller.usbRttMs <= 2.0 ? .green : .orange
                )
                metricCard(
                    title: "丢帧",
                    value: "\(controller.droppedFrames)",
                    unit: "frames",
                    tint: controller.droppedFrames == 0 ? .green : .orange
                )
            }

            if controller.fpsHistory.count > 2 {
                HStack(spacing: 12) {
                    sparklineView(
                        title: "FPS 趋势",
                        values: controller.fpsHistory,
                        maxVal: 125,
                        color: .green
                    )
                    sparklineView(
                        title: "编码延迟趋势 (ms)",
                        values: controller.encodeHistory,
                        maxVal: max(20, (controller.encodeHistory.max() ?? 20) * 1.2),
                        color: .cyan
                    )
                }
            }
        }
    }

    private func metricCard(title: String, value: String, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.75)
                    .lineLimit(1)
                Text(unit)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func sparklineView(title: String, values: [Double], maxVal: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Canvas { ctx, size in
                guard values.count > 1 else { return }
                var path = Path()
                let stepX = size.width / CGFloat(max(1, values.count - 1))
                for (idx, val) in values.enumerated() {
                    let x = CGFloat(idx) * stepX
                    let norm = min(1.0, max(0.0, val / max(1.0, maxVal)))
                    let y = size.height * (1.0 - CGFloat(norm))
                    if idx == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.8)
            }
            .frame(height: 28)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Quick Presets

    private var presetsRow: some View {
        HStack(spacing: 10) {
            presetButton(
                title: "极速日常",
                subtitle: "4:2:2 10b · 260M",
                icon: "bolt.fill",
                active: controller.preferredCodecMode == .hevc42210 && controller.bitrateMbps <= 300 && controller.prioritizeSpeed
            ) {
                controller.applyPreset(codec: .hevc42210, bitrate: 260, fps: 120, speed: true)
            }

            presetButton(
                title: "极致锐利",
                subtitle: "4:2:2 10b · 420M",
                icon: "sparkles",
                active: controller.preferredCodecMode == .hevc42210 && controller.bitrateMbps > 300
            ) {
                controller.applyPreset(codec: .hevc42210, bitrate: 420, fps: 120, speed: true)
            }

            presetButton(
                title: "M1 / 轻量",
                subtitle: "4:2:0 10b · 180M",
                icon: "leaf.fill",
                active: controller.preferredCodecMode == .hevc10
            ) {
                controller.applyPreset(codec: .hevc10, bitrate: 180, fps: 120, speed: true)
            }
        }
    }

    private func presetButton(title: String, subtitle: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(active ? .white : .accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption2.monospacedDigit())
                        .opacity(0.8)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .foregroundStyle(active ? .white : .primary)
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(active ? Color.clear : Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settings Card

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("显示与编码参数")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 11) {
                settingRow(label: "编码画质") {
                    Picker("", selection: $controller.preferredCodecMode) {
                        ForEach(CodecProfileMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: controller.preferredCodecMode) { _, _ in
                        controller.autoMatchDeviceCodec = false
                        controller.reconfigureEncoderInPlace()
                    }
                }

                settingRow(label: "编码策略") {
                    Toggle("速度优先（实测编码延迟 8–9 ms，推荐常开）", isOn: $controller.prioritizeSpeed)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .onChange(of: controller.prioritizeSpeed) { _, _ in
                            controller.reconfigureEncoderInPlace()
                        }
                }

                settingRow(label: "刷新率") {
                    Picker("", selection: $controller.targetFPS) {
                        Text("120 Hz (ProMotion)").tag(120)
                        Text("60 Hz").tag(60)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: controller.targetFPS) { _, _ in
                        controller.applySettingsAndRestartStream()
                    }
                }

                settingRow(label: "HiDPI 视野") {
                    Picker("", selection: $controller.scaleMultiplier) {
                        Text("1.0× 原生 Retina").tag(1.0)
                        Text("1.15× 更多空间").tag(1.15)
                        Text("1.30× 超大视野").tag(1.30)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: controller.scaleMultiplier) { _, _ in
                        controller.applySettingsAndRestartStream()
                    }
                }

                settingRow(label: "目标码率") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(controller.bitrateMbps) },
                                set: { controller.updateLiveBitrate(Int($0)) }
                            ),
                            in: 60...1000,
                            step: 20
                        )
                        Text("\(controller.bitrateMbps) Mbps")
                            .font(.callout.monospacedDigit().weight(.semibold))
                            .frame(width: 82, alignment: .trailing)
                    }
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private func settingRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Collapsible Guide & Logs

    private var collapsibleSections: some View {
        VStack(spacing: 10) {
            DisclosureGroup(isExpanded: $showGestureGuide) {
                VStack(alignment: .leading, spacing: 6) {
                    guideLine("单指轻点 / 双击 / 三击", "左键单击 / 选词 / 选段")
                    guideLine("单指滑动", "自然像素级惯性滚动 (120Hz)")
                    guideLine("按住停顿 0.22s 再拖", "拖拽窗口或框选文字 (青色光圈)")
                    guideLine("原地长按 0.55s / 双指轻点", "弹出右键菜单 (橙色光圈)")
                    guideLine("双指捏合 / 三指上滑 / 三指左右滑", "缩放 / 调度中心 / 切换桌面空间")
                    guideLine("三指轻点", "显示或隐藏 iPad 顶部状态胶囊")
                    guideLine("Apple Pencil", "悬停移动光标 · 落笔压感拖拽 · 捏合/双击=右键")
                }
                .padding(.top, 8)
            } label: {
                Label("触控与 Apple Pencil 手势速查", systemImage: "hand.point.up.left.fill")
                    .font(.subheadline.weight(.medium))
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            DisclosureGroup(isExpanded: $showLogs) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(controller.logs.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
                .padding(.top, 6)
            } label: {
                Label("连接与编码日志 (\(controller.logs.count))", systemImage: "terminal")
                    .font(.subheadline.weight(.medium))
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func guideLine(_ gesture: String, _ desc: String) -> some View {
        HStack {
            Text(gesture)
                .font(.caption.weight(.semibold))
                .frame(width: 195, alignment: .leading)
            Text(desc)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

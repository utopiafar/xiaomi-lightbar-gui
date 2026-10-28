import SwiftUI
import AppKit

final class LampModel: ObservableObject {
    @Published var ports: [String] = []
    @Published var selectedPort = ""
    @Published var connected = false
    @Published var connecting = false
    @Published var scanning = false
    @Published var pairing = false
    @Published var showPairing = false
    @Published var showDeviceSettings = false
    @Published var remoteID: String?
    @Published var status = "正在查找 USB 设备…"
    @Published var brightnessLevel = 7.0
    @Published var temperatureLevel = 7.0
    @Published var brightnessSet = false
    @Published var temperatureSet = false

    private let queue = DispatchQueue(label: "lightbar.serial")
    private let bridge = SerialBridge()
    private let cancellation = ScanCancellation()
    private var pendingBrightness: Int?
    private var pendingTemperature: Int?
    private var sliderScheduled = false
    private var sliderInFlight = false
    private var stopped = false
    var canControl: Bool { connected && remoteID != nil && !scanning && !pairing }

    func refreshPorts() {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        ports = entries.filter { $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.wchusbserial") }
            .sorted().map { "/dev/" + $0 }
        if !ports.contains(selectedPort) { selectedPort = ports.first ?? "" }
        if ports.isEmpty { status = "没有找到 USB 设备。请插入 RF-Nano 后点击连接。" }
    }

    func connect() {
        guard !connected && !connecting else { return }
        refreshPorts()
        guard !selectedPort.isEmpty else { return }
        let port = selectedPort
        connecting = true
        remoteID = nil
        status = "正在连接 USB 模块…"
        queue.async {
            do {
                let id = try self.bridge.connect(port)
                DispatchQueue.main.async {
                    self.connecting = false
                    self.connected = true
                    self.remoteID = id
                    if id == nil { self.scan() }
                    else { self.status = "USB 模块已连接，可以操作挂灯。" }
                }
            } catch { self.report(error) }
        }
    }

    private func report(_ error: Error) {
        bridge.close()
        DispatchQueue.main.async {
            self.connecting = false
            self.connected = false
            self.scanning = false
            self.pairing = false
            self.pendingBrightness = nil
            self.pendingTemperature = nil
            self.sliderInFlight = false
            self.status = "连接失败：" + error.localizedDescription
        }
    }

    func scan() {
        guard connected && !pairing else { return }
        if scanning {
            cancellation.set(true)
            status = "正在停止读取…"
            return
        }
        cancellation.set(false)
        pendingBrightness = nil
        pendingTemperature = nil
        scanning = true
        status = "正在监听原遥控器，正常使用一次即可尝试读取。"
        queue.async {
            do {
                let id = try self.bridge.scan(cancel: self.cancellation)
                let cancelled = self.cancellation.get()
                DispatchQueue.main.async {
                    self.scanning = false
                    if self.pairing { return }
                    if let id = id {
                        self.remoteID = id
                        self.status = "已读取并保存遥控器编号，可以测试挂灯。"
                    } else if cancelled {
                        self.status = "已停止读取遥控器。"
                    } else {
                        self.status = "未读到遥控器，请靠近模块并再试一次。"
                    }
                }
            } catch { self.report(error) }
        }
    }

    func pair() {
        guard connected && !pairing else { return }
        cancellation.set(true)
        pairing = true
        pendingBrightness = nil
        pendingTemperature = nil
        status = "正在发送配对指令…"
        let value = UInt32.random(in: 1...0xFFFFFE)
        let id = String(format: "%02X:%02X:%02X", (value >> 16) & 0xFF,
                        (value >> 8) & 0xFF, value & 0xFF)
        queue.async {
            do {
                try self.bridge.pair(id: id)
                DispatchQueue.main.async {
                    self.remoteID = id
                    self.scanning = false
                    self.pairing = false
                    self.status = "配对指令已发送；请确认挂灯是否闪烁，再试开关。"
                }
            } catch { self.report(error) }
        }
    }

    func send(_ command: String) {
        guard canControl else { return }
        status = "正在发送控制指令…"
        queue.async {
            do {
                try self.bridge.send(command)
                DispatchQueue.main.async { self.status = "指令已发送，请观察挂灯是否有变化。" }
            } catch { self.report(error) }
        }
    }

    func setBrightness(_ value: Double) {
        guard canControl else { return }
        let level = min(15, max(0, Int(value.rounded())))
        brightnessLevel = Double(level)
        brightnessSet = true
        pendingBrightness = level
        scheduleSliderUpdate()
    }

    func setTemperature(_ value: Double) {
        guard canControl else { return }
        let level = min(15, max(0, Int(value.rounded())))
        temperatureLevel = Double(level)
        temperatureSet = true
        pendingTemperature = level
        scheduleSliderUpdate()
    }

    private func scheduleSliderUpdate() {
        guard canControl && !stopped && !sliderScheduled && !sliderInFlight else { return }
        guard pendingBrightness != nil || pendingTemperature != nil else { return }
        sliderScheduled = true
        // Coalesce fast pointer movements. Only the latest position for each
        // control is sent, including the final position after dragging stops.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            self.sliderScheduled = false
            guard self.canControl && !self.stopped && !self.sliderInFlight else { return }
            let level: Int
            let commandByte: UInt8
            if let pending = self.pendingBrightness {
                level = pending
                commandByte = 0x04
                self.pendingBrightness = nil
            } else if let pending = self.pendingTemperature {
                level = pending
                commandByte = 0x02
                self.pendingTemperature = nil
            } else { return }
            self.sliderInFlight = true
            self.status = "正在调整挂灯…"
            self.queue.async {
                do {
                    try self.bridge.setLevel(level, commandByte: commandByte)
                    DispatchQueue.main.async {
                        self.sliderInFlight = false
                        guard self.canControl && !self.stopped else { return }
                        if self.pendingBrightness != nil || self.pendingTemperature != nil {
                            self.scheduleSliderUpdate()
                        } else {
                            self.status = "目标已发送，请观察挂灯的变化。"
                        }
                    }
                } catch { self.report(error) }
            }
        }
    }

    func stop() {
        stopped = true
        pendingBrightness = nil
        pendingTemperature = nil
        cancellation.set(true)
        queue.async { self.bridge.close() }
    }
}

private let lampAccent = Color(red: 0.90, green: 0.56, blue: 0.24)

struct PowerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Color.white)
            .frame(width: 44, height: 44)
            .background(
                Circle().fill(LinearGradient(
                    colors: [Color(red: 0.97, green: 0.70, blue: 0.38),
                             Color(red: 0.85, green: 0.45, blue: 0.21)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .overlay(Circle().strokeBorder(Color.white.opacity(0.22), lineWidth: 1))
            .shadow(color: lampAccent.opacity(configuration.isPressed ? 0.12 : 0.25), radius: 6, y: 3)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LampSlider: View {
    let title: String
    let icon: String
    let minimum: String
    let maximum: String
    let value: Binding<Double>
    let hasTarget: Bool
    let enabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .foregroundStyle(lampAccent)
                    .frame(width: 16)
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(hasTarget ? "目标 \(Int(value.wrappedValue) + 1) / 16" : "拖动设置")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...15, step: 1)
                .tint(lampAccent)
                .accessibilityLabel(title)
            HStack {
                Text(minimum)
                Spacer()
                Text(maximum)
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .disabled(!enabled)
    }
}

struct LampView: View {
    @ObservedObject var model: LampModel

    private var connectionText: String {
        if model.connecting { return "正在连接" }
        if model.scanning { return "正在读取遥控器" }
        if model.connected && model.remoteID != nil { return "已连接" }
        if model.connected { return "等待遥控器编号" }
        return "设备未连接"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "lamp.desk.fill")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(lampAccent)
                    .frame(width: 38, height: 38)
                    .background(lampAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("屏幕挂灯").font(.system(size: 15, weight: .semibold))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.canControl ? Color.green : Color.secondary.opacity(0.6))
                            .frame(width: 6, height: 6)
                        Text(connectionText).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { model.send("ON") } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(PowerButtonStyle())
                .disabled(!model.canControl)
                .opacity(model.canControl ? 1 : 0.45)
                .accessibilityLabel("切换挂灯开关")
                .help("切换挂灯开关")
            }

            if !model.canControl {
                Text(model.status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }

            Divider().padding(.vertical, 16)

            VStack(spacing: 19) {
                LampSlider(title: "亮度", icon: "sun.max.fill", minimum: "最暗", maximum: "最亮",
                           value: Binding(get: { model.brightnessLevel }, set: { model.setBrightness($0) }),
                           hasTarget: model.brightnessSet, enabled: model.canControl)
                LampSlider(title: "色温", icon: "thermometer.medium", minimum: "暖", maximum: "冷",
                           value: Binding(get: { model.temperatureLevel }, set: { model.setTemperature($0) }),
                           hasTarget: model.temperatureSet, enabled: model.canControl)
            }

            Text("滑块显示设置目标，遥控器调整不会同步显示。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Divider().padding(.vertical, 14)
            DisclosureGroup("设备与配对", isExpanded: $model.showDeviceSettings) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Picker("USB 设备", selection: $model.selectedPort) {
                            if model.ports.isEmpty { Text("未找到设备").tag("") }
                            ForEach(model.ports, id: \.self) { port in Text(port).tag(port) }
                        }.labelsHidden().disabled(model.connected || model.connecting)
                        Button("连接") { model.connect() }.disabled(model.connected || model.connecting)
                    }
                    Text(model.remoteID.map { "遥控编号：\($0)" } ?? "尚未设置遥控编号")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Button(model.scanning ? "停止读取" : "读取遥控器") { model.scan() }
                            .disabled(!model.connected || model.pairing)
                        Button("配对电脑…") { model.showPairing = true }
                            .disabled(!model.connected || model.pairing)
                    }
                    Text("读取时将遥控器放在 USB 模块附近，按压或转动一次。")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }
            .font(.system(size: 11))
            .alert("配对电脑控制", isPresented: $model.showPairing) {
                Button("取消", role: .cancel) { }
                Button("发送配对") { model.pair() }
            } message: {
                Text("保持 RF-Nano 插在电脑上。先拔掉挂灯的电源，再接回电源，然后在 10 秒内点击“发送配对”。挂灯闪烁表示配对成功。\n\n配对电脑后，原遥控器会暂时无法直接控制挂灯。让挂灯重新与原遥控器配对即可恢复，但电脑需要再次配对或读取遥控器编号。")
            }

            HStack {
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 11))
            }
            .padding(.top, 12)
        }
        .padding(18)
        .frame(width: 344)
        .onAppear { model.refreshPorts(); model.connect() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LampModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.refreshPorts()
        model.connect()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

@main
struct LampApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("小米挂灯控制") {
            LampView(model: delegate.model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra("小米挂灯", systemImage: "lightbulb.fill") {
            LampView(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

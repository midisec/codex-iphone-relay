import Foundation
import AppKit
import SwiftUI
import CoreImage
import Network
import BridgeCore

let args = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }; return args[i + 1]
}
let configPath = option("--config") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-3/bridge.json").path
let gui = !args.contains("--headless")

final class RelayWindowModel: ObservableObject {
    @Published var selection = ConnectionMode.combined
    @Published var enabled = true
    @Published var ready = false
    @Published var active = 0
    @Published var channel = ""
    @Published var detail = "等待连接"
    @Published var pending = false
    @Published var apiState = APISettingsState()
    @Published var apiSync = "待连接同步"
    @Published var apiBase = ""
    @Published var apiModel = ""
    var title: String { !enabled ? "已停止" : (ready ? (active > 0 ? "正在转发" : "已连接") : "等待 iPhone") }
    var subtitle: String {
        if pending { return "本轮结束后切换" }
        if !enabled { return "连接已暂停" }
        if ready { return active > 0 ? "\(channel) · \(active) 个请求" : channel }
        if detail.contains("权限") || detail.contains("开启 Mac 蓝牙") { return detail }
        return selection == .usb ? "连接数据线并开启手机转发" : "在手机上开启转发"
    }
}

struct RelayWindow: View {
    @ObservedObject var model: RelayWindowModel
    let config: BridgeConfiguration
    let selectMode: (ConnectionMode) -> Void
    let toggle: () -> Void
    let saveAPI: (APIConfigurationDraft?, APISelection) throws -> Bool
    @State private var pairing = false
    @State private var details = false
    @State private var apiSettings = false
    @State private var copied = false
    private var card: Color { Color(nsColor: .controlBackgroundColor) }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.triangle.swap").font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.accentColor).frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                Text("Codex Relay").font(.system(size: 25, weight: .semibold))
                Spacer()
                Button { apiSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 19))
                }.buttonStyle(.plain).foregroundColor(.secondary)
                    .help("API 配置").accessibilityLabel("API 配置").accessibilityIdentifier("api-settings")
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("连接方式").font(.subheadline).foregroundColor(.secondary)
                HStack(spacing: 8) {
                    ForEach(ConnectionMode.allCases) { mode in
                        Button { selectMode(mode) } label: {
                            VStack(spacing: 10) {
                                Image(systemName: mode.symbol).font(.system(size: 21, weight: .medium))
                                Text(mode.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            }.frame(maxWidth: .infinity).frame(height: 82)
                                .foregroundColor(model.selection == mode ? .accentColor : .primary)
                                .background(model.selection == mode ? Color.accentColor.opacity(0.1) : card,
                                            in: RoundedRectangle(cornerRadius: 14))
                                .overlay(RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(model.selection == mode ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: 1))
                        }.buttonStyle(.plain).accessibilityLabel(mode.title).accessibilityIdentifier("mode-" + mode.rawValue)
                            .accessibilityValue(model.selection == mode ? "已选择" : "未选择")
                    }
                }
                Text(model.selection.caption).font(.caption).foregroundColor(.secondary)
            }
            HStack(spacing: 16) {
                Image(systemName: model.ready ? "checkmark.circle.fill" : (model.enabled ? "iphone" : "pause.circle"))
                    .font(.system(size: 32)).foregroundColor(model.ready ? .green : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.title).font(.system(size: 20, weight: .semibold))
                    Text(model.subtitle).font(.subheadline).foregroundColor(.secondary).lineLimit(2)
                }
                Spacer()
                if model.active > 0 { ProgressView().controlSize(.small) }
            }.padding(20).frame(maxWidth: .infinity, minHeight: 100, alignment: .leading)
                .background(card, in: RoundedRectangle(cornerRadius: 18))
            Button(action: toggle) {
                Label(model.enabled ? "停止转发" : "开始转发", systemImage: model.enabled ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 44)
                    .foregroundColor(model.enabled ? .primary : .white)
                    .background(model.enabled ? Color.primary.opacity(0.07) : Color.accentColor,
                                in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain).accessibilityLabel(model.enabled ? "停止转发" : "开始转发").accessibilityIdentifier("toggle-relay")
            HStack {
                Button("配对 iPhone") { pairing = true }.buttonStyle(.link).accessibilityLabel("配对 iPhone")
                Spacer()
                Button("连接详情") { details = true }.buttonStyle(.link).foregroundColor(.secondary).accessibilityLabel("连接详情")
            }.font(.subheadline)
        }.padding(28).frame(width: 520).background(Color(nsColor: .windowBackgroundColor))
            .sheet(isPresented: $pairing) {
                VStack(spacing: 20) {
                    Text("配对 iPhone").font(.title2.weight(.semibold))
                    Image(nsImage: pairingImage()).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(12).background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityLabel("配对二维码")
                    Text("在手机上扫描二维码").font(.subheadline).foregroundColor(.secondary)
                    HStack(spacing: 16) {
                        Button(copied ? "已复制" : "复制配对码") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(config.pairingToken, forType: .string)
                            copied = true
                        }
                        Button("完成") { pairing = false; copied = false }.keyboardShortcut(.defaultAction)
                    }
                }.padding(28).frame(width: 330)
            }
            .sheet(isPresented: $details) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("连接详情").font(.title2.weight(.semibold))
                    LabeledContent("本地地址", value: "127.0.0.1:\(config.port)")
                    LabeledContent("模型", value: model.apiModel)
                    LabeledContent("状态", value: model.detail)
                    HStack { Spacer(); Button("完成") { details = false }.keyboardShortcut(.defaultAction) }
                }.padding(28).frame(width: 370)
            }
            .sheet(isPresented: $apiSettings) {
                APISettingsView(model: model, save: saveAPI)
            }
    }
    private func pairingImage() -> NSImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data("codex-ble://pair?token=\(config.pairingToken)".utf8), forKey: "inputMessage")
        let image = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 7, y: 7))
        return NSImage(cgImage: CIContext().createCGImage(image, from: image.extent)!, size: NSSize(width: 220, height: 220))
    }
}

struct APISettingsView: View {
    @ObservedObject var model: RelayWindowModel
    let save: (APIConfigurationDraft?, APISelection) throws -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var key = ""
    @State private var modelName = ""
    @State private var selection = APISelection.automatic
    @State private var original: APICredentials?
    @State private var error: String?
    @State private var saved: String?
    private var fieldsChanged: Bool { baseURL != (original?.baseURL ?? "") || modelName != (original?.model ?? "") || !key.isEmpty }
    private var changed: Bool { fieldsChanged || selection != model.apiState.selection }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("API 配置").font(.title2.weight(.semibold))
            Picker("配置来源", selection: $selection) {
                ForEach(APISelection.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityLabel("配置来源")
            HStack {
                Text("当前使用：" + (model.apiState.effectiveOrigin?.title ?? "未设置"))
                Spacer(); Text(model.apiSync)
            }.font(.caption).foregroundColor(.secondary)
            Divider()
            Text("电脑端配置").font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("API 地址").font(.subheadline)
                TextField("https://api.example.com/v1", text: $baseURL)
                    .accessibilityLabel("API 地址").accessibilityIdentifier("api-base-url")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("API 密钥").font(.subheadline)
                SecureField("留空保留已有密钥", text: $key)
                    .accessibilityLabel("API 密钥").accessibilityIdentifier("api-key")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("模型").font(.subheadline)
                TextField("模型名称", text: $modelName)
                    .accessibilityLabel("模型").accessibilityIdentifier("api-model")
            }
            if let error { Text(error).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            if let saved, !changed { Label(saved, systemImage: "checkmark.circle.fill").font(.caption).foregroundColor(.green) }
            HStack {
                Spacer()
                Button(saved == nil ? "取消" : "完成") { key = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        let draft = fieldsChanged ? APIConfigurationDraft(baseURL: baseURL, apiKey: key, model: modelName) : nil
                        let modelChanged = try save(draft, selection)
                        load(); error = nil
                        saved = modelChanged ? "已保存；新会话使用新模型" : "已保存"
                    } catch { self.error = error.localizedDescription; saved = nil }
                }.keyboardShortcut(.defaultAction).disabled(!changed).accessibilityIdentifier("save-api-settings")
            }
        }.textFieldStyle(.roundedBorder).autocorrectionDisabled(true).padding(28).frame(width: 440)
            .onAppear { load() }
            .onChange(of: selection) { _ in error = nil }
            .onChange(of: baseURL) { _ in error = nil }
            .onChange(of: key) { _ in error = nil }
            .onChange(of: modelName) { _ in error = nil }
    }
    private func load() {
        original = model.apiState.computer?.credentials ?? model.apiState.effective
        baseURL = original?.baseURL ?? ""; modelName = original?.model ?? ""; key = ""; selection = model.apiState.selection
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var configuration: BridgeConfiguration!
    var proxy: LocalProxy!
    var apiCoordinator: APISettingsCoordinator?
    var bluetooth: BluetoothCentral?
    var testTransport: TCPTransport?
    var usb: USBConnector?
    var usbActive = false
    var usbStatus = "尚未连接"
    var mode = ConnectionMode.combined
    var modeTimer: Timer?
    var transportGeneration = 0
    var window: NSWindow?
    let ui = RelayWindowModel()
    func applicationDidFinishLaunching(_ notification: Notification) { launch() }
    func launch() {
        do {
            if let path = option("--link-trace") { try LinkTrace.start(path: path) }
            let config = try BridgeConfiguration.read(configPath)
            configuration = config; ui.apiBase = config.upstreamBase; ui.apiModel = config.model
            let testPort = option("--test-relay-port").flatMap(UInt16.init)
            proxy = LocalProxy(config: config, transportLabel: testPort == nil ? "bluetooth-l2cap" : "test-tcp")
            proxy.diagnosticUploadWindow = option("--bluetooth-upload-window").flatMap(Int.init) ?? BridgeProtocol.responseWindow
            if testPort == nil || config.apiSettings != nil {
                let settings = APISettingsCoordinator(origin: .computer, state: APISettingsState.importing(config)) { [weak self] state in
                    guard let self else { throw BridgeError.invalid("App 已退出") }
                    let updated = try APIConfigurationStore.save(state, current: self.configuration, at: configPath)
                    self.configuration = updated
                    self.proxy.applySynchronizedConfiguration(updated)
                }
                apiCoordinator = settings; ui.apiState = settings.state
                settings.onChange = { [weak self] state in
                    self?.ui.apiState = state
                    self?.ui.apiBase = state.effective?.baseURL ?? ""
                    self?.ui.apiModel = state.effective?.model ?? ""
                }
                settings.onStatus = { [weak self] in self?.ui.apiSync = $0 }
                proxy.synchronize(using: settings)
            }
            proxy.onStatus = { [weak self] status in self?.refreshUI(); print(status); fflush(stdout) }
            proxy.additionalDiagnostics = { [weak self] in
                ["background_wake_ready": self?.bluetooth?.wakeReady ?? false,
                 "background_wake_error": self?.bluetooth?.lastWakeError ?? "",
                 "usb_status": self?.usbStatus ?? "", "transport_mode": self?.mode.rawValue ?? "",
                 "relay_enabled": self?.ui.enabled ?? false,
                 "bluetooth_enabled": self?.bluetooth != nil, "usb_enabled": self?.usb != nil]
            }
            try proxy.start()
            mode = ConnectionMode(rawValue: option("--transport") ?? UserDefaults.standard.string(forKey: "transportMode") ?? "auto") ?? .combined
            ui.selection = mode
            if gui { showWindow(config) }
            configureTransports()
        } catch {
            fputs("Codex Relay: \(error.localizedDescription)\n", stderr)
            if gui { let alert = NSAlert(); alert.messageText = "无法启动转发"; alert.informativeText = error.localizedDescription; alert.runModal() }
            exit(1)
        }
    }
    func refreshUI() {
        ui.ready = proxy.ready; ui.active = proxy.activeRequestCount; ui.detail = proxy.status
        ui.channel = proxy.transportLabel == "usb-usbmux" ? "Type-C" : "蓝牙"
    }
    func stopTransports() {
        transportGeneration += 1
        testTransport?.close("连接已关闭"); testTransport = nil
        usb?.onTransport = nil; usb?.onStatus = nil; usb?.stop(); usb = nil
        bluetooth?.onTransport = nil; bluetooth?.onStatus = nil; bluetooth?.stop(); bluetooth = nil
        usbActive = false; usbStatus = "已停止"
    }
    func configureTransports() {
        stopTransports()
        guard ui.enabled else { proxy.setStatus("已停止"); return }
        let generation = transportGeneration
        proxy.setStatus("等待连接")
        if let port = option("--test-relay-port").flatMap(UInt16.init) {
            let transport = TCPTransport(NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp))
            testTransport = transport
            transport.start { [weak self] in
                guard let self, self.transportGeneration == generation else { return }
                self.proxy.attach(transport, label: "test-tcp")
            }
            return
        }
        if mode.usesBluetooth {
            let bluetooth = BluetoothCentral()
            bluetooth.streamWriteSize = option("--bluetooth-write-size").flatMap(Int.init) ?? 16_384; self.bluetooth = bluetooth
            bluetooth.onStatus = { [weak self] status in
                guard let self, self.transportGeneration == generation, !self.usbActive else { return }
                self.proxy.setStatus(status)
            }
            bluetooth.onTransport = { [weak self] transport in
                guard let self, self.transportGeneration == generation, !self.usbActive else { transport.close("连接已切换"); return }
                self.proxy.attach(transport, label: "bluetooth-l2cap")
            }
            bluetooth.start()
        }
        if mode.usesUSB {
            let usb = USBConnector(); self.usb = usb
            usb.onPrepareConnection = { [weak self] in self?.bluetooth?.wake(rebuildUSBListener: true) }
            usb.onStatus = { [weak self] status in
                guard let self, self.transportGeneration == generation else { return }; self.usbStatus = status
                if self.mode == .usb, !self.usbActive { self.proxy.setStatus(status) }
            }
            usb.onTransport = { [weak self] transport in
                guard let self, self.transportGeneration == generation else { transport.close("连接已切换"); return }
                guard self.proxy.activeRequestCount == 0 else { transport.close("等待当前请求完成"); return }
                self.usbActive = true; self.usbStatus = "Type-C 已连接"
                self.bluetooth?.stop(); self.bluetooth?.controlOnly = true; self.bluetooth?.start()
                transport.onSend = { [weak self] type in
                    if ["hello", "authenticate", "request", "benchmark", "ping"].contains(type) { self?.bluetooth?.wake() }
                }
                self.proxy.attach(transport, label: "usb-usbmux")
                let previous = transport.onClose
                transport.onClose = { [weak self] reason in
                    previous?(reason)
                    guard let self, self.transportGeneration == generation, self.usbActive else { return }
                    self.usbActive = false; self.usbStatus = reason
                    if self.mode == .combined { self.bluetooth?.stop(); self.bluetooth?.controlOnly = false; self.bluetooth?.start() }
                }
            }
            usb.start()
        }
    }
    func changeMode(_ selected: ConnectionMode) {
        ui.selection = selected; UserDefaults.standard.set(selected.rawValue, forKey: "transportMode")
        modeTimer?.invalidate(); modeTimer = nil; ui.pending = false
        guard selected != mode else { return }
        if proxy.activeRequestCount == 0 { mode = selected; configureTransports() }
        else {
            ui.pending = true
            modeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if self.proxy.activeRequestCount == 0 {
                    timer.invalidate(); self.ui.pending = false; self.mode = selected; self.configureTransports()
                }
            }
        }
    }
    func toggleRelay() {
        modeTimer?.invalidate(); modeTimer = nil; ui.pending = false
        ui.enabled.toggle(); mode = ui.selection; configureTransports()
    }
    func saveAPI(_ draft: APIConfigurationDraft?, selection: APISelection) throws -> Bool {
        guard let apiCoordinator else { throw BridgeError.invalid("测试模式未启用配置同步") }
        let before = configuration.model
        try apiCoordinator.update(draft, selection: selection)
        return configuration.model != before
    }
    func showWindow(_ config: BridgeConfiguration) {
        let content = RelayWindow(model: ui, config: config,
                                  selectMode: { [weak self] in self?.changeMode($0) }, toggle: { [weak self] in self?.toggleRelay() },
                                  saveAPI: { [weak self] draft, selection in
                                      guard let self else { throw BridgeError.invalid("请重新打开 App") }
                                      return try self.saveAPI(draft, selection: selection)
                                  })
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Codex Relay"; window.titleVisibility = .hidden
        window.contentView = hosting; window.setContentSize(hosting.fittingSize)
        self.window = window; window.delegate = self
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let menu = NSMenu(); let root = NSMenuItem(); menu.addItem(root)
        let appMenu = NSMenu(); root.submenu = appMenu
        appMenu.addItem(withTitle: "显示主窗口", action: #selector(showMainWindow), keyEquivalent: "1").target = self
        appMenu.addItem(withTitle: "退出 Codex Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
    }
    @objc func showMainWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMainWindow(); return true }
    func applicationWillTerminate(_ notification: Notification) { modeTimer?.invalidate(); stopTransports(); proxy?.stop() }
}

let delegate = AppDelegate()
if gui {
    let app = NSApplication.shared; app.setActivationPolicy(.regular); app.delegate = delegate; app.run()
} else { delegate.launch(); RunLoop.main.run() }

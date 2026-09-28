import SwiftUI
import UIKit
import Security
import BridgeCore
import Network
import CryptoKit

@main
struct BluetoothRelayApp: App {
    @UIApplicationDelegateAdaptor(RelayApplicationDelegate.self) var delegate
    var body: some Scene { WindowGroup { RelayView(model: delegate.model) } }
}

final class RelayApplicationDelegate: NSObject, UIApplicationDelegate {
    let model = RelayModel()
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if options?[.bluetoothPeripherals] != nil { model.restoreIfRequested() }
        return true
    }
    func applicationDidBecomeActive(_ application: UIApplication) { model.resumeTransport() }
}

final class RelayModel: ObservableObject {
    @Published var apiState = APISettingsState()
    @Published var apiSync = "待连接同步"
    private var apiCoordinator: APISettingsCoordinator?
    @Published var status = "未配对"
    @Published var paired = false
    @Published var running = false
    @Published var phase = PeripheralPhase.stopped
    @Published var networkStatus = "正在检查手机网络"
    @Published var metrics = RelayMetrics()
    @Published var usbStatus = "尚未启用"
    @Published var usbConnected = false
    @Published private(set) var mode = ConnectionMode.combined
    private let peripheral = BluetoothPeripheral()
    private let usb = USBRelayServer()
    private var usbEnabled = false
    private var bleMetrics = RelayMetrics()
    private var usbMetrics = RelayMetrics()
    private let network = NWPathMonitor()
    private var token = ""
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private let enabledKey = "relayRequested"
    private let keychainQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.bluetoothcodex.pairing", kSecAttrAccount as String: "mac"]
    init() {
        mode = ConnectionMode(rawValue: UserDefaults.standard.string(forKey: "transportMode") ?? "auto") ?? .combined
        var query = keychainQuery
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let text = String(data: data, encoding: .utf8), let saved = try? PairingCode.parse(text) {
            token = saved; paired = true; status = "已配对"
            // Permit OS-triggered Bluetooth restoration after the user has unlocked once.
            SecItemUpdate(keychainQuery as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        }
        do { configureAPI(try loadAPIState()) }
        catch { status = "无法读取 API 配置" }
        peripheral.onStatus = { [weak self] in self?.status = $0 }
        peripheral.onWake = { [weak self] rebuild in self?.usb.prepareForConnection(rebuildListener: rebuild) }
        peripheral.onPhase = { [weak self] phase in
            self?.phase = phase
        }
        peripheral.onMetrics = { [weak self] metrics in
            guard let self else { return }
            self.bleMetrics = metrics; self.updateMetrics()
        }
        usb.onMetrics = { [weak self] metrics in self?.usbMetrics = metrics; self?.updateMetrics() }
        usb.onStatus = { [weak self] in self?.usbStatus = $0 }
        usb.onConnected = { [weak self] connected in
            self?.usbConnected = connected
            self?.usbStatus = connected ? "Type-C 已连接" : (self?.usbEnabled == true ? "等待 Type-C 数据线" : "已停止")
        }
        network.pathUpdateHandler = { [weak self] path in
            let message: String
            if path.status != .satisfied { message = "无网络" }
            else if path.usesInterfaceType(.cellular) { message = "蜂窝网络" }
            else if path.usesInterfaceType(.wifi) { message = "Wi-Fi" }
            else { message = "网络已连接" }
            DispatchQueue.main.async { self?.networkStatus = message }
        }
        network.start(queue: DispatchQueue(label: "bluetoothcodex.network-status"))
    }
    private struct StoredAPI: Codable { let pairing: String; let state: APISettingsState }
    private var apiQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.bluetoothcodex.api", kSecAttrAccount as String: "profiles"] }
    private var pairingFingerprint: String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func loadAPIState() throws -> APISettingsState {
        var query = apiQuery; query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return APISettingsState() }
        guard result == errSecSuccess, let data = item as? Data else { throw BridgeError.invalid("无法读取 API 配置") }
        let saved = try JSONDecoder().decode(StoredAPI.self, from: data)
        let state = try saved.state.validated()
        return saved.pairing == pairingFingerprint ? state : APISettingsState(phone: state.phone)
    }
    private func persistAPI(_ state: APISettingsState) throws {
        let data = try JSONEncoder().encode(StoredAPI(pairing: pairingFingerprint, state: state))
        let attrs: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(apiQuery as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound { result = SecItemAdd(apiQuery.merging(attrs) { _, new in new } as CFDictionary, nil) }
        guard result == errSecSuccess else { throw BridgeError.invalid("无法保存 API 配置") }
    }
    private func configureAPI(_ state: APISettingsState) {
        let coordinator = APISettingsCoordinator(origin: .phone, state: state) { [weak self] in
            guard let self else { throw BridgeError.invalid("App 已退出") }
            try self.persistAPI($0)
        }
        apiCoordinator = coordinator; apiState = state; apiSync = coordinator.status
        coordinator.onChange = { [weak self] in self?.apiState = $0 }
        coordinator.onStatus = { [weak self] in self?.apiSync = $0 }
        peripheral.settings = coordinator; usb.settings = coordinator
    }
    func saveAPI(_ draft: APIConfigurationDraft?, selection: APISelection) throws {
        guard let apiCoordinator else { throw BridgeError.invalid("请重新打开 App") }
        try apiCoordinator.update(draft, selection: selection)
    }
    deinit { network.cancel() }
    @discardableResult func pair(_ input: String) -> Bool {
        let value: String
        do { value = try PairingCode.parse(input) }
        catch { status = error.localizedDescription; return false }
        stop()
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var result = SecItemUpdate(keychainQuery as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound {
            result = SecItemAdd(keychainQuery.merging(attrs) { _, new in new } as CFDictionary, nil)
        }
        guard result == errSecSuccess else { status = "无法保存配对 (\(result))"; return false }
        let changedPeer = token != value
        token = value; paired = true
        if changedPeer {
            let state = APISettingsState(phone: apiState.phone)
            configureAPI(state)
            do { try persistAPI(state) } catch { status = "无法保存 API 配置"; return false }
        }
        status = "已配对"; return true
    }
    func forget() {
        stop()
        let result = SecItemDelete(keychainQuery as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { status = "无法移除配对信息 (\(result))"; return }
        token = ""
        let state = APISettingsState(phone: apiState.phone); configureAPI(state)
        do { try persistAPI(state) } catch { status = "无法清除电脑端配置" }
        paired = false; metrics = RelayMetrics(); status = "未配对"
    }
    func selectMode(_ selected: ConnectionMode) {
        guard mode != selected, metrics.activeRequests == 0 else { return }
        let restart = running
        if restart { stop() }
        mode = selected; UserDefaults.standard.set(selected.rawValue, forKey: "transportMode")
        if restart { start() }
    }
    func start() {
        guard paired, !running else { return }
        guard apiCoordinator != nil else { status = "API 配置不可用，请重新打开 App"; return }
        UserDefaults.standard.set(true, forKey: enabledKey)
        running = true; UIApplication.shared.isIdleTimerDisabled = true
        bleMetrics = RelayMetrics(); usbMetrics = RelayMetrics(); metrics = RelayMetrics()
        if mode.usesUSB {
            usbEnabled = true
            do { try usb.start(token: token); usbStatus = "等待连接" }
            catch { usbEnabled = false; usbStatus = "无法启动 Type-C" }
        }
        if mode.usesBluetooth { peripheral.start(token: token) }
    }
    private func updateMetrics() {
        let wasIdle = metrics.activeRequests == 0
        var value = RelayMetrics()
        value.activeRequests = bleMetrics.activeRequests + usbMetrics.activeRequests
        value.completedRequests = bleMetrics.completedRequests + usbMetrics.completedRequests
        value.failedRequests = bleMetrics.failedRequests + usbMetrics.failedRequests
        value.uploadedBytes = bleMetrics.uploadedBytes + usbMetrics.uploadedBytes
        value.downloadedBytes = bleMetrics.downloadedBytes + usbMetrics.downloadedBytes
        value.upstreamHost = usbMetrics.upstreamHost ?? bleMetrics.upstreamHost
        metrics = value
        if value.activeRequests == 0 { endBackgroundTask() }
        else if wasIdle { beginBackgroundTask() }
    }
    func restoreIfRequested() {
        if paired && UserDefaults.standard.bool(forKey: enabledKey) { start() }
    }
    func resumeTransport() { if usbEnabled { usb.prepareForConnection() } }
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Bluetooth API request") { [weak self] in
            self?.endBackgroundTask()
            self?.peripheral.expireBackgroundRequests()
            self?.usb.expireBackgroundRequests()
        }
    }
    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        let task = backgroundTask; backgroundTask = .invalid
        UIApplication.shared.endBackgroundTask(task)
    }
    func stop() {
        UserDefaults.standard.set(false, forKey: enabledKey)
        running = false
        endBackgroundTask()
        usbEnabled = false; usb.stop()
        peripheral.stop(); running = false; UIApplication.shared.isIdleTimerDisabled = false
    }
    var connected: Bool { usbConnected || phase == .connected }
    var connectionTitle: String {
        if !paired { return "未配对" }
        if !running { return "已停止" }
        if metrics.activeRequests > 0 { return "正在转发" }
        return connected ? "已连接" : "等待 Mac"
    }
    var connectionSubtitle: String {
        if !paired { return "扫描 Mac 上的二维码" }
        if !running { return "连接已暂停" }
        if connected { return usbConnected ? "Type-C" : "蓝牙" }
        if phase == .blocked { return status }
        if mode == .usb && !usbEnabled { return usbStatus }
        return mode == .usb ? "连接 Type-C 数据线" : "在 Mac 上开启转发"
    }
}

struct RelayView: View {
    @ObservedObject var model: RelayModel
    @State private var pairing = false
    @State private var details = false
    @State private var apiSettings = false
    private var card: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("连接方式").font(.subheadline).foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            ForEach(ConnectionMode.allCases) { mode in
                                Button { model.selectMode(mode) } label: {
                                    VStack(spacing: 10) {
                                        Image(systemName: mode.symbol).font(.system(size: 22, weight: .medium))
                                        Text(mode.title).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                                    }.frame(maxWidth: .infinity).frame(height: 84)
                                        .foregroundColor(model.mode == mode ? .accentColor : .primary)
                                        .background(model.mode == mode ? Color.accentColor.opacity(0.1) : card,
                                                    in: RoundedRectangle(cornerRadius: 15))
                                        .overlay(RoundedRectangle(cornerRadius: 15)
                                            .strokeBorder(model.mode == mode ? Color.accentColor : Color.primary.opacity(0.05)))
                                }.buttonStyle(.plain).disabled(model.metrics.activeRequests > 0).accessibilityLabel(mode.title)
                                    .accessibilityIdentifier("mode-" + mode.rawValue)
                                    .accessibilityValue(model.mode == mode ? "已选择" : "未选择")
                            }
                        }
                        Text(model.mode.caption).font(.caption).foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 22) {
                        HStack {
                            Image(systemName: model.connected ? "checkmark.circle.fill" : (model.running ? "laptopcomputer" : "pause.circle"))
                                .font(.system(size: 30)).foregroundColor(model.connected ? .green : .secondary)
                            Spacer()
                            Label(model.networkStatus, systemImage: "network").font(.caption).foregroundColor(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(model.connectionTitle).font(.title2.weight(.semibold))
                            Text(model.connectionSubtitle).font(.subheadline).foregroundColor(.secondary)
                        }
                        Divider()
                        HStack(spacing: 8) {
                            statistic("已转发", value: String(model.metrics.completedRequests))
                            Spacer()
                            statistic("上传", value: bytes(model.metrics.uploadedBytes))
                            Spacer()
                            statistic("下载", value: bytes(model.metrics.downloadedBytes))
                        }
                    }.padding(22).background(card, in: RoundedRectangle(cornerRadius: 22))
                    Button {
                        if model.running { model.stop() } else { model.start() }
                    } label: {
                        Label(model.running ? "停止转发" : "开始转发", systemImage: model.running ? "stop.fill" : "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundColor(model.running ? .primary : .white)
                            .background(model.running ? Color.primary.opacity(0.07) : Color.accentColor,
                                        in: RoundedRectangle(cornerRadius: 15))
                    }.buttonStyle(.plain).disabled(!model.paired).opacity(model.paired ? 1 : 0.45)
                        .accessibilityLabel(model.running ? "停止转发" : "开始转发").accessibilityIdentifier("toggle-relay")
                    Button { pairing = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.paired ? "checkmark.shield" : "qrcode.viewfinder")
                                .font(.title3).foregroundColor(.accentColor)
                            Text(model.paired ? "已配对 Mac" : "配对 Mac").foregroundColor(.primary)
                            Spacer()
                            Text(model.paired ? "管理" : "扫码").font(.subheadline).foregroundColor(.secondary)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                        }.padding(18).background(card, in: RoundedRectangle(cornerRadius: 16))
                    }.buttonStyle(.plain)
                }.padding(20)
            }.background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("Codex Relay").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button { apiSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityLabel("API 配置").accessibilityIdentifier("api-settings")
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { details = true } label: { Image(systemName: "ellipsis.circle") }
                            .accessibilityLabel("连接详情")
                    }
                }
                .sheet(isPresented: $apiSettings) { PhoneAPISettingsView(model: model) }
                .sheet(isPresented: $pairing) { RelayPairingView(model: model) }
                .sheet(isPresented: $details) {
                    NavigationStack {
                        Form {
                            LabeledContent("连接方式", value: model.mode.title)
                            LabeledContent("网络", value: model.networkStatus)
                            if model.mode.usesUSB { LabeledContent("Type-C", value: model.usbStatus) }
                            if model.mode.usesBluetooth { LabeledContent("蓝牙", value: model.status) }
                            LabeledContent("API", value: model.metrics.upstreamHost ?? "—")
                            LabeledContent("请求中", value: String(model.metrics.activeRequests))
                            LabeledContent("传输失败", value: String(model.metrics.failedRequests))
                            Button("权限设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }.navigationTitle("连接详情").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { details = false } } }
                    }
                }
        }
    }
    private func statistic(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.system(.subheadline, design: .rounded).weight(.semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundColor(.secondary)
        }
    }
    private func bytes(_ value: Int) -> String {
        value == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

private struct RelayPairingView: View {
    @ObservedObject var model: RelayModel
    @Environment(\.dismiss) private var dismiss
    @State private var scanner = false
    @State private var manual = ""
    @State private var error: String?
    @State private var confirmForget = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { scanner = true } label: { Label("扫描二维码", systemImage: "qrcode.viewfinder") }
                    HStack {
                        SecureField("配对码", text: $manual).textInputAutocapitalization(.never).autocorrectionDisabled()
                        PasteButton(payloadType: String.self) { manual = $0.first ?? "" }.labelStyle(.iconOnly).accessibilityLabel("粘贴配对码")
                    }
                    Button("保存配对") { save(manual) }.disabled(manual.isEmpty)
                    if let error { Text(error).font(.footnote).foregroundColor(.red) }
                }
                if model.paired {
                    Section {
                        Label("已配对", systemImage: "checkmark.shield").foregroundColor(.green)
                        Button("解除配对", role: .destructive) { confirmForget = true }
                    }
                }
            }.navigationTitle("配对 Mac").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
                .confirmationDialog("解除当前配对？", isPresented: $confirmForget, titleVisibility: .visible) {
                    Button("解除配对", role: .destructive) { model.forget(); dismiss() }
                    Button("取消", role: .cancel) {}
                }
                .sheet(isPresented: $scanner) {
                    ScannerView { result in
                        scanner = false
                        switch result {
                        case .success(let value): if let value { save(value) }
                        case .failure(let failure): error = failure.localizedDescription
                        }
                    }.ignoresSafeArea()
                }
        }
    }
    private func save(_ value: String) {
        if model.pair(value) { manual = ""; dismiss() }
        else { error = model.status }
    }
}

private struct PhoneAPISettingsView: View {
    @ObservedObject var model: RelayModel
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = ""
    @State private var key = ""
    @State private var modelName = ""
    @State private var selection = APISelection.automatic
    @State private var original: APICredentials?
    @State private var error: String?
    @State private var saved = false
    private var fieldsChanged: Bool {
        baseURL != (original?.baseURL ?? "") || modelName != (original?.model ?? "") || !key.isEmpty
    }
    private var changed: Bool { fieldsChanged || selection != model.apiState.selection }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("配置来源", selection: $selection) {
                        ForEach(APISelection.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented)
                    LabeledContent("当前使用", value: model.apiState.effectiveOrigin?.title ?? "未设置")
                    LabeledContent("同步", value: model.apiSync)
                }
                Section("手机端配置") {
                    TextField("API 地址", text: $baseURL).keyboardType(.URL).accessibilityIdentifier("api-base-url")
                    SecureField("密钥：留空保留已有密钥", text: $key).accessibilityIdentifier("api-key")
                    TextField("模型名称", text: $modelName).accessibilityIdentifier("api-model")
                }.textInputAutocapitalization(.never).autocorrectionDisabled()
                Section {
                    Button("保存") {
                        do {
                            let draft = fieldsChanged ? APIConfigurationDraft(baseURL: baseURL, apiKey: key, model: modelName) : nil
                            try model.saveAPI(draft, selection: selection)
                            load(); error = nil; saved = true
                        } catch { self.error = error.localizedDescription; saved = false }
                    }.disabled(!changed).accessibilityIdentifier("save-api-settings")
                    if let error { Text(error).font(.footnote).foregroundColor(.red) }
                    if saved && !changed { Label("已保存", systemImage: "checkmark.circle.fill").foregroundColor(.green) }
                }
            }.navigationTitle("API 配置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { key = ""; dismiss() } } }
                .onAppear { load() }
                .onChange(of: selection) { _ in error = nil }
                .onChange(of: baseURL) { _ in error = nil }
                .onChange(of: key) { _ in error = nil }
                .onChange(of: modelName) { _ in error = nil }
        }
    }
    private func load() {
        original = model.apiState.phone?.credentials
        baseURL = original?.baseURL ?? ""; modelName = original?.model ?? ""; key = ""; selection = model.apiState.selection
    }
}

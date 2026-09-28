import Foundation
import CoreBluetooth

public final class BluetoothCentral: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    public var streamWriteSize = 16_384
    public var controlOnly = false
    public var wakeReady: Bool { peripheral?.state == .connected && control != nil }
    public private(set) var lastWakeError = ""
    public var onStatus: ((String) -> Void)?
    public var onTransport: ((StreamTransport) -> Void)?
    private var manager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var channel: CBL2CAPChannel?
    private var stream: StreamTransport?
    private var watchdog: Timer?
    private var connectingSince = Date()
    private var running = false
    private var control: CBCharacteristic?
    private var controlPending = false
    private var pendingUSBRecovery = false
    private var trySavedPeripheral = true
    private let savedPeripheralKey = "BluetoothCodex.savedPeripheral"
    public func start() {
        guard !running else { return }; running = true
        trySavedPeripheral = true
        manager = CBCentralManager(delegate: self, queue: .main)
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.running, self.stream == nil,
                  !(self.controlOnly && self.control != nil), Date().timeIntervalSince(self.connectingSince) > 25 else { return }
            if self.peripheral == nil { self.trySavedPeripheral = true; self.connectingSince = Date(); self.scan(); return }
            self.reset("蓝牙连接超时，正在重试")
        }
    }
    public func stop() {
        running = false; watchdog?.invalidate(); watchdog = nil
        manager?.stopScan(); stream?.close("Bluetooth stopped")
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        stream = nil; channel = nil; peripheral = nil; control = nil; controlPending = false; pendingUSBRecovery = false
    }
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard running, central === manager else { return }
        if central.state == .poweredOn { scan() }
        else {
            stream?.close("蓝牙不可用"); stream = nil; channel = nil; peripheral = nil
            onStatus?(central.state == .unauthorized ? "请在系统设置中允许 Bluetooth Codex 使用蓝牙" : "请开启 Mac 蓝牙")
        }
    }
    private func scan() {
        guard running, manager.state == .poweredOn, peripheral == nil else { return }
        if trySavedPeripheral, let saved = UserDefaults.standard.string(forKey: savedPeripheralKey),
           let id = UUID(uuidString: saved), let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
            trySavedPeripheral = false
            peripheral = known; known.delegate = self; connectingSince = Date()
            manager.connect(known, options: nil); onStatus?("正在重连已配对的 iPhone"); return
        }
        onStatus?("正在搜索 iPhone，请打开 Bluetooth Relay")
        manager.scanForPeripherals(withServices: [CBUUID(string: BridgeProtocol.service)], options: nil)
    }
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard running, central === manager, self.peripheral == nil else { return }
        self.peripheral = peripheral; connectingSince = Date(); peripheral.delegate = self
        central.stopScan(); central.connect(peripheral, options: nil); onStatus?("正在连接 iPhone 蓝牙")
    }
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard running, central === manager, peripheral === self.peripheral else { return }
        peripheral.discoverServices([CBUUID(string: BridgeProtocol.service)])
    }
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard running, central === manager else { return }
        if self.peripheral?.identifier == peripheral.identifier { reset("蓝牙连接失败，正在重试") }
    }
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard running, central === manager else { return }
        if self.peripheral?.identifier == peripheral.identifier { reset("iPhone 已断开，正在重新连接") }
    }
    private func reset(_ reason: String) {
        let old = peripheral
        trySavedPeripheral = stream != nil
        control = nil; controlPending = false; pendingUSBRecovery = false
        peripheral = nil; channel = nil
        let oldStream = stream; stream = nil; oldStream?.close(reason)
        if let old, old.state != .disconnected { manager.cancelPeripheralConnection(old) }
        onStatus?(reason)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.scan() }
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard running, peripheral === self.peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: BridgeProtocol.service) }) else { reset("未发现蓝牙转发服务"); return }
        peripheral.discoverCharacteristics([CBUUID(string: BridgeProtocol.psm), CBUUID(string: BridgeProtocol.control)], for: service)
    }
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard running, peripheral === self.peripheral else { return }
        guard error == nil, let characteristic = service.characteristics?.first(where: { $0.uuid == CBUUID(string: BridgeProtocol.psm) }) else { reset("未发现蓝牙通道"); return }
        control = service.characteristics?.first(where: { $0.uuid == CBUUID(string: BridgeProtocol.control) })
        peripheral.readValue(for: characteristic)
    }
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, peripheral === self.peripheral else { return }
        guard error == nil, let data = characteristic.value, data.count == 2 else { reset("读取蓝牙通道失败"); return }
        let psm = data.reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
        if controlOnly { wake(); return }
        peripheral.openL2CAPChannel(psm)
    }
    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard running, peripheral === self.peripheral else { return }
        guard error == nil, let channel else { reset("无法打开加密蓝牙通道，请检查系统配对提示"); return }
        self.channel = channel
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedPeripheralKey)
        let stream = StreamTransport(input: channel.inputStream, output: channel.outputStream, writeSize: streamWriteSize)
        // GATT delivery wakes a background peripheral to service an L2CAP request or heartbeat.
        stream.onSend = { [weak self] type in
            if ["hello", "authenticate", "request", "benchmark", "ping", "settings"].contains(type) { self?.wake() }
        }
        self.stream = stream; onTransport?(stream)
        let previous = stream.onClose
        stream.onClose = { [weak self] reason in
            previous?(reason)
            guard let self, self.stream != nil else { return }
            self.reset(reason)
        }
        stream.start()
    }
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard running, peripheral === self.peripheral else { return }
        if characteristic.uuid == CBUUID(string: BridgeProtocol.control) {
            controlPending = false; lastWakeError = error.map { String(($0 as NSError).code) } ?? ""
            if pendingUSBRecovery { pendingUSBRecovery = false; wake(rebuildUSBListener: true) }
        }
    }
    public func wake(rebuildUSBListener: Bool = false) {
        guard let peripheral, let control else { return }
        if controlPending { pendingUSBRecovery = pendingUSBRecovery || rebuildUSBListener; return }
        controlPending = true
        peripheral.writeValue(Data([rebuildUSBListener ? 2 : 1]), for: control, type: .withResponse)
    }
}

public enum PeripheralPhase: String {
    case stopped, starting, waitingForBluetooth, advertising, authenticating, connected, blocked
}

public final class BluetoothPeripheral: NSObject, CBPeripheralManagerDelegate {
    public var settings: APISettingsCoordinator?
    public static let restorationIdentifier = "local.bluetoothcodex.peripheral"
    public var onStatus: ((String) -> Void)?
    public var onPhase: ((PeripheralPhase) -> Void)?
    public var onMetrics: ((RelayMetrics) -> Void)?
    public var onWake: ((Bool) -> Void)?
    private var manager: CBPeripheralManager!
    private var psm: CBL2CAPPSM?
    private var channel: CBL2CAPChannel?
    private var engine: RelayEngine?
    private var token = ""
    private var running = false
    private var lastConnection = Date.distantPast
    private var generation = 0
    private var lowLatencyCentral: UUID?
    public func start(token: String) {
        stop()
        guard let token = try? PairingCode.parse(token) else { onPhase?(.blocked); onStatus?("配对信息无效，请重新扫码"); return }
        self.token = token; running = true; onPhase?(.starting)
        manager = CBPeripheralManager(delegate: self, queue: .main,
            options: [CBPeripheralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier])
    }
    public func expireBackgroundRequests() { engine?.cancelActiveRequests("iOS 后台执行时间不足，请打开 Bluetooth Relay 后重试") }
    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // L2CAP streams/HTTPS tasks do not survive process termination. Publish a fresh PSM
        // in didUpdateState and let the known Mac reconnect; never replay a POST silently.
        onStatus?("正在恢复蓝牙服务，等待 Mac 重连")
    }
    public func stop() {
        running = false; generation += 1
        lowLatencyCentral = nil
        engine?.stop(); engine = nil; channel = nil
        if let manager, manager.state == .poweredOn {
            manager.stopAdvertising()
            if let psm { manager.unpublishL2CAPChannel(psm) }
            manager.removeAllServices()
        }
        psm = nil; manager?.delegate = nil; manager = nil
        onPhase?(.stopped); onStatus?("已停止")
    }
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard running, peripheral === manager else { return }
        if peripheral.state == .poweredOn {
            peripheral.removeAllServices(); psm = nil
            onPhase?(.starting); peripheral.publishL2CAPChannel(withEncryption: true)
        }
        else {
            engine?.stop("蓝牙不可用"); engine = nil; channel = nil; psm = nil
            if peripheral.state == .unauthorized || peripheral.state == .unsupported {
                onPhase?(.blocked)
                onStatus?(peripheral.state == .unauthorized ? "请在设置中允许蓝牙权限，再点击开始转发" : "设备不支持所需蓝牙功能，请使用真实 iPhone")
            } else { onPhase?(.waitingForBluetooth); onStatus?("请开启 iPhone 蓝牙，开启后将自动连接") }
        }
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard running, peripheral === manager else { return }
        guard error == nil else { onPhase?(.blocked); onStatus?("创建加密蓝牙通道失败，请重试"); return }
        psm = PSM
        var big = PSM.bigEndian
        let value = withUnsafeBytes(of: &big) { Data($0) }
        let characteristic = CBMutableCharacteristic(type: CBUUID(string: BridgeProtocol.psm), properties: [.read], value: value, permissions: [.readable])
        let service = CBMutableService(type: CBUUID(string: BridgeProtocol.service), primary: true)
        let control = CBMutableCharacteristic(type: CBUUID(string: BridgeProtocol.control), properties: [.write],
            value: nil, permissions: [.writeEncryptionRequired])
        service.characteristics = [characteristic, control]; peripheral.add(service)
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        let valid = running && peripheral === manager && requests.allSatisfy {
            $0.characteristic.uuid == CBUUID(string: BridgeProtocol.control) && $0.offset == 0 &&
            ($0.value == Data([1]) || $0.value == Data([2]))
        }
        peripheral.respond(to: first, withResult: valid ? .success : .requestNotSupported)
        if valid { onWake?(requests.contains { $0.value == Data([2]) }) }
        if valid && lowLatencyCentral != first.central.identifier {
            lowLatencyCentral = first.central.identifier
            peripheral.setDesiredConnectionLatency(.low, for: first.central)
        }
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard running, peripheral === manager else { return }
        guard error == nil else { onPhase?(.blocked); onStatus?("发布蓝牙服务失败，请重试"); return }
        advertise()
    }
    private func advertise() {
        guard running, engine == nil, manager?.state == .poweredOn, psm != nil else { return }
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BridgeProtocol.service)], CBAdvertisementDataLocalNameKey: "Codex Relay"])
    }
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard running, peripheral === manager else { return }
        // A queued advertisement callback may arrive after L2CAP authentication.
        guard engine == nil else { peripheral.stopAdvertising(); return }
        onPhase?(error == nil ? .advertising : .blocked)
        onStatus?(error == nil ? "等待 Mac 蓝牙连接" : "蓝牙广播启动失败")
    }
    public func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?, error: Error?) {
        guard running, peripheral === manager else { channel?.inputStream.close(); channel?.outputStream.close(); return }
        guard error == nil, let channel else { onStatus?("蓝牙通道连接失败"); return }
        guard engine == nil, Date().timeIntervalSince(lastConnection) >= 2 else { channel.inputStream.close(); channel.outputStream.close(); return }
        lowLatencyCentral = nil
        lastConnection = Date(); self.channel = channel; peripheral.stopAdvertising()
        let transport = StreamTransport(input: channel.inputStream, output: channel.outputStream)
        let engine = RelayEngine(transport: transport, token: token, settings: settings)
        self.engine = engine
        onPhase?(.authenticating)
        engine.onAuthenticated = { [weak self] in self?.onPhase?(.connected) }
        engine.onMetrics = { [weak self] in self?.onMetrics?($0) }
        engine.onStatus = { [weak self] in self?.onStatus?($0) }
        engine.onClose = { [weak self] in
            guard let self else { return }; self.engine = nil; self.channel = nil
            self.onPhase?(self.running ? .starting : .stopped)
            let generation = self.generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.generation == generation else { return }; self.advertise()
            }
        }
        transport.start(); onStatus?("Mac 正在验证配对")
    }
}

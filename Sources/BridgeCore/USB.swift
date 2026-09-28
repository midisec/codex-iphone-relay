import Foundation
import Network

/// Phone loopback service reached through Apple's USB multiplexer, never a Wi-Fi listener.
public final class USBRelayServer {
    public var settings: APISettingsCoordinator?
    public var onStatus: ((String) -> Void)?
    public var onMetrics: ((RelayMetrics) -> Void)?
    public var onConnected: ((Bool) -> Void)?
    private var listener: NWListener?
    private var engine: RelayEngine?
    private var transport: TCPTransport?
    private var token = ""
    private var running = false
    private var generation = 0
    private var listenerWaiting = false
    private var retryAfter = Date.distantPast
    public init() {}
    public func start(token: String) throws {
        stop(); self.token = token; running = true
        do { try listen() }
        catch { running = false; throw error }
    }
    // iOS can invalidate a listening socket while the app is in the background
    // or its network path changes. A Bluetooth wake gives us time to restore it.
    public func prepareForConnection(rebuildListener: Bool = false) {
        guard running, Date() >= retryAfter else { return }
        if listenerWaiting || rebuildListener {
            generation += 1; listener?.cancel(); listener = nil
        }
        guard listener == nil else { return }
        do { try listen() }
        catch { retryLater("USB 服务暂不可用，正在重试") }
    }
    private func retryLater(_ status: String) {
        onStatus?(status); retryAfter = Date().addingTimeInterval(3)
        let generation = self.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == generation else { return }
            self.prepareForConnection()
        }
    }
    private func listen() throws {
        generation += 1; let generation = self.generation
        listenerWaiting = false
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: BridgeProtocol.usbPort)!)
        let listener = try NWListener(using: parameters); self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.running, self.generation == generation else { return }
            switch state {
            case .ready:
                self.listenerWaiting = false
                if self.engine == nil { self.onStatus?("等待 Type-C 数据线") }
            case .waiting:
                self.listenerWaiting = true
                self.retryLater("USB 服务等待恢复")
            case .failed(let error):
                self.generation += 1; self.listener?.cancel(); self.listener = nil
                self.retryLater("USB 服务正在恢复（\(error)）")
            case .cancelled:
                self.generation += 1; self.listener = nil; self.retryLater("USB 服务正在重新启动")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self, self.running, self.generation == generation, self.engine == nil else { connection.cancel(); return }
            let transport = TCPTransport(connection); self.transport = transport
            let engine = RelayEngine(transport: transport, token: self.token, settings: self.settings); self.engine = engine
            engine.onStatus = { [weak self] in self?.onStatus?($0) }
            engine.onMetrics = { [weak self] in self?.onMetrics?($0) }
            engine.onAuthenticated = { [weak self] in self?.onConnected?(true) }
            engine.onClose = { [weak self] in self?.engine = nil; self?.transport = nil; self?.onConnected?(false) }
            transport.start()
        }
        listener.start(queue: .main)
    }
    public func expireBackgroundRequests() { engine?.cancelActiveRequests("iOS 后台执行时间不足，请打开 Relay 后重试") }
    public func stop() {
        running = false; generation += 1; listenerWaiting = false; retryAfter = .distantPast
        listener?.cancel(); listener = nil
        engine?.stop("USB 转发已停止"); engine = nil; transport = nil
        onConnected?(false)
    }
}

#if os(macOS)
/// Minimal plist usbmux protocol client; uses the daemon already supplied by macOS.
/// Only physical USB devices are eligible. Network/Wi-Fi devices are never selected.
public final class USBConnector {
    public var onTransport: ((TCPTransport) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onPrepareConnection: (() -> Void)?
    private var timer: Timer?
    private var connection: NWConnection?
    private var transport: TCPTransport?
    private var generation = 0
    private var startedAt = Date()
    public init() {}
    public func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.connection == nil { self.connect() }
            else if self.transport == nil && Date().timeIntervalSince(self.startedAt) > 8 { self.reset() }
        }
        connect()
    }
    public func stop() { timer?.invalidate(); timer = nil; reset() }
    private func reset() {
        generation += 1
        let old = transport; transport = nil; old?.close("USB 连接已关闭")
        connection?.cancel(); connection = nil
    }
    private func connect() {
        guard connection == nil else { return }
        generation += 1; let generation = self.generation; startedAt = Date()
        let connection = NWConnection(to: .unix(path: "/var/run/usbmuxd"), using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == generation else { return }
            switch state {
            case .ready:
                self.exchange(["MessageType": "ListDevices"], tag: 1) { [weak self] reply in
                    guard let self else { return }
                    let devices = (reply["DeviceList"] as? [[String: Any]] ?? []).filter {
                        ($0["Properties"] as? [String: Any])?["ConnectionType"] as? String == "USB"
                    }
                    guard devices.count == 1, let device = devices.first?["DeviceID"] as? Int else {
                        self.onStatus?(devices.isEmpty ? "等待 Type-C 数据线连接 iPhone" : "请只连接一台 USB iPhone"); self.reset(); return
                    }
                    self.onPrepareConnection?()
                    // Allow the GATT wake to reach the phone and rebind its listener.
                    // A listening socket may be stale after suspension without a
                    // timely Network.framework state callback.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.exchange(["MessageType": "Connect", "DeviceID": device,
                        "PortNumber": Int(BridgeProtocol.usbPort.bigEndian)], tag: 2) { [weak self] reply in
                        guard let self else { return }
                        guard (reply["Number"] as? Int) == 0 else { self.onStatus?("请在 iPhone 开始转发并信任此 Mac"); self.reset(); return }
                        let transport = TCPTransport(connection); self.transport = transport
                        let cleanup: () -> Void = { [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.transport = nil; self.connection?.cancel(); self.connection = nil
                        }
                        transport.onClose = { _ in cleanup() }
                        self.onTransport?(transport)
                        guard self.transport === transport else { return }
                        let previous = transport.onClose
                        transport.onClose = { reason in previous?(reason); cleanup() }
                        transport.start(alreadyConnected: true)
                    }
                    }
                }
            case .failed, .cancelled: self.reset()
            default: break
            }
        }
        connection.start(queue: .main)
    }
    private func exchange(_ values: [String: Any], tag: UInt32, completion: @escaping ([String: Any]) -> Void) {
        guard let connection else { return }
        let generation = self.generation
        var request = values
        request["ClientVersionString"] = "BluetoothCodex-1.2"
        request["ProgName"] = "BluetoothCodex"; request["kLibUSBMuxVersion"] = 3
        do {
            let body = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
            var packet = Data()
            for value: UInt32 in [UInt32(body.count + 16), 1, 8, tag] {
                var value = value.littleEndian; packet.append(withUnsafeBytes(of: &value) { Data($0) })
            }
            connection.send(content: packet + body, completion: .contentProcessed { [weak self] error in
                guard let self, self.generation == generation else { return }
                guard error == nil else { self.reset(); return }
                self.readExactly(16) { [weak self] header in
                    guard let self else { return }
                    let words = stride(from: 0, to: 16, by: 4).map { i in
                        header.subdata(in: i..<i+4).enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
                    }
                    guard (16...1_048_576).contains(words[0]), words[1] == 1, words[2] == 8, words[3] == tag else { self.reset(); return }
                    self.readExactly(Int(words[0]) - 16) { [weak self] body in
                        guard let reply = (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any] else { self?.reset(); return }
                        completion(reply)
                    }
                }
            })
        } catch { reset() }
    }
    private func readExactly(_ count: Int, accumulated: Data = Data(), completion: @escaping (Data) -> Void) {
        if count <= accumulated.count { completion(accumulated); return }
        guard let connection else { return }
        let generation = self.generation
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { [weak self] data, _, complete, error in
            guard let self, self.generation == generation else { return }
            guard error == nil, let data, !data.isEmpty else { self.reset(); return }
            let combined = accumulated + data
            if combined.count == count { completion(combined) }
            else if complete { self.reset() }
            else { self.readExactly(count, accumulated: combined, completion: completion) }
        }
    }
}
#endif

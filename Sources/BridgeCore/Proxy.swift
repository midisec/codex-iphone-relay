import Foundation
import Network

public struct BridgeConfiguration: Codable, Equatable {
    public var upstreamBase: String
    public var apiKey: String
    public var localToken: String
    public var pairingToken: String
    public var model: String
    public var port: UInt16
    public var apiSettings: APISettingsState?
    public static func read(_ path: String) throws -> Self {
        let config = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard !config.apiKey.isEmpty, config.localToken.count >= 32, config.pairingToken.count >= 32, config.port > 0 else { throw BridgeError.invalid("Invalid bridge configuration") }
        return config
    }
}

public final class LocalProxy {
    public var onStatus: ((String) -> Void)?
    public var additionalDiagnostics: (() -> [String: Any])?
    public var diagnosticUploadWindow = BridgeProtocol.responseWindow
    public private(set) var ready = false
    public private(set) var status = "等待 iPhone 蓝牙连接"
    public private(set) var completedRequests = 0
    public private(set) var receivedBytes = 0
    public private(set) var sentBytes = 0
    private var recentRequests = [[String: Any]]()
    private var settingsLink: APISettingsLink?
    private var config: BridgeConfiguration
    public private(set) var transportLabel: String
    public var activeRequestCount: Int { clients.values.filter { $0.forwarded && !$0.closed }.count }
    private var transport: MessageTransport?
    private var clients = [String: HTTPClient]()
    private var listener: NWListener?
    private var clientNonce = ""
    private var challengeAccepted = false
    private var uploadWindow = 0
    private var lastDisconnectReason = ""
    private var lastPeerActivity = Date()
    private var attachedAt = Date()
    private var timer: Timer?
    public init(config: BridgeConfiguration, transportLabel: String = "bluetooth-l2cap") {
        self.config = config; self.transportLabel = transportLabel
    }
    public func synchronize(using coordinator: APISettingsCoordinator) {
        settingsLink?.stop()
        settingsLink = APISettingsLink(coordinator) { [weak self] in self?.transport?.send($0) }
    }
    public func applySynchronizedConfiguration(_ updated: BridgeConfiguration) {
        precondition(updated.port == config.port && updated.localToken == config.localToken && updated.pairingToken == config.pairingToken)
        config = updated
    }
    public func updateConfiguration(_ updated: BridgeConfiguration) throws {
        guard activeRequestCount == 0 else { throw BridgeError.invalid("请等待当前请求结束后保存") }
        guard updated.port == config.port, updated.localToken == config.localToken,
              updated.pairingToken == config.pairingToken else { throw BridgeError.invalid("API 编辑不能更改端口或配对信息") }
        transport?.close("API 配置已更新，正在重新连接")
        config = updated
    }
    public func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: config.port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            guard self.clients.count < 16 else { connection.cancel(); return }
            let client = HTTPClient(connection: connection)
            self.clients[client.id] = client
            client.onRequest = { [weak self, weak client] request in if let client { self?.handle(request, client: client) } }
            client.onClose = { [weak self] id in
                guard let self, let client = self.clients.removeValue(forKey: id), client.forwarded else { return }
                self.recentRequests.append(client.diagnostic)
                if self.recentRequests.count > 12 { self.recentRequests.removeFirst() }
                self.transport?.send(Message("cancel", id: id))
                self.refreshStatus()
            }
            client.start()
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.setStatus("本地端口启动失败，请检查端口占用") }
        }
        listener.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let transport = self.transport {
                if !self.ready && Date().timeIntervalSince(self.attachedAt) > 20 { transport.close("蓝牙认证超时") }
                else if self.ready && Date().timeIntervalSince(self.lastPeerActivity) > 45 { transport.close("iPhone 心跳超时") }
                else if self.ready { transport.send(Message("ping")); self.settingsLink?.retryIfNeeded() }
            }
        }
    }
    public func setStatus(_ status: String) { self.status = status; onStatus?(status) }
    private func refreshStatus() {
        guard ready else { return }
        let active = clients.values.filter { $0.forwarded && !$0.closed }.count
        setStatus(active == 0 ? "iPhone 已连接 · 可以使用 Codex 3" : "正在转发 \(active) 个请求")
    }
    public func attach(_ transport: MessageTransport, label: String? = nil) {
        self.transport?.close("Connection replaced")
        if let label { transportLabel = label }
        self.transport = transport; ready = false; challengeAccepted = false; uploadWindow = 0
        clientNonce = Pairing.nonce(); attachedAt = Date(); lastPeerActivity = Date()
        transport.onMessage = { [weak self] message in self?.receive(message) }
        transport.onClose = { [weak self] reason in
            guard let self else { return }
            self.lastDisconnectReason = reason
            self.settingsLink?.stop(); self.ready = false; self.transport = nil; self.setStatus(reason)
            for client in Array(self.clients.values) where client.forwarded { client.fail(502, "iPhone relay disconnected; retry after reconnecting") }
        }
        var hello = Message("hello"); hello.version = BridgeProtocol.version; hello.nonce = clientNonce
        transport.send(hello); setStatus("蓝牙已连接，正在验证配对")
    }
    public func stop() {
        timer?.invalidate(); timer = nil; listener?.cancel(); listener = nil
        transport?.close("代理已停止")
        for client in Array(clients.values) { client.close() }
    }
    private func receive(_ message: Message) {
        lastPeerActivity = Date()
        if !ready {
            if message.type == "challenge", !challengeAccepted, let nonce = message.nonce, (32...128).contains(nonce.count),
               Pairing.verify(message.proof, token: config.pairingToken, text: "server|\(clientNonce)|\(nonce)") {
                challengeAccepted = true
                var auth = Message("authenticate"); auth.baseURL = config.upstreamBase
                auth.settings = settingsLink?.coordinator.state
                auth.uploadWindow = min(BridgeProtocol.responseWindow, max(1, diagnosticUploadWindow))
                auth.proof = Pairing.proof(token: config.pairingToken, text: "client|\(clientNonce)|\(nonce)|\(config.upstreamBase)")
                transport?.send(auth); return
            }
            if message.type == "ready" && challengeAccepted {
                uploadWindow = min(BridgeProtocol.responseWindow, max(1, diagnosticUploadWindow), max(0, message.uploadWindow ?? 0))
                if let settingsLink {
                    do {
                        guard let state = message.settings else { throw BridgeError.invalid("请更新 iPhone App") }
                        try settingsLink.coordinator.receive(state)
                    } catch { settingsLink.coordinator.failed(); transport?.close("API 配置同步失败"); return }
                }
                ready = true; settingsLink?.start(); setStatus("iPhone 已连接 · 可以使用 Codex 3"); return
            }
            transport?.close("配对失败，请在 iPhone 重新扫描二维码"); return
        }
        if settingsLink?.receive(message) == true { return }
        if message.type == "pong" { return }
        guard let id = message.id, let client = clients[id], client.forwarded else { return }
        switch message.type {
        case "bodyAck":
            LinkTrace.emit("upload.ack", ["in_flight": client.uploadInFlight, "remaining": client.uploadBody.count - client.uploadOffset])
            guard uploadWindow > 0, client.uploadInFlight > 0 else { client.fail(502, "Unexpected upload acknowledgement"); return }
            client.uploadInFlight -= 1; client.touch(); pumpUpload(client)
        case "response":
            guard let status = message.status, (100...599).contains(status) else { client.fail(502, "Invalid upstream status"); return }
            client.response(status: status, headers: message.headers ?? [:])
        case "data":
            guard let data = message.data, data.count <= BridgeProtocol.chunk else { client.fail(502, "Invalid response chunk"); return }
            receivedBytes += data.count
            let ackStarted = DispatchTime.now().uptimeNanoseconds
            client.chunk(data) { [weak self, weak client] in
                if client?.closed == false {
                    LinkTrace.emit("download.ack", ["delay_us": (DispatchTime.now().uptimeNanoseconds - ackStarted) / 1000])
                    self?.transport?.send(Message("ack", id: id))
                }
            }
        case "end": completedRequests += 1; client.end()
        case "error": client.fail(502, message.error ?? "iPhone relay failed")
        default: client.fail(502, "Unexpected relay message")
        }
    }
    private func handle(_ request: HTTPRequest, client: HTTPClient) {
        if request.method == "GET" && request.path == "/health" {
            var info: [String: Any] = ["ready": ready, "transport": transportLabel, "status": status,
                "protocol_version": BridgeProtocol.version,
                "transport_diagnostics": transport?.diagnostics ?? [:], "last_disconnect_reason": lastDisconnectReason,
                "upload_window": uploadWindow, "response_window": BridgeProtocol.responseWindow,
                "wire_sent_bytes": transport?.wireBytesSent ?? 0, "wire_received_bytes": transport?.wireBytesReceived ?? 0,
                "completed_requests": completedRequests, "sent_bytes": sentBytes, "received_bytes": receivedBytes,
                "active_requests": clients.values.filter { $0.forwarded && !$0.closed }.map { $0.diagnostic },
                "recent_requests": recentRequests]
            if let coordinator = settingsLink?.coordinator {
                info["api_sync"] = coordinator.status
                info["api_source"] = coordinator.state.effectiveOrigin?.rawValue ?? ""
                info["api_selection"] = coordinator.state.selection.rawValue
            }
            info.merge(additionalDiagnostics?() ?? [:]) { current, _ in current }
            client.fixed(200, body: (try? JSONSerialization.data(withJSONObject: info)) ?? Data()); return
        }
        guard request.headers["authorization"] == "Bearer \(config.localToken)" else { client.fail(401, "Local proxy authentication required"); return }
        let benchmark = request.method == "POST" && request.path == "/bridge/benchmark"
        if benchmark && request.body.count > BridgeProtocol.maxBenchmark { client.fail(413, "Benchmark limited to 4 MiB"); return }
        do { if !benchmark { _ = try RequestPolicy.upstream(base: config.upstreamBase, path: request.path, method: request.method, allowLoopback: transportLabel == "test-tcp") } }
        catch { client.fail(400, "Unsupported API route"); return }
        guard ready, let transport else { client.fail(503, "iPhone Bluetooth relay is not connected. Open Bluetooth Relay on iPhone and pair first."); return }
        if !benchmark, let coordinator = settingsLink?.coordinator, !coordinator.synchronized {
            client.fail(503, "API configuration is synchronizing; retry shortly"); return
        }
        guard clients.values.filter({ $0.forwarded }).count < 4 else { client.fail(429, "At most four API requests may run concurrently"); return }
        client.forwarded = true
        LinkTrace.emit("request.start", ["bytes": request.body.count, "benchmark": benchmark])
        client.requestBytes = request.body.count
        var head = Message(benchmark ? "benchmark" : "request", id: client.id)
        head.baseURL = config.upstreamBase
        head.method = request.method; head.path = request.path
        var headers = RequestPolicy.filteredHeaders(request.headers)
        if !benchmark { headers["authorization"] = "Bearer \(config.apiKey)" }
        head.headers = headers; transport.send(head)
        client.uploadBody = request.body
        sentBytes += request.body.count
        pumpUpload(client)
        refreshStatus()
    }
    private func pumpUpload(_ client: HTTPClient) {
        guard !client.closed, !client.uploadEnded, let transport else { return }
        while client.uploadOffset < client.uploadBody.count && (uploadWindow == 0 || client.uploadInFlight < uploadWindow) {
            let end = min(client.uploadOffset + BridgeProtocol.chunk, client.uploadBody.count)
            var body = Message("body", id: client.id)
            body.data = client.uploadBody.subdata(in: client.uploadOffset..<end)
            client.uploadOffset = end
            if uploadWindow > 0 { client.uploadInFlight += 1 }
            transport.send(body)
        }
        if client.uploadOffset == client.uploadBody.count && client.uploadInFlight == 0 {
            client.uploadEnded = true; client.uploadBody.removeAll()
            transport.send(Message("requestEnd", id: client.id))
        }
        LinkTrace.emit("upload.state", ["in_flight": client.uploadInFlight, "remaining": max(0, client.uploadBody.count - client.uploadOffset),
            "ended": client.uploadEnded])
    }
}

private final class HTTPClient {
    let id = UUID().uuidString
    var onRequest: ((HTTPRequest) -> Void)?
    var onClose: ((String) -> Void)?
    var forwarded = false
    var requestBytes = 0
    var uploadBody = Data()
    var uploadOffset = 0
    var uploadInFlight = 0
    var uploadEnded = false
    func touch() { lastActivity = Date() }
    private var responseBytes = 0
    private var responseStatus: Int?
    private var firstByteAt: Date?
    private var stream: ResponseStreamObserver?
    private var outcome = "active"
    var diagnostic: [String: Any] {
        var result: [String: Any] = ["id": id, "outcome": outcome, "request_bytes": requestBytes,
            "response_bytes": responseBytes, "elapsed_ms": Int(Date().timeIntervalSince(createdAt) * 1000),
            "idle_ms": Int(Date().timeIntervalSince(lastActivity) * 1000)]
        if let responseStatus { result["http_status"] = responseStatus }
        if let firstByteAt { result["first_byte_ms"] = Int(firstByteAt.timeIntervalSince(createdAt) * 1000) }
        if let last = stream?.lastEvent { result["last_event"] = last }
        if let terminal = stream?.terminalEvent { result["terminal_event"] = terminal }
        return result
    }
    private(set) var closed = false
    private let connection: NWConnection
    private var parser = HTTPParser()
    private var parsed = false
    private var started = false
    private var finishing = false
    private var queued = 0
    private var lastActivity = Date()
    private let createdAt = Date()
    private var timer: Timer?
    init(connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .ready: self?.read(); case .failed, .cancelled: self?.close(); default: break }
        }
        connection.start(queue: .main)
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastActivity) > (self.parsed ? 180 : 30) || Date().timeIntervalSince(self.createdAt) > 900 {
                self.fail(504, "Request timed out")
            }
        }
    }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                self.lastActivity = Date()
                if self.parsed { self.fail(400, "One HTTP request per connection is supported"); return }
                do {
                    if let request = try self.parser.append(data) { self.parsed = true; self.onRequest?(request) }
                } catch { self.fail(400, error.localizedDescription); return }
            }
            if error != nil { self.close() }
            else if !complete { self.read() }
            // A TCP half-close is a valid HTTP client; the response may still be written.
            else if !self.parsed { self.close() }
        }
    }
    func response(status: Int, headers: [String: String]) {
        guard !started else { fail(502, "Duplicate response headers"); return }
        started = true
        responseStatus = status
        if headers["content-type"]?.lowercased().hasPrefix("text/event-stream") == true { stream = ResponseStreamObserver() }
        var text = "HTTP/1.1 \(status) Response\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n"
        for (key, value) in headers where ["content-type", "retry-after", "x-request-id", "x-codex-turn-state"].contains(key.lowercased()) {
            if RequestPolicy.safeHeaderValue(value) { text += "\(key): \(value)\r\n" }
        }
        text += "\r\n"; send(Data(text.utf8))
    }
    func chunk(_ data: Data, done: @escaping () -> Void) {
        guard started, !finishing else { fail(502, "Response body before headers"); return }
        if data.isEmpty { done(); return }
        if firstByteAt == nil { firstByteAt = Date() }
        responseBytes += data.count; stream?.append(data)
        var frame = Data("\(String(data.count, radix: 16))\r\n".utf8)
        frame.append(data); frame.append(Data("\r\n".utf8)); send(frame, done: done)
    }
    func end() {
        guard started else { fail(502, "Missing response headers"); return }
        guard !finishing else { return }; finishing = true; outcome = "completed"
        send(Data("0\r\n\r\n".utf8), done: { [weak self] in self?.close() })
    }
    func fixed(_ status: Int, body: Data) {
        guard !started else { close(); return }; started = true; finishing = true
        var data = Data("HTTP/1.1 \(status) Response\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body); send(data, done: { [weak self] in self?.close() })
    }
    func fail(_ status: Int, _ message: String) {
        outcome = "failed"
        if started { close() } // An interrupted SSE must not look like a successfully completed response.
        else { fixed(status, body: (try? JSONSerialization.data(withJSONObject: ["error": ["message": message, "type": "bluetooth_relay_error"]])) ?? Data()) }
    }
    private func send(_ data: Data, done: @escaping () -> Void = {}) {
        guard !closed else { return }
        queued += data.count
        guard queued <= 256 * 1024 else { close(); return }
        lastActivity = Date()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            self.queued -= data.count
            if error != nil { self.close() } else { done() }
        })
    }
    func close() {
        guard !closed else { return }; closed = true
        if outcome == "active" { outcome = stream?.terminalEvent != nil ? "terminal_received" : "cancelled" }
        timer?.invalidate(); timer = nil
        connection.cancel(); onClose?(id); onClose = nil; onRequest = nil
    }
}

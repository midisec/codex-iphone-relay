import Foundation

public struct RelayMetrics {
    public var activeRequests = 0
    public var completedRequests = 0
    public var failedRequests = 0
    public var uploadedBytes = 0
    public var downloadedBytes = 0
    public var upstreamHost: String?
    public init() {}
}

// This is the iPhone's HTTPS implementation; the same engine runs in RelayHarness for host tests.
public final class RelayEngine: NSObject, URLSessionDataDelegate {
    private final class Request {
        let head: Message
        var body = Data()
        var task: URLSessionDataTask?
        var pending = Data()
        var inFlight = 0
        var stream: ResponseStreamObserver?
        var suspended = false
        var completed = false
        var failure: String?
        var touched = Date()
        init(_ head: Message) { self.head = head }
    }
    private let transport: MessageTransport
    private var settingsLink: APISettingsLink?
    private let token: String
    private let allowLoopback: Bool
    private var baseURL: String?
    private var requests = [String: Request]()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 900
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.allowsCellularAccess = true
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private var watchdog: Timer?
    public var onStatus: ((String) -> Void)?
    public var onClose: (() -> Void)?
    public var onAuthenticated: (() -> Void)?
    public var onMetrics: ((RelayMetrics) -> Void)?
    private var metrics = RelayMetrics()
    private var stopped = false
    private var authenticated = false
    private var uploadWindow = 0
    private var clientNonce: String?
    private let serverNonce = Pairing.nonce()
    private var handshakeDeadline = Date().addingTimeInterval(15)

    public init(transport: MessageTransport, token: String, allowLoopback: Bool = false, settings: APISettingsCoordinator? = nil) {
        self.transport = transport; self.token = token; self.allowLoopback = allowLoopback
        super.init()
        if let settings { settingsLink = APISettingsLink(settings) { [weak transport] in transport?.send($0) } }
        transport.onMessage = { [weak self] in self?.receive($0) }
        transport.onClose = { [weak self] reason in self?.stop(reason) }
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.checkTimeouts() }
    }
    public func stop(_ reason: String = "Relay stopped") {
        guard !stopped else { return }; stopped = true
        settingsLink?.stop()
        watchdog?.invalidate(); watchdog = nil
        for request in requests.values { request.task?.cancel() }
        requests.removeAll(); session.invalidateAndCancel()
        publishMetrics()
        transport.close(reason); onStatus?(reason); onClose?(); onClose = nil
    }
    public func cancelActiveRequests(_ reason: String) {
        for id in Array(requests.keys) { fail(id, reason) }
    }
    private func checkTimeouts() {
        if !authenticated && Date() > handshakeDeadline { stop("Pairing timeout"); return }
        for (id, request) in Array(requests) where Date().timeIntervalSince(request.touched) > 180 {
            fail(id, "Request idle timeout")
        }
    }
    private func receive(_ message: Message) {
        guard !stopped else { return }
        if !authenticated {
            if message.type == "hello", message.version != BridgeProtocol.version { stop("请同时更新 Mac 和 iPhone 的蓝牙转发程序"); return }
            if message.type == "hello", clientNonce == nil, message.version == BridgeProtocol.version,
               let nonce = message.nonce, (32...128).contains(nonce.count), token.count >= 32 {
                clientNonce = nonce
                var challenge = Message("challenge"); challenge.nonce = serverNonce
                challenge.proof = Pairing.proof(token: token, text: "server|\(nonce)|\(serverNonce)")
                transport.send(challenge); return
            }
            guard message.type == "authenticate", let clientNonce, let base = message.baseURL,
                  Pairing.verify(message.proof, token: token, text: "client|\(clientNonce)|\(serverNonce)|\(base)"),
                  (try? RequestPolicy.upstream(base: base, path: "/responses", method: "POST", allowLoopback: allowLoopback)) != nil else { stop("Pairing failed"); return }
            if let settingsLink {
                do {
                    guard let state = message.settings else { throw BridgeError.invalid("请更新 Mac App") }
                    try settingsLink.coordinator.receive(state)
                } catch { settingsLink.coordinator.failed(); stop("API 配置同步失败"); return }
            }
            baseURL = message.baseURL; authenticated = true
            uploadWindow = min(BridgeProtocol.responseWindow, max(0, message.uploadWindow ?? 0))
            metrics.upstreamHost = URL(string: base)?.host
            var ready = Message("ready"); ready.uploadWindow = uploadWindow
            ready.settings = settingsLink?.coordinator.state
            transport.send(ready); settingsLink?.start(); onAuthenticated?(); publishMetrics()
            onStatus?("Mac 已连接 · 等待请求"); return
        }
        if settingsLink?.receive(message) == true { return }
        if message.type == "ping" { transport.send(Message("pong")); settingsLink?.retryIfNeeded(); return }
        guard let id = message.id, id.count <= 64 else { stop("Missing request identifier"); return }
        switch message.type {
        case "benchmark":
            guard requests[id] == nil, requests.count < 4 else { fail(id, "Benchmark unavailable"); return }
            requests[id] = Request(message); publishMetrics()
        case "request":
            guard requests[id] == nil else { stop("Duplicate request identifier"); return }
            guard requests.count < 4 else { fail(id, "Too many simultaneous requests"); return }
            guard let path = message.path, let method = message.method,
                  (try? RequestPolicy.upstream(base: message.baseURL ?? baseURL!, path: path, method: method, allowLoopback: allowLoopback)) != nil else { fail(id, "API route rejected"); return }
            requests[id] = Request(message)
            publishMetrics()
        case "body":
            guard let request = requests[id], request.task == nil, !request.completed, let data = message.data,
                  request.body.count + data.count <= (request.head.type == "benchmark" ? BridgeProtocol.maxBenchmark : BridgeProtocol.maxBody) else { fail(id, "Invalid request body"); return }
            request.body.append(data); request.touched = Date()
            if uploadWindow > 0 { transport.send(Message("bodyAck", id: id)) }
            metrics.uploadedBytes += data.count; publishMetrics()
        case "requestEnd": startRequest(id)
        case "ack":
            if let request = requests[id], request.inFlight > 0 { request.inFlight -= 1; request.touched = Date(); pump(id) }
        case "cancel": remove(id)
        default: stop("Unknown protocol message")
        }
    }
    private func startRequest(_ id: String) {
        guard let request = requests[id], request.task == nil, !request.completed else { fail(id, "Invalid request state"); return }
        if request.head.type == "benchmark" {
            var head = Message("response", id: id); head.status = 200
            head.headers = ["content-type": "application/octet-stream"]; transport.send(head)
            request.pending = request.body; request.body.removeAll(); request.completed = true
            metrics.downloadedBytes += request.pending.count
            pump(id); return
        }
        do {
            let url = try RequestPolicy.upstream(base: request.head.baseURL ?? baseURL!, path: request.head.path!, method: request.head.method!, allowLoopback: allowLoopback)
            var upstream = URLRequest(url: url)
            upstream.httpMethod = request.head.method
            // Authorization originates in the local proxy's config, never in a remote URL or redirect.
            let headers = request.head.headers ?? [:]
            for (name, value) in RequestPolicy.filteredHeaders(headers) { upstream.setValue(value, forHTTPHeaderField: name) }
            guard let auth = headers["authorization"], auth.hasPrefix("Bearer "), RequestPolicy.safeHeaderValue(auth) else { throw BridgeError.invalid("Missing upstream authorization") }
            upstream.setValue(auth, forHTTPHeaderField: "Authorization")
            upstream.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            if request.head.method == "POST" { upstream.httpBody = request.body }
            request.body.removeAll()
            let task = session.dataTask(with: upstream); task.taskDescription = id
            request.task = task; task.resume(); onStatus?("正在通过 iPhone 请求 API")
        } catch { fail(id, error.localizedDescription) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward the API key across an upstream redirect.
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let id = dataTask.taskDescription, let request = requests[id], let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        request.touched = Date()
        if http.statusCode == 200, request.head.path == "/responses",
           http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true {
            request.stream = ResponseStreamObserver()
        }
        var message = Message("response", id: id); message.status = http.statusCode
        var headers = [String: String]()
        for name in ["Content-Type", "Retry-After", "X-Request-ID", "x-codex-turn-state"] {
            if let value = http.value(forHTTPHeaderField: name) { headers[name.lowercased()] = value }
        }
        message.headers = headers; transport.send(message); completionHandler(.allow)
    }
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let id = dataTask.taskDescription, let request = requests[id], !request.completed else { return }
        guard request.pending.count + data.count <= 4 * 1024 * 1024 else { fail(id, "Response buffer exceeded; Bluetooth peer is too slow"); return }
        request.touched = Date(); request.pending.append(data)
        request.stream?.append(data)
        if request.stream?.terminalEvent != nil {
            // Some compatible providers leave HTTP open after the terminal SSE event.
            // Drain every received byte and finish without waiting for HTTP EOF.
            request.completed = true; request.task?.cancel()
        }
        metrics.downloadedBytes += data.count; publishMetrics()
        if !request.completed && request.pending.count >= 256 * 1024 && !request.suspended { request.task?.suspend(); request.suspended = true }
        pump(id)
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription, let request = requests[id], !request.completed else { return }
        request.completed = true
        if let error { request.failure = "iPhone HTTPS request failed (\((error as NSError).code))" }
        else if request.stream != nil && request.stream?.terminalEvent == nil {
            request.failure = "API stream ended without a response completion event; retry the turn"
        }
        pump(id)
    }
    private func pump(_ id: String) {
        guard let request = requests[id] else { return }
        while !request.pending.isEmpty && request.inFlight < BridgeProtocol.responseWindow {
            let chunk = Data(request.pending.prefix(BridgeProtocol.chunk))
            request.pending.removeFirst(chunk.count)
            request.inFlight += 1
            var message = Message("data", id: id); message.data = chunk; transport.send(message)
            if !request.completed && request.suspended && request.pending.count < 128 * 1024 { request.suspended = false; request.task?.resume() }
        }
        if request.pending.isEmpty && request.inFlight == 0 && request.completed {
            if let failure = request.failure { fail(id, failure) }
            else { metrics.completedRequests += 1; transport.send(Message("end", id: id)); remove(id); onStatus?("请求完成 · Mac 已连接") }
        }
    }
    private func publishMetrics() { metrics.activeRequests = requests.count; onMetrics?(metrics) }
    private func remove(_ id: String) {
        requests.removeValue(forKey: id)?.task?.cancel(); publishMetrics()
        if requests.isEmpty && !stopped { onStatus?("Mac 已连接 · 等待请求") }
    }
    private func fail(_ id: String, _ error: String) {
        metrics.failedRequests += 1
        remove(id); var message = Message("error", id: id); message.error = error; transport.send(message)
        onStatus?(error)
    }
}

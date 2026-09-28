import Foundation
import BridgeCore

var passed = 0
func check(_ name: String, _ condition: @autoclosure () -> Bool) {
    guard condition() else { fatalError("FAIL: \(name)") }
    passed += 1; print("PASS: \(name)")
}
func rejects(_ name: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAIL: \(name) accepted invalid input") }
    catch { passed += 1; print("PASS: \(name)") }
}

var sample = Message("data", id: "test"); sample.data = Data("中文 🔵\u{0} raw".utf8)
let frame = try FrameDecoder.encode(sample)
for split in 0...frame.count {
    var decoder = FrameDecoder()
    let one = try decoder.append(Data(frame.prefix(split)))
    let two = try decoder.append(Data(frame.dropFirst(split)))
    let messages = one + two
    precondition(messages.count == 1 && messages[0].data == sample.data)
}
check("frame can split at every byte boundary", true)
var decoder = FrameDecoder()
let coalesced = try decoder.append(frame + frame + frame)
check("coalesced frames preserve order", coalesced.count == 3)
rejects("oversized frame") { var d = FrameDecoder(); _ = try d.append(Data([0, 3, 0, 0])) }
rejects("zero frame") { var d = FrameDecoder(); _ = try d.append(Data([0, 0, 0, 0])) }
rejects("invalid frame JSON") { var d = FrameDecoder(); _ = try d.append(Data([0, 0, 0, 1, 0])) }
var p = HTTPParser()
let request = Data("POST /responses HTTP/1.1\r\nHost: localhost\r\nContent-Length: 6\r\n\r\n你好".utf8)
var result: HTTPRequest?
for byte in request { if let req = try p.append(Data([byte])) { result = req } }
check("HTTP request split byte by byte", result?.body == Data("你好".utf8))
for (name, value) in [
    ("duplicate length", "Content-Length: 0\r\nContent-Length: 0"),
    ("negative length", "Content-Length: -1"),
    ("ambiguous length", "Content-Length: +1"),
    ("oversized body", "Content-Length: 16777217"),
    ("chunked upload", "Transfer-Encoding: chunked"),
    ("missing length", "Host: localhost"),
    ("header whitespace smuggling", "Content-Length : 0")
] {
    rejects(name) { var parser = HTTPParser(); _ = try parser.append(Data("POST /responses HTTP/1.1\r\n\(value)\r\n\r\n".utf8)) }
}
rejects("pipelined requests") { var parser = HTTPParser(); _ = try parser.append(Data("GET /models HTTP/1.1\r\n\r\nGET /models HTTP/1.1\r\n\r\n".utf8)) }
rejects("absolute proxy target") { var parser = HTTPParser(); _ = try parser.append(Data("GET https://evil.invalid HTTP/1.1\r\n\r\n".utf8)) }
let upstream = try RequestPolicy.upstream(base: "https://example.invalid/v1/", path: "/responses", method: "POST")
check("base URL path is preserved", upstream.absoluteString == "https://example.invalid/v1/responses")
for path in ["//evil.invalid/responses", "/responses/../other", "/responses?url=evil", "/v1/responses"] {
    rejects("reject unsupported route \(path)") { _ = try RequestPolicy.upstream(base: "https://example.invalid", path: path, method: "POST") }
}
rejects("production plaintext upstream") { _ = try RequestPolicy.upstream(base: "http://127.0.0.1", path: "/responses", method: "POST") }
rejects("URL embedded credentials") { _ = try RequestPolicy.upstream(base: "https://user:password@example.invalid", path: "/responses", method: "POST") }
let filtered = RequestPolicy.filteredHeaders(["authorization": "secret", "host": "evil.invalid", "content-type": "application/json", "accept": "a\r\nb: c", "cookie": "secret"])
check("header allowlist removes routing and credential injection", filtered == ["content-type": "application/json"])
let token = String(repeating: "a", count: 64)
let proof = Pairing.proof(token: token, text: "server|nonce1|nonce2")
check("pairing proof validates", Pairing.verify(proof, token: token, text: "server|nonce1|nonce2"))
check("wrong pairing secret rejected", !Pairing.verify(proof, token: "bad", text: "server|nonce1|nonce2"))
check("replayed nonce rejected", !Pairing.verify(proof, token: token, text: "server|nonce1|nonce3"))
check("client and server proofs cannot be reflected", !Pairing.verify(proof, token: token, text: "client|nonce1|nonce2"))
let parsedQR = try PairingCode.parse("codex-ble://pair?token=\(token)")
check("iPhone QR pairing roundtrip", parsedQR == token)
let parsedPaste = try PairingCode.parse(" \n\(token.uppercased())\n")
check("iPhone pasted pairing code normalizes whitespace and case", parsedPaste == token)
for invalid in ["https://evil.invalid/?token=\(token)", "codex-ble://pair?token=\(token)&token=\(token)",
                "codex-ble://pair/path?token=\(token)", "codex-ble://pair?token=\(token)#extra", "a", String(repeating: "Ｇ", count: 64)] {
    rejects("invalid iPhone pairing payload") { _ = try PairingCode.parse(invalid) }
}
print("\(passed) core checks passed")

var compressible = Message("data", id: "compressed")
compressible.data = Data(String(repeating: "中文 response.output_text.delta ", count: 600).utf8)
let packed = try FrameDecoder.encode(compressible)
check("repetitive SSE frame compresses by more than 80 percent", packed.count < compressible.data!.count / 5)
for split in 0...packed.count {
    var d = FrameDecoder()
    let decoded = try d.append(Data(packed.prefix(split))) + d.append(Data(packed.dropFirst(split)))
    precondition(decoded.count == 1 && decoded[0].data == compressible.data)
}
check("compressed frame roundtrips at every byte boundary", true)
rejects("compressed expansion bomb") { var d = FrameDecoder(); _ = try d.append(Data([128,0,0,5,0,3,0,0,1])) }
rejects("corrupt compressed data") { var d = FrameDecoder(); _ = try d.append(Data([128,0,0,6,0,0,4,0,1,2])) }
let terminal = Data("event: response.completed\r\ndata: {\"type\":\r\ndata: \"response.completed\"}\r\n\r\n".utf8)
for split in 0...terminal.count {
    var observer = ResponseStreamObserver()
    observer.append(Data(terminal.prefix(split))); observer.append(Data(terminal.dropFirst(split)))
    precondition(observer.terminalEvent == "response.completed")
}
check("terminal SSE supports split CRLF and multiline JSON", true)
var observer = ResponseStreamObserver()
observer.append(Data("data: {\"type\":\"response.output_text.done\",\"text\":\"response.completed\"}\n\n".utf8))
check("text completion is not response completion", observer.terminalEvent == nil)
observer.append(Data("data: {\"type\":\"response.completed\"}\n".utf8))
check("partial SSE event is not considered completed", observer.terminalEvent == nil)
observer.append(Data("\n".utf8))
check("complete terminal event is recognized", observer.terminalEvent == "response.completed")
print("\(passed) total core checks passed")

final class BackpressuredOutput: OutputStream {
    var budget = 0
    var limit = 11
    var zeroNext = false
    var captured = Data()
    private weak var targetDelegate: StreamDelegate?
    init() { super.init(toMemory: ()) }
    override var delegate: StreamDelegate? { get { targetDelegate } set { targetDelegate = newValue } }
    override func close() { budget = 0 }
    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}
    override var hasSpaceAvailable: Bool { budget > 0 }
    override func write(_ buffer: UnsafePointer<UInt8>, maxLength len: Int) -> Int {
        if zeroNext { zeroNext = false; return 0 }
        let amount = min(budget, limit, len)
        captured.append(buffer, count: amount); budget -= amount
        return amount
    }
}
let blockedOutput = BackpressuredOutput()
let prioritized = StreamTransport(input: InputStream(data: Data()), output: blockedOutput)
var firstBody = Message("body", id: "first"); firstBody.data = Data((0..<128).map(UInt8.init))
var secondBody = Message("body", id: "second"); secondBody.data = Data([7, 8, 9])
blockedOutput.budget = 7
prioritized.send(firstBody) // Leave a partial frame; priority traffic may not splice it.
prioritized.send(Message("request", id: "second"))
prioritized.send(secondBody)
prioritized.send(Message("requestEnd", id: "second"))
prioritized.send(Message("ack", id: "one"))
prioritized.send(Message("pong"))
prioritized.send(Message("ack", id: "two"))
check("backpressure retains queued bytes", (prioritized.diagnostics["queued_bytes"] as? Int ?? 0) > 0)
blockedOutput.budget = 100_000
prioritized.stream(blockedOutput, handle: .hasSpaceAvailable)
var priorityDecoder = FrameDecoder()
let reordered = try priorityDecoder.append(blockedOutput.captured)
check("priority acks never split a partially written frame", reordered.first?.data == firstBody.data)
check("acks bypass unsent payload and preserve priority FIFO", reordered.map(\.type) == ["body", "ack", "pong", "ack", "request", "body", "requestEnd"] && reordered[1].id == "one" && reordered[3].id == "two")
check("request body and end retain order and contents", reordered[4].id == "second" && reordered[5].data == secondBody.data && reordered[6].id == "second")
check("partial writes drain without losing bytes", prioritized.wireBytesSent == blockedOutput.captured.count && prioritized.diagnostics["queued_bytes"] as? Int == 0)
let zeroOutput = BackpressuredOutput(); zeroOutput.budget = 1000; zeroOutput.zeroNext = true
let zeroStream = StreamTransport(input: InputStream(data: Data()), output: zeroOutput)
zeroStream.send(Message("ping"))
check("zero-byte write waits without discarding data", zeroStream.wireBytesSent == 0 && zeroStream.diagnostics["zero_writes"] as? Int == 1)
zeroStream.stream(zeroOutput, handle: .hasSpaceAvailable)
var zeroDecoder = FrameDecoder()
let resumedMessages = try zeroDecoder.append(zeroOutput.captured)
check("writable callback resumes a zero-byte write", resumedMessages.map(\.type) == ["ping"])
let closedOutput = BackpressuredOutput()
let closedStream = StreamTransport(input: InputStream(data: Data()), output: closedOutput)
closedStream.send(firstBody); closedStream.close("test")
closedOutput.budget = 100_000; closedStream.stream(closedOutput, handle: .hasSpaceAvailable)
check("close drops pending work and ignores late writable callback", closedOutput.captured.isEmpty && closedStream.diagnostics["queued_bytes"] as? Int == 0)
prioritized.close("test"); zeroStream.close("test")
print("\(passed) total core checks passed")

let raw = Data((0..<BridgeProtocol.chunk).map { _ in UInt8.random(in: 0...255) })
var binary = Message("body", id: "binary-check"); binary.data = raw
let binaryFrame = try FrameDecoder.encode(binary)
check("random binary payload has at most 18 bytes of overhead", binaryFrame.count <= raw.count + 18)
var binaryDecoder = FrameDecoder()
check("binary upload roundtrips", try! binaryDecoder.append(binaryFrame).first?.data == raw)
for malformed: [UInt8] in [[64,0,0,2,3,0], [64,0,0,2,1,65], [64,0,0,3,1,1,255], [64,0,0,2,1,1]] {
    rejects("invalid binary envelope") { var d = FrameDecoder(); _ = try d.append(Data(malformed)) }
}
var overlong = Message("data", id: "oversized"); overlong.data = Data(count: BridgeProtocol.chunk + 1)
rejects("oversized binary payload rejected") { _ = try FrameDecoder.encode(overlong) }
print("\(passed) total core checks passed")

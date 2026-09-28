import Foundation
import Network
import CryptoKit
import Compression

public enum BridgeError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum BridgeProtocol {
    public static let service = "E291E591-985B-46CC-B32B-7C93BD69D40A"
    public static let psm = "E291E592-985B-46CC-B32B-7C93BD69D40A"
    public static let control = "E291E593-985B-46CC-B32B-7C93BD69D40A"
    public static let version = 3
    public static let chunk = 32 * 1024
    public static let responseWindow = 4
    public static let usbPort: UInt16 = 48765
    public static let maxBenchmark = 4 * 1024 * 1024
    public static let maxBody = 16 * 1024 * 1024
    public static let maxFrame = 128 * 1024
    public static let maxQueue = 24 * 1024 * 1024
}

public struct Message: Codable {
    public var type: String
    public var id: String?
    public var nonce: String?
    public var proof: String?
    public var version: Int?
    public var uploadWindow: Int?
    public var baseURL: String?
    public var method: String?
    public var path: String?
    public var headers: [String: String]?
    public var status: Int?
    public var data: Data?
    public var error: String?
    public var settings: APISettingsState?
    public var settingsDigest: String?
    public init(_ type: String, id: String? = nil) { self.type = type; self.id = id }
}

public enum Pairing {
    public static func nonce() -> String { UUID().uuidString + UUID().uuidString }
    public static func proof(token: String, text: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)).base64EncodedString()
    }
    public static func verify(_ proof: String?, token: String, text: String) -> Bool {
        guard let proof, let bytes = Data(base64Encoded: proof) else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(bytes, authenticating: Data(text.utf8), using: SymmetricKey(data: Data(token.utf8)))
    }
}

public struct FrameDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [Message] {
        buffer.append(data)
        var messages: [Message] = []
        var offset = 0
        while buffer.count - offset >= 4 {
            let header = buffer.dropFirst(offset).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let compressed = header & 0x8000_0000 != 0
            let binary = header & 0x4000_0000 != 0
            let length = Int(header & 0x3fff_ffff)
            guard length > 0 && length <= BridgeProtocol.maxFrame else { throw BridgeError.invalid("Invalid frame size") }
            guard buffer.count - offset >= length + 4 else { break }
            var body = buffer.subdata(in: (offset + 4)..<(offset + 4 + length))
            if compressed {
                // A bounded destination also rejects compression bombs and truncated streams.
                guard body.count > 4 else { throw BridgeError.invalid("Invalid compressed frame") }
                let expected = body.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
                guard expected > 0 && expected <= BridgeProtocol.maxFrame else { throw BridgeError.invalid("Invalid expanded frame size") }
                var decoded = Data(count: expected + 1)
                let size = decoded.withUnsafeMutableBytes { destination in
                    body.dropFirst(4).withUnsafeBytes { source in
                        compression_decode_buffer(destination.baseAddress!.assumingMemoryBound(to: UInt8.self), expected + 1,
                            source.baseAddress!.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_ZLIB)
                    }
                }
                guard size == expected else { throw BridgeError.invalid("Corrupt compressed frame") }
                decoded.count = size; body = decoded
            }
            if binary {
                guard body.count >= 2, body[0] == 1 || body[0] == 2 else { throw BridgeError.invalid("Invalid binary frame type") }
                let idLength = Int(body[1])
                guard (1...64).contains(idLength), body.count >= 2 + idLength,
                      body.count - 2 - idLength <= BridgeProtocol.chunk,
                      let id = String(data: body.subdata(in: 2..<(2 + idLength)), encoding: .utf8) else { throw BridgeError.invalid("Invalid binary frame") }
                var message = Message(body[0] == 1 ? "body" : "data", id: id)
                message.data = body.subdata(in: (2 + idLength)..<body.count); messages.append(message)
            } else { messages.append(try JSONDecoder().decode(Message.self, from: body)) }
            offset += length + 4
        }
        if offset > 0 { buffer = Data(buffer.dropFirst(offset)) }
        guard buffer.count <= BridgeProtocol.maxFrame + 4 else { throw BridgeError.invalid("Frame buffer exceeded") }
        return messages
    }
    public static func encode(_ message: Message) throws -> Data {
        var body: Data
        var flag: UInt32 = 0
        if ["body", "data"].contains(message.type), let id = message.id, let payload = message.data {
            let identifier = Data(id.utf8)
            guard (1...64).contains(identifier.count), payload.count <= BridgeProtocol.chunk else { throw BridgeError.invalid("Invalid binary payload") }
            body = Data([message.type == "body" ? 1 : 2, UInt8(identifier.count)]) + identifier + payload
            flag = 0x4000_0000
        } else { body = try JSONEncoder().encode(message) }
        guard body.count <= BridgeProtocol.maxFrame else { throw BridgeError.invalid("Frame too large") }
        // Binary payloads avoid base64 allocation/expansion. Text still compresses;
        // small SSE events are sent immediately without aggregation delays.
        if body.count >= 1024 {
            var compressed = Data(count: body.count)
            let size = compressed.withUnsafeMutableBytes { destination in
                body.withUnsafeBytes { source in
                    compression_encode_buffer(destination.baseAddress!.assumingMemoryBound(to: UInt8.self), destination.count,
                        source.baseAddress!.assumingMemoryBound(to: UInt8.self), source.count, nil, COMPRESSION_ZLIB)
                }
            }
            if size > 0 && size + 4 < body.count * 9 / 10 {
                compressed.count = size
                var expanded = UInt32(body.count).bigEndian
                body = withUnsafeBytes(of: &expanded) { Data($0) } + compressed
                flag |= 0x8000_0000
            }
        }
        var count = (UInt32(body.count) | flag).bigEndian
        var result = withUnsafeBytes(of: &count) { Data($0) }
        result.append(body)
        return result
    }
}

// All transports and their callbacks are confined to the main queue/run loop.
public protocol MessageTransport: AnyObject {
    var diagnostics: [String: Any] { get }
    var wireBytesSent: Int { get }
    var wireBytesReceived: Int { get }
    var onMessage: ((Message) -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    func send(_ message: Message)
    func close(_ reason: String)
}

public extension MessageTransport { var diagnostics: [String: Any] { [:] } }

public final class StreamTransport: NSObject, MessageTransport, StreamDelegate {
    public private(set) var wireBytesSent = 0
    public private(set) var wireBytesReceived = 0
    public var onSend: ((String) -> Void)?
    public var onMessage: ((Message) -> Void)?
    public var onClose: ((String) -> Void)?
    private let writeSize: Int
    private struct PendingFrame {
        let data: Data
        let type: String
        let sequence: Int
        let priority: Bool
        let enqueuedAt: UInt64
    }
    private var nextSequence = 0
    private var controlFrames = 0
    private var maxControlQueueMicroseconds: UInt64 = 0
    private var writeCalls = 0
    private var maxWriteMicroseconds = 0
    private var writeMicroseconds = 0
    private var readCalls = 0
    private var spaceEvents = 0
    private var zeroWrites = 0
    private var queueHighWater = 0
    private var encodeMicroseconds = 0
    private var decodeMicroseconds = 0
    private var spaceWaitStarted: UInt64?
    private var spaceWaitMicroseconds: UInt64 = 0
    public var diagnostics: [String: Any] {
        ["write_size": writeSize, "write_calls": writeCalls, "write_microseconds": writeMicroseconds,
         "max_write_microseconds": maxWriteMicroseconds, "queued_bytes": queued,
         "read_calls": readCalls, "space_events": spaceEvents, "zero_writes": zeroWrites,
         "queue_high_water": queueHighWater, "encode_microseconds": encodeMicroseconds,
         "control_frames": controlFrames, "max_control_queue_microseconds": maxControlQueueMicroseconds,
         "decode_microseconds": decodeMicroseconds,
         "space_wait_microseconds": spaceWaitMicroseconds + (spaceWaitStarted.map { (DispatchTime.now().uptimeNanoseconds - $0) / 1000 } ?? 0)]
    }
    private let input: InputStream
    private let output: OutputStream
    private var decoder = FrameDecoder()
    private var pending = [PendingFrame]()
    private var offset = 0
    private var queued = 0
    private var closed = false
    public init(input: InputStream, output: OutputStream, writeSize: Int = 16_384) {
        self.writeSize = min(65_536, max(256, writeSize))
        self.input = input; self.output = output; super.init()
    }
    public func start() {
        for stream in [input as Stream, output as Stream] {
            stream.delegate = self; stream.schedule(in: .main, forMode: .common); stream.open()
        }
    }
    public func send(_ message: Message) {
        guard !closed else { return }
        onSend?(message.type)
        do {
            let started = DispatchTime.now().uptimeNanoseconds
            let data = try FrameDecoder.encode(message)
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1000)
            encodeMicroseconds += elapsed
            guard queued + data.count <= BridgeProtocol.maxQueue else { throw BridgeError.invalid("Bluetooth send queue exceeded") }
            // Acks unblock traffic in the opposite direction. Keep FIFO within each class,
            // and never interrupt a partially written frame or reorder request/body/end.
            let priority = data.count <= 512 && ["ack", "bodyAck", "ping", "pong", "settingsAck"].contains(message.type)
            nextSequence += 1
            let frame = PendingFrame(data: data, type: message.type, sequence: nextSequence,
                priority: priority, enqueuedAt: DispatchTime.now().uptimeNanoseconds)
            if priority {
                var index = offset > 0 ? 1 : 0
                while index < pending.count && pending[index].priority { index += 1 }
                pending.insert(frame, at: index)
            } else { pending.append(frame) }
            queued += data.count; queueHighWater = max(queueHighWater, queued)
            LinkTrace.emit("frame.enqueue", ["type": message.type, "sequence": frame.sequence,
                "priority": priority, "bytes": data.count, "queued": queued, "encode_us": elapsed])
            flush()
        } catch { close(error.localizedDescription) }
    }
    private func flush() {
        guard !closed else { return }
        if output.hasSpaceAvailable { finishSpaceWait() }
        while !pending.isEmpty && output.hasSpaceAvailable && !closed {
            let started = DispatchTime.now().uptimeNanoseconds
            let written = pending[0].data.withUnsafeBytes { bytes -> Int in
                output.write(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self).advanced(by: offset), maxLength: min(writeSize, bytes.count - offset))
            }
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1000)
            writeCalls += 1; writeMicroseconds += elapsed; maxWriteMicroseconds = max(maxWriteMicroseconds, elapsed)
            LinkTrace.emit("stream.write", ["bytes": written, "queued_before": queued, "cpu_us": elapsed])
            if written < 0 { close("Bluetooth write failed"); return }
            if written == 0 { zeroWrites += 1; beginSpaceWait(); return }
            offset += written; queued -= written
            wireBytesSent += written
            if offset == pending[0].data.count {
                let frame = pending.removeFirst(); offset = 0
                let delay = (DispatchTime.now().uptimeNanoseconds - frame.enqueuedAt) / 1000
                if frame.priority { controlFrames += 1; maxControlQueueMicroseconds = max(maxControlQueueMicroseconds, delay) }
                LinkTrace.emit("frame.sent", ["type": frame.type, "sequence": frame.sequence, "queue_us": delay])
            }
        }
        if queued > 0 && !closed { beginSpaceWait() }
    }
    private func beginSpaceWait() {
        guard spaceWaitStarted == nil else { return }
        spaceWaitStarted = DispatchTime.now().uptimeNanoseconds
        LinkTrace.emit("stream.wait", ["queued": queued])
    }
    private func finishSpaceWait() {
        guard let started = spaceWaitStarted else { return }
        let elapsed = (DispatchTime.now().uptimeNanoseconds - started) / 1000
        spaceWaitMicroseconds += elapsed; spaceWaitStarted = nil
        LinkTrace.emit("stream.resume", ["wait_us": elapsed, "queued": queued])
    }
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.errorOccurred) || eventCode.contains(.endEncountered) { close("Bluetooth stream disconnected"); return }
        if eventCode.contains(.hasSpaceAvailable) {
            spaceEvents += 1
            LinkTrace.emit("stream.space", ["queued": queued, "available": output.hasSpaceAvailable])
            flush()
        }
        if eventCode.contains(.hasBytesAvailable) {
            var bytes = [UInt8](repeating: 0, count: 32_768)
            while input.hasBytesAvailable && !closed {
                let count = input.read(&bytes, maxLength: bytes.count)
                readCalls += 1
                LinkTrace.emit("stream.read", ["bytes": count])
                if count < 0 { close("Bluetooth read failed"); return }
                if count == 0 { break }
                wireBytesReceived += count
                do {
                    let started = DispatchTime.now().uptimeNanoseconds
                    let messages = try decoder.append(Data(bytes.prefix(count)))
                    decodeMicroseconds += Int((DispatchTime.now().uptimeNanoseconds - started) / 1000)
                    for message in messages where !closed {
                        LinkTrace.emit("frame.receive", ["type": message.type, "bytes": message.data?.count ?? 0])
                        onMessage?(message)
                    }
                }
                catch { close("Invalid Bluetooth frame: " + error.localizedDescription); return }
            }
        }
    }
    public func close(_ reason: String) {
        guard !closed else { return }; closed = true
        finishSpaceWait(); LinkTrace.emit("stream.close")
        for stream in [input as Stream, output as Stream] {
            stream.close(); stream.remove(from: .main, forMode: .common); stream.delegate = nil
        }
        pending.removeAll(); queued = 0
        onClose?(reason); onClose = nil; onMessage = nil
    }
}

// Framed Network.framework stream, used by the explicit TCP harness and USB multiplexing.
public final class TCPTransport: MessageTransport {
    public var onSend: ((String) -> Void)?
    public private(set) var wireBytesSent = 0
    public private(set) var wireBytesReceived = 0
    public var onMessage: ((Message) -> Void)?
    public var onClose: ((String) -> Void)?
    private let connection: NWConnection
    private var decoder = FrameDecoder()
    private var closed = false
    private var queued = 0
    public init(_ connection: NWConnection) { self.connection = connection }
    public func start(alreadyConnected: Bool = false, ready: @escaping () -> Void = {}) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: ready(); self.read()
            case .failed: self.close("数据通道已断开")
            case .cancelled: self.close("数据通道已取消")
            default: break
            }
        }
        if alreadyConnected { ready(); read() } else { connection.start(queue: .main) }
    }
    private func read() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do { if let data { self.wireBytesReceived += data.count; for message in try self.decoder.append(data) { self.onMessage?(message) } } }
            catch { self.close("Invalid transport frame"); return }
            if complete || error != nil { self.close("数据通道已结束") } else { self.read() }
        }
    }
    public func send(_ message: Message) {
        guard !closed else { return }
        onSend?(message.type)
        do {
            let data = try FrameDecoder.encode(message)
            guard queued + data.count <= BridgeProtocol.maxQueue else { throw BridgeError.invalid("Test send queue exceeded") }
            queued += data.count
            wireBytesSent += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                self?.queued -= data.count
                if error != nil { self?.close("Test transport write failed") }
            })
        } catch { close(error.localizedDescription) }
    }
    public func close(_ reason: String) {
        guard !closed else { return }; closed = true
        connection.stateUpdateHandler = nil
        connection.cancel(); onClose?(reason); onClose = nil; onMessage = nil
    }
}

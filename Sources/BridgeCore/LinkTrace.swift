import Foundation
import Darwin

/// Opt-in timing capture. Never records payloads, addresses, headers or credentials.
/// Call only on the main queue, like the transports. Disk work uses a separate queue.
public final class LinkTrace {
    private static var recorder: LinkTrace?
    private let file: FileHandle
    private let writer = DispatchQueue(label: "local.bluetoothcodex.trace", qos: .utility)
    private var timer: Timer?
    private var count = 0
    private let start = DispatchTime.now().uptimeNanoseconds
    private var lastTick = DispatchTime.now().uptimeNanoseconds

    public static func start(path: String) throws {
        // Exclusive creation avoids following symlinks or overwriting an existing capture.
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw BridgeError.invalid("无法创建新的链路诊断文件") }
        recorder = LinkTrace(file: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
    }
    private init(file: FileHandle) {
        self.file = file
        append("trace.start", ["unix_seconds": Date().timeIntervalSince1970, "format": 1])
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            self.append("main.tick", ["gap_us": (now - self.lastTick) / 1000])
            self.lastTick = now
        }
        RunLoop.main.add(timer!, forMode: .common)
    }
    public static func emit(_ event: String, _ fields: [String: Any] = [:]) {
        recorder?.append(event, fields)
    }
    private func append(_ event: String, _ fields: [String: Any]) {
        guard count < 100_000 else { timer?.invalidate(); timer = nil; return }
        count += 1
        var record = fields
        record["event"] = count == 100_000 ? "trace.limit" : event
        record["us"] = (DispatchTime.now().uptimeNanoseconds - start) / 1000
        let immutable = record
        writer.async { [file] in
            guard var bytes = try? JSONSerialization.data(withJSONObject: immutable, options: [.sortedKeys]) else { return }
            bytes.append(10)
            try? file.write(contentsOf: bytes)
        }
    }
}

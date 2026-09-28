import Foundation
import Darwin
import BridgeCore

func address() -> sockaddr_in {
    var value = sockaddr_in()
    value.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    value.sin_family = sa_family_t(AF_INET)
    value.sin_port = UInt16(48765).bigEndian
    value.sin_addr.s_addr = inet_addr("127.0.0.1")
    return value
}
func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
    var value = address()
    return withUnsafePointer(to: &value) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
}
func wait(_ seconds: TimeInterval, until predicate: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    return predicate()
}
func portAcceptsConnections() -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    return withAddress { connect(fd, $0, $1) } == 0
}
func check(_ condition: Bool, _ description: String) {
    guard condition else { fputs("FAIL: \(description)\n", stderr); exit(1) }
    print("PASS: \(description)")
}

let blocker = socket(AF_INET, SOCK_STREAM, 0)
check(withAddress { bind(blocker, $0, $1) } == 0 && listen(blocker, 1) == 0,
      "reserve the phone listener port on the test Mac")
let server = USBRelayServer()
var sawFailure = false
server.onStatus = { if $0.contains("恢复") || $0.contains("重试") { sawFailure = true } }
try server.start(token: String(repeating: "a", count: 64))
check(wait(3, until: { sawFailure }), "listener reports an occupied port")
close(blocker)
check(wait(8, until: { portAcceptsConnections() }), "listener recovers after the port becomes available")
server.prepareForConnection(rebuildListener: true)
check(wait(3, until: { portAcceptsConnections() }), "explicit USB recovery reopens a previously ready listener")
server.stop()
_ = wait(4, until: { false })
check(!portAcceptsConnections(), "stopped relay stays stopped after pending retry timers")
try server.start(token: String(repeating: "a", count: 64))
check(wait(3, until: { portAcceptsConnections() }), "explicit restart opens the listener again")
server.stop()

// Stop during a failure retry, then ensure the delayed callback cannot revive it.
let secondBlocker = socket(AF_INET, SOCK_STREAM, 0)
var reuse: Int32 = 1
setsockopt(secondBlocker, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
_ = wait(1, until: { false })
check(withAddress { bind(secondBlocker, $0, $1) } == 0 && listen(secondBlocker, 1) == 0,
      "reserve the port again for cancellation coverage")
sawFailure = false
try server.start(token: String(repeating: "a", count: 64))
check(wait(3, until: { sawFailure }), "retry is scheduled before stop")
server.stop(); close(secondBlocker)
server.prepareForConnection(rebuildListener: true)
_ = wait(4, until: { false })
check(!portAcceptsConnections(), "stop cancels scheduled recovery")

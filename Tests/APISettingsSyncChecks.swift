import Foundation
@testable import BridgeCore

var passed = 0
func check(_ name: String, _ value: @autoclosure () throws -> Bool) {
    precondition((try? value()) == true, "FAIL: \(name)"); passed += 1; print("PASS: \(name)")
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); fatalError("FAIL: \(name)") } catch { passed += 1; print("PASS: \(name)") }
}
func draft(_ name: String) -> APIConfigurationDraft {
    APIConfigurationDraft(baseURL: "https://\(name).example.org/v1", apiKey: "synthetic-key-\(name)", model: "model-\(name)")
}
var mac = APISettingsState()
try mac.edit(draft("mac"), origin: .computer, selection: .automatic, now: 100)
var phone = APISettingsState()
try phone.edit(draft("phone"), origin: .phone, selection: .automatic, now: 200)
let merged = try mac.merged(with: phone)
check("offline edits converge in both directions", try merged == phone.merged(with: mac))
check("automatic selects newest save", merged.effectiveOrigin == .phone)
check("both source profiles are retained", merged.computer != nil && merged.phone != nil)
check("merge is idempotent", try merged.merged(with: merged) == merged)
mac = merged
try mac.edit(draft("mac2"), origin: .computer, selection: .automatic, now: 50)
check("observed peer edit precedes new edit despite clock skew", mac.effectiveOrigin == .computer)
check("hybrid clock advances logically", mac.computer!.revision.milliseconds == 200 && mac.computer!.revision.logical == 1)
phone = try phone.merged(with: mac)
try phone.edit(nil, origin: .phone, selection: .phone, now: 20)
mac = try mac.merged(with: phone)
check("phone can pin its own source on both ends", mac.selection == .phone && mac.effectiveOrigin == .phone)
try mac.edit(draft("mac3"), origin: .computer, selection: .phone, now: 300)
check("manual source remains pinned across other-side edit", mac.effectiveOrigin == .phone)
try phone.edit(nil, origin: .phone, selection: .computer, now: 400)
mac = try mac.merged(with: phone)
check("phone can select computer settings", mac.effectiveOrigin == .computer && mac.effective?.model == "model-mac3")
try mac.edit(nil, origin: .computer, selection: .automatic, now: 500)
phone = try phone.merged(with: mac)
check("return to automatic selects newest saved profile", phone.selection == .automatic && phone.effectiveOrigin == .computer)
check("stale snapshot cannot roll back settings", try phone.merged(with: merged) == phone)
var empty = APISettingsState()
rejects("missing manual source rejected") { try empty.edit(nil, origin: .phone, selection: .computer) }
var conflict = mac; conflict.computer!.credentials.model = "conflicting-model"
rejects("equal-revision conflicting credentials rejected") { _ = try mac.merged(with: conflict) }
var bad = mac; bad.phone!.credentials.baseURL = "http://untrusted.example.org"
rejects("insecure imported API rejected") { _ = try mac.merged(with: bad) }
bad = mac; bad.phone!.revision.logical = Int64.max
rejects("overflowing peer clock rejected") { _ = try mac.merged(with: bad) }
let digest = phone.digest
var keyChange = phone; keyChange.phone!.credentials.apiKey = "different-synthetic-key"
check("digest includes credentials without exposing them", digest != keyChange.digest && digest.count == 64)
var ties = merged; ties.computer!.revision = APIRevision(milliseconds: 700, id: "a"); ties.phone!.revision = APIRevision(milliseconds: 700, id: "b")
check("simultaneous timestamps have deterministic ordering", ties.effectiveOrigin == .phone)
let persisted = try JSONDecoder().decode(APISettingsState.self, from: JSONEncoder().encode(mac))
check("restart preserves profiles and source selection", persisted == mac && persisted.digest == mac.digest)

// Two independently persisted devices, with asynchronous ordered messages.
var savedMac = mac; var savedPhone = merged
var refusePhoneSave = false
let computer = APISettingsCoordinator(origin: .computer, state: mac) { savedMac = $0 }
let handset = APISettingsCoordinator(origin: .phone, state: merged) {
    if refusePhoneSave { throw BridgeError.invalid("simulated Keychain failure") }; savedPhone = $0
}
var toMac = [Message](); var toPhone = [Message]()
let macLink = APISettingsLink(computer) { toPhone.append($0) }
let phoneLink = APISettingsLink(handset) { toMac.append($0) }
func drain() {
    var loops = 0
    while !toMac.isEmpty || !toPhone.isEmpty {
        loops += 1; precondition(loops < 100, "sync must converge without ping-pong")
        let m = toMac; toMac.removeAll(); for message in m { _ = macLink.receive(message) }
        let p = toPhone; toPhone.removeAll(); for message in p { _ = phoneLink.receive(message) }
    }
}
macLink.start(); phoneLink.start(); drain()
check("connecting merges and acknowledges both persisted states", computer.synchronized && handset.synchronized && savedMac == savedPhone)
try handset.update(draft("phone-live"), selection: .automatic)
check("edited settings are pending before acknowledgement", !handset.synchronized)
drain()
check("live phone edit reaches computer", savedMac.effective?.model == "model-phone-live" && savedPhone == savedMac)
try computer.update(nil, selection: .computer); drain()
check("computer can select its retained source", handset.state.effectiveOrigin == .computer && computer.synchronized)
try handset.update(nil, selection: .phone); drain()
check("handset can select phone source", computer.state.effectiveOrigin == .phone && handset.synchronized)
let stable = computer.state
refusePhoneSave = true
try computer.update(draft("failed-remote-save"), selection: .automatic); drain()
check("failed peer storage is not acknowledged", !computer.synchronized && savedPhone == stable && computer.error != nil)
refusePhoneSave = false
macLink.retryIfNeeded(); drain()
check("retry commits and clears sync failure", computer.synchronized && handset.synchronized && computer.error == nil && savedPhone == savedMac)
let beforeFailure = handset.state
refusePhoneSave = true
rejects("local storage failure propagates to editor") { try handset.update(draft("failed-local-save"), selection: .automatic) }
check("local storage failure cannot mutate published state", handset.state == beforeFailure)
refusePhoneSave = false
macLink.stop(); phoneLink.stop()
check("disconnect marks configurations pending", !computer.synchronized && computer.status == "待连接同步")
try computer.update(draft("offline-computer"), selection: .automatic)
try handset.update(draft("offline-phone"), selection: .automatic)
macLink.start(); phoneLink.start(); drain()
check("reconnection merges independent offline saves", computer.state == handset.state && computer.synchronized && handset.synchronized)
check("offline reconnect retains both edits", computer.state.computer?.credentials.model == "model-offline-computer" && computer.state.phone?.credentials.model == "model-offline-phone")
macLink.stop(); phoneLink.stop()
print("\(passed) API synchronization checks passed")

final class TestTransport: MessageTransport {
    var wireBytesSent = 0; var wireBytesReceived = 0
    var onMessage: ((Message) -> Void)?; var onClose: ((String) -> Void)?
    var sent = [Message](); var closed = false
    func send(_ message: Message) { sent.append(message) }
    func close(_ reason: String) { guard !closed else { return }; closed = true; let callback = onClose; onClose = nil; callback?(reason) }
}
let fixture: [String: Any] = ["upstreamBase": "https://computer.example.org/v1", "apiKey": "synthetic",
    "model": "computer", "port": 48793, "localToken": String(repeating: "a", count: 64), "pairingToken": String(repeating: "b", count: 64)]
var configuration = try JSONDecoder().decode(BridgeConfiguration.self, from: JSONSerialization.data(withJSONObject: fixture))
let proxy = LocalProxy(config: configuration)
let localSettings = APISettingsCoordinator(origin: .computer, state: .importing(configuration)) { state in
    let api = state.effective!
    configuration.upstreamBase = api.baseURL; configuration.apiKey = api.apiKey; configuration.model = api.model; configuration.apiSettings = state
    proxy.applySynchronizedConfiguration(configuration)
}
let remoteSettings = APISettingsCoordinator(origin: .phone, state: phone) { _ in }
proxy.synchronize(using: localSettings)
let upstream = TestTransport(); let downstream = TestTransport()
let engine = RelayEngine(transport: downstream, token: configuration.pairingToken, settings: remoteSettings)
proxy.attach(upstream)
func pumpHandshake() {
    var n = 0
    while !upstream.sent.isEmpty || !downstream.sent.isEmpty {
        n += 1; precondition(n < 100)
        let outgoing = upstream.sent; upstream.sent.removeAll()
        for m in outgoing { downstream.onMessage?(m) }
        let incoming = downstream.sent; downstream.sent.removeAll()
        for m in incoming { upstream.onMessage?(m) }
    }
}
pumpHandshake()
check("authenticated handshake merges API state before ready", proxy.ready && localSettings.state == remoteSettings.state && localSettings.synchronized && remoteSettings.synchronized)
try remoteSettings.update(draft("handshake-phone"), selection: .automatic); pumpHandshake()
check("phone live setting updates running proxy without disconnect", proxy.ready && !upstream.closed && configuration.model == "model-handshake-phone" && localSettings.synchronized)
engine.stop(); proxy.stop()
check("stopped transports remove sync acknowledgements", !localSettings.synchronized && !remoteSettings.synchronized)
let untrusted = TestTransport()
var unauthenticatedSaves = 0
let protectedSettings = APISettingsCoordinator(origin: .phone, state: APISettingsState()) { _ in unauthenticatedSaves += 1 }
let protectedEngine = RelayEngine(transport: untrusted, token: configuration.pairingToken, settings: protectedSettings)
var attack = Message("settings"); attack.settings = phone; untrusted.onMessage?(attack)
check("configuration cannot be imported before pairing authentication", untrusted.closed && unauthenticatedSaves == 0 && protectedSettings.state.computer == nil)
protectedEngine.stop()
print("\(passed) API synchronization checks passed")

var firstPhone = APISettingsState()
rejects("first phone save requires its own key") { try firstPhone.edit(APIConfigurationDraft(baseURL: "https://phone.example.org", model: "m"), origin: .phone, selection: .automatic) }
rejects("oversized URL cannot break settings frames") { _ = try APIConfigurationDraft(baseURL: "https://example.org/" + String(repeating: "a", count: 4096), apiKey: "synthetic", model: "m").credentials(retaining: "") }
print("\(passed) API synchronization checks passed")

import Foundation
import BridgeCore

var passed = 0
func check(_ name: String, _ value: @autoclosure () throws -> Bool) {
    precondition((try? value()) == true, "FAIL: \(name)"); passed += 1; print("PASS: \(name)")
}
func rejects(_ name: String, _ action: () throws -> Void) {
    do { try action(); fatalError("FAIL: \(name)") }
    catch { passed += 1; print("PASS: \(name)") }
}
let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temp) }
let configURL = temp.appendingPathComponent("bridge.json")
let profileURL = temp.appendingPathComponent("config.toml")
let fixture: [String: Any] = ["upstreamBase": "https://old.example.org/v1", "apiKey": "synthetic-original-key",
    "model": "original-model", "port": 48791, "localToken": String(repeating: "a", count: 64), "pairingToken": String(repeating: "b", count: 64)]
let originalData = try JSONSerialization.data(withJSONObject: fixture)
try originalData.write(to: configURL)
let original = try BridgeConfiguration.read(configURL.path)
let draft = APIConfigurationDraft(baseURL: " https://new.example.org/custom/v1/ ", model: "new-model")
let normalized = try draft.applying(to: original)
check("HTTPS base path preserved and whitespace normalized", normalized.upstreamBase == "https://new.example.org/custom/v1")
check("empty key preserves original", normalized.apiKey == original.apiKey)
for bad in ["http://example.org", "https://", "https://user:pass@example.org", "https://example.org?q=1", "https://example.org/#frag", "https://ex ample.org"] {
    rejects("invalid base URL") { _ = try APIConfigurationDraft(baseURL: bad, model: "m").applying(to: original) }
}
for bad in ["line\nbreak", "with space", "\u{0}bad"] {
    rejects("invalid key") { _ = try APIConfigurationDraft(baseURL: original.upstreamBase, apiKey: bad, model: "m").applying(to: original) }
}
rejects("model cannot inject TOML") {
    _ = try APIConfigurationDraft(baseURL: original.upstreamBase, model: "model\"\nother=1").applying(to: original)
}
let profile = """
# Keep settings and comments
model = "original-model" # default
review_model = 'original-model'
model_reasoning_effort = "high"
notify = ["unchanged", "value"]
instructions = '''
model = "do-not-edit"
[not-a-table]
'''
[model_providers.iphone_bluetooth]
base_url = "http://127.0.0.1:48791"
[projects."/example/project"]
model = "project-model"
trust_level = "trusted"

"""
try profile.write(to: profileURL, atomically: true, encoding: .utf8)
let updated = try APIConfigurationStore.save(draft, current: original, at: configURL.path)
let stored = try BridgeConfiguration.read(configURL.path)
let storedProfile = try String(contentsOf: profileURL, encoding: .utf8)
check("settings persist", stored == updated)
check("tokens and port preserved", stored.localToken == original.localToken && stored.pairingToken == original.pairingToken && stored.port == original.port)
check("only root model and matching review model change", storedProfile == profile.replacingOccurrences(of: "\"original-model\" # default", with: "\"new-model\" # default").replacingOccurrences(of: "'original-model'", with: "\"new-model\""))
for url in [configURL, profileURL] {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    check("saved files are private", (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}
let contents = try FileManager.default.contentsOfDirectory(atPath: temp.path)
check("no temporary credential files remain", !contents.contains(where: { $0.hasPrefix(".api-settings-") }))
rejects("stale configuration rejected") { _ = try APIConfigurationStore.save(draft, current: original, at: configURL.path) }
let unchanged = try Data(contentsOf: configURL)
try "not-a-model = 1\n".write(to: profileURL, atomically: true, encoding: .utf8)
rejects("model sync failure does not partially save API settings") {
    _ = try APIConfigurationStore.save(APIConfigurationDraft(baseURL: original.upstreamBase, apiKey: "replacement-key", model: "another-model"), current: updated, at: configURL.path)
}
check("failed save keeps bridge file intact", try Data(contentsOf: configURL) == unchanged)
let keyOnly = try APIConfigurationStore.save(APIConfigurationDraft(baseURL: updated.upstreamBase, apiKey: "replacement-key", model: updated.model), current: updated, at: configURL.path)
check("key-only change does not rewrite Codex profile", try String(contentsOf: profileURL, encoding: .utf8) == "not-a-model = 1\n")
check("key replacement persists", keyOnly.apiKey == "replacement-key")
let customReview = "model = \"original-model\"\nreview_model = \"custom-review\"\n"
check("custom review model preserved", try CodexModelSettings.updating(customReview, from: "original-model", to: "new-model") == "model = \"new-model\"\nreview_model = \"custom-review\"\n")
rejects("multiline model rejected without rewriting other values") {
    _ = try CodexModelSettings.updating("model = '''original-model'''\n", from: "original-model", to: "new-model")
}

final class MemoryTransport: MessageTransport {
    var wireBytesSent = 0; var wireBytesReceived = 0
    var onMessage: ((Message) -> Void)?; var onClose: ((String) -> Void)?
    var sent = [Message](); var closed = false
    func send(_ message: Message) { sent.append(message) }
    func close(_ reason: String) { closed = true; let callback = onClose; onClose = nil; callback?(reason) }
}
let proxy = LocalProxy(config: original)
let firstTransport = MemoryTransport(); proxy.attach(firstTransport)
try proxy.updateConfiguration(keyOnly)
check("live update closes old API session", firstTransport.closed)
let secondTransport = MemoryTransport(); proxy.attach(secondTransport)
let nonce = secondTransport.sent.first!.nonce!
var challenge = Message("challenge"); challenge.nonce = String(repeating: "c", count: 64)
challenge.proof = Pairing.proof(token: original.pairingToken, text: "server|\(nonce)|\(challenge.nonce!)")
secondTransport.onMessage?(challenge)
check("reconnection authenticates new upstream URL", secondTransport.sent.last?.type == "authenticate" && secondTransport.sent.last?.baseURL == keyOnly.upstreamBase)
var illegal = keyOnly; illegal.localToken = "different"
rejects("runtime API edit cannot replace local credentials") { try proxy.updateConfiguration(illegal) }
var ready = Message("ready"); ready.uploadWindow = 4; secondTransport.onMessage?(ready)
try proxy.start()
let sessionConfig = URLSessionConfiguration.ephemeral; sessionConfig.connectionProxyDictionary = [:]
let session = URLSession(configuration: sessionConfig)
var request = URLRequest(url: URL(string: "http://127.0.0.1:\(original.port)/models")!)
request.setValue("Bearer \(original.localToken)", forHTTPHeaderField: "Authorization")
let task = session.dataTask(with: request); task.resume()
let deadline = Date().addingTimeInterval(5)
while !secondTransport.sent.contains(where: { $0.type == "request" }) && Date() < deadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
let forwarded = secondTransport.sent.first { $0.type == "request" }
check("new requests use the updated API key", forwarded?.headers?["authorization"] == "Bearer replacement-key")
rejects("in-flight request blocks configuration changes") { try proxy.updateConfiguration(original) }
check("blocked edit keeps the active connection", !secondTransport.closed)
proxy.applySynchronizedConfiguration(original)
check("synchronized edit preserves in-flight requests", !secondTransport.closed && proxy.activeRequestCount == 1)
check("forwarded request retains original endpoint and key snapshot", forwarded?.baseURL == keyOnly.upstreamBase && forwarded?.headers?["authorization"] == "Bearer replacement-key")
if let id = forwarded?.id {
    var head = Message("response", id: id); head.status = 200; secondTransport.onMessage?(head)
    secondTransport.onMessage?(Message("end", id: id))
}
let completedDeadline = Date().addingTimeInterval(3)
while proxy.activeRequestCount > 0 && Date() < completedDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
check("request finishes after a blocked edit", proxy.activeRequestCount == 0)
session.invalidateAndCancel()
proxy.stop()
print("\(passed) API configuration checks passed")

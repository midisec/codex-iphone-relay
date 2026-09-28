import Foundation
import CryptoKit

public enum APIOrigin: String, Codable, CaseIterable {
    case computer, phone
    public var title: String { self == .computer ? "电脑端" : "手机端" }
}
public enum APISelection: String, Codable, CaseIterable, Identifiable {
    case automatic, computer, phone
    public var id: String { rawValue }
    public var title: String {
        switch self { case .automatic: return "自动"; case .computer: return "电脑端"; case .phone: return "手机端" }
    }
}
public struct APICredentials: Codable, Equatable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public init(baseURL: String, apiKey: String, model: String) { self.baseURL = baseURL; self.apiKey = apiKey; self.model = model }
    public func validated() throws -> Self {
        try APIConfigurationDraft(baseURL: baseURL, apiKey: apiKey, model: model).credentials(retaining: "")
    }
}
/// Hybrid logical clock: saves made after observing a peer always sort after it,
/// even when the two system clocks differ. The UUID resolves concurrent ties.
public struct APIRevision: Codable, Equatable, Comparable {
    public var milliseconds: Int64
    public var logical: Int64
    public var id: String
    public init(milliseconds: Int64 = 0, logical: Int64 = 0, id: String = "") {
        self.milliseconds = milliseconds; self.logical = logical; self.id = id
    }
    public static func < (a: Self, b: Self) -> Bool {
        if a.milliseconds != b.milliseconds { return a.milliseconds < b.milliseconds }
        if a.logical != b.logical { return a.logical < b.logical }
        return a.id < b.id
    }
}
public struct APIProfile: Codable, Equatable {
    public var credentials: APICredentials
    public var revision: APIRevision
    public init(credentials: APICredentials, revision: APIRevision = APIRevision()) { self.credentials = credentials; self.revision = revision }
}
public struct APISettingsState: Codable, Equatable {
    public var computer: APIProfile?
    public var phone: APIProfile?
    public var selection: APISelection = .automatic
    public var selectionRevision = APIRevision()
    public init(computer: APIProfile? = nil, phone: APIProfile? = nil) { self.computer = computer; self.phone = phone }
    public func profile(_ origin: APIOrigin) -> APIProfile? { origin == .computer ? computer : phone }
    public var effectiveOrigin: APIOrigin? {
        switch selection {
        case .computer: return computer == nil ? nil : .computer
        case .phone: return phone == nil ? nil : .phone
        case .automatic:
            guard let computer else { return phone == nil ? nil : .phone }
            guard let phone else { return .computer }
            return computer.revision < phone.revision ? .phone : .computer
        }
    }
    public var effective: APICredentials? { effectiveOrigin.flatMap { profile($0)?.credentials } }
    public var digest: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: (try? encoder.encode(self)) ?? Data()).map { String(format: "%02x", $0) }.joined()
    }
    public static func importing(_ config: BridgeConfiguration) -> Self {
        config.apiSettings ?? Self(computer: APIProfile(credentials: APICredentials(baseURL: config.upstreamBase, apiKey: config.apiKey, model: config.model)))
    }
    public func validated() throws -> Self {
        for profile in [computer, phone].compactMap({ $0 }) {
            guard try profile.credentials.validated() == profile.credentials else { throw BridgeError.invalid("API 配置格式无效") }
        }
        for revision in [computer?.revision, phone?.revision, selectionRevision].compactMap({ $0 }) {
            guard revision.milliseconds >= 0, revision.milliseconds < Int64.max - 1,
                  revision.logical >= 0, revision.logical < Int64.max - 1, revision.id.utf8.count <= 64 else {
                throw BridgeError.invalid("API 配置版本无效")
            }
        }
        return self
    }
    public func merged(with peer: Self) throws -> Self {
        _ = try peer.validated()
        var result = self
        for origin in APIOrigin.allCases {
            if let incoming = peer.profile(origin), profile(origin) == nil || profile(origin)!.revision < incoming.revision {
                if origin == .computer { result.computer = incoming } else { result.phone = incoming }
            } else if let incoming = peer.profile(origin), let local = profile(origin), local.revision == incoming.revision, local != incoming {
                throw BridgeError.invalid("API 配置版本冲突")
            }
        }
        if selectionRevision < peer.selectionRevision { result.selection = peer.selection; result.selectionRevision = peer.selectionRevision }
        else if selectionRevision == peer.selectionRevision && selection != peer.selection { throw BridgeError.invalid("配置来源版本冲突") }
        return result
    }
    public mutating func edit(_ draft: APIConfigurationDraft?, origin: APIOrigin, selection: APISelection, now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws {
        if let draft {
            let credentials = try draft.credentials(retaining: profile(origin)?.credentials.apiKey ?? "")
            if credentials != profile(origin)?.credentials {
                let profile = APIProfile(credentials: credentials, revision: nextRevision(now: now))
                if origin == .computer { computer = profile } else { phone = profile }
            }
        }
        if selection == .computer && computer == nil { throw BridgeError.invalid("电脑端尚未保存配置") }
        if selection == .phone && phone == nil { throw BridgeError.invalid("手机端尚未保存配置") }
        if self.selection != selection { selectionRevision = nextRevision(now: now); self.selection = selection }
    }
    private func nextRevision(now: Int64) -> APIRevision {
        let previous = [computer?.revision, phone?.revision, selectionRevision].compactMap { $0 }.max() ?? APIRevision()
        let physical = max(now, previous.milliseconds)
        return APIRevision(milliseconds: physical, logical: physical == previous.milliseconds ? previous.logical + 1 : 0, id: UUID().uuidString)
    }
}

/// Main-queue coordinator shared by all active transports on one device.
public final class APISettingsCoordinator {
    public let origin: APIOrigin
    public private(set) var state: APISettingsState
    public var onChange: ((APISettingsState) -> Void)?
    public var onStatus: ((String) -> Void)?
    public private(set) var error: String?
    private let persist: (APISettingsState) throws -> Void
    private var observers = [UUID: (APISettingsState) -> Void]()
    private var links = Set<UUID>()
    private var acknowledgements = [UUID: String]()
    public var synchronized: Bool { links.contains { acknowledgements[$0] == state.digest } }
    public var status: String { error ?? (links.isEmpty ? "待连接同步" : synchronized ? "已同步" : "正在同步") }
    public init(origin: APIOrigin, state: APISettingsState, persist: @escaping (APISettingsState) throws -> Void) {
        self.origin = origin; self.state = state; self.persist = persist
    }
    public func update(_ draft: APIConfigurationDraft?, selection: APISelection) throws {
        var updated = state; try updated.edit(draft, origin: origin, selection: selection); try commit(updated)
    }
    @discardableResult public func receive(_ incoming: APISettingsState) throws -> APISettingsState {
        try commit(state.merged(with: incoming)); return state
    }
    private func commit(_ updated: APISettingsState) throws {
        guard updated != state else { return }
        try persist(updated); state = updated; error = nil
        onChange?(state); publishStatus()
        for notify in Array(observers.values) { notify(state) }
    }
    public func observe(_ callback: @escaping (APISettingsState) -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    public func removeObserver(_ id: UUID) { observers.removeValue(forKey: id); disconnect(id) }
    public func connect(_ id: UUID) { links.insert(id); error = nil; publishStatus() }
    public func disconnect(_ id: UUID) { links.remove(id); acknowledgements.removeValue(forKey: id); publishStatus() }
    public func acknowledge(_ id: UUID, digest: String?) {
        if digest == state.digest { acknowledgements[id] = digest; error = nil }; publishStatus()
    }
    public func failed(_ message: String = "配置同步失败") { error = message; publishStatus() }
    private func publishStatus() { onStatus?(status) }
}

/// One authenticated connection. Changes are committed before acknowledgement.
final class APISettingsLink {
    let coordinator: APISettingsCoordinator
    private let send: (Message) -> Void
    private var observer: UUID?
    init(_ coordinator: APISettingsCoordinator, send: @escaping (Message) -> Void) {
        self.coordinator = coordinator; self.send = send
    }
    func start() {
        stop()
        observer = coordinator.observe { [weak self] _ in self?.publish() }
        coordinator.connect(observer!)
        publish()
    }
    func stop() { if let observer { coordinator.removeObserver(observer) }; observer = nil }
    deinit { stop() }
    func publish() {
        guard observer != nil else { return }
        var message = Message("settings"); message.settings = coordinator.state; send(message)
    }
    func retryIfNeeded() { if !coordinator.synchronized { publish() } }
    func receive(_ message: Message) -> Bool {
        guard ["settings", "settingsAck", "settingsError"].contains(message.type) else { return false }
        guard let observer else { return true }
        if message.type == "settingsAck" { coordinator.acknowledge(observer, digest: message.settingsDigest); return true }
        if message.type == "settingsError" { coordinator.failed("对端未能保存配置"); return true }
        do {
            guard let state = message.settings else { throw BridgeError.invalid("缺少配置") }
            let merged = try coordinator.receive(state)
            var ack = Message("settingsAck"); ack.settingsDigest = merged.digest; send(ack)
            // The incoming state itself also proves what the peer has persisted.
            coordinator.acknowledge(observer, digest: state.digest)
            if merged != state { publish() }
        } catch {
            coordinator.failed(); send(Message("settingsError"))
        }
        return true
    }
}

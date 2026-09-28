import Foundation
import Darwin

public struct APIConfigurationDraft {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public init(baseURL: String, apiKey: String = "", model: String) {
        self.baseURL = baseURL; self.apiKey = apiKey; self.model = model
    }
    public func applying(to current: BridgeConfiguration) throws -> BridgeConfiguration {
        let values = try credentials(retaining: current.apiKey)
        var value = current
        value.upstreamBase = values.baseURL; value.apiKey = values.apiKey; value.model = values.model
        return value
    }
    public func credentials(retaining existingKey: String) throws -> APICredentials {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.utf8.count <= 4096, let parts = URLComponents(string: base), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              !base.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              (try? RequestPolicy.upstream(base: base, path: "/models", method: "GET")) != nil else {
            throw BridgeError.invalid("请输入有效的 HTTPS API 地址，不含账号、查询参数或片段")
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = key.isEmpty ? existingKey : key
        guard !effectiveKey.isEmpty, effectiveKey.utf8.count <= 8192,
              !effectiveKey.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw BridgeError.invalid("API 密钥不能包含空格或换行")
        }
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256,
              name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]*$"#, options: .regularExpression) != nil else {
            throw BridgeError.invalid("请输入有效的模型名称")
        }
        return APICredentials(baseURL: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")), apiKey: effectiveKey, model: name)
    }
}

/// Changes only root model values; all unrelated TOML bytes remain intact.
public enum CodexModelSettings {
    public static func updating(_ text: String, from old: String, to model: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        var quote: Character?; var multiline = false; var depth = 0
        var foundModel = false
        let assignment = try NSRegularExpression(pattern: #"^(\s*(model|review_model|"model"|"review_model"|'model'|'review_model')\s*=\s*)("(?:[^"\\]|\\.)*"|'[^']*')(\s*(?:#.*)?\r?)$"#)
        for index in lines.indices {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if quote == nil && depth == 0 {
                if trimmed.hasPrefix("[") { break }
                if let match = assignment.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                   let keyRange = Range(match.range(at: 2), in: line), let valueRange = Range(match.range(at: 3), in: line) {
                    let key = String(line[keyRange]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    let raw = String(line[valueRange])
                    let decoded = raw.hasPrefix("'") ? String(raw.dropFirst().dropLast()) :
                        ((try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String)
                    if key == "model" || decoded == old {
                        lines[index].replaceSubrange(valueRange, with: "\"\(model)\"")
                    }
                    if key == "model" {
                        guard !foundModel else { throw BridgeError.invalid("Codex 配置包含重复的模型项") }
                        foundModel = true
                    }
                } else if trimmed.range(of: #"^(model|review_model|"model"|"review_model"|'model'|'review_model')\s*="#, options: .regularExpression) != nil {
                    throw BridgeError.invalid("Codex 模型配置格式不支持编辑，请使用单行字符串")
                }
            }
            // Track quoted strings and arrays so keys inside multiline values are not edited.
            let chars = Array(line); var i = 0
            while i < chars.count {
                let c = chars[i]
                if let current = quote {
                    if current == "\"" && c == "\\" { i += 2; continue }
                    if c == current {
                        if !multiline { quote = nil }
                        else if i + 2 < chars.count && chars[i + 1] == current && chars[i + 2] == current {
                            quote = nil; multiline = false; i += 2
                        }
                    }
                } else {
                    if c == "#" { break }
                    if c == "\"" || c == "'" {
                        quote = c
                        multiline = i + 2 < chars.count && chars[i + 1] == c && chars[i + 2] == c
                        if multiline { i += 2 }
                    } else if c == "[" || c == "{" { depth += 1 }
                    else if c == "]" || c == "}" { depth -= 1 }
                }
                i += 1
            }
        }
        guard foundModel else { throw BridgeError.invalid("Codex 配置中没有可编辑的默认模型") }
        return lines.joined(separator: "\n")
    }
}

public enum APIConfigurationStore {
    public static func save(_ draft: APIConfigurationDraft, current: BridgeConfiguration, at path: String) throws -> BridgeConfiguration {
        let updated = try draft.applying(to: current)
        return try save(updated, current: current, at: path)
    }
    public static func save(_ state: APISettingsState, current: BridgeConfiguration, at path: String) throws -> BridgeConfiguration {
        _ = try state.validated()
        guard let effective = state.effective else { throw BridgeError.invalid("所选来源尚无 API 配置") }
        var updated = current
        updated.upstreamBase = effective.baseURL; updated.apiKey = effective.apiKey; updated.model = effective.model
        updated.apiSettings = state
        return try save(updated, current: current, at: path)
    }
    private static func save(_ updated: BridgeConfiguration, current: BridgeConfiguration, at path: String) throws -> BridgeConfiguration {
        let url = URL(fileURLWithPath: path)
        let previous = try Data(contentsOf: url)
        guard try JSONDecoder().decode(BridgeConfiguration.self, from: previous) == current else {
            throw BridgeError.invalid("配置已在外部修改，请重新打开 App 后再编辑")
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(updated) + Data([10])
        let profileURL = url.deletingLastPathComponent().appendingPathComponent("config.toml")
        var profile: Data?; var modifiedProfile: Data?
        if current.model != updated.model {
            let original = try Data(contentsOf: profileURL)
            guard let text = String(data: original, encoding: .utf8) else { throw BridgeError.invalid("Codex 配置不是 UTF-8 文本") }
            modifiedProfile = Data(try CodexModelSettings.updating(text, from: current.model, to: updated.model).utf8)
            profile = original
        }
        // Stage all writes first; both temporary files are private from creation.
        let stagedBridge = try stage(json, beside: url)
        defer { try? FileManager.default.removeItem(at: stagedBridge) }
        var stagedProfile: URL?
        if let modifiedProfile { stagedProfile = try stage(modifiedProfile, beside: profileURL) }
        defer { if let stagedProfile { try? FileManager.default.removeItem(at: stagedProfile) } }
        let profileUnchanged = try profile.map { try Data(contentsOf: profileURL) == $0 } ?? true
        guard try Data(contentsOf: url) == previous, profileUnchanged else {
            throw BridgeError.invalid("配置已在外部修改，请重试")
        }
        if let stagedProfile { try replace(stagedProfile, with: profileURL) }
        do { try replace(stagedBridge, with: url) }
        catch {
            if let profile {
                let rollback = try stage(profile, beside: profileURL)
                defer { try? FileManager.default.removeItem(at: rollback) }
                try replace(rollback, with: profileURL)
            }
            throw error
        }
        return updated
    }
    private static func stage(_ data: Data, beside url: URL) throws -> URL {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".api-settings-\(UUID().uuidString)")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw BridgeError.invalid("无法创建配置文件，请检查目录权限") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try handle.write(contentsOf: data); try handle.synchronize(); try handle.close() }
        catch { try? handle.close(); try? FileManager.default.removeItem(at: temp); throw error }
        return temp
    }
    private static func replace(_ staged: URL, with destination: URL) throws {
        guard rename(staged.path, destination.path) == 0 else { throw BridgeError.invalid("无法保存配置，请检查文件权限") }
    }
}

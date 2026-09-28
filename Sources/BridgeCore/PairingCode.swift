import Foundation

public enum PairingCode {
    public static func parse(_ input: String) throws -> String {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if raw.contains("://") {
            guard let url = URLComponents(string: raw), url.scheme == "codex-ble", url.host == "pair",
                  url.path.isEmpty, url.user == nil, url.password == nil, url.port == nil, url.fragment == nil,
                  let items = url.queryItems, items.count == 1, items[0].name == "token", let value = items[0].value else {
                throw BridgeError.invalid("请扫描 Mac 的 Bluetooth Codex 窗口中的配对二维码")
            }
            token = value.lowercased()
        } else { token = raw.lowercased() }
        guard token.utf8.count == 64, token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw BridgeError.invalid("配对码应为 64 位十六进制字符，请重新扫描或粘贴")
        }
        return token
    }
}

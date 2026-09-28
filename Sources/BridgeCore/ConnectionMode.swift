import Foundation

public enum ConnectionMode: String, CaseIterable, Identifiable {
    case usb
    case bluetooth
    case combined = "auto"

    public var id: String { rawValue }
    public var usesUSB: Bool { self != .bluetooth }
    public var usesBluetooth: Bool { self != .usb }
    public var title: String {
        switch self {
        case .usb: return "Type-C"
        case .bluetooth: return "蓝牙"
        case .combined: return "Type-C + 蓝牙"
        }
    }
    public var symbol: String {
        switch self {
        case .usb: return "cable.connector"
        case .bluetooth: return "antenna.radiowaves.left.and.right"
        case .combined: return "arrow.left.arrow.right"
        }
    }
    public var caption: String {
        switch self {
        case .usb: return "有线直连"
        case .bluetooth: return "无线连接"
        case .combined: return "有线优先，蓝牙备用"
        }
    }
}

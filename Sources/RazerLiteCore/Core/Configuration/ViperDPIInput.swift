import Foundation

/// Local editor text only. Does not read devices, create permits or send reports.
/// Exact values loaded from devices/profiles bypass editing and are never rounded.
public struct ViperDPIInput: Equatable, Sendable {
    public private(set) var x = ""
    public private(set) var y = ""
    public private(set) var axesLinked = true

    public init() {}

    public init(x: Int, y: Int) {
        self.x = String(x); self.y = String(y)
        axesLinked = x == y
    }

    public mutating func editX(_ text: String) {
        x = text
        if axesLinked { y = text }
    }

    public mutating func editY(_ text: String) {
        y = text
        if axesLinked { x = text }
    }

    /// An explicit user action: enabling adopts X for both axes in the draft.
    public mutating func setLinked(_ linked: Bool) {
        axesLinked = linked
        if linked { y = x }
    }

    public var target: MouseDPIStage? {
        guard let x = Int(x), let y = Int(y),
              (try? ViperV4DPIProtocol.validateTarget(x: x, y: y)) != nil else { return nil }
        return .init(x: x, y: y)
    }

    public func matches(_ original: MouseDPIStage) -> Bool {
        Int(x) == original.x && Int(y) == original.y
    }

    /// Unedited device values can be outside the writable step/range and remain exact.
    public func validationMessage(preserving original: MouseDPIStage? = nil) -> String? {
        if let original, matches(original) { return nil }
        if x.isEmpty && y.isEmpty { return nil }
        guard !x.isEmpty, !y.isEmpty else { return "请填写 X 和 Y 轴 DPI。" }
        guard let x = Int(x), let y = Int(y) else { return "DPI 请输入整数。" }
        guard (100...50000).contains(x), (100...50000).contains(y) else { return "DPI 须在 100–50,000 之间。" }
        guard x % 50 == 0, y % 50 == 0 else { return "修改值须为 50 的整数倍。" }
        return nil
    }
}

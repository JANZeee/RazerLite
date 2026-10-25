import Combine
import Foundation

public enum LoginItemStatus: Sendable {
    case notRegistered, enabled, requiresApproval, notFound, unavailable
    public var isRegistered: Bool { self == .enabled || self == .requiresApproval }
    public var title: String {
        switch self {
        case .notRegistered: "未开启"
        case .enabled: "已开启"
        case .requiresApproval: "等待系统批准"
        case .notFound: "系统未找到服务"
        case .unavailable: "状态不可用"
        }
    }
}

@MainActor
public protocol LoginItemServicing {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() async throws
}

public enum LoginItemInstallation {
    /// A product policy: don't register a cache, build symlink or movable checkout.
    /// Apple additionally checks signature and user approval during registration.
    public static func blockingReason(bundleURL: URL, homeURL: URL, isSimulation: Bool) -> String? {
        if isSimulation { return "离线场景不注册登录项。" }
        let actual = bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     homeURL.appendingPathComponent("Applications", isDirectory: true)]
        guard actual.pathExtension == "app", roots.contains(where: {
            actual.deletingLastPathComponent() == $0.resolvingSymlinksInPath().standardizedFileURL
        }) else { return "请先安装到“应用程序”或 ~/Applications，再从安装位置启动。" }
        return nil
    }
}

@MainActor
public final class LoginItemController: ObservableObject {
    @Published public private(set) var status: LoginItemStatus = .notRegistered
    @Published public private(set) var issue: String?
    @Published public private(set) var isUpdating = false
    public let installationIssue: String?
    private let service: any LoginItemServicing
    public var canEnable: Bool { installationIssue == nil && status != .unavailable && !isUpdating }

    public init(service: any LoginItemServicing, installationIssue: String?) {
        self.service = service
        self.installationIssue = installationIssue
        refresh()
    }

    public func refresh() { status = service.status }

    /// Called only by an explicit user action. No Boolean preference is treated
    /// as evidence of registration, and launching never retries a failed change.
    public func setEnabled(_ enabled: Bool) async {
        guard !isUpdating else { return }
        refresh()
        guard enabled != status.isRegistered else { return }
        if enabled, !canEnable { issue = installationIssue ?? "当前系统状态不允许注册。"; return }
        isUpdating = true
        issue = nil
        defer { refresh(); isUpdating = false }
        do {
            if enabled { try service.register() }
            else { try await service.unregister() }
        } catch { issue = error.localizedDescription }
    }
}

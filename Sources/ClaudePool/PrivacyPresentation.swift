import Foundation
import PoolCore

enum PrivacyPhase: Equatable { case notInstalled, installing, ready, failed }
struct PrivacyPresentation: Equatable {
    var phase: PrivacyPhase = .notInstalled
    var modelVersion: String?
    var progress: Double?
    var protectedCount = 0
    var requestCount = 0
    var message: String?
    var isProcessing = false
    /// The version an automatic update is installing; detection keeps running on the current one.
    var updatingTo: String?
    /// Why the last automatic update did not happen; the current version keeps working.
    var updateMessage: String?
}
enum PrivacyPreviewPhase: Equatable { case idle, working, ready, failed }
struct PrivacyCategoryCount: Equatable, Identifiable {
    var id: String
    var title: String
    var count: Int
}
struct PrivacyPreviewPresentation: Equatable {
    var phase: PrivacyPreviewPhase = .idle
    var text = ""
    var protectedCount = 0
    var categories: [PrivacyCategoryCount] = []
    var message: String?
}

enum RouteFlowActivity: Equatable {
    case inactive, starting, working, waiting, attention
    var hasMotion: Bool { self == .starting || self == .working }
}

extension PoolAppModel {
    func routeMotionEnabled(for sessionID: UUID?, reduceMotion: Bool) -> Bool {
        !demo && !reduceMotion && (privacy.isProcessing || routeFlowActivity(for: sessionID).hasMotion)
    }
    func routeFlowActivity(for sessionID: UUID?) -> RouteFlowActivity {
        guard let id = sessionID, let session = snapshot.sessions.first(where: { $0.id == id }),
              snapshot.mode == .running || snapshot.mode == .stopping else { return .inactive }
        switch session.state {
        case .starting: return .starting
        case .running: return generatingSessionIDs.contains(id) ? .working : .starting
        case .waiting: return .waiting
        case .attention: return .attention
        case .idle, .ended: return .inactive
        }
    }
    /// "AstrLink Guard 0.1.3 · Updates automatically", or the version an update is installing.
    var privacyModelLine: String {
        if let next = privacy.updatingTo { return t("AstrLink Guard · updating to {0}…", next) }
        guard let version = privacy.modelVersion, privacy.phase == .ready else { return "AstrLink Guard" }
        return "AstrLink Guard \(version) · " + t("Updates automatically")
    }
    var privacyStatusTitle: String {
        switch privacy.phase {
        case .notInstalled: return t("Setup needed")
        case .installing: return t("Preparing…")
        case .ready: return t(privacy.isProcessing ? "Redacting…" : "Ready")
        case .failed: return t("Needs attention")
        }
    }
}

import Foundation

public enum RuntimeError: Error, Equatable, Sendable, LocalizedError {
    case unsafePath, missingFile, invalidLibrary, oversizedInput, storageFailure
    case invalidExecutable, launchFailed(Int32), processExited, processBusy, processUnresponsive
    case invalidTerminalInput, writeFailed, invalidAuthentication, signedOut, unsupportedAuthentication, signOutFailed
    case workspaceInUse

    public var errorDescription: String? {
        switch self {
        case .unsafePath: return "Claude Pool could not access its data folder safely. Check folder permissions."
        case .missingFile: return "The requested app file is missing."
        case .invalidLibrary: return "The saved account list could not be read. The original file is unchanged."
        case .oversizedInput: return "The local input exceeds the supported size."
        case .storageFailure: return "The app could not save its data. Check available disk space and permissions."
        case .invalidExecutable: return "Claude Code is unavailable. Install or update it in Settings."
        case .launchFailed: return "Claude Code could not start. Check its status in Settings."
        case .processExited: return "The local Claude session has ended."
        case .processBusy: return "This account is still in use. Wait for its current operation to finish."
        case .processUnresponsive: return "The Claude session could not finish closing. Check its session in Claude Pool."
        case .invalidTerminalInput: return "This message contains unsupported terminal control characters."
        case .writeFailed: return "The local Claude session could not receive input."
        case .invalidAuthentication: return "Claude Code did not confirm this account's isolated sign-in."
        case .signedOut: return "Sign in to this account with Claude Code."
        case .unsupportedAuthentication: return "This account must use a Claude subscription sign-in."
        case .signOutFailed: return "Claude Code could not sign out. The account is still saved."
        case .workspaceInUse: return "Claude Pool is already running. Quit the other copy first."
        }
    }
}

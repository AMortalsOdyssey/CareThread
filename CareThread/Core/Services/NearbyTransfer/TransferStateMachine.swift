import Foundation

enum TransferRole: String, Codable, Sendable {
    case sender
    case receiver
}

struct TransferProgress: Equatable, Sendable {
    let completedBytes: Int64
    let totalBytes: Int64

    init(completedBytes: Int64, totalBytes: Int64) throws {
        guard completedBytes >= 0,
              totalBytes >= 0,
              completedBytes <= totalBytes else {
            throw TransferProtocolError.invalidChunk("invalid progress")
        }
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }
}

enum TransferState: Equatable, Sendable {
    case idle
    case discovering
    case connecting
    case pairing
    case awaitingPairingConfirmation
    case negotiating
    case transferring(TransferProgress)
    case verifying
    case awaitingCommitReceipt
    case commitReady
    case committing
    case completed
    case failed(TransferProtocolError)
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .completed, .cancelled:
            return true
        default:
            return false
        }
    }
}

struct TransferStateMachine: Sendable {
    let role: TransferRole
    private(set) var state: TransferState = .idle

    init(role: TransferRole) {
        self.role = role
    }

    mutating func transition(to next: TransferState) throws {
        guard Self.isAllowed(from: state, to: next, role: role) else {
            throw TransferProtocolError.invalidStateTransition
        }
        state = next
    }

    mutating func acceptVerifiedCommitReceipt(_ receipt: VerifiedCommitReceipt) throws {
        guard role == .sender,
              state == .awaitingCommitReceipt else {
            throw TransferProtocolError.invalidStateTransition
        }
        state = .completed
    }

    private static func isAllowed(
        from current: TransferState,
        to next: TransferState,
        role: TransferRole
    ) -> Bool {
        if case .failed = next {
            return !current.isTerminal
        }
        if next == .cancelled {
            return !current.isTerminal
        }
        if case .failed = current {
            return next == .connecting || next == .cancelled
        }

        switch (current, next) {
        case (.idle, .discovering),
             (.discovering, .connecting),
             (.connecting, .pairing),
             (.pairing, .awaitingPairingConfirmation),
             (.awaitingPairingConfirmation, .negotiating):
            return true
        case let (.negotiating, .transferring(progress)):
            return progress.completedBytes == 0
        case let (.transferring(previous), .transferring(nextProgress)):
            return nextProgress.totalBytes == previous.totalBytes &&
                nextProgress.completedBytes >= previous.completedBytes
        case let (.transferring(progress), .verifying):
            return progress.completedBytes == progress.totalBytes
        case (.verifying, .commitReady):
            return role == .receiver
        case (.verifying, .awaitingCommitReceipt):
            return role == .sender
        case (.commitReady, .committing):
            return role == .receiver
        case (.committing, .completed):
            return role == .receiver
        default:
            return false
        }
    }
}

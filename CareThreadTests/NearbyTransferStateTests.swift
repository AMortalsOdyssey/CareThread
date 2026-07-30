import Foundation
import Testing
@testable import CareThread

struct NearbyTransferStateTests {
    @Test("接收端只有验证后才进入 commit-ready 并提交")
    func receiverFollowsTransactionalPath() throws {
        var machine = TransferStateMachine(role: .receiver)
        try machine.transition(to: .discovering)
        try machine.transition(to: .connecting)
        try machine.transition(to: .pairing)
        try machine.transition(to: .awaitingPairingConfirmation)
        try machine.transition(to: .negotiating)
        try machine.transition(to: .transferring(try TransferProgress(completedBytes: 0, totalBytes: 10)))
        try machine.transition(to: .transferring(try TransferProgress(completedBytes: 10, totalBytes: 10)))
        try machine.transition(to: .verifying)
        try machine.transition(to: .commitReady)
        try machine.transition(to: .committing)
        try machine.transition(to: .completed)
        #expect(machine.state == .completed)
    }

    @Test("发送端不能进入接收端 commit-ready")
    func senderCannotCommitReceiverStaging() throws {
        var machine = try senderAtVerifying()
        #expect(throws: TransferProtocolError.invalidStateTransition) {
            try machine.transition(to: .commitReady)
        }
        try machine.transition(to: .awaitingCommitReceipt)
        #expect(machine.state == .awaitingCommitReceipt)
        #expect(throws: TransferProtocolError.invalidStateTransition) {
            try machine.transition(to: .completed)
        }
    }

    @Test("传输进度不允许倒退")
    func progressCannotRegress() throws {
        var machine = TransferStateMachine(role: .sender)
        try machine.transition(to: .discovering)
        try machine.transition(to: .connecting)
        try machine.transition(to: .pairing)
        try machine.transition(to: .awaitingPairingConfirmation)
        try machine.transition(to: .negotiating)
        try machine.transition(to: .transferring(try TransferProgress(completedBytes: 0, totalBytes: 10)))
        try machine.transition(to: .transferring(try TransferProgress(completedBytes: 5, totalBytes: 10)))
        #expect(throws: TransferProtocolError.invalidStateTransition) {
            try machine.transition(
                to: .transferring(try TransferProgress(completedBytes: 4, totalBytes: 10))
            )
        }
    }

    @Test("未传完全部字节不能进入验证")
    func incompleteTransferCannotVerify() throws {
        var machine = TransferStateMachine(role: .receiver)
        try machine.transition(to: .discovering)
        try machine.transition(to: .connecting)
        try machine.transition(to: .pairing)
        try machine.transition(to: .awaitingPairingConfirmation)
        try machine.transition(to: .negotiating)
        try machine.transition(to: .transferring(try TransferProgress(completedBytes: 0, totalBytes: 10)))
        try machine.transition(to: .transferring(try TransferProgress(completedBytes: 9, totalBytes: 10)))
        #expect(throws: TransferProtocolError.invalidStateTransition) {
            try machine.transition(to: .verifying)
        }
    }

    @Test("失败后可重新连接恢复，但完成后不可回退")
    func failureCanResumeAndCompletionIsTerminal() throws {
        var machine = TransferStateMachine(role: .sender)
        try machine.transition(to: .discovering)
        try machine.transition(to: .failed(.transport("interrupted")))
        try machine.transition(to: .connecting)
        #expect(machine.state == .connecting)

        var receiver = TransferStateMachine(role: .receiver)
        try receiver.transition(to: .discovering)
        try receiver.transition(to: .connecting)
        try receiver.transition(to: .pairing)
        try receiver.transition(to: .awaitingPairingConfirmation)
        try receiver.transition(to: .negotiating)
        try receiver.transition(
            to: .transferring(try TransferProgress(completedBytes: 0, totalBytes: 0))
        )
        try receiver.transition(to: .verifying)
        try receiver.transition(to: .commitReady)
        try receiver.transition(to: .committing)
        try receiver.transition(to: .completed)
        #expect(throws: TransferProtocolError.invalidStateTransition) {
            try receiver.transition(to: .connecting)
        }
    }

    private func senderAtVerifying() throws -> TransferStateMachine {
        var machine = TransferStateMachine(role: .sender)
        try machine.transition(to: .discovering)
        try machine.transition(to: .connecting)
        try machine.transition(to: .pairing)
        try machine.transition(to: .awaitingPairingConfirmation)
        try machine.transition(to: .negotiating)
        try machine.transition(to: .transferring(try TransferProgress(completedBytes: 0, totalBytes: 0)))
        try machine.transition(to: .verifying)
        return machine
    }
}

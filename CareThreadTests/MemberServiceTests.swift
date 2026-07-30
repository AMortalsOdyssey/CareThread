import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct MemberServiceTests {
    @Test("50 个并发创建请求最多产生 20 个成员和 20 个 Vault")
    func concurrentCreation_neverExceedsTwenty() async throws {
        let container = try TestSupport.container()
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provisioner = DirectoryMemberVaultProvisioner(root: root)
        let selection = InMemorySelectedMemberStore()
        let service = MemberService(
            context: container.mainContext,
            vaultProvisioner: provisioner,
            selectionStore: selection
        )

        let successCount = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<50 {
                group.addTask { @MainActor in
                    (try? service.createMember(displayName: "成员 \(index)")) != nil
                }
            }
            var count = 0
            for await succeeded in group where succeeded {
                count += 1
            }
            return count
        }

        #expect(successCount == 20)
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Patient>()) == 20)
        #expect(provisioner.provisionedIDs.count == 20)
        let directoryCount = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).count
        #expect(directoryCount == 20)
        #expect(selection.selectedPatientId != nil)
    }

    @Test("第 21 人失败时无患者、目录或选择副作用")
    func twentyFirstMember_hasNoSideEffects() throws {
        let container = try TestSupport.container()
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provisioner = DirectoryMemberVaultProvisioner(root: root)
        let selection = InMemorySelectedMemberStore()
        let service = MemberService(
            context: container.mainContext,
            vaultProvisioner: provisioner,
            selectionStore: selection
        )
        for index in 0..<20 {
            _ = try service.createMember(displayName: "成员 \(index)")
        }
        let selectedBefore = selection.selectedPatientId

        #expect(throws: MemberServiceError.maximumReached(limit: 20)) {
            try service.createMember(displayName: "第 21 人")
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Patient>()) == 20)
        #expect(provisioner.provisionedIDs.count == 20)
        #expect(selection.selectedPatientId == selectedBefore)
    }

    @Test("Vault provision 失败回滚插入且不改变选择")
    func vaultFailure_rollsBackPatient() throws {
        let container = try TestSupport.container()
        let provisioner = FailingMemberVaultProvisioner()
        let selection = InMemorySelectedMemberStore()
        selection.selectedPatientId = UUID()
        let selectedBefore = selection.selectedPatientId
        let service = MemberService(
            context: container.mainContext,
            vaultProvisioner: provisioner,
            selectionStore: selection
        )

        #expect(throws: MemberServiceError.vaultProvisionFailed) {
            try service.createMember(displayName: "失败成员")
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Patient>()) == 0)
        #expect(provisioner.rollbackCount == 1)
        #expect(selection.selectedPatientId == selectedBefore)
    }

    @Test("数据库保存失败回滚患者和已 provision Vault")
    func saveFailure_rollsBackPatientAndVault() throws {
        let container = try TestSupport.container()
        let root = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let provisioner = DirectoryMemberVaultProvisioner(root: root)
        let selection = InMemorySelectedMemberStore()
        let service = MemberService(
            context: container.mainContext,
            vaultProvisioner: provisioner,
            selectionStore: selection,
            saveAction: { _ in throw InjectedMemberError.save }
        )

        #expect(throws: MemberServiceError.databaseSaveFailed) {
            try service.createMember(displayName: "保存失败")
        }
        #expect(try container.mainContext.fetchCount(FetchDescriptor<Patient>()) == 0)
        #expect(provisioner.provisionedIDs.isEmpty)
        #expect(selection.selectedPatientId == nil)
    }

    @Test("成员创建可由第二 ModelContext 读取")
    func creation_isVisibleFromSecondContext() throws {
        let container = try TestSupport.container()
        let created = try MemberService(
            context: container.mainContext,
            vaultProvisioner: NoopMemberVaultProvisioner(),
            selectionStore: InMemorySelectedMemberStore()
        )
            .createMember(displayName: "第二上下文")
        let secondContext = ModelContext(container)
        let id = created.id
        let descriptor = FetchDescriptor<Patient>(
            predicate: #Predicate { $0.id == id }
        )
        #expect(try secondContext.fetch(descriptor).first?.displayName == "第二上下文")
    }
}

private enum InjectedMemberError: Error {
    case save
}

private final class DirectoryMemberVaultProvisioner: MemberVaultProvisioning {
    let root: URL
    private(set) var provisionedIDs = Set<UUID>()

    init(root: URL) {
        self.root = root
    }

    func provisionVault(for patientId: UUID) throws {
        let url = root.appendingPathComponent(patientId.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        provisionedIDs.insert(patientId)
    }

    func rollbackVault(for patientId: UUID) {
        let url = root.appendingPathComponent(patientId.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        provisionedIDs.remove(patientId)
    }
}

private final class FailingMemberVaultProvisioner: MemberVaultProvisioning {
    private(set) var rollbackCount = 0

    func provisionVault(for patientId: UUID) throws {
        throw InjectedMemberError.save
    }

    func rollbackVault(for patientId: UUID) {
        rollbackCount += 1
    }
}

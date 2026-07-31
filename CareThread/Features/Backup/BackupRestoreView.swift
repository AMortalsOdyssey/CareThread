import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct BackupRestoreView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.createdAt) private var patients: [Patient]
    let patientID: UUID

    @State private var exportAllMembers = true
    @State private var showOptionalPassword = false
    @State private var backupPassword = ""
    @State private var importPassword = ""
    @State private var exportedPackage: BackupExportPackage?
    @State private var importPlan: BackupImportPlan?
    @State private var selectedImportArchiveURL: URL?
    @State private var selectedImportArchiveRoot: URL?
    @State private var importNeedsPassword = false
    @State private var showFileImporter = false
    @State private var showNearbySync = false
    @State private var showRestoreConfirmation = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var debugRecordCount = 0
    @State private var workTask: Task<Void, Never>?

    private var isU10Mode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-M8U10")
        #else
        false
        #endif
    }

    var body: some View {
        List {
            Section(BackupCopy.transferTitle) {
                Label(BackupCopy.transferDescription, systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(CT.Font.bodyReading)
                    .foregroundStyle(CT.Color.inkSecondary)
                Button {
                    showNearbySync = true
                } label: {
                    Label(BackupCopy.openTransfer, systemImage: "arrow.left.arrow.right")
                        .font(CT.Font.headline)
                }
                .foregroundStyle(CT.Color.primary)
                .accessibilityIdentifier("m8.backup.transfer")
            }

            Section(BackupCopy.exportTitle) {
                Text(BackupCopy.exportDescription)
                    .font(CT.Font.bodyReading)
                    .foregroundStyle(CT.Color.inkSecondary)
                Picker(
                    BackupCopy.scope,
                    selection: $exportAllMembers
                ) {
                    Text(BackupCopy.currentMember).tag(false)
                    Text(BackupCopy.allMembers).tag(true)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("m8.backup.scope")
                Label(BackupCopy.exportRisk, systemImage: "exclamationmark.shield.fill")
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.warningOnContainer)
                    .padding(.vertical, CT.Space.s2)
                Button(BackupCopy.prepareExport) {
                    createReadableExport()
                }
                .font(CT.Font.headline)
                .foregroundStyle(CT.Color.primary)
                .disabled(isWorking)
                .accessibilityIdentifier("m8.backup.export")

                Button {
                    showOptionalPassword.toggle()
                } label: {
                    HStack(spacing: CT.Space.s2) {
                        Text(BackupCopy.optionalPassword)
                        Spacer()
                        Image(
                            systemName: showOptionalPassword
                                ? "chevron.up"
                                : "chevron.down"
                        )
                    }
                    .font(CT.Font.body)
                    .foregroundStyle(CT.Color.inkPrimary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showOptionalPassword ? "已展开" : "已收起")
                .accessibilityIdentifier("m8.backup.optionalPassword")
                if showOptionalPassword {
                    SecureField(BackupCopy.password, text: $backupPassword)
                        .textContentType(.newPassword)
                        .font(CT.Font.body)
                        .accessibilityIdentifier("m8.backup.password")
                    Text(BackupCopy.passwordHint)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                    Text(BackupCopy.passwordLossWarning)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.warningOnContainer)
                    Button(BackupCopy.prepareEncryptedExport) {
                        createEncryptedExport()
                    }
                    .font(CT.Font.subhead.weight(.semibold))
                    .foregroundStyle(CT.Color.primary)
                    .disabled(isWorking || backupPassword.count < 12)
                    .accessibilityIdentifier("m8.backup.encryptedExport")
                }
                if let exportedPackage {
                    ShareLink(
                        item: exportedPackage.archiveURL,
                        preview: SharePreview(BackupCopy.shareExport)
                    ) {
                        Label(BackupCopy.shareExport, systemImage: "square.and.arrow.up")
                            .font(CT.Font.headline)
                    }
                    .foregroundStyle(CT.Color.primary)
                    .accessibilityIdentifier("m8.backup.share")
                    LabeledContent(
                        BackupCopy.lastExport,
                        value: exportedPackage.preview.exportedAt.formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                    )
                    .font(CT.Font.footnote)
                }
            }

            Section(BackupCopy.importTitle) {
                Text(BackupCopy.importDescription)
                    .font(CT.Font.bodyReading)
                    .foregroundStyle(CT.Color.inkSecondary)
                Button {
                    showFileImporter = true
                } label: {
                    Label(
                        BackupCopy.chooseBackup,
                        systemImage: "square.and.arrow.down"
                    )
                    .font(CT.Font.headline)
                }
                .foregroundStyle(CT.Color.primary)
                .disabled(isWorking)
                .accessibilityIdentifier("m8.backup.import")
                if importNeedsPassword {
                    SecureField(BackupCopy.password, text: $importPassword)
                        .textContentType(.password)
                        .font(CT.Font.body)
                        .accessibilityIdentifier("m8.backup.importPassword")
                    Text(BackupCopy.encryptedImport)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                    Button(BackupCopy.validateEncryptedImport) {
                        preflightSelectedArchive()
                    }
                    .font(CT.Font.headline)
                    .foregroundStyle(CT.Color.primary)
                    .disabled(isWorking || importPassword.isEmpty)
                    .accessibilityIdentifier("m8.backup.validateEncrypted")
                }
                if let plan = importPlan {
                    backupSummary(plan.preview)
                    Button(BackupCopy.restore, role: .destructive) {
                        showRestoreConfirmation = true
                    }
                    .font(CT.Font.headline)
                    .accessibilityIdentifier("m8.backup.restore")
                }
            }

            if isU10Mode {
                Section("DEBUG · U10") {
                    Text(String(
                        format: BackupCopy.debugCountFormat,
                        debugRecordCount
                    ))
                    .font(CT.Font.valueMono)
                    .accessibilityIdentifier("m8.backup.debug.count")
                    Button(BackupCopy.debugPrepare) {
                        createReadableExport(forceAll: true)
                    }
                    .accessibilityIdentifier("m8.backup.debug.export")
                    Button(BackupCopy.debugClear, role: .destructive) {
                        debugClearDatabase()
                    }
                    .accessibilityIdentifier("m8.backup.debug.clear")
                    Button(BackupCopy.debugRestore) {
                        debugRestoreLatest()
                    }
                    .disabled(exportedPackage == nil)
                    .accessibilityIdentifier("m8.backup.debug.restore")
                }
            }

            if isWorking {
                Section {
                    HStack(spacing: CT.Space.s3) {
                        ProgressView()
                        Text(BackupCopy.working)
                            .font(CT.Font.body)
                    }
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.danger)
                        .accessibilityIdentifier("m8.backup.error")
                }
            }
            if let successMessage {
                Section {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(CT.Font.body)
                        .foregroundStyle(CT.Color.success)
                        .accessibilityIdentifier("m8.backup.success")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(BackupCopy.navigationTitle)
        .sheet(isPresented: $showNearbySync) {
            NearbySyncFlowHost(
                patients: patients,
                selectedPatientID: patientID
            )
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.zip, .data],
            allowsMultipleSelection: false
        ) { result in
            handleImportSelection(result)
        }
        .alert(
            BackupCopy.restoreQuestion,
            isPresented: $showRestoreConfirmation
        ) {
            Button(BackupCopy.cancel, role: .cancel) {}
            Button(BackupCopy.restore, role: .destructive) {
                restoreSelectedPlan()
            }
        } message: {
            Text(BackupCopy.restoreWarning)
        }
        .task {
            reloadDebugCount()
        }
        .onDisappear {
            workTask?.cancel()
            discardTransientArtifacts()
        }
        .accessibilityIdentifier("m8.backup.screen")
    }

    @ViewBuilder
    private func backupSummary(_ preview: BackupPreview) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s2) {
            Text(BackupCopy.validationTitle)
                .font(CT.Font.headline)
                .foregroundStyle(CT.Color.success)
            LabeledContent(
                BackupCopy.exportedAt,
                value: preview.exportedAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            LabeledContent(BackupCopy.memberCount, value: "\(preview.memberCount)")
            LabeledContent(BackupCopy.recordCount, value: "\(preview.recordCount)")
            LabeledContent(
                BackupCopy.attachmentCount,
                value: "\(preview.attachmentCount)"
            )
        }
        .font(CT.Font.footnote)
        .accessibilityIdentifier("m8.backup.preview")
    }

    @MainActor
    private func createEncryptedExport(forceAll: Bool? = nil) {
        workTask?.cancel()
        discardExportedPackage()
        isWorking = true
        errorMessage = nil
        successMessage = nil
        let all = forceAll ?? exportAllMembers
        let password = resolvedExportPassword
        workTask = Task { @MainActor in
            defer {
                isWorking = false
                workTask = nil
                reloadDebugCount()
            }
            do {
                let vault = try CaptureVaultService()
                let package = try await BackupExporter(
                    context: modelContext,
                    vault: vault
                ).exportEncrypted(
                    scope: all ? .allMembers : .singleMember(patientID),
                    password: password
                )
                exportedPackage = package
                CareActivityHistoryStore().recordBackup(
                    at: package.preview.exportedAt
                )
                successMessage = "带口令的存档已生成"
            } catch is CancellationError {
                AppLog.userAction.info("Backup export cancelled")
            } catch {
                let failure = error as NSError
                AppLog.data.error(
                    "Backup export UI failed; domain=\(failure.domain) code=\(failure.code)"
                )
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "带口令的存档生成失败，请稍后重试。"
            }
        }
    }

    @MainActor
    private func createReadableExport(forceAll: Bool? = nil) {
        workTask?.cancel()
        discardExportedPackage()
        isWorking = true
        errorMessage = nil
        successMessage = nil
        let all = forceAll ?? exportAllMembers
        workTask = Task { @MainActor in
            defer {
                isWorking = false
                workTask = nil
            }
            do {
                let vault = try CaptureVaultService()
                let package = try await BackupExporter(
                    context: modelContext,
                    vault: vault
                ).export(
                    scope: all
                        ? .allMembers
                        : .singleMember(patientID)
                )
                exportedPackage = package
                CareActivityHistoryStore().recordBackup(
                    at: package.preview.exportedAt
                )
                successMessage = "存档已生成"
            } catch is CancellationError {
                AppLog.userAction.info("Backup archive export cancelled")
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "存档生成失败，请稍后重试。"
            }
        }
    }

    @MainActor
    private func handleImportSelection(
        _ result: Result<[URL], Error>
    ) {
        workTask?.cancel()
        discardImportPlan()
        discardSelectedImportArchive()
        isWorking = true
        errorMessage = nil
        successMessage = nil
        let selectedURL: URL
        do {
            let urls = try result.get()
            guard let first = urls.first else {
                throw BackupError.unsupportedArchive
            }
            selectedURL = first
        } catch {
            isWorking = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "备份校验失败，当前资料没有改变。"
            return
        }
        let secured = selectedURL.startAccessingSecurityScopedResource()
        defer {
            if secured { selectedURL.stopAccessingSecurityScopedResource() }
        }
        do {
            let copy = try makeProtectedImportCopy(from: selectedURL)
            selectedImportArchiveRoot = copy.root
            selectedImportArchiveURL = copy.archive
            importNeedsPassword = BackupEncryption.isEncryptedBackup(copy.archive)
            isWorking = false
            if importNeedsPassword && importPassword.isEmpty {
                return
            }
            preflightSelectedArchive()
        } catch {
            isWorking = false
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "存档校验失败，当前资料没有改变。"
        }
    }

    @MainActor
    private func preflightSelectedArchive() {
        guard let selectedImportArchiveURL else { return }
        workTask?.cancel()
        discardImportPlan()
        isWorking = true
        errorMessage = nil
        successMessage = nil
        let password = importNeedsPassword ? importPassword : nil
        workTask = Task { @MainActor in
            defer {
                isWorking = false
                workTask = nil
            }
            do {
                let vault = try CaptureVaultService()
                importPlan = try await BackupImporter(
                    context: modelContext,
                    vault: vault
                ).preflight(
                    archiveURL: selectedImportArchiveURL,
                    password: password
                )
                discardSelectedImportArchive()
            } catch is CancellationError {
                AppLog.userAction.info("Backup preflight cancelled")
            } catch {
                importPlan = nil
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "存档校验失败，当前资料没有改变。"
            }
        }
    }

    private func makeProtectedImportCopy(
        from source: URL
    ) throws -> (root: URL, archive: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CareThreadSelectedBackup", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var excludedRoot = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excludedRoot.setResourceValues(values)
        let archive = root.appendingPathComponent("selected-archive")
        try FileManager.default.copyItem(at: source, to: archive)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: archive.path
        )
        return (root, archive)
    }

    @MainActor
    private func restoreSelectedPlan() {
        guard let importPlan else { return }
        workTask?.cancel()
        isWorking = true
        errorMessage = nil
        successMessage = nil
        workTask = Task { @MainActor in
            defer {
                isWorking = false
                workTask = nil
                reloadDebugCount()
            }
            do {
                let vault = try CaptureVaultService()
                _ = try await BackupImporter(
                    context: modelContext,
                    vault: vault
                ).restore(plan: importPlan, userConfirmed: true)
                self.importPlan = nil
                successMessage = BackupCopy.restored
            } catch is CancellationError {
                AppLog.userAction.info("Backup restore cancelled")
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "恢复失败，当前资料已回到恢复前状态。"
            }
        }
    }

    @MainActor
    private func debugClearDatabase() {
        #if DEBUG
        guard isU10Mode else { return }
        do {
            try deleteForDebug(ContentRevision.self)
            try deleteForDebug(AppleReminderBinding.self)
            try deleteForDebug(ReminderSchedule.self)
            try deleteForDebug(RecordAssignmentAudit.self)
            try deleteForDebug(CapturePage.self)
            try deleteForDebug(CaptureDraft.self)
            try deleteForDebug(ImportBatch.self)
            try deleteForDebug(RecordTag.self)
            try deleteForDebug(LabMeasurement.self)
            try deleteForDebug(Attachment.self)
            try deleteForDebug(FollowUp.self)
            try deleteForDebug(MedicalOrder.self)
            try deleteForDebug(Medication.self)
            try deleteForDebug(MedicalRecord.self)
            // Keep the selected member alive so the navigation destination
            // remains mounted while U10 exercises the destructive restore.
            // Production restore still replaces every V1 entity, including
            // Patient, and is covered by the importer rollback tests.
            try modelContext.save()
            successMessage = "DEBUG 清空完成"
        } catch {
            modelContext.rollback()
            errorMessage = "DEBUG 清空失败"
        }
        reloadDebugCount()
        #endif
    }

    @MainActor
    private func debugRestoreLatest() {
        #if DEBUG
        guard isU10Mode, let exportedPackage else { return }
        do {
            let vault = try CaptureVaultService()
            let importer = BackupImporter(context: modelContext, vault: vault)
            let plan = try importer.preflight(
                archiveURL: exportedPackage.archiveURL,
                password: nil
            )
            _ = try importer.restore(plan: plan, userConfirmed: true)
            successMessage = BackupCopy.restored
            errorMessage = nil
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription
                ?? "DEBUG 恢复失败"
        }
        reloadDebugCount()
        #endif
    }

    @MainActor
    private func deleteForDebug<T: PersistentModel>(_ type: T.Type) throws {
        for value in try modelContext.fetch(FetchDescriptor<T>()) {
            modelContext.delete(value)
        }
    }

    @MainActor
    private func reloadDebugCount() {
        debugRecordCount = (
            try? modelContext.fetchCount(FetchDescriptor<MedicalRecord>())
        ) ?? 0
    }

    private func discardTransientArtifacts() {
        discardExportedPackage()
        discardImportPlan()
        discardSelectedImportArchive()
    }

    private func discardExportedPackage() {
        exportedPackage?.discard()
        exportedPackage = nil
    }

    private func discardImportPlan() {
        importPlan?.discard()
        importPlan = nil
    }

    private func discardSelectedImportArchive() {
        if let selectedImportArchiveRoot {
            try? FileManager.default.removeItem(at: selectedImportArchiveRoot)
        }
        selectedImportArchiveURL = nil
        selectedImportArchiveRoot = nil
        importNeedsPassword = false
        importPassword = ""
    }

    private var resolvedExportPassword: String {
        #if DEBUG
        if isU10Mode && backupPassword.isEmpty {
            return "U10-Fictional-Backup!"
        }
        #endif
        return backupPassword
    }
}

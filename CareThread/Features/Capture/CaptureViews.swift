import PDFKit
import PhotosUI
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

struct CaptureFlowHost: View {
    private struct CameraImportSession: Identifiable {
        let id = UUID()
        let batchID: UUID
        let vaultRootURL: URL
        let sourceOrder: Int
        let pageLimit: Int
        let ownsBatch: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.displayName) private var patients: [Patient]
    @StateObject private var controller: M3CaptureFlowController
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var cameraImportSession: CameraImportSession?
    @State private var showDiscardConfirmation = false
    @State private var showAppendMenu = false
    @State private var importedSourceForAppend: M3CaptureSource?
    @State private var showError = false
    @State private var importTask: Task<Void, Never>?
    @State private var processingTask: Task<Void, Never>?
    @State private var didApplyInitialSource = false

    let initialSource: M3CaptureSource?
    let onSwitchMember: (UUID) -> Void
    let onSaved: () -> Void

    init(
        patient: Patient,
        initialSource: M3CaptureSource? = nil,
        onSwitchMember: @escaping (UUID) -> Void,
        onSaved: @escaping () -> Void
    ) {
        _controller = StateObject(wrappedValue: M3CaptureFlowController(patient: patient))
        self.initialSource = initialSource
        self.onSwitchMember = onSwitchMember
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Group {
                switch controller.phase {
                case .sources:
                    CaptureSourceView(
                        selectedPhotoItems: $selectedPhotoItems,
                        hasSavedDraft: hasSavedDraft,
                        onCamera: { prepareCameraImport() },
                        onFiles: {
                            importedSourceForAppend = nil
                            showFileImporter = true
                        },
                        onManual: controller.beginManual,
                        onFixture: {
                            controller.loadFixture(
                                mismatch: ProcessInfo.processInfo.arguments.contains("-M3NameMismatch"),
                                ambiguous: ProcessInfo.processInfo.arguments.contains(
                                    "-M3AmbiguousNames"
                                )
                            )
                        },
                        onContinueDraft: resumeLatestDraft
                    )
                    #if DEBUG
                    .screenshotReady(.captureSource)
                    #endif
                case .workbench:
                    CaptureWorkbenchView(
                        controller: controller,
                        onAppend: { showAppendMenu = true },
                        onContinue: startProcessing
                    )
                case .processing:
                    CaptureProcessingView(
                        processedPageCount: controller.processedPageCount,
                        totalPageCount: controller.totalProcessingPageCount,
                        onCancel: {
                            processingTask?.cancel()
                            persistCurrentDraft()
                            controller.phase = .workbench
                        }
                    )
                case .confirmation:
                    CaptureConfirmationView(
                        controller: controller,
                        patients: patients,
                        onSwitchMember: onSwitchMember,
                        onSaved: {
                            onSaved()
                        },
                        onSaveDraft: {
                            persistCurrentDraft()
                            dismiss()
                        }
                    )
                    #if DEBUG
                    .screenshotReady(.captureConfirmation)
                    #endif
                case .completed:
                    CaptureCompletedView(count: controller.completedRecordCount) {
                        onSaved()
                        dismiss()
                    }
                }
            }
            .background(CT.Color.bgBase)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Copy.Common.close) {
                        if controller.phase == .workbench {
                            showDiscardConfirmation = true
                        } else {
                            dismiss()
                        }
                    }
                    .accessibilityIdentifier("m3.capture.close")
                }
            }
        }
        .interactiveDismissDisabled(controller.phase == .processing)
        .presentationCornerRadius(CT.Radius.sheet)
        .sheet(item: $cameraImportSession) { session in
            DocumentCameraPicker(
                configuration: DocumentCameraStagingConfiguration(
                    batchID: session.batchID,
                    vaultRootURL: session.vaultRootURL,
                    pageDisplayNames: (0..<session.pageLimit).map {
                        Copy.Capture.scanPage(session.sourceOrder + $0 + 1)
                    }
                ),
                onComplete: { result in
                    finishCameraImport(result, session: session)
                },
                onCancel: {
                    cancelCameraImport(session)
                }
            )
            .ignoresSafeArea()
        }
        .confirmationDialog(
            Copy.Capture.addPage,
            isPresented: $showAppendMenu,
            titleVisibility: .visible
        ) {
            Button(Copy.Capture.camera) {
                importedSourceForAppend = .camera
                prepareCameraImport()
            }
            PhotosPicker(
                selection: $selectedPhotoItems,
                maxSelectionCount: max(1, 100 - controller.pageCount),
                selectionBehavior: .ordered,
                matching: .images
            ) {
                Text(Copy.Capture.photos)
            }
            Button(Copy.Capture.files) {
                importedSourceForAppend = .files
                showFileImporter = true
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .pdf],
            allowsMultipleSelection: true
        ) { result in
            importFiles(result)
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: max(1, 100 - controller.pageCount),
            selectionBehavior: .ordered,
            matching: .images
        )
        .onChange(of: selectedPhotoItems) { _, items in
            guard !items.isEmpty else { return }
            importTask?.cancel()
            importTask = Task { await importPhotos(items) }
        }
        .alert(Copy.Capture.keepDraftTitle, isPresented: $showDiscardConfirmation) {
            Button(Copy.Capture.keepDraft) {
                persistCurrentDraft()
                dismiss()
            }
            Button(Copy.Capture.continueEditing, role: .cancel) {}
        } message: {
            Text(Copy.Capture.keepDraftBody)
        }
        .alert(Copy.Capture.importFailure, isPresented: $showError) {
            Button(Copy.Common.acknowledge, role: .cancel) {}
        } message: {
            Text(controller.errorMessage ?? Copy.Capture.importFailure)
        }
        .onChange(of: controller.errorMessage) { _, value in
            showError = value != nil
        }
        .onDisappear {
            importTask?.cancel()
        }
        .onAppear {
            applyInitialSourceIfNeeded()
#if DEBUG
            if controller.phase == .sources,
               ProcessInfo.processInfo.arguments.contains(
                   "-M3BlankOCRConfirmation"
               ) {
                controller.loadBlankOCRConfirmationFixtureState()
                processingTask = Task { @MainActor in
                    do {
                        try await materializeConfirmation()
                        controller.phase = .confirmation
                    } catch {
                        AppLog.data.error(
                            "B5 fixture materialization failed; code=B5-FIXTURE-0001"
                        )
                        controller.errorMessage = Copy.Capture.saveFailure
                        controller.phase = .sources
                    }
                }
            } else if controller.phase == .sources,
                      ProcessInfo.processInfo.arguments.contains(
                          "-M3DirectAmbiguousConfirmation"
                      ) {
                controller.loadAmbiguousConfirmationFixture()
            } else if controller.phase == .sources,
                      ProcessInfo.processInfo.arguments.contains(
                          "-ScreenshotCaptureConfirmation"
                      ) {
                controller.beginManual()
            }
#endif
        }
        .accessibilityIdentifier("m3.capture.host")
    }

    @MainActor
    private func applyInitialSourceIfNeeded() {
        guard !didApplyInitialSource,
              controller.phase == .sources,
              let initialSource else {
            return
        }
        didApplyInitialSource = true
        switch initialSource {
        case .camera:
            prepareCameraImport()
        case .photos:
            showPhotoPicker = true
        case .files:
            importedSourceForAppend = nil
            showFileImporter = true
        case .manual:
            controller.beginManual()
        case .fixture:
            controller.loadFixture(mismatch: false)
        }
    }

    private var hasSavedDraft: Bool {
        let patientID = controller.frozenPatientID
        let descriptor = FetchDescriptor<ImportBatch>(
            predicate: #Predicate {
                $0.patientId == patientID && $0.statusRawValue != "completed"
            }
        )
        return ((try? modelContext.fetchCount(descriptor)) ?? 0) > 0
    }

    @MainActor
    private func prepareCameraImport() {
        let remaining = 100 - controller.pageCount
        guard remaining > 0 else {
            controller.errorMessage = Copy.Capture.pageLimit
            importedSourceForAppend = nil
            return
        }
        do {
            let hadExistingBatch: Bool
            if let activeBatchID = controller.activeBatchID {
                hadExistingBatch = try fetchBatch(id: activeBatchID) != nil
            } else {
                hadExistingBatch = false
            }
            let batchID = try ensureImportBatch(
                source: controller.activeSource ?? .camera
            )
            let vault = try CaptureVaultService()
            cameraImportSession = CameraImportSession(
                batchID: batchID,
                vaultRootURL: vault.rootURL,
                sourceOrder: controller.pageCount,
                pageLimit: remaining,
                ownsBatch: !hadExistingBatch
            )
        } catch {
            controller.errorMessage = Copy.Capture.importFailure
        }
    }

    @MainActor
    private func finishCameraImport(
        _ result: Result<[StagedCaptureAsset], Error>,
        session: CameraImportSession
    ) {
        cameraImportSession = nil
        importedSourceForAppend = nil
        switch result {
        case let .success(staged):
            let assets = staged.enumerated().map { index, asset in
                M3CapturePageAsset(
                    stagedAssetID: asset.id,
                    batchID: asset.batchID,
                    displayName: asset.displayName,
                    relativePath: asset.originalRelativePath,
                    previewRelativePath: asset.previewRelativePath,
                    kind: asset.kind,
                    sourceSessionID: asset.id.uuidString,
                    sourceOrder: session.sourceOrder + index,
                    captureSource: .camera
                )
            }
            guard !assets.isEmpty else {
                cancelCameraImport(session)
                controller.errorMessage = Copy.Capture.importFailure
                return
            }
            acceptImportedAssets(assets, source: .camera)
        case .failure(is CaptureBulkImportError):
            cancelCameraImport(session)
            controller.errorMessage = Copy.Capture.pageLimit
        case .failure:
            cancelCameraImport(session)
            controller.errorMessage = Copy.Capture.importFailure
        }
    }

    @MainActor
    private func cancelCameraImport(_ session: CameraImportSession) {
        cameraImportSession = nil
        importedSourceForAppend = nil
        guard session.ownsBatch, controller.pageCount == session.sourceOrder else {
            return
        }
        do {
            try CaptureVaultService(rootURL: session.vaultRootURL)
                .discardBatch(session.batchID)
            if let batch = try fetchBatch(id: session.batchID) {
                modelContext.delete(batch)
                try modelContext.save()
            }
            if controller.activeBatchID == session.batchID {
                controller.activeBatchID = nil
            }
        } catch {
            AppLog.vault.error(
                "Unable to remove cancelled empty camera staging batch"
            )
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        let source = importedSourceForAppend ?? .files
        var importedAssets: [M3CapturePageAsset] = []
        do {
            let urls = try result.get()
            let batchID = try ensureImportBatch(source: source)
            for url in urls {
                importedAssets.append(
                    contentsOf: try M3CaptureFileStore.assets(
                        fromFile: url,
                        batchID: batchID,
                        startingAt: controller.pageCount + importedAssets.count
                    )
                )
            }
            acceptImportedAssets(importedAssets, source: source)
        } catch CaptureVaultError.unsupportedType {
            acceptImportedAssets(importedAssets, source: source)
            controller.errorMessage = Copy.Capture.videoRejected
        } catch {
            acceptImportedAssets(importedAssets, source: source)
            controller.errorMessage = Copy.Capture.importFailure
        }
        importedSourceForAppend = nil
    }

    private func acceptImportedAssets(
        _ assets: [M3CapturePageAsset],
        source: M3CaptureSource
    ) {
        guard !assets.isEmpty else { return }
        guard controller.pageCount + assets.count <= 100 else {
            let grouped = Dictionary(grouping: assets.compactMap { asset in
                asset.batchID.map { ($0, asset.stagedAssetID) }
            }, by: { $0.0 })
            if let vault = try? CaptureVaultService() {
                for (batchID, values) in grouped {
                    let assetIDs = Set(values.compactMap { $0.1 })
                    try? vault.discardStagedAssets(
                        batchID: batchID,
                        assetIDs: assetIDs
                    )
                }
            }
            controller.errorMessage = Copy.Capture.pageLimit
            return
        }
        if controller.phase == .workbench {
            controller.appendAssets(assets)
        } else {
            controller.loadAssets(assets, source: source)
        }
        persistStagingModels()
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        let remaining = 100 - controller.pageCount
        guard remaining > 0 else {
            selectedPhotoItems = []
            controller.errorMessage = Copy.Capture.pageLimit
            importTask = nil
            return
        }
        let batchID: UUID
        let vaultRootURL: URL
        let ownsBatch = controller.activeBatchID == nil
        do {
            batchID = try ensureImportBatch(source: controller.activeSource ?? .photos)
            vaultRootURL = try CaptureVaultService().rootURL
        } catch {
            controller.errorMessage = Copy.Capture.importFailure
            return
        }
        let sourceOrder = controller.pageCount
        let selected = Array(items.prefix(remaining))
        var staged: [StagedCaptureAsset] = []
        staged.reserveCapacity(selected.count)
        do {
            for (index, item) in selected.enumerated() {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CaptureVaultError.invalidImage
                }
                try Task.checkCancellation()
                let type = item.supportedContentTypes.first {
                    $0.conforms(to: .image)
                } ?? .jpeg
                let asset = try await CaptureAssetStagingWorker.stagePhotoData(
                    data,
                    vaultRootURL: vaultRootURL,
                    batchID: batchID,
                    displayName: Copy.Capture.photoPage(sourceOrder + index + 1),
                    preferredExtension: type.preferredFilenameExtension ?? "jpg",
                    uniformTypeIdentifier: type.identifier
                )
                staged.append(asset)
            }
            let assets = staged.enumerated().map { index, asset in
                M3CapturePageAsset(
                    stagedAssetID: asset.id,
                    batchID: asset.batchID,
                    displayName: asset.displayName,
                    relativePath: asset.originalRelativePath,
                    previewRelativePath: asset.previewRelativePath,
                    kind: asset.kind,
                    sourceSessionID: asset.id.uuidString,
                    sourceOrder: sourceOrder + index,
                    captureSource: .photos
                )
            }
            acceptImportedAssets(assets, source: .photos)
        } catch is CancellationError {
            await discardImportedAssets(
                staged,
                batchID: batchID,
                vaultRootURL: vaultRootURL
            )
            if ownsBatch {
                await removeEmptyImportBatch(
                    batchID: batchID,
                    vaultRootURL: vaultRootURL
                )
            }
        } catch {
            await discardImportedAssets(
                staged,
                batchID: batchID,
                vaultRootURL: vaultRootURL
            )
            if ownsBatch {
                await removeEmptyImportBatch(
                    batchID: batchID,
                    vaultRootURL: vaultRootURL
                )
            }
            controller.errorMessage = Copy.Capture.importFailure
        }
        selectedPhotoItems = []
        importTask = nil
    }

    private func discardImportedAssets(
        _ assets: [StagedCaptureAsset],
        batchID: UUID,
        vaultRootURL: URL
    ) async {
        let assetIDs = Set(assets.map(\.id))
        guard !assetIDs.isEmpty else { return }
        await Task.detached(priority: .utility) {
            try? CaptureVaultService(rootURL: vaultRootURL)
                .discardStagedAssets(batchID: batchID, assetIDs: assetIDs)
        }.value
    }

    private func removeEmptyImportBatch(
        batchID: UUID,
        vaultRootURL: URL
    ) async {
        await Task.detached(priority: .utility) {
            try? CaptureVaultService(rootURL: vaultRootURL)
                .discardBatch(batchID)
        }.value
        if let batch = try? fetchBatch(id: batchID) {
            modelContext.delete(batch)
            try? modelContext.save()
        }
        if controller.activeBatchID == batchID {
            controller.activeBatchID = nil
        }
    }

    private func startProcessing() {
        guard controller.groupingConfirmed else {
            controller.errorMessage = Copy.Capture.groupingRequired
            return
        }
        controller.phase = .processing
        controller.totalProcessingPageCount = controller.pageCount
        controller.processedPageCount = 0
        processingTask = Task { @MainActor in
            do {
                if !controller.hasCompletedRecognition {
                    try await recognizeImportedPages()
                    controller.markRecognitionCompleted()
                    try controller.validateReadyForMaterialization()
                }
                if !controller.hasAppliedGroupingSuggestions {
                    try applyGroupingSuggestions()
                    controller.hasAppliedGroupingSuggestions = true
                    controller.groupingConfirmed = false
                    persistStagingModels()
                    controller.phase = .workbench
                    return
                }
                try controller.validateReadyForMaterialization()
                try await materializeConfirmation()
                controller.phase = .confirmation
            } catch is CancellationError {
                persistCurrentDraft()
                controller.phase = .workbench
            } catch {
                AppLog.data.error(
                    "M3 capture processing failed: \(String(describing: error), privacy: .private(mask: .hash))"
                )
                controller.errorMessage = Copy.Capture.saveFailure
                controller.phase = .workbench
            }
        }
    }

    private func recognizeImportedPages() async throws {
        let vault = try CaptureVaultService()
        for documentIndex in controller.documents.indices {
            for pageIndex in controller.documents[documentIndex].pages.indices {
                try Task.checkCancellation()
                let page = controller.documents[documentIndex].pages[pageIndex]
                let output: M3RecognitionOutput
                if page.relativePath == nil, let existingText = page.ocrText {
                    output = try await M3CaptureRecognitionPipeline.outputForExistingText(
                        existingText,
                        detectedNames: page.detectedNames
                    )
                } else {
                    output = try await M3CaptureRecognitionPipeline.recognize(
                        page: page,
                        pageIndex: page.sourceOrder,
                        vault: vault
                    )
                }
                controller.documents[documentIndex].pages[pageIndex].ocrText =
                    output.text
                controller.documents[documentIndex].pages[pageIndex].detectedNames =
                    output.names
                controller.documents[documentIndex].pages[pageIndex].suggestedHospital =
                    output.extraction.hospital
                controller.documents[documentIndex].pages[pageIndex].suggestedDate =
                    output.extraction.eventDate
                controller.documents[documentIndex].pages[pageIndex].suggestedTitle =
                    output.extraction.title
                controller.documents[documentIndex].pages[pageIndex].machineExtraction =
                    output.extraction
                controller.documents[documentIndex].pages[pageIndex].recognitionGeneration =
                    controller.flowGeneration
                controller.documents[documentIndex].pages[pageIndex].recognitionStatus =
                    output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .noEvidence
                    : .recognized
                controller.processedPageCount += 1
            }
        }
    }

    private func applyGroupingSuggestions() throws {
        guard let source = controller.activeSource else { return }
        let orderedPages = controller.documents.flatMap(\.pages)
            .sorted { $0.sourceOrder < $1.sourceOrder }
        let evidence = M3CaptureRecognitionPipeline.groupingEvidence(
            for: orderedPages,
            source: source
        )
        let overrides: [ImportBoundaryOverride]
        if controller.hasManualGroupingEdits {
            let documentByPageID = Dictionary(
                uniqueKeysWithValues: controller.documents.flatMap { document in
                    document.pages.map { ($0.id, document.id) }
                }
            )
            overrides = zip(orderedPages, orderedPages.dropFirst()).map {
                previous,
                next in
                ImportBoundaryOverride(
                    previousPageID: previous.id,
                    nextPageID: next.id,
                    decision: documentByPageID[previous.id] == documentByPageID[next.id]
                        ? .sameDocument
                        : .newDocument
                )
            }
        } else {
            overrides = []
        }
        let result = try ImportGroupingEngine().suggest(
            pages: evidence,
            overrides: overrides
        )
        controller.duplicateSuggestionCount =
            result.duplicateSuggestions.count
        let decisions = Dictionary(
            uniqueKeysWithValues: result.boundaries.map {
                ($0.key.nextPageID, $0.decision)
            }
        )
        var suggestedDocuments: [M3CaptureDocument] = []
        for var page in orderedPages {
            let decision = decisions[page.id]
            let previousPage = suggestedDocuments.last?.pages.last
            let sameImmutablePDF = previousPage?.kind == .pdf
                && previousPage?.stagedAssetID != nil
                && previousPage?.stagedAssetID == page.stagedAssetID
            let continues = sameImmutablePDF || decision == .sameDocument
            page.isSuggestedContinuation = continues
            if continues, !suggestedDocuments.isEmpty {
                suggestedDocuments[suggestedDocuments.count - 1].pages.append(page)
            } else {
                suggestedDocuments.append(M3CaptureDocument(pages: [page]))
            }
        }
        coalesceImmutablePDFDocuments(&suggestedDocuments)
        controller.documents = suggestedDocuments
        controller.normalizeOrders()
        controller.largeDocumentWarningAcknowledged = false
    }

    private func coalesceImmutablePDFDocuments(
        _ documents: inout [M3CaptureDocument]
    ) {
        var ownerByAssetID: [UUID: Int] = [:]
        var index = 0
        while index < documents.count {
            let pdfAssetIDs = Set(
                documents[index].pages
                    .filter { $0.kind == .pdf }
                    .compactMap(\.stagedAssetID)
            )
            let destinationIndexes = pdfAssetIDs.compactMap {
                ownerByAssetID[$0]
            }
            if let destination = destinationIndexes.min(), destination < index {
                documents[destination].pages.append(contentsOf: documents[index].pages)
                documents.remove(at: index)
                continue
            }
            for assetID in pdfAssetIDs {
                ownerByAssetID[assetID] = index
            }
            index += 1
        }
    }

    private func materializeConfirmation() async throws {
        guard let source = controller.activeSource else { return }
        let batchID = try ensureImportBatch(source: source)
        guard let batch = try fetchBatch(id: batchID) else {
            throw CaptureCommitError.batchMissing
        }
        let previousDrafts = batch.drafts
        var outputs: [M3ConfirmationDocument] = []
        do {
            for (documentIndex, document) in controller.documents.enumerated() {
                try Task.checkCancellation()
                let combinedText = document.pages.compactMap(\.ocrText)
                    .joined(separator: "\n")
                let machine = try await M3CaptureRecognitionPipeline.extractText(
                    combinedText
                )
                let documentSource = document.pages.first?.captureSource ?? source
                let draft = CaptureDraft(
                    patientId: controller.frozenPatientID,
                    batchId: batch.id,
                    documentIndex: documentIndex,
                    titleSuggestion: machine.title,
                    sourceType: documentSource.sourceType,
                    attachmentPaths: Array(Set(document.pages.compactMap(\.relativePath))).sorted(),
                    selectedType: machine.type,
                    selectedDate: machine.eventDate,
                    ocrText: combinedText,
                    machineExtraction: machine
                )
                try batch.bindDraft(draft)
                modelContext.insert(draft)
                for (pageIndex, asset) in document.pages.enumerated() {
                    let page = CapturePage(
                        patientId: controller.frozenPatientID,
                        batchId: batch.id,
                        draftId: draft.id,
                        sourceOrder: asset.sourceOrder,
                        pageIndex: pageIndex,
                        stagingRelativePath: asset.relativePath
                            ?? "fixture/\(asset.id.uuidString)",
                        ocrStatus: .pending,
                        pageMarker: M3PersistedPageMetadata(
                            page: asset,
                            flowGeneration: controller.flowGeneration
                        ).encoded(),
                        draft: draft
                    )
                    try draft.bindPage(page)
                    modelContext.insert(page)
                }
                for (page, asset) in zip(
                    draft.pages.sorted(by: { $0.pageIndex < $1.pageIndex }),
                    document.pages
                ) {
                    let status = asset.recognitionStatus
                        ?? (asset.ocrText == nil ? .noEvidence : .recognized)
                    try page.applyOCR(
                        generation: draft.generation,
                        status: status,
                        text: asset.ocrText,
                        detectedNameCandidates: asset.detectedNames,
                        hospitalSuggestion: asset.suggestedHospital,
                        dateSuggestion: asset.suggestedDate,
                        titleSuggestion: asset.suggestedTitle,
                        pageMarker: M3PersistedPageMetadata(
                            page: asset,
                            flowGeneration: controller.flowGeneration
                        ).encoded(),
                        overlapFingerprint: asset.isSuggestedContinuation
                            ? "continuation" : nil
                    )
                }
                let patient = patients.first(where: {
                    $0.id == controller.frozenPatientID
                })
                let evidence = try patient.map {
                    try CaptureNameEvidenceAggregator.evaluate(
                        draft: draft,
                        frozenPatient: $0
                    )
                }
                outputs.append(
                    M3ConfirmationDocument(
                        id: document.id,
                        draftID: draft.id,
                        generation: draft.generation,
                        evidence: evidence,
                        sourceType: documentSource.sourceType,
                        importSource: documentSource.importSource,
                        pages: document.pages,
                        machine: machine,
                        type: machine.type,
                        title: machine.title,
                        summary: machine.summary,
                        eventDate: machine.eventDate ?? Date(),
                        hospital: machine.hospital ?? "",
                        department: machine.department ?? "",
                        doctor: "",
                        diseases: "",
                        structuredFields: machine.structuredFields,
                        labItems: machine.labItems
                    )
                )
            }
            previousDrafts.forEach(modelContext.delete)
            batch.advance(to: .recognizing)
            batch.advance(to: .readyForReview)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
        controller.confirmations = outputs
    }

    private func persistCurrentDraft() {
        if controller.documents.isEmpty,
           controller.confirmations.first?.sourceType == .manual {
            persistManualConfirmationDraft()
            return
        }
        guard controller.activeSource != nil, !controller.documents.isEmpty else { return }
        persistStagingModels()
    }

    private func persistManualConfirmationDraft() {
        guard let source = controller.activeSource,
              let confirmation = controller.confirmations.first else { return }
        do {
            let batchID = try ensureImportBatch(source: source)
            guard let batch = try fetchBatch(id: batchID) else { return }
            let previousDrafts = batch.drafts
            let draft = CaptureDraft(
                patientId: controller.frozenPatientID,
                batchId: batch.id,
                documentIndex: 0,
                titleSuggestion: confirmation.machine.title,
                confirmedTitle: confirmation.title,
                sourceType: .manual,
                selectedType: confirmation.type,
                selectedDate: confirmation.eventDate,
                machineExtraction: confirmation.machine
            )
            try batch.bindDraft(draft)
            modelContext.insert(draft)
            previousDrafts.forEach(modelContext.delete)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            controller.errorMessage = Copy.Capture.saveFailure
        }
    }

    private func ensureImportBatch(source: M3CaptureSource) throws -> UUID {
        if let activeBatchID = controller.activeBatchID,
           try fetchBatch(id: activeBatchID) != nil {
            return activeBatchID
        }
        let batch = ImportBatch(
            patientId: controller.frozenPatientID,
            sourceType: source.sourceType,
            status: .staging
        )
        try CaptureVaultService().beginBatch(batch.id)
        modelContext.insert(batch)
        try modelContext.save()
        controller.activeBatchID = batch.id
        return batch.id
    }

    private func fetchBatch(id: UUID) throws -> ImportBatch? {
        var descriptor = FetchDescriptor<ImportBatch>(
            predicate: #Predicate { $0.id == id }
        )
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func persistStagingModels() {
        guard let source = controller.activeSource,
              !controller.documents.isEmpty else { return }
        do {
            let batchID = try ensureImportBatch(source: source)
            guard let batch = try fetchBatch(id: batchID) else { return }
            let previousDrafts = batch.drafts
            for (documentIndex, document) in controller.documents.enumerated() {
                let draft = CaptureDraft(
                    patientId: controller.frozenPatientID,
                    batchId: batch.id,
                    documentIndex: documentIndex,
                    sourceType: source.sourceType,
                    attachmentPaths: Array(Set(document.pages.compactMap(\.relativePath))).sorted(),
                    ocrText: document.pages.compactMap(\.ocrText).joined(separator: "\n")
                )
                try batch.bindDraft(draft)
                modelContext.insert(draft)
                for (pageIndex, asset) in document.pages.enumerated() {
                    let page = CapturePage(
                        patientId: controller.frozenPatientID,
                        batchId: batch.id,
                        draftId: draft.id,
                        sourceOrder: asset.sourceOrder,
                        pageIndex: pageIndex,
                        stagingRelativePath: asset.relativePath
                            ?? "staging/\(batch.id.uuidString)/fixture/\(asset.id.uuidString)",
                        ocrStatus: .pending,
                        pageMarker: M3PersistedPageMetadata(
                            page: asset,
                            flowGeneration: controller.flowGeneration
                        ).encoded(),
                        draft: draft
                    )
                    try draft.bindPage(page)
                    modelContext.insert(page)
                }
                for (page, asset) in zip(
                    draft.pages.sorted(by: { $0.pageIndex < $1.pageIndex }),
                    document.pages
                ) where asset.recognitionStatus != nil {
                    try page.applyOCR(
                        generation: draft.generation,
                        status: asset.recognitionStatus ?? .noEvidence,
                        text: asset.ocrText,
                        detectedNameCandidates: asset.detectedNames,
                        hospitalSuggestion: asset.suggestedHospital,
                        dateSuggestion: asset.suggestedDate,
                        titleSuggestion: asset.suggestedTitle,
                        pageMarker: M3PersistedPageMetadata(
                            page: asset,
                            flowGeneration: controller.flowGeneration
                        ).encoded(),
                        overlapFingerprint: asset.isSuggestedContinuation
                            ? "continuation" : nil
                    )
                }
            }
            try CaptureVaultService().updateJournalState(
                batchID: batchID,
                state: .staging
            )
            previousDrafts.forEach(modelContext.delete)
            try modelContext.save()
        } catch {
            modelContext.rollback()
            controller.errorMessage = Copy.Capture.saveFailure
        }
    }

    private func resumeLatestDraft() {
        let patientID = controller.frozenPatientID
        let descriptor = FetchDescriptor<ImportBatch>(
            predicate: #Predicate {
                $0.patientId == patientID && $0.statusRawValue != "completed"
            },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        guard let batch = try? modelContext.fetch(descriptor).first else {
            controller.errorMessage = Copy.Capture.noDraft
            return
        }
        if batch.sourceType == .manual,
           let draft = batch.drafts.sorted(by: {
               $0.documentIndex < $1.documentIndex
           }).first {
            let machine = draft.machineExtraction ?? .empty
            controller.activeSource = .manual
            controller.activeBatchID = batch.id
            controller.confirmations = [
                M3ConfirmationDocument(
                    id: draft.id,
                    draftID: nil,
                    generation: nil,
                    evidence: nil,
                    sourceType: .manual,
                    importSource: .generated,
                    pages: [],
                    machine: machine,
                    type: draft.selectedType ?? .other,
                    title: draft.confirmedTitle ?? "",
                    summary: machine.summary,
                    eventDate: draft.selectedDate ?? Date(),
                    hospital: machine.hospital ?? "",
                    department: machine.department ?? "",
                    doctor: "",
                    diseases: "",
                    structuredFields: machine.structuredFields,
                    labItems: machine.labItems,
                    abnormalItems: machine.abnormalFlags,
                    labDrafts: machine.labItems.map(M3LabItemDraft.init)
                )
            ]
            controller.phase = .confirmation
            return
        }
        let journal = try? CaptureVaultService().journal(batchID: batch.id)
        let stagedByPath = Dictionary(
            uniqueKeysWithValues: (journal?.assets ?? []).map {
                ($0.originalRelativePath, $0)
            }
        )
        var nextPDFPageIndex: [UUID: Int] = [:]
        let documents = batch.drafts
            .sorted { $0.documentIndex < $1.documentIndex }
            .map { draft in
                let assets = draft.pages
                    .sorted { $0.pageIndex < $1.pageIndex }
                    .map { page in
                        let staged = page.stagingRelativePath.flatMap {
                            stagedByPath[$0]
                        }
                        let metadata = M3PersistedPageMetadata.decode(page.pageMarker)
                        let pdfPageIndex: Int?
                        if let persistedIndex = metadata?.pdfPageIndex {
                            pdfPageIndex = persistedIndex
                        } else if let staged, staged.kind == .pdf {
                            pdfPageIndex = nextPDFPageIndex[staged.id, default: 0]
                            nextPDFPageIndex[staged.id, default: 0] += 1
                        } else {
                            pdfPageIndex = nil
                        }
                        return M3CapturePageAsset(
                            id: page.id,
                            stagedAssetID: staged?.id,
                            batchID: staged == nil ? nil : batch.id,
                            displayName: Copy.Capture.draftPage(page.pageIndex + 1),
                            relativePath: page.stagingRelativePath,
                            previewRelativePath: staged?.previewRelativePath,
                            kind: staged?.kind ?? .image,
                            sourceSessionID: staged?.id.uuidString
                                ?? batch.id.uuidString,
                            sourceOrder: page.sourceOrder,
                            rotationQuarterTurns: metadata?.rotationQuarterTurns ?? 0,
                            pdfPageIndex: pdfPageIndex,
                            ocrText: page.ocrText,
                            detectedNames: page.detectedNameCandidates,
                            suggestedHospital: page.hospitalSuggestion,
                            suggestedDate: page.dateSuggestion,
                            suggestedTitle: page.titleSuggestion,
                            machineExtraction: draft.machineExtraction,
                            isSuggestedContinuation: page.pageIndex > 0,
                            captureSource: metadata?.captureSource
                                ?? source(for: batch.sourceType),
                            recognitionGeneration: metadata?.recognitionGeneration,
                            recognitionStatus: metadata?.recognitionStatus
                        )
                    }
                return M3CaptureDocument(id: draft.id, pages: assets)
            }
        controller.activeSource = source(for: batch.sourceType)
        controller.activeBatchID = batch.id
        controller.documents = documents
        let restoredGeneration = documents
            .flatMap(\.pages)
            .compactMap { page in
                M3PersistedPageMetadata.decode(
                    batch.drafts
                        .flatMap(\.pages)
                        .first(where: { $0.id == page.id })?
                        .pageMarker
                )?.flowGeneration
            }
            .max() ?? 0
        controller.restoreRecognitionState(flowGeneration: restoredGeneration)
        controller.largeDocumentWarningAcknowledged = false
        controller.groupingConfirmed = false
        controller.phase = .workbench
    }

    private func source(for sourceType: SourceType) -> M3CaptureSource {
        switch sourceType {
        case .camera: .camera
        case .photo: .photos
        case .file: .files
        case .manual: .manual
        case .fixture: .fixture
        }
    }
}

private struct CaptureSourceView: View {
    @Binding var selectedPhotoItems: [PhotosPickerItem]
    let hasSavedDraft: Bool
    let onCamera: () -> Void
    let onFiles: () -> Void
    let onManual: () -> Void
    let onFixture: () -> Void
    let onContinueDraft: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s4) {
                Text(Copy.Capture.sourceSubtitle)
                    .font(CT.Font.subhead)
                    .foregroundStyle(CT.Color.inkSecondary)
                CaptureSourceButton(
                    title: Copy.Capture.camera,
                    subtitle: Copy.Capture.cameraHint,
                    symbol: "doc.viewfinder",
                    identifier: "m3.source.camera",
                    action: onCamera
                )
                PhotosPicker(
                    selection: $selectedPhotoItems,
                    maxSelectionCount: 100,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    CaptureSourceLabel(
                        title: Copy.Capture.photos,
                        subtitle: Copy.Capture.photosHint,
                        symbol: "photo.on.rectangle.angled"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("m3.source.photos")
                CaptureSourceButton(
                    title: Copy.Capture.files,
                    subtitle: Copy.Capture.filesHint,
                    symbol: "folder",
                    identifier: "m3.source.files",
                    action: onFiles
                )
                CaptureSourceButton(
                    title: Copy.Capture.manual,
                    subtitle: Copy.Capture.manualHint,
                    symbol: "square.and.pencil",
                    identifier: "m3.source.manual",
                    action: onManual
                )
#if DEBUG
                CaptureSourceButton(
                    title: Copy.Capture.fixture,
                    subtitle: Copy.Capture.fixtureHint,
                    symbol: "doc.on.doc",
                    identifier: "m3.source.fixture",
                    action: onFixture
                )
#endif
                Button(action: onContinueDraft) {
                    Label(Copy.Capture.continueDraft, systemImage: "clock.arrow.circlepath")
                        .frame(maxWidth: .infinity, minHeight: CT.Size.secondaryButtonHeight)
                }
                .buttonStyle(.bordered)
                .disabled(!hasSavedDraft)
                .accessibilityIdentifier("m3.source.continueDraft")
            }
            .padding(CT.Space.s4)
        }
        .navigationTitle(Copy.Capture.sourceTitle)
    }
}

private struct CaptureSourceButton: View {
    let title: String
    let subtitle: String
    let symbol: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CaptureSourceLabel(title: title, subtitle: subtitle, symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

private struct CaptureSourceLabel: View {
    let title: String
    let subtitle: String
    let symbol: String

    var body: some View {
        CTCard {
            HStack(spacing: CT.Space.s4) {
                Image(systemName: symbol)
                    .font(CT.Font.title2)
                    .foregroundStyle(CT.Color.primary)
                    .frame(width: M3Layout.sourceIcon, height: M3Layout.sourceIcon)
                VStack(alignment: .leading, spacing: CT.Space.s1) {
                    Text(title)
                        .font(CT.Font.headline)
                        .foregroundStyle(CT.Color.inkPrimary)
                    Text(subtitle)
                        .font(CT.Font.subhead)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: CT.Space.s2)
                Image(systemName: "chevron.right")
                    .foregroundStyle(CT.Color.inkTertiary)
            }
            .frame(minHeight: CT.Size.listRowHeight)
        }
    }
}

private struct CaptureProcessingView: View {
    let processedPageCount: Int
    let totalPageCount: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: CT.Space.s5) {
            ProgressView(
                value: Double(processedPageCount),
                total: Double(max(totalPageCount, 1))
            )
                .controlSize(.large)
                .tint(CT.Color.primary)
            Text(Copy.Capture.processing)
                .font(CT.Font.title2)
                .foregroundStyle(CT.Color.inkPrimary)
            Text(Copy.Capture.processingDetail)
                .font(CT.Font.body)
                .foregroundStyle(CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
            Text(Copy.Capture.progress(processedPageCount, totalPageCount))
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
            Button(Copy.Capture.cancelProcessing, action: onCancel)
                .buttonStyle(CTSecondaryButtonStyle())
        }
        .padding(CT.Space.s6)
        .navigationBarBackButtonHidden()
        .accessibilityIdentifier("m3.processing")
    }
}

private struct CaptureCompletedView: View {
    let count: Int
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: CT.Space.s5) {
            Color.clear
                .frame(width: CT.Space.s1, height: CT.Space.s1)
                .accessibilityElement()
                .accessibilityIdentifier("m3.capture.completed")
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: CT.Size.elderEmptySymbol))
                .foregroundStyle(CT.Color.success)
            Text(Copy.Capture.saved)
                .font(CT.Font.title2)
            Text(Copy.Capture.savedCount(count))
                .font(CT.Font.body)
                .foregroundStyle(CT.Color.inkSecondary)
            Button(Copy.Common.done, action: onDone)
                .buttonStyle(CTPrimaryButtonStyle())
                .accessibilityIdentifier("m3.capture.done")
        }
        .padding(CT.Space.s6)
    }
}

enum CaptureBulkImportError: Error {
    case tooManyPages
    case imageEncodingFailed
}

struct DocumentCameraStagingConfiguration: Sendable {
    let batchID: UUID
    let vaultRootURL: URL
    let pageDisplayNames: [String]
}

struct DocumentCameraPicker: UIViewControllerRepresentable {
    let configuration: DocumentCameraStagingConfiguration
    let onComplete: (Result<[StagedCaptureAsset], Error>) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            configuration: configuration,
            onComplete: onComplete,
            onCancel: onCancel
        )
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        /// VisionKit does not declare `VNDocumentCameraScan` Sendable. The
        /// delegate hands us an immutable, completed scan; the staging worker
        /// then reads it serially (never concurrently) and the box is not
        /// retained after the task completes. This narrow wrapper avoids
        /// keeping decoded pages on MainActor while documenting the invariant
        /// behind the unchecked conformance.
        private final class ScanBox: @unchecked Sendable {
            let scan: VNDocumentCameraScan

            init(_ scan: VNDocumentCameraScan) {
                self.scan = scan
            }
        }

        let configuration: DocumentCameraStagingConfiguration
        let onComplete: (Result<[StagedCaptureAsset], Error>) -> Void
        let onCancel: () -> Void

        init(
            configuration: DocumentCameraStagingConfiguration,
            onComplete: @escaping (Result<[StagedCaptureAsset], Error>) -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.configuration = configuration
            self.onComplete = onComplete
            self.onCancel = onCancel
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            guard scan.pageCount <= configuration.pageDisplayNames.count else {
                controller.dismiss(animated: true) {
                    self.onComplete(.failure(CaptureBulkImportError.tooManyPages))
                }
                return
            }
            let scanBox = ScanBox(scan)
            let configuration = configuration
            controller.dismiss(animated: true)
            Task {
                let result: Result<[StagedCaptureAsset], Error>
                do {
                    let staged = try await CaptureAssetStagingWorker.stagePages(
                        count: scanBox.scan.pageCount,
                        vaultRootURL: configuration.vaultRootURL,
                        batchID: configuration.batchID,
                        preferredExtension: "jpg",
                        uniformTypeIdentifier: UTType.jpeg.identifier,
                        displayName: {
                            configuration.pageDisplayNames[$0]
                        },
                        dataForPage: { index in
                            guard let data = scanBox.scan
                                .imageOfPage(at: index)
                                .jpegData(compressionQuality: 0.94) else {
                                throw CaptureBulkImportError.imageEncodingFailed
                            }
                            return data
                        }
                    )
                    result = .success(staged)
                } catch {
                    result = .failure(error)
                }
                await MainActor.run {
                    self.onComplete(result)
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) {
                self.onCancel()
            }
        }
    }
}

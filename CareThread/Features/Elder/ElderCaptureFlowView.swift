import PhotosUI
import SwiftData
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ElderCaptureFlowView: View {
    private struct CameraImportSession: Identifiable {
        let id = UUID()
        let batchID: UUID
        let vaultRootURL: URL
    }

    private enum Step {
        case source
        case type
        case date
        case saving
        case completed
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let patient: Patient
    let onSaved: () -> Void
    let onBackToday: () -> Void

    @State private var step: Step = .source
    @State private var stagedAssets: [StagedCaptureAsset] = []
    @State private var captureBatchID: UUID?
    @State private var captureSource: M3CaptureSource = .fixture
    @State private var selectedType: ElderCaptureTypeChoice = .other
    @State private var eventDate = Date()
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var cameraImportSession: CameraImportSession?
    @State private var importTask: Task<Void, Never>?
    @State private var showDatePicker = false
    @State private var ocrWasEmpty = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .source:
                    sourceStep
                case .type:
                    typeStep
                case .date:
                    dateStep
                case .saving:
                    savingStep
                case .completed:
                    completedStep
                }
            }
            .padding(CT.Space.elderScreen)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CT.Color.bgBase)
            .navigationTitle(Copy.Elder.capture)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .saving {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Copy.Common.close) {
                            Task {
                                await discardPendingCapture()
                                dismiss()
                            }
                        }
                        .font(CT.Font.elderSubhead)
                        .frame(minHeight: CT.Size.elderTouchTarget)
                    }
                }
            }
        }
        .fullScreenCover(item: $cameraImportSession) { session in
            DocumentCameraPicker(
                configuration: DocumentCameraStagingConfiguration(
                    batchID: session.batchID,
                    vaultRootURL: session.vaultRootURL,
                    pageDisplayNames: (0..<50).map {
                        "老人版报告第\($0 + 1)页.jpg"
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
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else { return }
            importTask?.cancel()
            importTask = Task { await importPhotos(items) }
        }
        .alert(
            Copy.Common.operationFailed,
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button(Copy.Common.acknowledge) {}
        } message: {
            Text(errorMessage ?? Copy.Elder.saveFailed)
        }
        .dynamicTypeSize(...ElderDynamicTypePolicy.maximum)
        .accessibilityIdentifier("elder.capture")
        .onAppear {
            #if DEBUG
            if step == .source,
               ProcessInfo.processInfo.arguments.contains(
                   "-ScreenshotElderCaptureQuestion"
               ) {
                importTask = Task { await importScreenshotFixture() }
            }
            #endif
        }
    }

    private var sourceStep: some View {
        VStack(spacing: CT.Space.s5) {
            Spacer()
            Image(systemName: "doc.viewfinder")
                .font(.system(size: CT.Size.elderEmptySymbol))
                .foregroundStyle(CT.Color.primary)
            Text(Copy.Elder.captureDescription)
                .font(CT.Font.elderBody)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
                .lineSpacing(8)
            VStack(spacing: CT.Space.s3) {
                Button {
                    prepareCameraImport()
                } label: {
                    Label(Copy.Elder.captureCamera, systemImage: "doc.viewfinder")
                }
                .buttonStyle(ElderPrimaryButtonStyle())
                .accessibilityIdentifier("elder.capture.camera")

                PhotosPicker(
                    selection: $selectedPhotos,
                    maxSelectionCount: 50,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label(Copy.Elder.capturePhotos, systemImage: "photo.on.rectangle")
                        .font(CT.Font.elderHeadline)
                        .foregroundStyle(CT.Color.primary)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: CT.Size.elderPrimaryButtonHeight
                        )
                        .background(CT.Color.bgElevated)
                        .clipShape(
                            RoundedRectangle(
                                cornerRadius: CT.Radius.elderButton,
                                style: .continuous
                            )
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: CT.Radius.elderButton,
                                style: .continuous
                            )
                            .stroke(
                                CT.Color.outline,
                                lineWidth: CT.Stroke.hairline
                            )
                        }
                }
                .accessibilityIdentifier("elder.capture.photos")

                #if DEBUG
                Button {
                    importTask?.cancel()
                    importTask = Task { await importScreenshotFixture() }
                } label: {
                    Label(Copy.Elder.captureFixture, systemImage: "doc.badge.gearshape")
                }
                .buttonStyle(ElderSecondaryButtonStyle())
                .accessibilityIdentifier("elder.capture.fixture")
                #endif
            }
            Text(Copy.Elder.multiPageHint)
                .font(CT.Font.elderFootnote)
                .foregroundStyle(CT.Color.inkSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var typeStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CT.Space.s5) {
                Color.clear
                    .frame(width: 1, height: 1)
                    .accessibilityElement()
                    .accessibilityIdentifier(
                        "elder.capture.typeQuestion"
                    )
                Text(Copy.Elder.typeQuestion)
                    .font(CT.Font.elderTitle2)
                    .foregroundStyle(CT.Color.inkPrimary)
                    .accessibilityAddTraits(.isHeader)
                if stagedAssets.count > 1 {
                    Text("\(stagedAssets.count) 页会存成一份报告")
                        .font(CT.Font.elderSubhead)
                        .foregroundStyle(CT.Color.inkSecondary)
                }
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: CT.Space.s3),
                        GridItem(.flexible(), spacing: CT.Space.s3)
                    ],
                    spacing: CT.Space.s3
                ) {
                    ForEach(ElderCaptureTypeChoice.allCases) { choice in
                        ElderBigChoiceButton(
                            title: choice.title,
                            systemImage: choice.systemImage
                        ) {
                            selectedType = choice
                            step = .date
                            AppLog.userAction.info(
                                "Elder capture type choice selected"
                            )
                        }
                        .accessibilityIdentifier(
                            "elder.capture.type.\(choice.rawValue)"
                        )
                    }
                }
            }
        }
    }

    private var dateStep: some View {
        VStack(alignment: .leading, spacing: CT.Space.s5) {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("elder.capture.dateQuestion")
            Text(Copy.Elder.dateQuestion)
                .font(CT.Font.elderTitle2)
                .foregroundStyle(CT.Color.inkPrimary)
                .accessibilityAddTraits(.isHeader)
            Button(Copy.Elder.todayChoice) {
                eventDate = Date()
                save()
            }
            .buttonStyle(ElderPrimaryButtonStyle())
            .accessibilityIdentifier("elder.capture.today")
            Button(Copy.Elder.chooseDate) {
                showDatePicker = true
            }
            .buttonStyle(ElderSecondaryButtonStyle())
            .accessibilityIdentifier("elder.capture.chooseDate")
            if showDatePicker {
                DatePicker(
                    Copy.Elder.dateQuestion,
                    selection: $eventDate,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(CT.Color.primary)
                Button(Copy.Common.done) {
                    save()
                }
                .buttonStyle(ElderPrimaryButtonStyle())
                .accessibilityIdentifier("elder.capture.dateDone")
            }
            Spacer()
        }
    }

    private var savingStep: some View {
        VStack(spacing: CT.Space.s5) {
            Spacer()
            ProgressView()
                .controlSize(.large)
                .tint(CT.Color.primary)
            Text(Copy.Elder.saving)
                .font(CT.Font.elderTitle2)
                .foregroundStyle(CT.Color.inkPrimary)
            Text(Copy.Capture.processingDetail)
                .font(CT.Font.elderBody)
                .foregroundStyle(CT.Color.inkPrimary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .accessibilityIdentifier("elder.capture.saving")
    }

    private var completedStep: some View {
        VStack(spacing: CT.Space.s5) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: CT.Size.elderEmptySymbol))
                .foregroundStyle(CT.Color.success)
            Text(Copy.Elder.saved)
                .font(CT.Font.elderTitle2)
                .foregroundStyle(CT.Color.success)
                .accessibilityIdentifier("elder.capture.saved")
            Text(
                ocrWasEmpty
                    ? Copy.Elder.ocrEmpty
                    : "已存好，等家人帮忙核对。"
            )
            .font(CT.Font.elderBody)
            .foregroundStyle(CT.Color.inkPrimary)
            .multilineTextAlignment(.center)
            .lineSpacing(8)
            Spacer()
            Button(Copy.Elder.captureAgain) {
                stagedAssets = []
                captureBatchID = nil
                step = .source
            }
            .buttonStyle(ElderPrimaryButtonStyle())
            .accessibilityIdentifier("elder.capture.again")
            Button(Copy.Elder.backToday) {
                onBackToday()
                dismiss()
            }
            .buttonStyle(ElderSecondaryButtonStyle())
            .accessibilityIdentifier("elder.capture.backToday")
        }
    }

    private func beginQuestions(
        with newAssets: [StagedCaptureAsset],
        batchID: UUID,
        source: M3CaptureSource
    ) {
        guard !newAssets.isEmpty, newAssets.count <= 50 else {
            errorMessage = Copy.Elder.saveFailed
            return
        }
        captureSource = source
        captureBatchID = batchID
        stagedAssets = newAssets
        step = .type
    }

    @MainActor
    private func prepareCameraImport() {
        do {
            let vault = try CaptureVaultService()
            cameraImportSession = CameraImportSession(
                batchID: UUID(),
                vaultRootURL: vault.rootURL
            )
        } catch {
            errorMessage = Copy.Elder.saveFailed
        }
    }

    @MainActor
    private func finishCameraImport(
        _ result: Result<[StagedCaptureAsset], Error>,
        session: CameraImportSession
    ) {
        cameraImportSession = nil
        switch result {
        case let .success(assets):
            beginQuestions(
                with: assets,
                batchID: session.batchID,
                source: .camera
            )
        case .failure:
            Task { await discardBatch(session) }
            errorMessage = Copy.Elder.saveFailed
        }
    }

    @MainActor
    private func cancelCameraImport(_ session: CameraImportSession) {
        cameraImportSession = nil
        Task { await discardBatch(session) }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        let batchID = UUID()
        let vaultRootURL: URL
        do {
            vaultRootURL = try CaptureVaultService().rootURL
        } catch {
            errorMessage = Copy.Elder.saveFailed
            selectedPhotos = []
            return
        }
        var assets: [StagedCaptureAsset] = []
        do {
            for (index, item) in items.prefix(50).enumerated() {
                try Task.checkCancellation()
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw CaptureVaultError.invalidImage
                }
                let type = item.supportedContentTypes.first {
                    $0.conforms(to: .image)
                } ?? .jpeg
                let asset = try await CaptureAssetStagingWorker.stagePhotoData(
                    data,
                    vaultRootURL: vaultRootURL,
                    batchID: batchID,
                    displayName: "老人版报告第\(index + 1)页."
                        + (type.preferredFilenameExtension ?? "jpg"),
                    preferredExtension: type.preferredFilenameExtension ?? "jpg",
                    uniformTypeIdentifier: type.identifier
                )
                assets.append(asset)
            }
            beginQuestions(
                with: assets,
                batchID: batchID,
                source: .photos
            )
        } catch {
            await discardBatch(
                CameraImportSession(
                    batchID: batchID,
                    vaultRootURL: vaultRootURL
                )
            )
            if !(error is CancellationError) {
                errorMessage = Copy.Elder.saveFailed
            }
        }
        selectedPhotos = []
        importTask = nil
    }

    #if DEBUG
    private func importScreenshotFixture() async {
        let batchID = UUID()
        do {
            let vaultRootURL = try CaptureVaultService().rootURL
            let assets = try await CaptureAssetStagingWorker.stagePages(
                count: 1,
                vaultRootURL: vaultRootURL,
                batchID: batchID,
                preferredExtension: "jpg",
                uniformTypeIdentifier: UTType.jpeg.identifier,
                displayName: { _ in "虚构老人版报告.jpg" },
                dataForPage: { _ in
                    let image = TextFixtureRenderer.image(
                        text: """
                        虚构市中心医院 检验报告
                        检验日期 2026-07-31
                        TSH 0.08 mIU/L 参考范围 0.27-4.20 ↓
                        """
                    )
                    guard let data = image.jpegData(compressionQuality: 0.94) else {
                        throw CaptureBulkImportError.imageEncodingFailed
                    }
                    return data
                }
            )
            beginQuestions(
                with: assets,
                batchID: batchID,
                source: .fixture
            )
        } catch {
            errorMessage = Copy.Elder.saveFailed
        }
        importTask = nil
    }
    #endif

    private func discardBatch(_ session: CameraImportSession) async {
        await Task.detached(priority: .utility) {
            try? CaptureVaultService(rootURL: session.vaultRootURL)
                .discardBatch(session.batchID)
        }.value
    }

    private func discardPendingCapture() async {
        importTask?.cancel()
        guard let batchID = captureBatchID else { return }
        let rootURL = try? CaptureVaultService().rootURL
        stagedAssets = []
        captureBatchID = nil
        guard let rootURL else { return }
        await discardBatch(
            CameraImportSession(
                batchID: batchID,
                vaultRootURL: rootURL
            )
        )
    }

    private func save() {
        guard !stagedAssets.isEmpty, let captureBatchID else { return }
        step = .saving
        let request = ElderCaptureRequest(
            patientID: patient.id,
            batchID: captureBatchID,
            stagedAssets: stagedAssets,
            source: captureSource,
            typeChoice: selectedType,
            eventDate: eventDate
        )
        Task {
            do {
                let vault = try CaptureVaultService()
                let result = try await ElderCaptureService(
                    context: modelContext,
                    vault: vault
                ).save(request)
                ocrWasEmpty = result.ocrWasEmpty
                stagedAssets = []
                self.captureBatchID = nil
                onSaved()
                step = .completed
            } catch ElderCaptureError.identityRequiresStandardReview {
                stagedAssets = []
                self.captureBatchID = nil
                errorMessage = Copy.Elder.identityReviewNeeded
                step = .source
            } catch {
                stagedAssets = []
                self.captureBatchID = nil
                errorMessage = Copy.Elder.saveFailed
                step = .source
            }
        }
    }
}

import SwiftData
import SwiftUI

enum NearbySyncUIDirection: String, CaseIterable, Identifiable {
    case send
    case receive

    var id: String { rawValue }
}

enum NearbySyncUIPhase: Equatable {
    case setup
    case discovering
    case pairing(alias: String, code: String)
    case manifest(alias: String, preview: TransferPreviewCounts, bytes: Int64)
    case transferring(TransferProgress)
    case completed(String)
    case failed(String, canResume: Bool)
}

struct NearbySyncMemberOption: Identifiable, Equatable {
    let id: UUID
    let displayName: String
}

@MainActor
final class NearbySyncViewModel: ObservableObject {
    @Published var direction: NearbySyncUIDirection = .send
    @Published var sendAllMembers = false
    @Published var selectedMemberID: UUID?
    @Published private(set) var phase: NearbySyncUIPhase = .setup
    @Published private(set) var isBusy = false
    @Published private(set) var discoveredPeers: [NearbySyncFlowPeer] = []
    @Published private(set) var waitingAlias: String?

    let members: [NearbySyncMemberOption]
    private let startSend: @MainActor (TransferScope) async throws -> Void
    private let startReceive: @MainActor () async throws -> Void
    private let pairingDecision: @MainActor (Bool) -> Void
    private let manifestDecision: @MainActor (Bool) -> Void
    private let cancelAction: @MainActor () async -> Void
    private let resumeAction: @MainActor () async throws -> Void
    private let selectPeerAction: @MainActor (UUID) async throws -> Void
    private let recordCompletion: @MainActor () -> Void
    private var eventTask: Task<Void, Never>?
    private var flowController: NearbySyncFlowController?

    init(
        members: [NearbySyncMemberOption],
        startSend: @escaping @MainActor (TransferScope) async throws -> Void,
        startReceive: @escaping @MainActor () async throws -> Void,
        pairingDecision: @escaping @MainActor (Bool) -> Void,
        manifestDecision: @escaping @MainActor (Bool) -> Void,
        cancel: @escaping @MainActor () async -> Void,
        resume: @escaping @MainActor () async throws -> Void,
        selectPeer: @escaping @MainActor (UUID) async throws -> Void = { _ in },
        recordCompletion: @escaping @MainActor () -> Void = {}
    ) {
        self.members = members
        selectedMemberID = members.first?.id
        self.startSend = startSend
        self.startReceive = startReceive
        self.pairingDecision = pairingDecision
        self.manifestDecision = manifestDecision
        cancelAction = cancel
        resumeAction = resume
        selectPeerAction = selectPeer
        self.recordCompletion = recordCompletion
    }

    convenience init(
        members: [NearbySyncMemberOption],
        selectedMemberID: UUID?,
        controller: NearbySyncFlowController
    ) {
        self.init(
            members: members,
            startSend: { scope in
                try await controller.startSending(scope: scope)
            },
            startReceive: {
                try await controller.startReceiving()
            },
            pairingDecision: { accepted in
                controller.confirmPairing(accepted)
            },
            manifestDecision: { accepted in
                controller.confirmManifest(accepted)
            },
            cancel: {
                await controller.cancel()
            },
            resume: {
                try await controller.retry()
            },
            selectPeer: { id in
                try await controller.selectPeer(id)
            },
            recordCompletion: {
                CareActivityHistoryStore().recordNearbyMigration()
            }
        )
        if let selectedMemberID,
           members.contains(where: { $0.id == selectedMemberID }) {
            self.selectedMemberID = selectedMemberID
        }
        flowController = controller
        eventTask = Task { [weak self, controller] in
            for await event in controller.events {
                guard let self else { return }
                self.consume(event)
            }
        }
    }

    func begin() {
        guard !isBusy else { return }
        isBusy = true
        phase = .discovering
        Task {
            do {
                if direction == .send {
                    let scope: TransferScope
                    if sendAllMembers {
                        scope = .allPatients
                    } else if let selectedMemberID {
                        scope = .singlePatient(selectedMemberID)
                    } else {
                        throw NearbySyncError.unsupportedEntity(NearbySyncCopy.noMember)
                    }
                    try await startSend(scope)
                } else {
                    try await startReceive()
                }
            } catch {
                fail(error, canResume: true)
            }
        }
    }

    func consume(_ event: NearbySyncCoordinatorEvent) {
        switch event {
        case .state:
            break
        case let .pairingCode(alias, code):
            phase = .pairing(alias: alias, code: code)
        case let .manifestPreview(alias, preview, totalByteCount):
            phase = .manifest(alias: alias, preview: preview, bytes: totalByteCount)
        case let .progress(progress):
            phase = .transferring(progress)
        case let .result(result):
            complete(result.resultSHA256)
        }
    }

    func consume(_ event: NearbySyncFlowEvent) {
        switch event {
        case let .discovering(peers):
            discoveredPeers = peers
            waitingAlias = nil
            phase = .discovering
        case let .waiting(alias):
            waitingAlias = alias
            discoveredPeers = []
            phase = .discovering
        case let .coordinator(event):
            consume(event)
        case let .completed(resultSHA256):
            complete(resultSHA256)
        case let .failed(message, canResume):
            phase = .failed(message, canResume: canResume)
            isBusy = false
        case .cancelled:
            discoveredPeers = []
            waitingAlias = nil
            phase = .setup
            isBusy = false
        }
    }

    func confirmPairing(_ matches: Bool) {
        pairingDecision(matches)
        if !matches {
            phase = .failed("安全码不同，连接已停止。", canResume: false)
            isBusy = false
        }
    }

    func confirmManifest(_ accepted: Bool) {
        manifestDecision(accepted)
        if !accepted {
            phase = .setup
            isBusy = false
        }
    }

    func cancel() {
        Task {
            await cancelAction()
            phase = .setup
            isBusy = false
        }
    }

    func selectPeer(_ id: UUID) {
        guard isBusy else { return }
        Task {
            do {
                try await selectPeerAction(id)
            } catch {
                fail(error, canResume: true)
            }
        }
    }

    func resume() {
        guard !isBusy else { return }
        isBusy = true
        phase = .discovering
        Task {
            do {
                try await resumeAction()
            } catch {
                fail(error, canResume: true)
            }
        }
    }

    func complete(_ resultSHA256: String) {
        if case .completed = phase {
            return
        }
        phase = .completed(resultSHA256)
        isBusy = false
        recordCompletion()
    }

    func fail(_ error: Error, canResume: Bool) {
        phase = .failed(
            (error as? LocalizedError)?.errorDescription
                ?? "迁移未完成，请稍后重试。",
            canResume: canResume
        )
        isBusy = false
    }

    func cleanup() {
        eventTask?.cancel()
        eventTask = nil
        let controller = flowController
        Task {
            await controller?.cancel()
        }
    }

    func background() {
        let controller = flowController
        Task {
            await controller?.handleBackgrounding()
        }
    }

    deinit {
        eventTask?.cancel()
    }
}

struct NearbySyncView: View {
    @StateObject private var model: NearbySyncViewModel
    @EnvironmentObject private var appLockController: AppLockController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAppLockOffer = false
    private let appLockOfferStore: any AppLockTransferOfferStoring

    init(
        model: @autoclosure @escaping () -> NearbySyncViewModel,
        appLockOfferStore: any AppLockTransferOfferStoring =
            AppLockTransferOfferStore()
    ) {
        _model = StateObject(wrappedValue: model())
        self.appLockOfferStore = appLockOfferStore
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CT.Space.s5) {
                    privacyHeader
                    phaseContent
                }
                .padding(CT.Space.s4)
            }
            .background(CT.Color.bgBase)
            .navigationTitle(NearbySyncCopy.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        model.cleanup()
                        dismiss()
                    }
                    .frame(minHeight: CT.Size.secondaryButtonHeight)
                    .accessibilityIdentifier("nearbySync.close")
                }
            }
        }
        .accessibilityIdentifier("nearbySync.root")
        .onDisappear {
            model.cleanup()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                model.background()
            }
        }
        .onChange(of: model.phase) { _, phase in
            considerAppLockOffer(for: phase)
        }
        .task {
            considerAppLockOffer(for: model.phase)
        }
        .alert(
            NearbySyncCopy.appLockOfferTitle,
            isPresented: $showAppLockOffer
        ) {
            Button(NearbySyncCopy.enableAppLock) {
                Task {
                    _ = await appLockController.setEnabled(true)
                }
            }
            Button(NearbySyncCopy.declineAppLock, role: .cancel) {}
        } message: {
            Text(NearbySyncCopy.appLockOfferMessage)
        }
    }

    @MainActor
    private func considerAppLockOffer(for phase: NearbySyncUIPhase) {
        guard case .completed = phase else { return }
        showAppLockOffer = AppLockTransferOfferPolicy.claimIfNeeded(
            isReceiving: model.direction == .receive,
            isAppLockEnabled: appLockController.isEnabled,
            isBiometricAuthenticationAvailable:
                appLockController.canOfferAfterTransfer,
            store: appLockOfferStore
        )
    }

    private var privacyHeader: some View {
        VStack(alignment: .leading, spacing: CT.Space.s2) {
            Label(
                NearbySyncCopy.intro,
                systemImage: "lock.shield.fill"
            )
            .font(CT.Font.callout)
            Text(NearbySyncCopy.safetyReminder)
                .font(CT.Font.footnote)
        }
            .foregroundStyle(CT.Color.primaryOnContainer)
            .padding(CT.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CT.Color.primaryContainer)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card))
            .accessibilityIdentifier("nearbySync.privacy")
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch model.phase {
        case .setup:
            setupContent
        case .discovering:
            discoveryContent
        case let .pairing(alias, code):
            pairingContent(alias: alias, code: code)
        case let .manifest(alias, preview, bytes):
            manifestContent(alias: alias, preview: preview, bytes: bytes)
        case let .transferring(progress):
            transferContent(progress)
        case let .completed(result):
            resultContent(result)
        case let .failed(message, canResume):
            failureContent(message: message, canResume: canResume)
        }
    }

    private var discoveryContent: some View {
        VStack(alignment: .leading, spacing: CT.Space.s4) {
            statusCard(
                title: model.direction == .send
                    ? NearbySyncCopy.findDevice
                    : NearbySyncCopy.waiting,
                symbol: "iphone.radiowaves.left.and.right"
            )
            if model.direction == .send, !model.discoveredPeers.isEmpty {
                Text(NearbySyncCopy.chooseDevice)
                    .font(CT.Font.title2)
                Text(
                    "\(model.discoveredPeers.count) \(NearbySyncCopy.deviceCount)"
                )
                .font(CT.Font.callout)
                .foregroundStyle(CT.Color.inkSecondary)
                .accessibilityIdentifier("nearbySync.deviceCount")
                ForEach(model.discoveredPeers) { peer in
                    Button {
                        model.selectPeer(peer.id)
                    } label: {
                        Label(peer.alias, systemImage: "iphone")
                            .font(CT.Font.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .frame(minHeight: CT.Size.primaryButtonHeight)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CT.Color.primary)
                    .accessibilityLabel("连接附近设备 \(peer.alias)")
                    .accessibilityIdentifier(
                        "nearbySync.peer.\(peer.id.uuidString.lowercased())"
                    )
                }
            } else {
                Text(NearbySyncCopy.waitingHelp)
                    .font(CT.Font.body)
                    .foregroundStyle(CT.Color.inkSecondary)
                if let alias = model.waitingAlias {
                    Text("本机识别码 \(alias)")
                        .font(CT.Font.valueMono)
                        .foregroundStyle(CT.Color.inkTertiary)
                        .accessibilityIdentifier("nearbySync.listenerAlias")
                }
                Text(NearbySyncCopy.localNetworkHelp)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkTertiary)
            }
            cancelButton
                .frame(minHeight: CT.Size.secondaryButtonHeight)
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .accessibilityIdentifier("nearbySync.discovery")
    }

    private var setupContent: some View {
        VStack(alignment: .leading, spacing: CT.Space.s4) {
            Picker("迁移方向", selection: $model.direction) {
                Text("发送").tag(NearbySyncUIDirection.send)
                Text("接收").tag(NearbySyncUIDirection.receive)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("nearbySync.direction")

            if model.direction == .send {
                Toggle(NearbySyncCopy.allMembers, isOn: $model.sendAllMembers)
                    .font(CT.Font.body)
                    .accessibilityIdentifier("nearbySync.allMembers")
                if !model.sendAllMembers {
                    Picker("选择成员", selection: $model.selectedMemberID) {
                        ForEach(model.members) { member in
                            Text(member.displayName).tag(Optional(member.id))
                        }
                    }
                    .accessibilityIdentifier("nearbySync.member")
                }
            }
            Button(action: model.begin) {
                Label(
                    model.direction == .send
                        ? NearbySyncCopy.send
                        : NearbySyncCopy.receive,
                    systemImage: model.direction == .send
                        ? "arrow.up.circle.fill"
                        : "arrow.down.circle.fill"
                )
                .font(CT.Font.headline)
                .frame(maxWidth: .infinity)
                .frame(height: CT.Size.primaryButtonHeight)
            }
            .buttonStyle(.borderedProminent)
            .tint(CT.Color.primary)
            .accessibilityIdentifier("nearbySync.begin")
        }
    }

    private func pairingContent(alias: String, code: String) -> some View {
        VStack(spacing: CT.Space.s5) {
            statusCard(title: alias, symbol: "iphone")
            Text(NearbySyncCopy.pairingTitle)
                .font(CT.Font.title2)
            Text(code)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("安全码 \(code.map(String.init).joined(separator: " "))")
                .accessibilityIdentifier("nearbySync.sas")
            Text(NearbySyncCopy.pairingHelp)
                .font(CT.Font.body)
                .foregroundStyle(CT.Color.inkSecondary)
            Button(NearbySyncCopy.codeMatches) {
                model.confirmPairing(true)
            }
            .buttonStyle(.borderedProminent)
            .tint(CT.Color.primary)
            .frame(minHeight: CT.Size.primaryButtonHeight)
            .accessibilityIdentifier("nearbySync.sas.confirm")
            Button(NearbySyncCopy.codeDoesNotMatch, role: .destructive) {
                model.confirmPairing(false)
            }
            .frame(minHeight: CT.Size.secondaryButtonHeight)
            .accessibilityIdentifier("nearbySync.sas.reject")
        }
        .frame(maxWidth: .infinity)
    }

    private func manifestContent(
        alias: String,
        preview: TransferPreviewCounts,
        bytes: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s4) {
            Text(NearbySyncCopy.manifestTitle).font(CT.Font.title2)
            Text(alias).font(CT.Font.headline)
            metric("成员", "\(preview.memberCount)")
            metric("病历", "\(preview.recordCount)")
            metric("原件", "\(preview.attachmentCount)")
            metric("大小", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
            Text(NearbySyncCopy.manifestPrivacy)
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
            Button(NearbySyncCopy.confirmReceive) {
                model.confirmManifest(true)
            }
            .buttonStyle(.borderedProminent)
            .tint(CT.Color.primary)
            .frame(minHeight: CT.Size.primaryButtonHeight)
            .accessibilityIdentifier("nearbySync.manifest.confirm")
            Button(NearbySyncCopy.cancel, role: .cancel) {
                model.confirmManifest(false)
            }
            .frame(minHeight: CT.Size.secondaryButtonHeight)
            .accessibilityIdentifier("nearbySync.manifest.reject")
        }
        .padding(CT.Space.s4)
        .background(CT.Color.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card))
        .accessibilityIdentifier("nearbySync.manifest")
    }

    private func transferContent(_ progress: TransferProgress) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s4) {
            Text("正在迁移").font(CT.Font.title2)
            ProgressView(
                value: Double(progress.completedBytes),
                total: max(1, Double(progress.totalBytes))
            )
            Text(
                "\(ByteCountFormatter.string(fromByteCount: progress.completedBytes, countStyle: .file))"
                    + " / "
                    + ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
            )
            .font(CT.Font.valueMono)
            cancelButton
        }
        .accessibilityIdentifier("nearbySync.progress")
    }

    private func resultContent(_ result: String) -> some View {
        VStack(spacing: CT.Space.s4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: CT.Size.emptySymbol))
                .foregroundStyle(CT.Color.success)
            Text(NearbySyncCopy.done).font(CT.Font.title2)
            Text(NearbySyncCopy.resultHelp)
                .font(CT.Font.body)
                .foregroundStyle(CT.Color.inkSecondary)
            Text("校验号 \(result.prefix(12))")
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("nearbySync.completed")
    }

    private func failureContent(message: String, canResume: Bool) -> some View {
        VStack(spacing: CT.Space.s4) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: CT.Size.emptySymbol))
                .foregroundStyle(CT.Color.warning)
            Text(message).font(CT.Font.body)
            if canResume {
                Button(NearbySyncCopy.resume, action: model.resume)
                    .buttonStyle(.borderedProminent)
                    .tint(CT.Color.primary)
                    .frame(minHeight: CT.Size.primaryButtonHeight)
                    .accessibilityIdentifier("nearbySync.resume")
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("nearbySync.failed")
    }

    private var cancelButton: some View {
        Button(NearbySyncCopy.cancel, role: .destructive, action: model.cancel)
            .accessibilityIdentifier("nearbySync.cancel")
    }

    private func statusCard(title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(CT.Font.headline)
            .padding(CT.Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CT.Color.bgElevated)
            .clipShape(RoundedRectangle(cornerRadius: CT.Radius.card))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(CT.Color.inkSecondary)
            Spacer()
            Text(value).font(CT.Font.valueMono)
        }
    }
}

struct NearbySyncFlowHost: View {
    @Environment(\.modelContext) private var modelContext

    let patients: [Patient]
    let selectedPatientID: UUID?
    let onImportCompleted: @MainActor () -> Void

    init(
        patients: [Patient],
        selectedPatientID: UUID?,
        onImportCompleted: @escaping @MainActor () -> Void = {}
    ) {
        self.patients = patients
        self.selectedPatientID = selectedPatientID
        self.onImportCompleted = onImportCompleted
    }

    var body: some View {
        NearbySyncFlowHostContent(
            context: modelContext,
            members: patients.map {
                NearbySyncMemberOption(id: $0.id, displayName: $0.displayName)
            },
            selectedPatientID: selectedPatientID,
            onImportCompleted: onImportCompleted
        )
    }
}

private struct NearbySyncFlowHostContent: View {
    @StateObject private var model: NearbySyncViewModel

    @MainActor
    init(
        context: ModelContext,
        members: [NearbySyncMemberOption],
        selectedPatientID: UUID?,
        onImportCompleted: @escaping @MainActor () -> Void
    ) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains(
            "-M8NearbyReceiveComplete"
        ) {
            let debugModel = NearbySyncViewModel(
                members: members,
                startSend: { _ in },
                startReceive: {},
                pairingDecision: { _ in },
                manifestDecision: { _ in },
                cancel: {},
                resume: {}
            )
            debugModel.direction = .receive
            debugModel.complete("debug-receive-complete")
            _model = StateObject(wrappedValue: debugModel)
            return
        }
        #endif
        do {
            let controller = try NearbySyncFlowController.production(
                context: context,
                onImportCompleted: onImportCompleted
            )
            _model = StateObject(
                wrappedValue: NearbySyncViewModel(
                    members: members,
                    selectedMemberID: selectedPatientID,
                    controller: controller
                )
            )
        } catch {
            let preparationError = error
            _model = StateObject(
                wrappedValue: NearbySyncViewModel(
                    members: members,
                    startSend: { _ in throw preparationError },
                    startReceive: { throw preparationError },
                    pairingDecision: { _ in },
                    manifestDecision: { _ in },
                    cancel: {},
                    resume: { throw preparationError }
                )
            )
        }
    }

    var body: some View {
        NearbySyncView(model: model)
    }
}

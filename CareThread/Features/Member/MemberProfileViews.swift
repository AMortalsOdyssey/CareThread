import SwiftData
import SwiftUI

struct MemberManagementView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Patient.createdAt) private var patients: [Patient]
    @Binding private var selectedPatientID: UUID?
    @State private var showCreate = false
    @State private var message: String?
    @State private var pendingDeletion: Patient?

    init(selectedPatientID: Binding<UUID?>) {
        _selectedPatientID = selectedPatientID
    }

    var body: some View {
        List {
            Section {
                Text(MemberProfileCopy.membersSubtitle)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
            Section {
                ForEach(
                    Array(patients.enumerated()),
                    id: \.element.id
                ) { index, patient in
                    NavigationLink {
                        MemberProfileView(patient: patient)
                    } label: {
                        memberRow(patient)
                    }
                    .accessibilityIdentifier(
                        "member.row.index.\(index)"
                    )
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if patient.id != selectedPatientID {
                            Button(MemberProfileCopy.switchMember) {
                                select(patient)
                            }
                            .tint(CT.Color.primary)
                        }
                    }
                    .swipeActions(
                        edge: .trailing,
                        allowsFullSwipe: false
                    ) {
                        Button(role: .destructive) {
                            pendingDeletion = patient
                        } label: {
                            Label(
                                MemberProfileCopy.deleteMember,
                                systemImage: "trash"
                            )
                        }
                    }
                }
            } header: {
                Text("\(patients.count) / \(MemberLimitPolicy.maximumMembers)")
            }
            if let message {
                Section {
                    Text(message)
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        .accessibilityIdentifier("member.feedback")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(MemberProfileCopy.membersTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard patients.count < MemberLimitPolicy.maximumMembers else {
                        message = MemberProfileCopy.limitReached
                        return
                    }
                    showCreate = true
                } label: {
                    Label(MemberProfileCopy.addMember, systemImage: "person.badge.plus")
                }
                .disabled(patients.count >= MemberLimitPolicy.maximumMembers)
                .accessibilityIdentifier("member.add")
            }
        }
        .sheet(isPresented: $showCreate) {
            MemberCreateView { draft in
                create(draft)
            }
        }
        .confirmationDialog(
            MemberProfileCopy.deleteMemberTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { patient in
            Button(
                "永久删除“\(patient.displayName)”",
                role: .destructive
            ) {
                delete(patient)
            }
            Button("取消", role: .cancel) {}
        } message: { patient in
            Text(
                patient.id == selectedPatientID
                    ? MemberProfileCopy.deleteSelectedMemberWarning
                    : MemberProfileCopy.deleteMemberWarning
            )
        }
        .accessibilityIdentifier("member.management")
    }

    private func memberRow(_ patient: Patient) -> some View {
        HStack(spacing: CT.Space.s3) {
            Image(systemName: "person.crop.circle")
                .font(CT.Font.title2)
                .foregroundStyle(CT.Color.primary)
                .frame(
                    width: CT.Size.leadingIcon,
                    height: CT.Size.leadingIcon
                )
            VStack(alignment: .leading, spacing: CT.Space.s1) {
                Text(patient.displayName)
                    .font(CT.Font.headline)
                    .foregroundStyle(CT.Color.inkPrimary)
                Text(patient.reportName ?? "未填写报告姓名")
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
            Spacer()
            if patient.id == selectedPatientID {
                Text(MemberProfileCopy.selected)
                    .font(CT.Font.caption)
                    .foregroundStyle(CT.Color.primaryOnContainer)
                    .padding(.horizontal, CT.Space.s2)
                    .padding(.vertical, CT.Space.s1)
                    .background(CT.Color.primaryContainer)
                    .clipShape(Capsule())
            } else {
                Button(MemberProfileCopy.switchMember) {
                    select(patient)
                }
                .font(CT.Font.footnote.weight(.semibold))
                .buttonStyle(.borderless)
                .accessibilityIdentifier(
                    "member.select.\(patient.id.uuidString)"
                )
            }
        }
        .frame(minHeight: CT.Size.listRowHeight)
    }

    @MainActor
    private func create(_ draft: MemberCreateDraft) -> Bool {
        do {
            let store = InMemorySelectedMemberStore()
            let patient = try MemberService(
                context: modelContext,
                vaultProvisioner: try CaptureVaultService(),
                selectionStore: store
            ).createMember(
                displayName: draft.displayName,
                reportName: draft.reportName,
                birthDate: draft.hasBirthDate ? draft.birthDate : nil,
                gender: draft.gender
            )
            selectedPatientID = patient.id
            message = "已添加并切换到 \(patient.displayName)"
            return true
        } catch let error as MemberServiceError {
            switch error {
            case .maximumReached:
                message = MemberProfileCopy.limitReached
            case let .invalidProfile(reason):
                message = reason.localizedDescription
            default:
                message = "添加失败，现有资料没有改变。"
            }
            AppLog.data.error("Member creation user action failed")
            return false
        } catch {
            message = "添加失败，现有资料没有改变。"
            AppLog.data.error("Member creation user action failed")
            return false
        }
    }

    @MainActor
    private func select(_ patient: Patient) {
        let store = InMemorySelectedMemberStore()
        do {
            try MemberService(
                context: modelContext,
                vaultProvisioner: NoopMemberVaultProvisioner(),
                selectionStore: store
            ).selectMember(id: patient.id)
            selectedPatientID = store.selectedPatientId
            message = "已切换到 \(patient.displayName)"
        } catch {
            message = "切换失败，请重试。"
        }
    }

    @MainActor
    private func delete(_ patient: Patient) {
        let deletedName = patient.displayName
        let store = InMemorySelectedMemberStore()
        store.selectedPatientId = selectedPatientID
        do {
            let nextID = try MemberService(
                context: modelContext,
                vaultProvisioner: try CaptureVaultService(),
                selectionStore: store
            ).deleteMember(id: patient.id)
            selectedPatientID = nextID
            message = nextID == nil
                ? "已删除 \(deletedName)。现在可以添加新成员。"
                : "已删除 \(deletedName)，其他成员资料未改变。"
        } catch {
            message = "删除失败，现有资料和原文件没有改变。"
            AppLog.data.error("Member deletion user action failed")
        }
        pendingDeletion = nil
    }
}

private struct MemberCreateDraft {
    var displayName: String
    var reportName: String?
    var hasBirthDate: Bool
    var birthDate: Date
    var gender: String?
}

private enum MemberCreateField: Hashable {
    case displayName
    case reportName
    case gender
}

private struct MemberCreateView: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (MemberCreateDraft) -> Bool
    @State private var displayName = ""
    @State private var reportName = ""
    @State private var hasBirthDate = false
    @State private var birthDate = Date()
    @State private var gender = ""
    @State private var errorMessage: String?
    @FocusState private var focusedField: MemberCreateField?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：妈妈", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .displayName)
                        .accessibilityIdentifier("member.create.displayName")
                    TextField("报告上的姓名（可稍后填写）", text: $reportName)
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .reportName)
                        .accessibilityIdentifier("member.create.reportName")
                    TextField("性别说明（可选）", text: $gender)
                        .focused($focusedField, equals: .gender)
                        .accessibilityIdentifier("member.create.gender")
                    Toggle(MemberProfileCopy.birthDate, isOn: $hasBirthDate)
                    if hasBirthDate {
                        DatePicker(
                            MemberProfileCopy.birthDate,
                            selection: $birthDate,
                            in: ...Date(),
                            displayedComponents: .date
                        )
                    }
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(CT.Color.danger)
                    }
                }
            }
            .navigationTitle(MemberProfileCopy.addMember)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(MemberProfileCopy.addMember) {
                        focusedField = nil
                        let draft = MemberCreateDraft(
                            displayName: displayName,
                            reportName: MemberIdentity.optionalTrimmed(reportName),
                            hasBirthDate: hasBirthDate,
                            birthDate: birthDate,
                            gender: MemberIdentity.optionalTrimmed(gender)
                        )
                        if onCreate(draft) {
                            dismiss()
                        } else {
                            errorMessage = "请检查填写内容后重试。"
                        }
                    }
                    .disabled(
                        displayName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                    .accessibilityIdentifier("member.create.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                    .accessibilityIdentifier("member.create.keyboard.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private enum MemberProfileField: Hashable {
    case displayName
    case reportName
    case aliases
    case gender
    case conditions
    case allergies
    case historyYear(UUID)
    case historyText(UUID)
}

struct MemberProfileView: View {
    @Environment(\.modelContext) private var modelContext
    let patient: Patient
    @State private var form: MemberProfileFormState?
    @State private var feedback: String?
    @State private var showHistory = false
    @FocusState private var focusedField: MemberProfileField?

    var body: some View {
        Group {
            if let form {
                profileForm(form)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(MemberProfileCopy.profileTitle)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showHistory = true
                } label: {
                    Label(MemberProfileCopy.revisions, systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("member.profile.history")
                Button(MemberProfileCopy.save) {
                    focusedField = nil
                    save()
                }
                .fontWeight(.semibold)
                .accessibilityIdentifier("member.profile.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") {
                    focusedField = nil
                }
                .accessibilityIdentifier("member.profile.keyboard.done")
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                MemberRevisionHistoryView(
                    patient: patient,
                    onUndo: {
                        reload()
                    }
                )
            }
        }
        .task(id: patient.id) {
            reload()
        }
        .accessibilityIdentifier("member.profile")
    }

    private func profileForm(_ form: MemberProfileFormState) -> some View {
        Form {
            Section(MemberProfileCopy.identity) {
                TextField(
                    MemberProfileCopy.displayName,
                    text: binding(\.displayName)
                )
                .focused($focusedField, equals: .displayName)
                .accessibilityIdentifier("member.profile.displayName")
                TextField(
                    MemberProfileCopy.reportName,
                    text: binding(\.reportName)
                )
                .focused($focusedField, equals: .reportName)
                .accessibilityIdentifier("member.profile.reportName")
                TextField(
                    MemberProfileCopy.aliases,
                    text: binding(\.aliasesText),
                    axis: .vertical
                )
                .focused($focusedField, equals: .aliases)
                .lineLimit(2...5)
                Text(MemberProfileCopy.onePerLine)
                    .font(CT.Font.label)
                    .foregroundStyle(CT.Color.inkTertiary)
                Toggle(
                    MemberProfileCopy.birthDate,
                    isOn: binding(\.hasBirthDate)
                )
                if form.hasBirthDate {
                    DatePicker(
                        MemberProfileCopy.birthDate,
                        selection: binding(\.birthDate),
                        in: ...Date(),
                        displayedComponents: .date
                    )
                }
                TextField(
                    MemberProfileCopy.gender,
                    text: binding(\.gender)
                )
                .focused($focusedField, equals: .gender)
            }
            Section(MemberProfileCopy.health) {
                multilineField(
                    MemberProfileCopy.conditions,
                    keyPath: \.conditionsText,
                    identifier: "member.profile.conditions",
                    field: .conditions
                )
                multilineField(
                    MemberProfileCopy.allergies,
                    keyPath: \.allergiesText,
                    identifier: "member.profile.allergies",
                    field: .allergies
                )
            }
            Section(MemberProfileCopy.histories) {
                ForEach(Array(form.histories.enumerated()), id: \.element.id) {
                    index, history in
                    HStack(alignment: .top, spacing: CT.Space.s2) {
                        TextField(
                            "年份",
                            value: historyBinding(index, \.year),
                            format: .number.grouping(.never)
                        )
                        .keyboardType(.numberPad)
                        .focused(
                            $focusedField,
                            equals: .historyYear(history.id)
                        )
                        .frame(width: 72)
                        TextField(
                            "病史内容",
                            text: historyBinding(index, \.text),
                            axis: .vertical
                        )
                        .focused(
                            $focusedField,
                            equals: .historyText(history.id)
                        )
                        Button(role: .destructive) {
                            self.form?.histories.remove(at: index)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    self.form?.histories.append(
                        MemberHistoryForm(
                            year: Calendar.current.component(
                                .year,
                                from: Date()
                            ),
                            text: ""
                        )
                    )
                } label: {
                    Label("添加病史", systemImage: "plus")
                }
            }
            Section {
                NavigationLink {
                    CareQuestionListView(patient: patient)
                } label: {
                    LabeledContent(MemberProfileCopy.questions) {
                        Text("\(patient.careQuestions.count)")
                    }
                }
                .accessibilityIdentifier("member.profile.questions")
            }
            if let feedback {
                Section {
                    Text(feedback)
                        .font(CT.Font.footnote)
                        .foregroundStyle(
                            feedback == MemberProfileCopy.saved
                                ? CT.Color.success
                                : CT.Color.danger
                        )
                        .accessibilityIdentifier("member.profile.feedback")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
    }

    private func multilineField(
        _ title: String,
        keyPath: WritableKeyPath<MemberProfileFormState, String>,
        identifier: String,
        field: MemberProfileField
    ) -> some View {
        VStack(alignment: .leading, spacing: CT.Space.s1) {
            Text(title)
                .font(CT.Font.footnote)
                .foregroundStyle(CT.Color.inkSecondary)
            TextField(
                MemberProfileCopy.onePerLine,
                text: binding(keyPath),
                axis: .vertical
            )
            .focused($focusedField, equals: field)
            .lineLimit(2...6)
            .accessibilityIdentifier(identifier)
        }
    }

    private func binding<Value>(
        _ keyPath: WritableKeyPath<MemberProfileFormState, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let form else {
                    preconditionFailure("Profile form accessed before load")
                }
                return form[keyPath: keyPath]
            },
            set: { form?[keyPath: keyPath] = $0 }
        )
    }

    private func historyBinding<Value>(
        _ index: Int,
        _ keyPath: WritableKeyPath<MemberHistoryForm, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let form, form.histories.indices.contains(index) else {
                    preconditionFailure("History row index became invalid")
                }
                return form.histories[index][keyPath: keyPath]
            },
            set: { value in
                guard self.form?.histories.indices.contains(index) == true else {
                    return
                }
                self.form?.histories[index][keyPath: keyPath] = value
            }
        )
    }

    @MainActor
    private func reload() {
        form = MemberProfileFormState(patient: patient)
    }

    @MainActor
    private func save() {
        guard let form else { return }
        do {
            _ = try PatientProfileService(context: modelContext).save(
                patient,
                content: form.content(from: patient),
                expectedRevision: patient.contentRevision
            )
            reload()
            feedback = MemberProfileCopy.saved
        } catch ContentRevisionServiceError.revisionConflict {
            reload()
            feedback = MemberProfileCopy.conflict
        } catch {
            feedback = error.localizedDescription
            AppLog.data.error("Patient profile save failed")
        }
    }
}

private struct MemberProfileFormState {
    var displayName: String
    var reportName: String
    var aliasesText: String
    var hasBirthDate: Bool
    var birthDate: Date
    var gender: String
    var conditionsText: String
    var allergiesText: String
    var histories: [MemberHistoryForm]

    init(patient: Patient) {
        displayName = patient.displayName
        reportName = patient.reportName ?? ""
        aliasesText = patient.aliases.joined(separator: "\n")
        hasBirthDate = patient.birthDate != nil
        birthDate = patient.birthDate ?? Date()
        gender = patient.gender ?? ""
        conditionsText = patient.conditions.joined(separator: "\n")
        allergiesText = patient.allergies.joined(separator: "\n")
        histories = patient.histories.map {
            MemberHistoryForm(id: $0.id, year: $0.year, text: $0.text)
        }
    }

    func content(from patient: Patient) -> PatientEditableContent {
        var content = patient.editableContent()
        content.displayName = displayName
        content.reportName = MemberIdentity.optionalTrimmed(reportName)
        content.aliases = lines(aliasesText)
        content.birthDate = hasBirthDate ? birthDate : nil
        content.gender = MemberIdentity.optionalTrimmed(gender)
        content.conditions = lines(conditionsText)
        content.allergies = lines(allergiesText)
        content.histories = histories.map {
            HistoryItem(id: $0.id, year: $0.year, text: $0.text)
        }
        return content
    }

    private func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines)
            .compactMap(MemberIdentity.optionalTrimmed)
    }
}

private struct MemberHistoryForm: Identifiable {
    var id: UUID = UUID()
    var year: Int
    var text: String
}

private struct MemberRevisionHistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let patient: Patient
    let onUndo: () -> Void
    @State private var revisions: [ContentRevision] = []
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text(MemberProfileCopy.noSensitiveLogs)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
            }
            Section {
                if revisions.isEmpty {
                    Text("暂无修订")
                        .foregroundStyle(CT.Color.inkSecondary)
                }
                ForEach(revisions) { revision in
                    VStack(alignment: .leading, spacing: CT.Space.s1) {
                        Text("第 \(revision.revision) 次修改")
                            .font(CT.Font.headline)
                        Text(
                            revision.changedFieldKeys
                                .map(MemberRevisionFieldName.display)
                                .joined(separator: "、")
                        )
                        .font(CT.Font.footnote)
                        .foregroundStyle(CT.Color.inkSecondary)
                        Text(revision.createdAt.formatted())
                            .font(CT.Font.label)
                            .foregroundStyle(CT.Color.inkTertiary)
                    }
                }
            }
            Section {
                Button(MemberProfileCopy.undo, role: .destructive) {
                    undo()
                }
                .disabled(revisions.isEmpty)
                .accessibilityIdentifier("member.profile.undo")
                if let message {
                    Text(message)
                        .font(CT.Font.footnote)
                }
            }
        }
        .navigationTitle(MemberProfileCopy.revisions)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }
            }
        }
        .task {
            reload()
        }
    }

    @MainActor
    private func reload() {
        do {
            revisions = try PatientProfileService(
                context: modelContext
            ).history(for: patient)
        } catch {
            message = "修订历史读取失败。"
        }
    }

    @MainActor
    private func undo() {
        do {
            _ = try PatientProfileService(
                context: modelContext
            ).undoLast(
                patient,
                expectedRevision: patient.contentRevision
            )
            onUndo()
            reload()
            message = "已撤销最近一次修改。"
        } catch {
            message = "撤销失败，请刷新后重试。"
        }
    }
}

private enum MemberRevisionFieldName {
    static func display(_ key: String) -> String {
        switch key {
        case "displayName": "日常称呼"
        case "reportName": "报告姓名"
        case "aliases": "姓名别名"
        case "birthDate": "出生日期"
        case "gender": "性别说明"
        case "conditions": "主要情况"
        case "allergies": "过敏信息"
        case "histories": "重要病史"
        case "careQuestions": "问题与笔记"
        default: "资料字段"
        }
    }
}

private struct CareQuestionListView: View {
    @Environment(\.modelContext) private var modelContext
    let patient: Patient
    @State private var editingQuestion: CareQuestion?
    @State private var showCreate = false
    @State private var feedback: String?

    private var questions: [CareQuestion] {
        patient.careQuestions.sorted {
            if $0.status != $1.status {
                return $0.status == .pending
            }
            if $0.updatedAt != $1.updatedAt {
                return $0.updatedAt > $1.updatedAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    var body: some View {
        List {
            if questions.isEmpty {
                ContentUnavailableView(
                    MemberProfileCopy.noQuestions,
                    systemImage: "questionmark.bubble"
                )
                .listRowBackground(CT.Color.bgBase)
            }
            ForEach(questions) { question in
                Button {
                    editingQuestion = question
                } label: {
                    VStack(alignment: .leading, spacing: CT.Space.s2) {
                        HStack {
                            Text(question.text)
                                .font(CT.Font.body)
                                .foregroundStyle(CT.Color.inkPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(
                                question.status == .pending
                                    ? MemberProfileCopy.pending
                                    : MemberProfileCopy.answered
                            )
                            .font(CT.Font.caption)
                            .foregroundStyle(
                                question.status == .pending
                                    ? CT.Color.warningOnContainer
                                    : CT.Color.successOnContainer
                            )
                        }
                        if let answer = question.answer {
                            Text("\(MemberProfileCopy.answer)：\(answer)")
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.inkSecondary)
                        }
                        if let note = question.note {
                            Text("\(MemberProfileCopy.note)：\(note)")
                                .font(CT.Font.footnote)
                                .foregroundStyle(CT.Color.inkSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "member.question.\(question.id.uuidString)"
                )
                .swipeActions {
                    Button(role: .destructive) {
                        remove(question)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
            }
            if let feedback {
                Text(feedback)
                    .font(CT.Font.footnote)
                    .foregroundStyle(CT.Color.inkSecondary)
                    .accessibilityIdentifier("member.question.feedback")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CT.Color.bgBase)
        .navigationTitle(MemberProfileCopy.questions)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreate = true
                } label: {
                    Label(MemberProfileCopy.addQuestion, systemImage: "plus")
                }
                .accessibilityIdentifier("member.question.add")
            }
        }
        .sheet(isPresented: $showCreate) {
            CareQuestionEditorView(question: nil) { draft in
                add(draft)
            }
        }
        .sheet(item: $editingQuestion) { question in
            CareQuestionEditorView(question: question) { draft in
                update(question, draft: draft)
            }
        }
        .accessibilityIdentifier("member.questions")
    }

    @MainActor
    private func add(_ draft: CareQuestionDraft) -> Bool {
        do {
            _ = try PatientProfileService(
                context: modelContext
            ).addQuestion(
                to: patient,
                text: draft.text,
                answer: draft.answer,
                note: draft.note,
                status: draft.status,
                expectedRevision: patient.contentRevision
            )
            feedback = "问题与笔记已保存。"
            return true
        } catch {
            feedback = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func update(
        _ question: CareQuestion,
        draft: CareQuestionDraft
    ) -> Bool {
        do {
            _ = try PatientProfileService(
                context: modelContext
            ).updateQuestion(
                on: patient,
                id: question.id,
                text: draft.text,
                answer: draft.answer,
                note: draft.note,
                status: draft.status,
                expectedRevision: patient.contentRevision
            )
            editingQuestion = nil
            feedback = "问题与笔记已更新。"
            return true
        } catch {
            feedback = error.localizedDescription
            return false
        }
    }

    @MainActor
    private func remove(_ question: CareQuestion) {
        do {
            _ = try PatientProfileService(
                context: modelContext
            ).removeQuestion(
                from: patient,
                id: question.id,
                expectedRevision: patient.contentRevision
            )
            feedback = "已删除。"
        } catch {
            feedback = "删除失败，请刷新后重试。"
        }
    }
}

private struct CareQuestionDraft {
    var text: String
    var status: CareQuestionStatus
    var answer: String?
    var note: String?
}

private enum CareQuestionField: Hashable {
    case text
    case answer
    case note
}

private struct CareQuestionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let question: CareQuestion?
    let onSave: (CareQuestionDraft) -> Bool
    @State private var text: String
    @State private var status: CareQuestionStatus
    @State private var answer: String
    @State private var note: String
    @State private var validationMessage: String?
    @FocusState private var focusedField: CareQuestionField?

    init(
        question: CareQuestion?,
        onSave: @escaping (CareQuestionDraft) -> Bool
    ) {
        self.question = question
        self.onSave = onSave
        _text = State(initialValue: question?.text ?? "")
        _status = State(initialValue: question?.status ?? .pending)
        _answer = State(initialValue: question?.answer ?? "")
        _note = State(initialValue: question?.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("问题") {
                    TextField(
                        "想问医生什么？",
                        text: $text,
                        axis: .vertical
                    )
                    .focused($focusedField, equals: .text)
                    .lineLimit(2...6)
                    .accessibilityIdentifier("member.question.text")
                    Picker("状态", selection: $status) {
                        Text(MemberProfileCopy.pending)
                            .tag(CareQuestionStatus.pending)
                        Text(MemberProfileCopy.answered)
                            .tag(CareQuestionStatus.answered)
                    }
                    .pickerStyle(.segmented)
                }
                Section(MemberProfileCopy.answer) {
                    TextField(
                        "仅记录你手动输入的回答",
                        text: $answer,
                        axis: .vertical
                    )
                    .focused($focusedField, equals: .answer)
                    .lineLimit(2...8)
                    .accessibilityIdentifier("member.question.answer")
                }
                Section(MemberProfileCopy.note) {
                    TextField(
                        "就诊准备、沟通结果或下一步安排",
                        text: $note,
                        axis: .vertical
                    )
                    .focused($focusedField, equals: .note)
                    .lineLimit(2...8)
                    .accessibilityIdentifier("member.question.note")
                }
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(CT.Color.danger)
                }
            }
            .navigationTitle(
                question == nil
                    ? MemberProfileCopy.addQuestion
                    : "编辑问题与笔记"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(MemberProfileCopy.save) {
                        focusedField = nil
                        let draft = CareQuestionDraft(
                            text: text,
                            status: status,
                            answer: MemberIdentity.optionalTrimmed(answer),
                            note: MemberIdentity.optionalTrimmed(note)
                        )
                        let probe = CareQuestion(
                            text: draft.text,
                            status: draft.status,
                            answer: draft.answer,
                            note: draft.note
                        )
                        do {
                            try PatientProfilePolicy.validateQuestions([probe])
                            if onSave(draft) {
                                dismiss()
                            }
                        } catch {
                            validationMessage = error.localizedDescription
                        }
                    }
                    .disabled(
                        text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                    )
                    .accessibilityIdentifier("member.question.save")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        focusedField = nil
                    }
                    .accessibilityIdentifier("member.question.keyboard.done")
                }
            }
        }
    }
}

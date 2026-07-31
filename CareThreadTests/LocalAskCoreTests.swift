import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct LocalAskIntentAndTimeTests {
    private let router = LocalAskIntentRouter()
    private let now = CTDate.make(2026, 7, 31)

    @Test("指标意图六种问法均命中")
    func metricIntentVariants() {
        for query in [
            "去年TSH怎么样", "血压记录", "化验数值", "空腹血糖",
            "白细胞结果", "总胆固醇指标"
        ] {
            #expect(router.route(query).contains(.metric), "\(query)")
        }
    }

    @Test("用药意图六种问法均命中")
    func medicationIntentVariants() {
        for query in [
            "我在吃什么药", "优甲乐什么时候开始吃", "用药记录", "阿司匹林剂量",
            "停药时间", "格华止是哪天开始的"
        ] {
            #expect(router.route(query).contains(.medication), "\(query)")
        }
    }

    @Test("复查意图六种问法均命中")
    func followUpIntentVariants() {
        for query in [
            "下次什么时候复查", "复查安排", "预约是哪天", "随访记录",
            "什么时候去医院", "下次检查项目"
        ] {
            #expect(router.route(query).contains(.followUp), "\(query)")
        }
    }

    @Test("自由意图六种问法均命中")
    func freeTextIntentVariants() {
        for query in [
            "肺部检查有没有问题", "最近去过哪些医院", "头痛门诊", "手术记录",
            "出院小结", "海棠医院的资料"
        ] {
            #expect(router.route(query).contains(.freeText), "\(query)")
        }
    }

    @Test("症状加用药可同时执行两个意图")
    func multiIntentRoutesTogether() {
        let intents = router.route("之前头疼的时候吃了什么药")

        #expect(intents.contains(.medication))
        #expect(intents.contains(.freeText))
    }

    @Test("空问句安全退化到自由检索")
    func emptyQueryFallsBackSafely() {
        #expect(router.route("   ") == [.freeText])
    }

    @Test("八类时间范围和四条边界均可解析")
    func parsesRequiredTimeExpressions() {
        let parser = LocalAskTimeParser()
        let operationDate = CTDate.make(2025, 4, 12)

        let lastYear = parser.parse("去年TSH", now: now)
        #expect(lastYear.displayLabel == "去年")
        #expect(lastYear.contains(CTDate.make(2025, 6, 1)))
        #expect(!lastYear.contains(CTDate.make(2026, 1, 1)))

        let thisYear = parser.parse("今年血压", now: now)
        #expect(thisYear.contains(CTDate.make(2026, 2, 1)))

        let lastMonth = parser.parse("上个月复查", now: now)
        #expect(lastMonth.contains(CTDate.make(2026, 6, 20)))
        #expect(!lastMonth.contains(CTDate.make(2026, 7, 1)))

        let recentQuarter = parser.parse("最近三个月记录", now: now)
        #expect(recentQuarter.contains(CTDate.make(2026, 6, 1)))
        #expect(!recentQuarter.contains(CTDate.make(2026, 3, 1)))

        let threeYearsAgo = parser.parse("三年前血糖", now: now)
        #expect(threeYearsAgo.contains(CTDate.make(2023, 8, 1)))

        let explicitYear = parser.parse("2024年用药", now: now)
        #expect(explicitYear.contains(CTDate.make(2024, 8, 1)))

        let postoperative = parser.parse(
            "术后病理",
            now: now,
            procedureDates: [operationDate]
        )
        #expect(postoperative.interval?.start == operationDate)

        #expect(parser.parse("最近一次复查", now: now).selection == .mostRecent)
        #expect(parser.parse("第一次头痛", now: now).selection == .earliest)
        #expect(parser.parse("所有资料", now: now) == .allTime)

        let recentHospitals = parser.parse("最近去过哪些医院", now: now)
        #expect(recentHospitals.selection == .allTime)
        #expect(!recentHospitals.didFallback)
        #expect(recentHospitals.displayLabel.contains("较新记录优先"))

        let unsupported = parser.parse("前一阵子的资料", now: now)
        #expect(unsupported.selection == .allTime)
        #expect(unsupported.didFallback)

        let missingOperation = parser.parse("术后资料", now: now)
        #expect(missingOperation.selection == .allTime)
        #expect(missingOperation.didFallback)
    }
}

@MainActor
struct LocalAskSynonymTests {
    @Test("八条药品商品名与通用名映射逐条可查")
    func medicationMappings() {
        assertEntry("levothyroxine", alias: "优甲乐")
        assertEntry("acarbose", alias: "拜糖平")
        assertEntry("metformin", alias: "格华止")
        assertEntry("aspirin", alias: "拜阿司匹灵")
        assertEntry("atorvastatin", alias: "立普妥")
        assertEntry("amlodipine", alias: "络活喜")
        assertEntry("ibuprofen", alias: "芬必")
        assertEntry("omeprazole", alias: "洛赛克")
    }

    @Test("八条指标缩写与中文全称映射逐条可查")
    func metricMappings() {
        assertEntry("tsh", alias: "TSH")
        assertEntry("ft4", alias: "FT4")
        assertEntry("ft3", alias: "FT3")
        assertEntry("hemoglobin", alias: "HGB")
        assertEntry("wbc", alias: "WBC")
        assertEntry("glucose", alias: "GLU")
        assertEntry("blood_pressure", alias: "BP")
        assertEntry("cholesterol", alias: "TC")
    }

    @Test("八条口语与书面词映射逐条可查")
    func colloquialMappings() {
        assertEntry("headache", alias: "头疼")
        assertEntry("diarrhea", alias: "拉肚子")
        assertEntry("dyspnea", alias: "喘不上气")
        assertEntry("palpitation", alias: "心慌")
        assertEntry("abdominal_pain", alias: "肚子疼")
        assertEntry("fever", alias: "发烧")
        assertEntry("edema", alias: "腿肿")
        assertEntry("fatigue", alias: "没劲")
    }

    @Test("同义词文件保持三类各至少八条")
    func lexiconHasRequiredCoverage() {
        for category in MedicalSynonymCategory.allCases {
            #expect(MedicalSynonymLexicon.entries(in: category).count >= 8)
        }
    }

    @Test("提取引擎与 Ask 共用药名词表")
    func extractionEngineReusesMedicationLexicon() throws {
        let result = ExtractionEngine().extract(
            "虚构处方\n络活喜 5mg 每日1次 口服",
            today: CTDate.make(2026, 7, 31)
        )

        let hint = try #require(result.medicationHints.first)
        #expect(hint.name == "络活喜")
    }

    private func assertEntry(_ id: String, alias: String) {
        let entry = MedicalSynonymLexicon.matches(in: alias).first { $0.id == id }
        #expect(entry != nil, "\(id): \(alias)")
        #expect(entry.map { MedicalSynonymLexicon.markers(in: $0.canonical).contains($0.marker) } == true)
    }
}

@MainActor
struct LocalAskDerivedIndexTests {
    @Test("同一记录只建一次且手工记录无需附件")
    func manualRecordBuildsOnlyOnce() {
        let memberID = UUID()
        let record = MedicalRecord(
            patientId: memberID,
            title: "虚构手工头痛记录",
            summary: "虚构文字",
            eventDate: CTDate.make(2026, 1, 2),
            sourceType: .manual
        )
        let builder = CountingLocalAskIndexBuilder()
        let store = LocalAskDerivedIndexStore(builder: builder)

        let first = store.prepare(record)
        let second = store.prepare(record)

        #expect(builder.buildCount == 1)
        #expect(first.document == second.document)
        #expect(record.attachments.isEmpty)
        #expect(record.derivedTextIndexPayload != nil)
    }

    @Test("内容修订后仅惰性刷新当前记录")
    func revisionRefreshesIncrementally() {
        let record = MedicalRecord(
            patientId: UUID(),
            title: "虚构记录",
            eventDate: CTDate.make(2026, 2, 1)
        )
        let builder = CountingLocalAskIndexBuilder()
        let store = LocalAskDerivedIndexStore(builder: builder)
        _ = store.prepare(record)

        record.bumpContentRevision()
        _ = store.prepare(record)
        _ = store.prepare(record)

        #expect(builder.buildCount == 2)
        #expect(record.derivedTextIndexSourceRevision == record.contentRevision)
    }

    @Test("算法版本变化后惰性刷新")
    func algorithmVersionRefreshesLazily() {
        let record = MedicalRecord(
            patientId: UUID(),
            title: "虚构记录",
            eventDate: CTDate.make(2026, 2, 1)
        )
        let firstBuilder = CountingLocalAskIndexBuilder(version: "ask-index-test-v1")
        _ = LocalAskDerivedIndexStore(builder: firstBuilder).prepare(record)

        let secondBuilder = CountingLocalAskIndexBuilder(version: "ask-index-test-v2")
        _ = LocalAskDerivedIndexStore(builder: secondBuilder).prepare(record)
        _ = LocalAskDerivedIndexStore(builder: secondBuilder).prepare(record)

        #expect(firstBuilder.buildCount == 1)
        #expect(secondBuilder.buildCount == 1)
        #expect(record.derivedTextIndexAlgorithmVersion == "ask-index-test-v2")
    }

    @Test("持久化重开容器后不重复建索引")
    func persistentRestartReadsStoredIndex() throws {
        let directory = try TestSupport.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storeURL = directory.appendingPathComponent("Ask.store")
        let memberID = UUID()

        do {
            let container = try TestSupport.persistentContainer(at: storeURL)
            let record = MedicalRecord(
                patientId: memberID,
                title: "虚构跨进程记录",
                eventDate: CTDate.make(2026, 3, 1),
                sourceType: .manual
            )
            container.mainContext.insert(record)
            let builder = CountingLocalAskIndexBuilder()
            _ = LocalAskDerivedIndexStore(builder: builder).prepare(record)
            try container.mainContext.save()
            #expect(builder.buildCount == 1)
        }

        do {
            let container = try TestSupport.persistentContainer(at: storeURL)
            let record = try #require(
                container.mainContext.fetch(FetchDescriptor<MedicalRecord>()).first
            )
            let builder = CountingLocalAskIndexBuilder()
            _ = LocalAskDerivedIndexStore(builder: builder).prepare(record)
            #expect(builder.buildCount == 0)
        }
    }

    @Test("取消后台首建会立即停止且不写入任何派生索引字段")
    func cancellingInitialBuildLeavesDerivedIndexUnwritten() async throws {
        let memberID = UUID()
        let longLocalText = String(repeating: "虚构本地病程 TSH 优甲乐 复查。", count: 2_000)
        let records = (0..<600).map { index in
            MedicalRecord(
                patientId: memberID,
                title: "虚构取消索引记录 \(index)",
                summary: longLocalText,
                eventDate: CTDate.make(2026, 1, 1).addingTimeInterval(
                    Double(index)
                ),
                sourceType: .manual,
                ocrText: longLocalText
            )
        }
        let store = LocalAskDerivedIndexStore()
        let task = Task { @MainActor in
            try await store.prepareAsync(records)
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        let cancellationStarted = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("取消后的索引任务不应正常返回")
        } catch is CancellationError {
            // Expected: cancellation must propagate instead of committing results.
        }
        let cancellationMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - cancellationStarted
        ) / 1_000_000

        #expect(cancellationMilliseconds < 750)
        #expect(records.allSatisfy { $0.derivedTextIndexPayload == nil })
        #expect(records.allSatisfy {
            $0.derivedTextIndexAlgorithmVersion == nil
        })
        #expect(records.allSatisfy {
            $0.derivedTextIndexSourceRevision == nil
        })
    }

    @Test("长 OCR 的输入整理与分词均在后台且 stale 会后台重派")
    func longOCRAndStaleRetryStayOffMainThread() async throws {
        let memberID = UUID()
        let distinctTerms = [
            "甲状腺", "血红蛋白", "白细胞", "空腹血糖",
            "总胆固醇", "颈部超声", "胸部影像", "病理记录",
            "复查预约", "门诊处方", "出院小结", "心电检查"
        ]
        let records = distinctTerms.enumerated().map { index, term in
            MedicalRecord(
                patientId: memberID,
                title: "虚构长 OCR 记录 \(term)",
                summary: "旧摘要 \(term)",
                eventDate: CTDate.make(2026, 1, 1)
                    .addingTimeInterval(Double(index)),
                sourceType: .manual,
                ocrText: String(
                    repeating: "虚构OCR \(term) TSH 复查。",
                    count: 20_000
                )
            )
        }
        let recorder = LocalAskWorkerRecorder(delay: 0.01)
        let store = LocalAskDerivedIndexStore { phase in
            recorder.record(phase)
        }
        let service = LocalAskQueryService(indexStore: store)
        let task = Task { @MainActor in
            try await service.prepareAsync(
                memberID: memberID,
                records: records,
                medications: [],
                followUps: []
            )
        }

        while recorder.makeInputCount < 1 {
            await Task.yield()
        }
        let record = records[0]
        var edited = record.editableContent()
        edited.summary = "更新后的虚构摘要"
        record.applyEditableContent(edited)
        record.bumpContentRevision()

        let prepared = try await task.value
        #expect(recorder.makeInputCount == records.count + 1)
        #expect(recorder.events.allSatisfy { !$0.wasMainThread })
        #expect(recorder.events.contains { $0.phase == .postings })
        #expect(prepared.invertedIndex.postingsByTerm.count > 30)
        #expect(prepared.records.first?.snapshot.summary == "更新后的虚构摘要")
        #expect(prepared.records.first?.snapshot.ocrText == nil)
        #expect(
            prepared.records.first?.document.sourceRevision
                == record.contentRevision
        )
        #expect(record.derivedTextIndexSourceRevision == record.contentRevision)
    }

    @Test("索引源持续变化超过两轮时关闭失败且不落任何 shard")
    func continuousSourceChurnFailsClosedWithoutPartialCommit() async throws {
        let record = MedicalRecord(
            patientId: UUID(),
            title: "虚构持续变化记录",
            summary: "版本 0",
            eventDate: CTDate.make(2026, 1, 1),
            sourceType: .manual,
            ocrText: String(repeating: "虚构长 OCR。", count: 25_000)
        )
        let recorder = LocalAskWorkerRecorder(delay: 0.04)
        let store = LocalAskDerivedIndexStore { phase in
            recorder.record(phase)
        }
        let build = Task { @MainActor in
            try await store.prepareAsync([record])
        }
        let churn = Task { @MainActor in
            for round in 1...2 {
                while recorder.makeInputCount < round {
                    await Task.yield()
                }
                var edited = record.editableContent()
                edited.summary = "版本 \(round)"
                record.applyEditableContent(edited)
                record.bumpContentRevision()
            }
        }
        await churn.value

        do {
            _ = try await build.value
            Issue.record("持续变化必须触发可识别的 fail-closed 错误")
        } catch let error as LocalAskIndexPreparationError {
            #expect(error == .sourceKeptChanging)
        }
        #expect(recorder.makeInputCount == 2)
        #expect(recorder.events.allSatisfy { !$0.wasMainThread })
        #expect(record.derivedTextIndexPayload == nil)
        #expect(record.derivedTextIndexAlgorithmVersion == nil)
        #expect(record.derivedTextIndexSourceRevision == nil)
    }
}

@MainActor
struct LocalAskBoundaryAndQualityTests {
    private let now = CTDate.make(2026, 7, 31)

    @Test("空库单字超长纯标点均不崩溃")
    func queryEdgesAreSafe() {
        let service = LocalAskQueryService()
        let prepared = LocalAskPreparedData(
            memberID: UUID(),
            records: [],
            medications: [],
            followUps: []
        )
        for query in ["", "药", String(repeating: "虚构查询", count: 100), "！？。，……"] {
            let response = service.ask(query, in: prepared, now: now)
            #expect(response.recordHits.isEmpty)
            #expect(response.metricFacts.isEmpty)
            #expect(response.medicationFacts.isEmpty)
            #expect(response.followUpFacts.isEmpty)
        }
        #expect(LocalAskTokenizer().normalizedQuery(String(repeating: "字", count: 201)).count == 200)
    }

    @Test("记录药物复查与日期都严格隔离成员")
    func memberIsolationCoversEveryPath() {
        let currentID = UUID()
        let otherID = UUID()
        let own = makeRecord(
            id: 1,
            memberID: currentID,
            title: "虚构成员甲头痛记录",
            summary: "头痛",
            date: CTDate.make(2026, 1, 1)
        )
        let other = makeRecord(
            id: 2,
            memberID: otherID,
            title: "虚构成员乙头痛记录",
            summary: "头痛",
            date: CTDate.make(2026, 2, 1),
            labs: [LabItem(name: "TSH", value: 99, unit: "mIU/L", flag: .high)]
        )
        let ownMedication = Medication(
            patientId: currentID,
            name: "布洛芬",
            startDate: CTDate.make(2026, 1, 1),
            sourceRecordId: own.id
        )
        let otherMedication = Medication(
            patientId: otherID,
            name: "布洛芬",
            startDate: CTDate.make(2026, 2, 1),
            sourceRecordId: other.id
        )
        let otherFollowUp = FollowUp(
            patientId: otherID,
            plannedDate: CTDate.make(2026, 8, 1),
            items: ["虚构复查"],
            resultRecordId: other.id
        )
        let service = LocalAskQueryService()
        let prepared = service.prepare(
            memberID: currentID,
            records: [own, other],
            medications: [ownMedication, otherMedication],
            followUps: [otherFollowUp]
        )

        #expect(prepared.records.map(\.snapshot.patientID) == [currentID])
        #expect(prepared.medications.map(\.patientID) == [currentID])
        #expect(prepared.followUps.isEmpty)
        let response = service.ask("头疼的时候吃了什么药并复查", in: prepared, now: now)
        #expect(!response.rankedSourceRecordIDs.contains(other.id))
        #expect(response.metricFacts.allSatisfy { $0.numericValue != 99 })
    }

    @Test("时间解析失败明示全部时间")
    func failedTimeParsingIsExplicit() {
        let response = LocalAskQueryService().ask(
            "前一阵子的虚构资料",
            in: .init(memberID: UUID(), records: [], medications: [], followUps: []),
            now: now
        )

        #expect(response.timeScope.didFallback)
        #expect(response.scopeNotice == "未识别到明确时间，已查找全部资料。")
    }

    @Test("跨越所选时段的长期用药仍作为事实返回")
    func longRunningMedicationOverlapsSelectedPeriod() {
        let memberID = UUID()
        let medication = Medication(
            patientId: memberID,
            name: "左甲状腺素钠片",
            startDate: CTDate.make(2024, 1, 1),
            endDate: nil
        )
        let response = LocalAskQueryService().ask(
            "去年优甲乐记录",
            memberID: memberID,
            records: [],
            medications: [medication],
            followUps: [],
            now: now
        )

        #expect(response.medicationFacts.map(\.id) == [medication.id])
    }

    @Test("当前用药快捷问题排除已结束和未来用药")
    func currentMedicationPresetOnlyReturnsActiveCurrentFacts() {
        let memberID = UUID()
        let current = Medication(
            patientId: memberID,
            name: "左甲状腺素钠片",
            startDate: CTDate.make(2026, 1, 1),
            lifecycleStatus: .active
        )
        let completed = Medication(
            patientId: memberID,
            name: "虚构已完成药物",
            startDate: CTDate.make(2025, 1, 1),
            endDate: CTDate.make(2025, 2, 1),
            lifecycleStatus: .completed
        )
        let future = Medication(
            patientId: memberID,
            name: "虚构未来药物",
            startDate: CTDate.make(2026, 9, 1),
            lifecycleStatus: .active
        )

        let response = LocalAskQueryService().ask(
            "我在吃什么药？",
            memberID: memberID,
            records: [],
            medications: [current, completed, future],
            followUps: [],
            now: now
        )

        #expect(response.medicationFacts.map(\.id) == [current.id])
    }

    @Test("下次复查快捷问题只返回最近的未来待办")
    func nextFollowUpPresetReturnsNearestPendingFutureDate() {
        let memberID = UUID()
        let past = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 7, 1),
            items: ["虚构过去复查"]
        )
        let next = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 8, 10),
            items: ["虚构最近复查"]
        )
        let later = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 9, 10),
            items: ["虚构较晚复查"]
        )
        let completed = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 8, 1),
            items: ["虚构已完成复查"],
            status: .completed
        )

        let response = LocalAskQueryService().ask(
            "下次什么时候复查？",
            memberID: memberID,
            records: [],
            medications: [],
            followUps: [past, next, later, completed],
            now: now
        )

        #expect(response.followUpFacts.map(\.id) == [next.id])
    }

    @Test("下次复查按日历日包含今天且同日全部返回")
    func nextFollowUpUsesCalendarDayInsteadOfExactTime() {
        let memberID = UUID()
        let morning = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 7, 31, hour: 9),
            items: ["虚构上午复查"]
        )
        let afternoon = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 7, 31, hour: 15),
            items: ["虚构下午复查"]
        )
        let tomorrow = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 8, 1, hour: 9),
            items: ["虚构次日复查"]
        )

        let response = LocalAskQueryService().ask(
            "下次什么时候复查？",
            memberID: memberID,
            records: [],
            medications: [],
            followUps: [tomorrow, afternoon, morning],
            now: CTDate.make(2026, 7, 31, hour: 12)
        )

        #expect(response.followUpFacts.map(\.id) == [morning.id, afternoon.id])
    }

    @Test("什么时候去医院仍是复查问题而非医院历史")
    func hospitalWordInFollowUpQuestionIsNotMisrouted() {
        let memberID = UUID()
        let followUp = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 8, 2),
            items: ["虚构复查安排"]
        )
        let response = LocalAskQueryService().ask(
            "什么时候去医院复查？",
            memberID: memberID,
            records: [],
            medications: [],
            followUps: [followUp],
            now: now
        )

        #expect(response.hospitalFacts.isEmpty)
        #expect(response.followUpFacts.map(\.id) == [followUp.id])
    }

    @Test("最近医院只用结构化机构字段并去重保留最新来源")
    func recentHospitalsAreStructuredDeduplicatedAndMemberScoped() {
        let memberID = UUID()
        let otherID = UUID()
        let older = makeRecord(
            id: 81,
            memberID: memberID,
            title: "虚构门诊甲",
            summary: "虚构就诊资料",
            date: CTDate.make(2026, 1, 1),
            hospital: "协和门诊部"
        )
        let latest = makeRecord(
            id: 82,
            memberID: memberID,
            title: "虚构门诊乙",
            summary: "虚构复诊资料",
            date: CTDate.make(2026, 3, 1),
            hospital: " 协和门诊部 "
        )
        let textOnly = makeRecord(
            id: 83,
            memberID: memberID,
            title: "虚构医院字样但机构字段为空",
            summary: "医院二字仅在标题里",
            date: CTDate.make(2026, 4, 1)
        )
        let otherMember = makeRecord(
            id: 84,
            memberID: otherID,
            title: "虚构其他成员门诊",
            summary: "虚构其他成员资料",
            date: CTDate.make(2026, 5, 1),
            hospital: "其他成员医院"
        )

        let response = LocalAskQueryService().ask(
            "最近去过哪些医院？",
            memberID: memberID,
            records: [older, latest, textOnly, otherMember],
            medications: [],
            followUps: [],
            now: now
        )

        #expect(response.hospitalFacts.count == 1)
        #expect(response.hospitalFacts.first?.name == "协和门诊部")
        #expect(response.hospitalFacts.first?.visitCount == 2)
        #expect(response.hospitalFacts.first?.sourceRecordID == latest.id)
        #expect(response.recordHits.isEmpty)
        #expect(response.rankedSourceRecordIDs == [latest.id])
    }

    @Test("用药结束日等于查询起点时不与半开区间重叠")
    func medicationEndEqualToScopeStartIsExcluded() {
        let memberID = UUID()
        let ended = Medication(
            patientId: memberID,
            name: "虚构区间前药物",
            startDate: CTDate.make(2024, 1, 1),
            endDate: CTDate.make(2025, 1, 1, hour: 0),
            lifecycleStatus: .completed
        )
        let overlaps = Medication(
            patientId: memberID,
            name: "虚构区间内药物",
            startDate: CTDate.make(2025, 1, 1),
            lifecycleStatus: .active
        )

        let response = LocalAskQueryService().ask(
            "去年用药记录",
            memberID: memberID,
            records: [],
            medications: [ended, overlaps],
            followUps: [],
            now: now
        )

        #expect(response.medicationFacts.map(\.id) == [overlaps.id])
    }

    @Test("指标时间过滤使用指标日期而非父记录日期")
    func metricScopeUsesMeasurementDate() throws {
        let memberID = UUID()
        let parentInside = makeRecord(
            id: 85,
            memberID: memberID,
            title: "虚构父记录在区间内",
            summary: "虚构 TSH",
            date: CTDate.make(2025, 2, 1),
            labs: [LabItem(name: "TSH", value: 1.1, unit: "mIU/L", flag: .none)]
        )
        let parentOutside = makeRecord(
            id: 86,
            memberID: memberID,
            title: "虚构父记录在区间外",
            summary: "虚构 TSH",
            date: CTDate.make(2026, 2, 1),
            labs: [LabItem(name: "TSH", value: 2.2, unit: "mIU/L", flag: .none)]
        )
        let outsideMeasurement = try #require(parentInside.measurements.first)
        var outsideContent = outsideMeasurement.editableContent()
        outsideContent.eventDate = CTDate.make(2026, 2, 1)
        outsideMeasurement.applyEditableContent(outsideContent)
        let insideMeasurement = try #require(parentOutside.measurements.first)
        var insideContent = insideMeasurement.editableContent()
        insideContent.eventDate = CTDate.make(2025, 2, 1)
        insideMeasurement.applyEditableContent(insideContent)

        let response = LocalAskQueryService().ask(
            "去年 TSH 指标",
            memberID: memberID,
            records: [parentInside, parentOutside],
            medications: [],
            followUps: [],
            now: now
        )

        #expect(response.metricFacts.map(\.id) == [insideMeasurement.id])
    }

    @Test("系统生成文本禁用词扫描零命中")
    func generatedCopyContainsNoMedicalAdviceTerms() {
        let memberID = UUID()
        let record = makeRecord(
            id: 900,
            memberID: memberID,
            title: "虚构甲功复查记录",
            summary: "原报告建议留存原文：头痛 左甲状腺素钠片",
            date: CTDate.make(2026, 2, 1),
            labs: [LabItem(name: "TSH", value: 2.2, unit: "mIU/L", flag: .none)]
        )
        let medication = Medication(
            patientId: memberID,
            name: "左甲状腺素钠片",
            startDate: CTDate.make(2026, 2, 1),
            sourceRecordId: record.id
        )
        let followUp = FollowUp(
            patientId: memberID,
            plannedDate: CTDate.make(2026, 9, 1),
            items: ["虚构甲功复查"],
            compareRecordId: record.id
        )
        let response = LocalAskQueryService().ask(
            "TSH 优甲乐 复查 头疼",
            memberID: memberID,
            records: [record],
            medications: [medication],
            followUps: [followUp],
            now: now
        )
        let forbidden = ["应该", "建议", "说明", "可能是", "需要"]
        #expect(forbidden.allSatisfy {
            !response.generatedDisplayText.contains($0)
        })
        #expect(response.recordHits.contains { $0.summary.contains("建议") })
        #expect(response.factualOverview == nil)
        #expect(response.generatedDisplayText.contains("不做医学判断"))
    }

    @Test("运行时倒排与线性 BM25 排序等价且只取 postings 候选")
    func invertedIndexMatchesLinearRankingAndNarrowsCandidates() {
        let memberID = UUID()
        let records = (0..<40).map { index in
            makeRecord(
                id: 50_000 + index,
                memberID: memberID,
                title: "虚构常规记录 \(index)",
                summary: [7, 31].contains(index)
                    ? "虚构稀有目标 TSH \(index == 31 ? "稀有目标" : "")"
                    : "普通归档内容",
                date: CTDate.make(2026, 1, 1)
                    .addingTimeInterval(Double(index))
            )
        }
        let prepared = LocalAskQueryService().prepare(
            memberID: memberID,
            records: records,
            medications: [],
            followUps: []
        )
        let allowed = Set(prepared.records.map { $0.snapshot.id })
        let search = LocalAskBM25Search()
        let actual = search.search(
            query: "稀有目标",
            index: prepared.invertedIndex,
            allowedRecordIDs: allowed
        ).map(\.recordID)
        let expected = legacyLinearRanking(
            query: "稀有目标",
            records: prepared.records
        )
        let candidates = search.candidateRecordIDs(
            query: "稀有目标",
            index: prepared.invertedIndex,
            allowedRecordIDs: allowed
        )

        #expect(actual == expected)
        #expect(candidates == Set([records[7].id, records[31].id]))
        #expect(candidates.count < records.count)
    }

    @Test("二十组全虚构金标准达到 Top1 与 Top3 门槛")
    func twentyCaseGoldenSetMeetsQualityGates() throws {
        let fixture = makeGoldenFixture()
        let service = LocalAskQueryService()
        let prepared = service.prepare(
            memberID: fixture.memberID,
            records: fixture.records,
            medications: fixture.medications,
            followUps: fixture.followUps
        )
        var top1 = 0
        var top3 = 0
        for item in fixture.cases {
            let ranked = service.ask(item.query, in: prepared, now: now).rankedSourceRecordIDs
            if ranked.first == item.expectedRecordID { top1 += 1 }
            if ranked.prefix(3).contains(item.expectedRecordID) { top3 += 1 }
        }
        let top1Rate = Double(top1) / Double(fixture.cases.count)
        let top3Rate = Double(top3) / Double(fixture.cases.count)
        print("LOCAL_ASK_GOLDEN cases=\(fixture.cases.count) top1=\(top1Rate) top3=\(top3Rate)")

        #expect(fixture.cases.count == 20)
        #expect(top1Rate >= 0.85)
        #expect(top3Rate >= 0.95)
    }

    @Test("300 与 1000 条各五轮并记录 median p95，千条低于 50ms")
    func retrievalPerformanceFiveRounds() {
        let service = LocalAskQueryService()
        let memberID = UUID()
        for count in [300, 1_000] {
            let records = (0..<count).map { index in
                makeRecord(
                    id: 10_000 + index,
                    memberID: memberID,
                    title: index == count - 1 ? "虚构目标头痛记录" : "虚构常规记录\(index)",
                    summary: index == count - 1 ? "头痛 布洛芬" : "常规归档资料",
                    date: CTDate.make(2026, 1, 1).addingTimeInterval(Double(index))
                )
            }
            let prepared = service.prepare(
                memberID: memberID,
                records: records,
                medications: [],
                followUps: []
            )
            _ = service.ask("头疼布洛芬", in: prepared, now: now)
            var durations: [Double] = []
            for _ in 0..<5 {
                let start = DispatchTime.now().uptimeNanoseconds
                let response = service.ask("头疼布洛芬", in: prepared, now: now)
                let end = DispatchTime.now().uptimeNanoseconds
                #expect(response.recordHits.first?.recordID == records.last?.id)
                durations.append(Double(end - start) / 1_000_000)
            }
            let sorted = durations.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[Int(ceil(Double(sorted.count) * 0.95)) - 1]
            print(
                "LOCAL_ASK_PERF records=\(count) rounds=5 median_ms=\(median) p95_ms=\(p95)"
            )
            if count == 1_000 {
                #expect(p95 < 50)
            }
        }
    }

    @Test("1000 条首次文本索引在后台全量重建低于一秒")
    func initialIndexRebuildPerformance() async throws {
        let memberID = UUID()
        let records = (0..<1_000).map { index in
            makeRecord(
                id: 30_000 + index,
                memberID: memberID,
                title: "虚构首建索引记录\(index)",
                summary: "虚构本地病程摘要 TSH 左甲状腺素钠片",
                date: CTDate.make(2026, 1, 1).addingTimeInterval(Double(index))
            )
        }
        let service = LocalAskQueryService()
        let started = DispatchTime.now().uptimeNanoseconds
        let prepared = try await service.prepareAsync(
            memberID: memberID,
            records: records,
            medications: [],
            followUps: []
        )
        let elapsedMilliseconds = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000
        print(
            "LOCAL_ASK_INDEX_REBUILD records=1000 elapsed_ms=\(elapsedMilliseconds)"
        )

        #expect(prepared.records.count == 1_000)
        #expect(records.allSatisfy { $0.derivedTextIndexPayload != nil })
        #expect(elapsedMilliseconds < 1_000)
    }

    private func makeGoldenFixture() -> GoldenFixture {
        let memberID = UUID()
        var records: [MedicalRecord] = []
        func add(
            _ id: Int,
            _ title: String,
            _ summary: String,
            _ date: Date,
            labs: [LabItem] = [],
            hospital: String? = nil,
            tags: [String] = []
        ) -> MedicalRecord {
            let record = makeRecord(
                id: id,
                memberID: memberID,
                title: title,
                summary: summary,
                date: date,
                labs: labs,
                hospital: hospital,
                symptomTags: tags
            )
            records.append(record)
            return record
        }

        let headache = add(1, "虚构头痛门诊病历", "头痛时记录布洛芬", CTDate.make(2025, 2, 2), tags: ["头痛"])
        let thyroid = add(2, "虚构甲功五项", "促甲状腺激素检验", CTDate.make(2025, 5, 5), labs: [
            LabItem(name: "TSH", value: 2.1, unit: "mIU/L", refLow: 0.3, refHigh: 4.2, flag: .none)
        ])
        let levothyroxine = add(3, "虚构甲状腺出院小结", "记录左甲状腺素钠片", CTDate.make(2024, 9, 2))
        let lung = add(4, "虚构胸部 CT", "肺部影像检查所见", CTDate.make(2026, 1, 4))
        let diarrhea = add(5, "虚构腹泻门诊", "腹泻两日", CTDate.make(2026, 1, 5), tags: ["腹泻"])
        let dyspnea = add(6, "虚构呼吸困难记录", "呼吸困难", CTDate.make(2026, 1, 6), tags: ["呼吸困难"])
        let palpitation = add(7, "虚构心悸记录", "心悸发作", CTDate.make(2026, 1, 7), tags: ["心悸"])
        let abdominalPain = add(8, "虚构腹痛记录", "腹痛", CTDate.make(2026, 1, 8), tags: ["腹痛"])
        let fever = add(9, "虚构发热记录", "发热", CTDate.make(2026, 1, 9), tags: ["发热"])
        let edema = add(10, "虚构下肢水肿记录", "下肢水肿", CTDate.make(2026, 1, 10), tags: ["下肢水肿"])
        let fatigue = add(11, "虚构乏力记录", "乏力", CTDate.make(2026, 1, 11), tags: ["乏力"])
        let aspirin = add(12, "虚构阿司匹林用药来源", "阿司匹林肠溶片", CTDate.make(2026, 1, 12))
        let metformin = add(13, "虚构二甲双胍用药来源", "二甲双胍缓释片", CTDate.make(2026, 1, 13))
        let hb = add(14, "虚构血常规甲", "血红蛋白", CTDate.make(2026, 1, 14), labs: [
            LabItem(name: "血红蛋白", value: 130, unit: "g/L", flag: .none)
        ])
        let wbc = add(15, "虚构血常规乙", "白细胞计数", CTDate.make(2026, 1, 15), labs: [
            LabItem(name: "白细胞计数", value: 6.1, unit: "10^9/L", flag: .none)
        ])
        let glucose = add(16, "虚构血糖化验", "空腹血糖", CTDate.make(2026, 1, 16), labs: [
            LabItem(name: "血糖", value: 5.2, unit: "mmol/L", flag: .none)
        ])
        let cholesterol = add(17, "虚构血脂化验", "总胆固醇", CTDate.make(2026, 1, 17), labs: [
            LabItem(name: "总胆固醇", value: 4.6, unit: "mmol/L", flag: .none)
        ])
        let followSource = add(18, "虚构复查来源", "甲功复查安排", CTDate.make(2026, 2, 18))
        let hospital = add(19, "虚构海棠医院门诊", "海棠医院就诊", CTDate.make(2026, 3, 19), hospital: "海棠医院")
        let operation = add(20, "虚构甲状腺手术记录", "甲状腺切除手术", CTDate.make(2025, 4, 12))
        let pathology = add(21, "虚构术后病理记录", "术后病理原始文字", CTDate.make(2025, 4, 15))

        let medications = [
            Medication(patientId: memberID, name: "布洛芬", startDate: headache.eventDate, sourceRecordId: headache.id),
            Medication(patientId: memberID, name: "左甲状腺素钠片", startDate: levothyroxine.eventDate, sourceRecordId: levothyroxine.id),
            Medication(patientId: memberID, name: "阿司匹林", startDate: aspirin.eventDate, sourceRecordId: aspirin.id),
            Medication(patientId: memberID, name: "二甲双胍", startDate: metformin.eventDate, sourceRecordId: metformin.id)
        ]
        let followUps = [
            FollowUp(
                patientId: memberID,
                plannedDate: CTDate.make(2026, 9, 1),
                items: ["虚构甲功复查"],
                compareRecordId: followSource.id
            )
        ]
        let cases = [
            GoldenCase(query: "之前头疼的时候吃了什么药", expectedRecordID: headache.id),
            GoldenCase(query: "去年甲状腺指标怎么样", expectedRecordID: thyroid.id),
            GoldenCase(query: "优甲乐是什么时候开始吃的", expectedRecordID: levothyroxine.id),
            GoldenCase(query: "肺部检查有没有问题", expectedRecordID: lung.id),
            GoldenCase(query: "拉肚子的记录", expectedRecordID: diarrhea.id),
            GoldenCase(query: "喘不上气那次", expectedRecordID: dyspnea.id),
            GoldenCase(query: "心慌记录", expectedRecordID: palpitation.id),
            GoldenCase(query: "肚子疼资料", expectedRecordID: abdominalPain.id),
            GoldenCase(query: "发烧记录", expectedRecordID: fever.id),
            GoldenCase(query: "腿肿记录", expectedRecordID: edema.id),
            GoldenCase(query: "没劲那次", expectedRecordID: fatigue.id),
            GoldenCase(query: "拜阿司匹灵什么时候开始", expectedRecordID: aspirin.id),
            GoldenCase(query: "格华止用药", expectedRecordID: metformin.id),
            GoldenCase(query: "HGB数值", expectedRecordID: hb.id),
            GoldenCase(query: "WBC数值", expectedRecordID: wbc.id),
            GoldenCase(query: "GLU数值", expectedRecordID: glucose.id),
            GoldenCase(query: "TC指标", expectedRecordID: cholesterol.id),
            GoldenCase(query: "下次什么时候复查", expectedRecordID: followSource.id),
            GoldenCase(query: "海棠医院的资料", expectedRecordID: hospital.id),
            GoldenCase(query: "术后病理记录", expectedRecordID: pathology.id)
        ]
        _ = operation
        return GoldenFixture(
            memberID: memberID,
            records: records,
            medications: medications,
            followUps: followUps,
            cases: cases
        )
    }

    private func makeRecord(
        id: Int,
        memberID: UUID,
        title: String,
        summary: String,
        date: Date,
        labs: [LabItem] = [],
        hospital: String? = nil,
        symptomTags: [String] = []
    ) -> MedicalRecord {
        MedicalRecord(
            id: fixedID(id),
            patientId: memberID,
            type: labs.isEmpty ? .outpatient : .lab,
            title: title,
            summary: summary,
            eventDate: date,
            hospital: hospital,
            diseaseTags: [],
            sourceType: .manual,
            ocrText: summary,
            labItems: labs,
            attachments: []
        ).withSymptomTags(symptomTags)
    }

    private func fixedID(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0006-%012d", suffix))!
    }

    private func legacyLinearRanking(
        query: String,
        records: [LocalAskPreparedRecord]
    ) -> [UUID] {
        var seen = Set<String>()
        let terms = LocalAskTokenizer().terms(in: query, isQuery: true)
            .filter { seen.insert($0).inserted }
        let count = Double(records.count)
        let averageLength = max(
            1,
            Double(records.reduce(0) { $0 + $1.document.termCount }) / count
        )
        let frequencies = Dictionary(uniqueKeysWithValues: terms.map { term in
            (term, records.filter {
                $0.document.weightedTermFrequencies[term] != nil
            }.count)
        })
        return records.compactMap { record -> (UUID, Double, Date)? in
            let length = Double(record.document.termCount)
            var score = 0.0
            for term in terms {
                guard let frequency = record.document
                    .weightedTermFrequencies[term], frequency > 0 else {
                    continue
                }
                let df = Double(frequencies[term] ?? 0)
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let denominator = frequency
                    + 1.2 * (1 - 0.75 + 0.75 * length / averageLength)
                score += idf * frequency * 2.2 / denominator
            }
            return score > 0
                ? (record.snapshot.id, score, record.snapshot.eventDate)
                : nil
        }
        .sorted {
            if abs($0.1 - $1.1) > 0.000_001 { return $0.1 > $1.1 }
            if $0.2 != $1.2 { return $0.2 > $1.2 }
            return $0.0.uuidString < $1.0.uuidString
        }
        .prefix(20)
        .map(\.0)
    }
}

private final class CountingLocalAskIndexBuilder: LocalAskIndexBuilding {
    let algorithmVersion: String
    private(set) var buildCount = 0
    private let base: LocalAskTextIndexBuilder

    init(version: String = LocalAskTextIndexBuilder.currentAlgorithmVersion) {
        algorithmVersion = version
        base = LocalAskTextIndexBuilder(algorithmVersion: version)
    }

    func makeDocument(
        from snapshot: LocalAskRecordSnapshot,
        sourceRevision: Int
    ) -> LocalAskIndexedDocument {
        buildCount += 1
        return base.makeDocument(from: snapshot, sourceRevision: sourceRevision)
    }
}

private final class LocalAskWorkerRecorder: @unchecked Sendable {
    struct Event {
        var phase: LocalAskIndexWorkerPhase
        var wasMainThread: Bool
    }

    private let lock = NSLock()
    private let delay: TimeInterval
    private var storedEvents: [Event] = []

    init(delay: TimeInterval = 0) {
        self.delay = delay
    }

    func record(_ phase: LocalAskIndexWorkerPhase) {
        lock.lock()
        storedEvents.append(Event(
            phase: phase,
            wasMainThread: Thread.isMainThread
        ))
        lock.unlock()
        if phase == .makeInput, delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
    }

    var makeInputCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents.filter { $0.phase == .makeInput }.count
    }

    var events: [Event] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }
}

private struct GoldenCase {
    var query: String
    var expectedRecordID: UUID
}

private struct GoldenFixture {
    var memberID: UUID
    var records: [MedicalRecord]
    var medications: [Medication]
    var followUps: [FollowUp]
    var cases: [GoldenCase]
}

private extension MedicalRecord {
    func withSymptomTags(_ values: [String]) -> MedicalRecord {
        guard !values.isEmpty else { return self }
        let tags = values.map {
            RecordTag(patientId: patientId, recordId: id, kind: .symptom, displayValue: $0)
        }
        _ = try? replaceTags(with: tags)
        return self
    }
}

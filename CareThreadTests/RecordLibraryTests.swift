import Foundation
import SwiftData
import Testing
@testable import CareThread

@MainActor
struct M3RecordLibraryTests {
    @Test("150 条同时间戳记录分页无重复无遗漏")
    func boundedOffsetCursor_handlesLargeIdenticalTies() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "分页成员", reportName: "虚构姓名")
        context.insert(patient)
        let timestamp = CTDate.make(2026, 7, 31)
        for index in 0..<150 {
            context.insert(
                MedicalRecord(
                    patientId: patient.id,
                    title: index.isMultiple(of: 2)
                        ? "报告 \(index)"
                        : "中文报告 \(index)",
                    eventDate: timestamp,
                    createdAt: timestamp
                )
            )
        }
        try context.save()

        var cursor: M3RecordCursor?
        var ids: [UUID] = []
        repeat {
            let result = try M3RecordLibraryService.page(
                context: context,
                patientID: patient.id,
                searchText: "",
                filter: M3RecordFilter(),
                generation: 7,
                after: cursor
            )
            ids.append(contentsOf: result.records.map(\.id))
            cursor = result.nextCursor
        } while cursor != nil

        #expect(ids.count == 150)
        #expect(Set(ids).count == 150)
    }

    @Test("数字与中文标题排序跨页沿用数据库排序且无重复")
    func titleSort_usesOneStableDatabaseOrderAcrossPages() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "标题成员", reportName: "虚构姓名")
        context.insert(patient)
        let timestamp = CTDate.make(2026, 7, 31)
        for index in 0..<150 {
            let prefix = ["报告", "报告 2", "报告 10", "中文", "A"][index % 5]
            context.insert(
                MedicalRecord(
                    patientId: patient.id,
                    title: "\(prefix)-\(index)",
                    eventDate: timestamp,
                    createdAt: timestamp
                )
            )
        }
        try context.save()
        var filter = M3RecordFilter()
        filter.sort = .title
        var cursor: M3RecordCursor?
        var ids: [UUID] = []
        var sortKeys: [String] = []
        repeat {
            let result = try M3RecordLibraryService.page(
                context: context,
                patientID: patient.id,
                searchText: "",
                filter: filter,
                generation: 8,
                after: cursor
            )
            ids.append(contentsOf: result.records.map(\.id))
            sortKeys.append(contentsOf: result.records.map(\.titleSortKey))
            cursor = result.nextCursor
        } while cursor != nil

        #expect(ids.count == 150)
        #expect(Set(ids).count == 150)
        #expect(!sortKeys.contains(""))
        #expect(sortKeys == sortKeys.sorted())
    }

    @Test("seek 快照排除首屏后的新增并完整返回仍存活旧记录")
    func seekSnapshot_handlesInsertAndDeleteBetweenPages() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let patient = Patient(name: "快照成员")
        context.insert(patient)
        let createdAt = CTDate.make(2026, 7, 1)
        var originalIDs: [UUID] = []
        for index in 0..<95 {
            let record = MedicalRecord(
                patientId: patient.id,
                title: "原记录 \(index)",
                eventDate: createdAt.addingTimeInterval(TimeInterval(index)),
                createdAt: createdAt
            )
            originalIDs.append(record.id)
            context.insert(record)
        }
        try context.save()

        let first = try M3RecordLibraryService.page(
            context: context,
            patientID: patient.id,
            searchText: "",
            filter: M3RecordFilter(),
            generation: 11,
            after: nil
        )
        let firstIDs = Set(first.records.map(\.id))
        let cursor = try #require(first.nextCursor)
        let unseenID = try #require(
            originalIDs.first(where: { !firstIDs.contains($0) })
        )
        let unseen = try #require(
            context.fetch(
                FetchDescriptor<MedicalRecord>(
                    predicate: #Predicate { $0.id == unseenID }
                )
            ).first
        )
        context.delete(unseen)
        let inserted = MedicalRecord(
            patientId: patient.id,
            title: "首屏后新增",
            eventDate: createdAt.addingTimeInterval(100_000),
            createdAt: cursor.snapshotCreatedAtUpperBound.addingTimeInterval(1)
        )
        context.insert(inserted)
        try context.save()

        var ids = first.records.map(\.id)
        var next: M3RecordCursor? = cursor
        while let current = next {
            let page = try M3RecordLibraryService.page(
                context: context,
                patientID: patient.id,
                searchText: "",
                filter: M3RecordFilter(),
                generation: 11,
                after: current
            )
            ids.append(contentsOf: page.records.map(\.id))
            next = page.nextCursor
        }

        #expect(Set(ids).count == ids.count)
        #expect(Set(ids) == Set(originalIDs).subtracting([unseenID]))
        #expect(!ids.contains(inserted.id))
    }

    @Test("跨成员组合筛选使用 seek 分页且标题顺序严格稳定")
    func seekPagination_combinedFiltersStayMemberScopedAndStable() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let target = Patient(name: "目标成员")
        let other = Patient(name: "其他成员")
        context.insert(target)
        context.insert(other)
        let base = CTDate.make(2026, 1, 1)
        var expected: [MedicalRecord] = []
        for index in 0..<90 {
            let matches = index.isMultiple(of: 2)
            let record = MedicalRecord(
                patientId: target.id,
                type: matches ? .lab : .outpatient,
                title: matches ? "血糖报告-\(index % 7)" : "其他-\(index)",
                eventDate: base.addingTimeInterval(TimeInterval(index * 60)),
                hospital: matches ? "虚构市医院" : "别院",
                doctor: matches ? "虚构医生" : "其他医生",
                primaryDisease: matches ? "糖尿病" : "其他",
                diseaseTags: matches ? ["代谢"] : [],
                ageAtEvent: matches ? 66 : 20,
                createdAt: base.addingTimeInterval(TimeInterval(index))
            )
            context.insert(record)
            if matches { expected.append(record) }
            context.insert(
                MedicalRecord(
                    patientId: other.id,
                    type: .lab,
                    title: "血糖报告-\(index)",
                    eventDate: base,
                    hospital: "虚构市医院",
                    doctor: "虚构医生",
                    primaryDisease: "糖尿病",
                    ageAtEvent: 66,
                    createdAt: base
                )
            )
        }
        try context.save()

        var filter = M3RecordFilter()
        filter.startDate = base
        filter.endDate = base.addingTimeInterval(90 * 60)
        filter.typeRawValues = [RecordType.lab.rawValue]
        filter.diseaseValues = ["糖尿病"]
        filter.hospitalValues = ["虚构市医院"]
        filter.doctorValues = ["虚构医生"]
        filter.minimumAge = 60
        filter.maximumAge = 70
        filter.sort = .title
        var cursor: M3RecordCursor?
        var actual: [MedicalRecord] = []
        repeat {
            let page = try M3RecordLibraryService.page(
                context: context,
                patientID: target.id,
                searchText: "血糖",
                filter: filter,
                generation: 12,
                after: cursor
            )
            actual.append(contentsOf: page.records)
            cursor = page.nextCursor
        } while cursor != nil

        let sortedExpected = expected.sorted {
            if $0.title != $1.title { return $0.title < $1.title }
            if $0.eventDate != $1.eventDate { return $0.eventDate > $1.eventDate }
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id > $1.id
        }
        #expect(actual.map(\.id) == sortedExpected.map(\.id))
        #expect(Set(actual.map(\.patientId)) == [target.id])
    }

    @Test("待整理收件箱只返回当前成员待核对资料并给出准确计数")
    func pendingInbox_isMemberScopedAndCounted() throws {
        let container = try TestSupport.container()
        let context = container.mainContext
        let target = Patient(name: "待整理成员")
        let other = Patient(name: "其他成员")
        context.insert(target)
        context.insert(other)
        let date = CTDate.make(2026, 7, 31)
        let pending = MedicalRecord(
            patientId: target.id,
            title: "待核对报告",
            eventDate: date,
            reviewStatus: .pending
        )
        context.insert(pending)
        context.insert(
            MedicalRecord(
                patientId: target.id,
                title: "已核对报告",
                eventDate: date,
                reviewStatus: .confirmed
            )
        )
        context.insert(
            MedicalRecord(
                patientId: other.id,
                title: "别人的待核对报告",
                eventDate: date,
                reviewStatus: .pending
            )
        )
        try context.save()

        var filter = M3RecordFilter()
        filter.pendingReviewOnly = true
        let page = try M3RecordLibraryService.page(
            context: context,
            patientID: target.id,
            searchText: "",
            filter: filter,
            generation: 13,
            after: nil
        )
        let facets = try M3RecordLibraryService.facets(
            context: context,
            patientID: target.id
        )

        #expect(page.records.map(\.id) == [pending.id])
        #expect(facets.pendingReviewCount == 1)
        #expect(filter.signature != M3RecordFilter().signature)
    }
}

import Foundation
import SwiftData

enum ContentRevisionServiceError: Error, Equatable {
    case emptyChangedFields
    case noChanges
    case revisionConflict(expected: Int, actual: Int)
    case payloadEncodingFailed
    case historyMissing
    case historyCorrupted
    case databaseSaveFailed
}

@MainActor
final class ContentRevisionService {
    typealias SaveAction = @MainActor (ModelContext) throws -> Void

    private let context: ModelContext
    private let saveAction: SaveAction

    init(
        context: ModelContext,
        saveAction: @escaping SaveAction = { try $0.save() }
    ) {
        self.context = context
        self.saveAction = saveAction
    }

    @discardableResult
    func edit<Entity: RevisionedEditable>(
        _ entity: Entity,
        content: Entity.EditableContent,
        changedFieldKeys: [String],
        source: ContentRevisionSource,
        expectedRevision: Int
    ) throws -> ContentRevision {
        let actualRevision = try persistedRevision(for: entity)
        guard expectedRevision == actualRevision,
              entity.contentRevision == actualRevision else {
            throw ContentRevisionServiceError.revisionConflict(
                expected: expectedRevision,
                actual: actualRevision
            )
        }
        let keys = Array(Set(changedFieldKeys.filter { !$0.isEmpty })).sorted()
        guard !keys.isEmpty else {
            throw ContentRevisionServiceError.emptyChangedFields
        }
        let before = entity.editableContent()
        let beforeRevision = entity.contentRevision
        guard before != content else {
            throw ContentRevisionServiceError.noChanges
        }
        let beforePayload: Data
        let afterPayload: Data
        do {
            beforePayload = try ModelPayload.encode(before)
            afterPayload = try ModelPayload.encode(content)
        } catch {
            throw ContentRevisionServiceError.payloadEncodingFailed
        }

        do {
            try entity.applyEditableContent(content)
            entity.bumpContentRevision()
            let revision = ContentRevision(
                entityKind: Entity.editableEntityKind,
                entityId: entity.editableEntityId,
                patientId: entity.editablePatientId,
                revision: entity.contentRevision,
                changedFieldKeys: keys,
                beforeContentPayload: beforePayload,
                afterContentPayload: afterPayload,
                source: source
            )
            context.insert(revision)
            try saveAction(context)
            AppLog.userAction.info(
                "Edited \(Entity.editableEntityKind.rawValue, privacy: .private(mask: .hash)) \(entity.editableEntityId.uuidString, privacy: .private(mask: .hash))"
            )
            return revision
        } catch {
            context.rollback()
            try? entity.applyEditableContent(before)
            entity.restoreContentRevision(beforeRevision)
            AppLog.data.error("Content revision save failed")
            throw ContentRevisionServiceError.databaseSaveFailed
        }
    }

    func history<Entity: RevisionedEditable>(for entity: Entity) throws -> [ContentRevision] {
        let kind = Entity.editableEntityKind.rawValue
        let entityId = entity.editableEntityId
        var descriptor = FetchDescriptor<ContentRevision>(
            predicate: #Predicate {
                $0.entityKindRawValue == kind && $0.entityId == entityId
            },
            sortBy: [SortDescriptor(\.revision, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        return try context.fetch(descriptor)
    }

    @discardableResult
    func undoLast<Entity: RevisionedEditable>(
        _ entity: Entity,
        expectedRevision: Int
    ) throws -> ContentRevision {
        let actualRevision = try persistedRevision(for: entity)
        guard expectedRevision == actualRevision,
              entity.contentRevision == actualRevision else {
            throw ContentRevisionServiceError.revisionConflict(
                expected: expectedRevision,
                actual: actualRevision
            )
        }
        guard let previousRevision = try history(for: entity).first else {
            throw ContentRevisionServiceError.historyMissing
        }
        guard let restored = ModelPayload.read(
            Entity.EditableContent.self,
            from: previousRevision.beforeContentPayload
        ).value else {
            throw ContentRevisionServiceError.historyCorrupted
        }
        return try edit(
            entity,
            content: restored,
            changedFieldKeys: previousRevision.changedFieldKeys,
            source: .undo,
            expectedRevision: actualRevision
        )
    }

    /// Reads through a fresh context so a stale caller cannot overwrite a
    /// revision committed by another ModelContext. All edits are MainActor
    /// synchronous, making this check-and-save sequence the in-process CAS
    /// critical section.
    private func persistedRevision<Entity: RevisionedEditable>(
        for entity: Entity
    ) throws -> Int {
        let probeContext = ModelContext(context.container)
        guard let persisted = probeContext.model(
            for: entity.persistentModelID
        ) as? Entity else {
            throw ContentRevisionServiceError.databaseSaveFailed
        }
        return persisted.contentRevision
    }
}

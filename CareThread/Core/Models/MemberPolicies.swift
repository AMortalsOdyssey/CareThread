import Foundation

enum MemberLimitPolicyError: Error, Equatable {
    case invalidExistingCount(Int)
    case maximumReached(limit: Int)
}

enum PatientScopeError: Error, Equatable {
    case mismatch(expected: UUID, actual: UUID)
}

enum RecordAssignmentPolicyError: Error, Equatable {
    case invalidDecision(outcome: RecordAssignmentOutcome, decision: AssignmentDecision)
    case overrideReasonRequired
}

enum RecordAssignmentTransferPolicyError: Error, Equatable {
    case ownerMismatch
    case missingAssignedMember
    case missingRecord
    case invalidSwitch
    case invalidDecision
    case recordScope
}

enum RecordGraphValidationError: Error, Equatable {
    case attachmentScope
    case attachmentRecord
    case measurementScope
    case measurementRecord
    case tagScope
    case tagRecord
}

enum AttachmentValidationError: Error, Equatable {
    case invalidRelativePath
    case invalidSHA256
    case emptyContent
    case missingTypeIdentifier
    case missingDisplayFileName
}

enum CaptureGroupingError: Error, Equatable {
    case emptyDocument
    case wrongPatient
    case wrongBatch
    case wrongDocument
    case generationMismatch
    case duplicatePageIndex
    case ocrIncomplete
}

enum MemberLimitPolicy {
    static let maximumMembers = 20

    static func validateAddition(existingCount: Int) throws {
        guard existingCount >= 0 else {
            throw MemberLimitPolicyError.invalidExistingCount(existingCount)
        }
        guard existingCount < maximumMembers else {
            throw MemberLimitPolicyError.maximumReached(limit: maximumMembers)
        }
    }
}

enum PatientScopeValidator {
    static func require(_ actualPatientId: UUID, equals expectedPatientId: UUID) throws {
        guard actualPatientId == expectedPatientId else {
            throw PatientScopeError.mismatch(expected: expectedPatientId, actual: actualPatientId)
        }
    }
}

enum RecordAssignmentPolicy {
    /// Enforces the hard gate used after OCR name detection.
    ///
    /// A mismatch can never be silently or forcibly assigned. It may only be
    /// rejected, switched to the matching member, or accepted after the
    /// explicit "name recognition may be wrong" confirmation with a reason.
    static func validate(
        outcome: RecordAssignmentOutcome,
        decision: AssignmentDecision,
        overrideReason: String?
    ) throws {
        switch (outcome, decision) {
        case (.match, .acceptedMatch),
             (.noEvidence, .acceptedWithoutNameEvidence),
             (.mismatch, .switchedMember),
             (.mismatch, .rejected),
             (.ambiguous, .switchedMember),
             (.ambiguous, .rejected):
            return
        case (.mismatch, .acceptedAfterNameRecognitionOverride),
             (.ambiguous, .acceptedAfterNameRecognitionOverride):
            guard MemberIdentity.optionalTrimmed(overrideReason) != nil else {
                throw RecordAssignmentPolicyError.overrideReasonRequired
            }
        default:
            throw RecordAssignmentPolicyError.invalidDecision(outcome: outcome, decision: decision)
        }
    }
}

/// Canonical ownership rules for a committed assignment audit when it crosses
/// a backup or nearby-transfer trust boundary.
///
/// The final assigned member owns the audit. `capturedForPatientId` remains
/// opaque provenance for a switched capture and intentionally does not require
/// that member's profile to be present in a single-member package. Old rows
/// that predate `assignedPatientId` fall back to their captured member.
enum RecordAssignmentTransferPolicy {
    static func ownerPatientID(
        capturedForPatientID: UUID,
        assignedPatientID: UUID?
    ) -> UUID {
        assignedPatientID ?? capturedForPatientID
    }

    @discardableResult
    static func validateStructure(
        capturedForPatientID: UUID,
        assignedPatientID: UUID?,
        recordID: UUID?,
        outcome: RecordAssignmentOutcome,
        decision: AssignmentDecision,
        overrideReason: String?,
        expectedOwnerPatientID: UUID
    ) throws -> UUID {
        let owner = ownerPatientID(
            capturedForPatientID: capturedForPatientID,
            assignedPatientID: assignedPatientID
        )
        guard owner == expectedOwnerPatientID else {
            throw RecordAssignmentTransferPolicyError.ownerMismatch
        }
        guard let recordID else {
            throw RecordAssignmentTransferPolicyError.missingRecord
        }

        if decision == .switchedMember {
            guard let assignedPatientID else {
                throw RecordAssignmentTransferPolicyError.missingAssignedMember
            }
            guard assignedPatientID == owner,
                  capturedForPatientID != assignedPatientID else {
                throw RecordAssignmentTransferPolicyError.invalidSwitch
            }
        } else {
            guard capturedForPatientID == owner,
                  assignedPatientID == nil || assignedPatientID == owner else {
                throw RecordAssignmentTransferPolicyError.ownerMismatch
            }
        }

        do {
            try RecordAssignmentPolicy.validate(
                outcome: outcome,
                decision: decision,
                overrideReason: overrideReason
            )
        } catch {
            throw RecordAssignmentTransferPolicyError.invalidDecision
        }
        return recordID
    }

    static func validateRecordScope(
        recordPatientID: UUID?,
        expectedOwnerPatientID: UUID
    ) throws {
        guard recordPatientID == expectedOwnerPatientID else {
            throw RecordAssignmentTransferPolicyError.recordScope
        }
    }
}

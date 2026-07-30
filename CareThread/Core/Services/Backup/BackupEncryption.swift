import CryptoKit
import Foundation
import Security

struct EncryptedBackupHeader: Codable, Equatable {
    static let formatVersion = 1
    static let kdfName = "PBKDF2-HMAC-SHA256"
    static let cipherName = "AES-256-GCM-CHUNKED"

    let formatVersion: Int
    let kdf: String
    let iterations: Int
    let salt: Data
    let cipher: String
    let noncePrefix: Data
    let chunkSize: Int
    let archiveByteCount: Int64
    let archiveSHA256: String

    func validate() throws {
        guard formatVersion == Self.formatVersion,
              kdf == Self.kdfName,
              cipher == Self.cipherName,
              (100_000...1_000_000).contains(iterations),
              salt.count == 16,
              noncePrefix.count == 4,
              (64 * 1_024...4 * 1_024 * 1_024).contains(chunkSize),
              archiveByteCount > 0,
              archiveByteCount <= BackupLimits.maximumExpandedBytes,
              archiveSHA256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw BackupError.unsupportedArchive
        }
    }
}

enum BackupEncryption {
    static let fileExtension = "ctbackup"
    static let iterations = 210_000
    static let chunkSize = 1 * 1_024 * 1_024
    private static let magic = Data("CTBKP001".utf8)
    private static let maximumHeaderBytes = 64 * 1_024
    private static let tagBytes = 16

    static func encrypt(
        zipURL: URL,
        password: String,
        outputURL: URL,
        randomBytes: (Int) throws -> Data = secureRandomBytes
    ) throws {
        guard password.count >= 12 else { throw BackupError.weakPassword }
        let sourceValues = try zipURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              let sourceSize = sourceValues.fileSize,
              sourceSize > 0 else {
            throw BackupError.unsupportedArchive
        }
        try Task.checkCancellation()
        let salt = try randomBytes(16)
        let prefix = try randomBytes(4)
        guard salt.count == 16, prefix.count == 4 else {
            throw BackupError.unsupportedArchive
        }
        let header = EncryptedBackupHeader(
            formatVersion: EncryptedBackupHeader.formatVersion,
            kdf: EncryptedBackupHeader.kdfName,
            iterations: iterations,
            salt: salt,
            cipher: EncryptedBackupHeader.cipherName,
            noncePrefix: prefix,
            chunkSize: chunkSize,
            archiveByteCount: Int64(sourceSize),
            archiveSHA256: try BackupExporter.sha256(zipURL)
        )
        try header.validate()
        let headerData = try StableJSON.encode(header)
        guard headerData.count <= maximumHeaderBytes else {
            throw BackupError.unsupportedArchive
        }
        let key = try deriveKey(password: password, header: header)
        let input = try FileHandle(forReadingFrom: zipURL)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        do {
            try output.write(contentsOf: magic)
            try output.write(contentsOf: uint32Data(UInt32(headerData.count)))
            try output.write(contentsOf: headerData)
            let headerDigest = Data(SHA256.hash(data: headerData))
            var index: UInt64 = 0
            var current = try input.read(upToCount: chunkSize) ?? Data()
            guard !current.isEmpty else { throw BackupError.unsupportedArchive }
            while !current.isEmpty {
                try Task.checkCancellation()
                let next = try input.read(upToCount: chunkSize) ?? Data()
                let isFinal = next.isEmpty
                let nonce = try AES.GCM.Nonce(
                    data: prefix + uint64Data(index)
                )
                let aad = frameAAD(
                    headerDigest: headerDigest,
                    index: index,
                    plainByteCount: current.count,
                    isFinal: isFinal
                )
                let box = try AES.GCM.seal(
                    current,
                    using: key,
                    nonce: nonce,
                    authenticating: aad
                )
                try output.write(contentsOf: uint32Data(UInt32(current.count)))
                try output.write(contentsOf: Data([isFinal ? 1 : 0]))
                try output.write(contentsOf: box.ciphertext)
                try output.write(contentsOf: box.tag)
                current = next
                index += 1
            }
            try output.synchronize()
            try harden(outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    static func decrypt(
        encryptedURL: URL,
        password: String,
        outputZipURL: URL
    ) throws {
        guard !password.isEmpty else { throw BackupError.passwordRequired }
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: encryptedURL)
        defer { try? input.close() }
        do {
            guard try readExactly(input, count: magic.count) == magic else {
                throw BackupError.unsupportedArchive
            }
            let headerLength = try decodeUInt32(
                readExactly(input, count: MemoryLayout<UInt32>.size)
            )
            guard headerLength > 0, headerLength <= maximumHeaderBytes else {
                throw BackupError.unsupportedArchive
            }
            let headerData = try readExactly(input, count: headerLength)
            let header = try StableJSON.decode(
                EncryptedBackupHeader.self,
                from: headerData
            )
            try header.validate()
            let key = try deriveKey(password: password, header: header)
            let headerDigest = Data(SHA256.hash(data: headerData))
            FileManager.default.createFile(
                atPath: outputZipURL.path,
                contents: nil
            )
            let output = try FileHandle(forWritingTo: outputZipURL)
            defer { try? output.close() }
            var index: UInt64 = 0
            var total: Int64 = 0
            var hasher = SHA256()
            var sawFinal = false
            while !sawFinal {
                try Task.checkCancellation()
                let lengthData = try readExactly(
                    input,
                    count: MemoryLayout<UInt32>.size
                )
                let plainCount = try decodeUInt32(lengthData)
                guard plainCount > 0,
                      plainCount <= header.chunkSize,
                      total + Int64(plainCount) <= header.archiveByteCount else {
                    throw BackupError.decryptionFailed
                }
                let flag = try readExactly(input, count: 1)[0]
                guard flag == 0 || flag == 1 else {
                    throw BackupError.decryptionFailed
                }
                let ciphertext = try readExactly(input, count: plainCount)
                let tag = try readExactly(input, count: tagBytes)
                let nonce = try AES.GCM.Nonce(
                    data: header.noncePrefix + uint64Data(index)
                )
                let aad = frameAAD(
                    headerDigest: headerDigest,
                    index: index,
                    plainByteCount: plainCount,
                    isFinal: flag == 1
                )
                let box = try AES.GCM.SealedBox(
                    nonce: nonce,
                    ciphertext: ciphertext,
                    tag: tag
                )
                let plain: Data
                do {
                    plain = try AES.GCM.open(
                        box,
                        using: key,
                        authenticating: aad
                    )
                } catch {
                    throw BackupError.decryptionFailed
                }
                try output.write(contentsOf: plain)
                hasher.update(data: plain)
                total += Int64(plain.count)
                sawFinal = flag == 1
                index += 1
            }
            guard (try input.read(upToCount: 1) ?? Data()).isEmpty,
                  total == header.archiveByteCount,
                  Data(hasher.finalize()).hexString == header.archiveSHA256 else {
                throw BackupError.decryptionFailed
            }
            try output.synchronize()
            try harden(outputZipURL)
        } catch {
            try? FileManager.default.removeItem(at: outputZipURL)
            if error is BackupError || error is CancellationError {
                throw error
            }
            throw BackupError.decryptionFailed
        }
    }

    static func isEncryptedBackup(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: magic.count)) == magic
    }

    private static func deriveKey(
        password: String,
        header: EncryptedBackupHeader
    ) throws -> SymmetricKey {
        guard let passwordData = password.data(using: .utf8), !passwordData.isEmpty else {
            throw BackupError.passwordRequired
        }
        let keyData = try pbkdf2SHA256(
            password: passwordData,
            salt: header.salt,
            iterations: header.iterations
        )
        return SymmetricKey(data: keyData)
    }

    /// RFC 8018 PBKDF2, one 32-byte block for an AES-256 key.
    private static func pbkdf2SHA256(
        password: Data,
        salt: Data,
        iterations: Int
    ) throws -> Data {
        let key = SymmetricKey(data: password)
        let firstInput = salt + Data([0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(
            for: firstInput,
            using: key
        ))
        var result = u
        if iterations > 1 {
            for iteration in 2...iterations {
                if iteration.isMultiple(of: 1_024) {
                    try Task.checkCancellation()
                }
                u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                for index in result.indices {
                    result[index] ^= u[index]
                }
            }
        }
        return result
    }

    private static func frameAAD(
        headerDigest: Data,
        index: UInt64,
        plainByteCount: Int,
        isFinal: Bool
    ) -> Data {
        headerDigest
            + uint64Data(index)
            + uint32Data(UInt32(plainByteCount))
            + Data([isFinal ? 1 : 0])
    }

    private static func readExactly(
        _ handle: FileHandle,
        count: Int
    ) throws -> Data {
        guard count >= 0 else { throw BackupError.unsupportedArchive }
        var result = Data()
        while result.count < count {
            let part = try handle.read(upToCount: count - result.count) ?? Data()
            guard !part.isEmpty else { throw BackupError.decryptionFailed }
            result.append(part)
        }
        return result
    }

    private static func uint32Data(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func uint64Data(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private static func decodeUInt32(_ data: Data) throws -> Int {
        guard data.count == MemoryLayout<UInt32>.size else {
            throw BackupError.unsupportedArchive
        }
        return Int(data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    }

    private static func secureRandomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard result == errSecSuccess else {
            throw BackupError.unsupportedArchive
        }
        return Data(bytes)
    }

    private static func harden(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
}

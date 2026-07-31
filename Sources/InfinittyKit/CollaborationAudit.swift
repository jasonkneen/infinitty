import CryptoKit
import Darwin
import Foundation

struct CollaborationAuditQuery: Codable, Equatable, Sendable {
    var cursor: String?
    var channelID: String?
    var actorID: String?
    var eventKinds: [String]
    var from: Date?
    var through: Date?
    var limit: Int

    init(
        cursor: String? = nil,
        channelID: String? = nil,
        actorID: String? = nil,
        eventKinds: [String] = [],
        from: Date? = nil,
        through: Date? = nil,
        limit: Int = 100
    ) {
        self.cursor = cursor
        self.channelID = channelID
        self.actorID = actorID
        self.eventKinds = eventKinds
        self.from = from
        self.through = through
        self.limit = limit
    }
}

struct CollaborationAuditSummary: Codable, Equatable, Sendable {
    let sequence: Int
    let eventID: String
    let timestamp: Date
    let actor: CollaborationActor
    let channelID: String
    let eventKind: String
    let commandFingerprint: String
    let causationID: String?
    let hash: String
}

struct CollaborationAuditPage: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let verified: Bool
    let journalTipSequence: Int
    let journalTipHash: String
    let records: [CollaborationAuditSummary]
    let nextCursor: String?
}

struct CollaborationAuditExportReceipt: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let exportID: String
    let path: String
    let recordCount: Int
    let journalTipSequence: Int
    let journalTipHash: String
    let payloadSHA256: String
    let signingPublicKey: String
    let signature: String
    let createdAt: Date
}

struct CollaborationAuditVerification: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let exportID: String
    let verified: Bool
    let recordCount: Int
    let journalTipSequence: Int
    let journalTipHash: String
    let payloadSHA256: String
}

enum CollaborationAuditError: Error, Equatable, CustomStringConvertible {
    case invalidQuery(String)
    case integrityFailure(sequence: Int)
    case cursorInvalid
    case cursorTipUnavailable
    case exportTooLarge
    case exportNotFound
    case exportInvalid(String)

    var description: String {
        switch self {
        case let .invalidQuery(reason):
            return "invalid audit query: \(reason)"
        case let .integrityFailure(sequence):
            return "audit integrity check failed at sequence \(sequence)"
        case .cursorInvalid:
            return "audit cursor is invalid"
        case .cursorTipUnavailable:
            return "audit cursor no longer identifies the verified journal tip"
        case .exportTooLarge:
            return "audit export exceeds the local verified export limit"
        case .exportNotFound:
            return "audit export was not found"
        case let .exportInvalid(reason):
            return "audit export verification failed: \(reason)"
        }
    }
}

final class CollaborationAuditService {
    static let maximumQueryCount = 200
    static let maximumQueryResponseBytes = 128 * 1024
    static let maximumExportRecords = 100_000
    static let maximumExportBytes = 64 * 1024 * 1024

    private struct Cursor: Codable {
        let version: Int
        let afterSequence: Int
        let tipSequence: Int
        let tipHash: String
        let checksum: String
    }

    private struct CursorMaterial: Codable {
        let version: Int
        let afterSequence: Int
        let tipSequence: Int
        let tipHash: String
    }

    private struct ExportManifest: Codable {
        let type: String
        let schemaVersion: Int
        let exportID: String
        let createdAt: Date
        let recordCount: Int
        let firstSequence: Int?
        let lastSequence: Int?
        let firstPreviousHash: String
        let lastHash: String
        let journalTipSequence: Int
        let journalTipHash: String
    }

    private struct ExportRecord: Codable {
        let type: String
        let record: CollaborationAuditRecord
    }

    private struct ExportSignature: Codable {
        let type: String
        let algorithm: String
        let payloadSHA256: String
        let signingPublicKey: String
        let signature: String
    }

    private let store: CollaborationEventStore
    private let rootDirectory: URL
    private let exportsDirectory: URL
    private let keyURL: URL
    private let now: () -> Date
    private let idFactory: () -> String
    private let lock = NSLock()

    init(
        store: CollaborationEventStore,
        rootDirectory: URL,
        now: @escaping () -> Date = Date.init,
        idFactory: @escaping () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.store = store
        self.rootDirectory = rootDirectory
        exportsDirectory = rootDirectory.appendingPathComponent(
            "exports", isDirectory: true)
        keyURL = rootDirectory.appendingPathComponent(
            "audit-signing-key-v1")
        self.now = now
        self.idFactory = idFactory
    }

    func query(_ rawQuery: CollaborationAuditQuery) throws
        -> CollaborationAuditPage
    {
        lock.lock()
        defer { lock.unlock() }
        let query = try validated(query: rawQuery)
        let records = try verifiedRecords()
        let liveTipSequence = records.last?.sequence ?? 0
        let liveTipHash =
            records.last?.hash ?? CollaborationAuditRecord.genesisHash

        let cursor = try query.cursor.map(decode(cursor:))
        let tipSequence: Int
        let tipHash: String
        let afterSequence: Int
        if let cursor {
            guard cursor.tipSequence <= liveTipSequence,
                  cursor.tipSequence == 0
                    || records[cursor.tipSequence - 1].hash
                        == cursor.tipHash
            else {
                throw CollaborationAuditError.cursorTipUnavailable
            }
            tipSequence = cursor.tipSequence
            tipHash = cursor.tipHash
            afterSequence = cursor.afterSequence
        } else {
            tipSequence = liveTipSequence
            tipHash = liveTipHash
            afterSequence = 0
        }

        let kinds = Set(query.eventKinds)
        func matches(_ record: CollaborationAuditRecord) -> Bool {
            (query.channelID == nil || record.channelID == query.channelID)
                && (query.actorID == nil || record.actor.id == query.actorID)
                && (kinds.isEmpty || kinds.contains(record.body.auditKind))
                && (query.from == nil || record.timestamp >= query.from!)
                && (query.through == nil || record.timestamp <= query.through!)
        }

        var summaries: [CollaborationAuditSummary] = []
        var scannedThrough = afterSequence
        var hasMore = false
        for record in records where
            record.sequence > afterSequence
                && record.sequence <= tipSequence
        {
            guard matches(record) else {
                scannedThrough = record.sequence
                continue
            }
            if summaries.count == query.limit {
                hasMore = true
                break
            }
            summaries.append(record.summary)
            let trial = CollaborationAuditPage(
                schemaVersion: 1,
                verified: true,
                journalTipSequence: tipSequence,
                journalTipHash: tipHash,
                records: summaries,
                nextCursor: nil)
            if try CollaborationJSON.encoder.encode(trial).count
                > Self.maximumQueryResponseBytes
            {
                summaries.removeLast()
                hasMore = true
                break
            }
            scannedThrough = record.sequence
        }
        if !hasMore, scannedThrough < tipSequence {
            hasMore = records.contains {
                $0.sequence > scannedThrough
                    && $0.sequence <= tipSequence
                    && matches($0)
            }
        }
        let nextCursor = hasMore
            ? try encodeCursor(
                afterSequence: scannedThrough,
                tipSequence: tipSequence,
                tipHash: tipHash)
            : nil
        return CollaborationAuditPage(
            schemaVersion: 1,
            verified: true,
            journalTipSequence: tipSequence,
            journalTipHash: tipHash,
            records: summaries,
            nextCursor: nextCursor)
    }

    func export() throws -> CollaborationAuditExportReceipt {
        lock.lock()
        defer { lock.unlock() }
        let records = try verifiedRecords()
        guard records.count <= Self.maximumExportRecords else {
            throw CollaborationAuditError.exportTooLarge
        }
        try preparePrivateDirectory(rootDirectory)
        try preparePrivateDirectory(exportsDirectory)
        let signingKey = try loadOrCreateSigningKey()
        let exportID = try validatedExportID(
            "audit-\(idFactory())")
        let createdAt = now()
        let tipSequence = records.last?.sequence ?? 0
        let tipHash =
            records.last?.hash ?? CollaborationAuditRecord.genesisHash
        let manifest = ExportManifest(
            type: "infinitty_audit_manifest",
            schemaVersion: 1,
            exportID: exportID,
            createdAt: createdAt,
            recordCount: records.count,
            firstSequence: records.first?.sequence,
            lastSequence: records.last?.sequence,
            firstPreviousHash:
                records.first?.previousHash
                    ?? CollaborationAuditRecord.genesisHash,
            lastHash: tipHash,
            journalTipSequence: tipSequence,
            journalTipHash: tipHash)
        var payload = try line(manifest)
        for record in records {
            payload.append(try line(ExportRecord(
                type: "infinitty_audit_record",
                record: record)))
            guard payload.count <= Self.maximumExportBytes else {
                throw CollaborationAuditError.exportTooLarge
            }
        }
        let payloadDigest = Self.sha256(payload)
        let signature = try signingKey.signature(for: payload)
        let publicKey = signingKey.publicKey.rawRepresentation
            .base64EncodedString()
        let signatureValue = signature.base64EncodedString()
        let trailer = ExportSignature(
            type: "infinitty_audit_signature",
            algorithm: "Ed25519",
            payloadSHA256: payloadDigest,
            signingPublicKey: publicKey,
            signature: signatureValue)
        var complete = payload
        complete.append(try line(trailer))
        guard complete.count <= Self.maximumExportBytes else {
            throw CollaborationAuditError.exportTooLarge
        }
        let url = exportURL(for: exportID)
        try complete.write(to: url, options: [.atomic])
        _ = chmod(url.path, 0o600)
        return CollaborationAuditExportReceipt(
            schemaVersion: 1,
            exportID: exportID,
            path: url.path,
            recordCount: records.count,
            journalTipSequence: tipSequence,
            journalTipHash: tipHash,
            payloadSHA256: payloadDigest,
            signingPublicKey: publicKey,
            signature: signatureValue,
            createdAt: createdAt)
    }

    func verify(exportID rawExportID: String) throws
        -> CollaborationAuditVerification
    {
        lock.lock()
        defer { lock.unlock() }
        let exportID = try validatedExportID(rawExportID)
        let url = exportURL(for: exportID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CollaborationAuditError.exportNotFound
        }
        let complete = try Data(
            contentsOf: url,
            options: [.mappedIfSafe])
        guard complete.count <= Self.maximumExportBytes,
              let finalNewline = complete.lastIndex(of: 0x0A),
              finalNewline == complete.index(before: complete.endIndex)
        else {
            throw CollaborationAuditError.exportInvalid("invalid file framing")
        }
        let withoutFinalNewline = complete[..<finalNewline]
        guard let trailerStart = withoutFinalNewline.lastIndex(of: 0x0A)
        else {
            throw CollaborationAuditError.exportInvalid("missing signature")
        }
        let payloadEnd = complete.index(after: trailerStart)
        let payload = Data(complete[..<payloadEnd])
        let trailerData = Data(
            complete[payloadEnd..<finalNewline])
        let trailer: ExportSignature
        do {
            trailer = try CollaborationJSON.decoder.decode(
                ExportSignature.self, from: trailerData)
        } catch {
            throw CollaborationAuditError.exportInvalid(
                "signature record cannot be decoded")
        }
        guard trailer.type == "infinitty_audit_signature",
              trailer.algorithm == "Ed25519",
              trailer.payloadSHA256 == Self.sha256(payload),
              let publicData = Data(
                  base64Encoded: trailer.signingPublicKey),
              let signatureData = Data(
                  base64Encoded: trailer.signature)
        else {
            throw CollaborationAuditError.exportInvalid(
                "signature metadata does not match the payload")
        }
        let signingKey = try loadOrCreateSigningKey()
        guard publicData == signingKey.publicKey.rawRepresentation else {
            throw CollaborationAuditError.exportInvalid(
                "export is not signed by this Infinitty authority")
        }
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: publicData)
        guard publicKey.isValidSignature(signatureData, for: payload) else {
            throw CollaborationAuditError.exportInvalid("signature is invalid")
        }

        let payloadLines = payload.split(
            separator: 0x0A,
            omittingEmptySubsequences: true)
        guard let first = payloadLines.first else {
            throw CollaborationAuditError.exportInvalid("missing manifest")
        }
        let manifest = try CollaborationJSON.decoder.decode(
            ExportManifest.self, from: Data(first))
        guard manifest.type == "infinitty_audit_manifest",
              manifest.schemaVersion == 1,
              manifest.exportID == exportID
        else {
            throw CollaborationAuditError.exportInvalid("manifest mismatch")
        }
        let records: [CollaborationAuditRecord] = try payloadLines.dropFirst()
            .map {
                let entry = try CollaborationJSON.decoder.decode(
                    ExportRecord.self, from: Data($0))
                guard entry.type == "infinitty_audit_record" else {
                    throw CollaborationAuditError.exportInvalid(
                        "unexpected payload record")
                }
                return entry.record
            }
        guard records.count == manifest.recordCount,
              manifest.firstSequence == records.first?.sequence,
              manifest.lastSequence == records.last?.sequence,
              manifest.firstPreviousHash
                == (records.first?.previousHash
                    ?? CollaborationAuditRecord.genesisHash),
              manifest.lastHash
                == (records.last?.hash
                    ?? CollaborationAuditRecord.genesisHash),
              manifest.journalTipSequence == (records.last?.sequence ?? 0),
              manifest.journalTipHash
                == (records.last?.hash
                    ?? CollaborationAuditRecord.genesisHash)
        else {
            throw CollaborationAuditError.exportInvalid(
                "manifest range does not match records")
        }
        try verify(records: records)
        return CollaborationAuditVerification(
            schemaVersion: 1,
            exportID: exportID,
            verified: true,
            recordCount: records.count,
            journalTipSequence: manifest.journalTipSequence,
            journalTipHash: manifest.journalTipHash,
            payloadSHA256: trailer.payloadSHA256)
    }

    private func validated(query: CollaborationAuditQuery) throws
        -> CollaborationAuditQuery
    {
        guard (1...Self.maximumQueryCount).contains(query.limit) else {
            throw CollaborationAuditError.invalidQuery(
                "limit must be 1...\(Self.maximumQueryCount)")
        }
        guard query.eventKinds.count <= 32,
              query.eventKinds.allSatisfy({
                  !$0.isEmpty && $0.utf8.count <= 80
              }),
              query.channelID.map({ !$0.isEmpty && $0.utf8.count <= 160 })
                ?? true,
              query.actorID.map({ !$0.isEmpty && $0.utf8.count <= 160 })
                ?? true,
              query.from == nil || query.through == nil
                || query.from! <= query.through!
        else {
            throw CollaborationAuditError.invalidQuery(
                "filters are malformed or exceed their limits")
        }
        return query
    }

    private func verifiedRecords() throws -> [CollaborationAuditRecord] {
        var records: [CollaborationAuditRecord] = []
        try store.scan { record in
            guard records.count < Self.maximumExportRecords else {
                throw CollaborationAuditError.exportTooLarge
            }
            records.append(record)
        }
        try verify(records: records)
        return records
    }

    private func verify(records: [CollaborationAuditRecord]) throws {
        var previousHash = CollaborationAuditRecord.genesisHash
        for (index, record) in records.enumerated() {
            let expected = index + 1
            guard record.sequence == expected,
                  record.previousHash == previousHash,
                  CollaborationAuditRecord.verify(record)
            else {
                throw CollaborationAuditError.integrityFailure(
                    sequence: expected)
            }
            previousHash = record.hash
        }
        do {
            _ = try CollaborationRoom(
                store: MemoryCollaborationEventStore(records: records))
        } catch let error as CollaborationRoomError {
            if case let .auditIntegrityFailure(sequence) = error {
                throw CollaborationAuditError.integrityFailure(
                    sequence: sequence)
            }
            throw CollaborationAuditError.exportInvalid(
                "semantic replay failed")
        }
    }

    private func encodeCursor(
        afterSequence: Int,
        tipSequence: Int,
        tipHash: String
    ) throws -> String {
        let material = CursorMaterial(
            version: 1,
            afterSequence: afterSequence,
            tipSequence: tipSequence,
            tipHash: tipHash)
        let checksum = Self.sha256(
            try CollaborationJSON.encoder.encode(material))
        let data = try CollaborationJSON.encoder.encode(Cursor(
            version: material.version,
            afterSequence: material.afterSequence,
            tipSequence: material.tipSequence,
            tipHash: material.tipHash,
            checksum: checksum))
        return Self.base64URL(data)
    }

    private func decode(cursor encoded: String) throws -> Cursor {
        guard encoded.utf8.count <= 1_024,
              let data = Self.decodeBase64URL(encoded),
              let cursor = try? CollaborationJSON.decoder.decode(
                  Cursor.self, from: data),
              cursor.version == 1,
              cursor.afterSequence >= 0,
              cursor.afterSequence <= cursor.tipSequence
        else {
            throw CollaborationAuditError.cursorInvalid
        }
        let material = CursorMaterial(
            version: cursor.version,
            afterSequence: cursor.afterSequence,
            tipSequence: cursor.tipSequence,
            tipHash: cursor.tipHash)
        guard cursor.checksum == Self.sha256(
            try CollaborationJSON.encoder.encode(material))
        else {
            throw CollaborationAuditError.cursorInvalid
        }
        return cursor
    }

    private func loadOrCreateSigningKey() throws
        -> Curve25519.Signing.PrivateKey
    {
        try preparePrivateDirectory(rootDirectory)
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let data = try Data(contentsOf: keyURL)
            guard data.count == 32 else {
                throw CollaborationAuditError.exportInvalid(
                    "signing key is malformed")
            }
            _ = chmod(keyURL.path, 0o600)
            return try Curve25519.Signing.PrivateKey(
                rawRepresentation: data)
        }
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.write(to: keyURL, options: [.atomic])
        _ = chmod(keyURL.path, 0o600)
        return key
    }

    private func preparePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        _ = chmod(url.path, 0o700)
    }

    private func exportURL(for exportID: String) -> URL {
        exportsDirectory.appendingPathComponent(
            "\(exportID).jsonl",
            isDirectory: false)
    }

    private func validatedExportID(_ value: String) throws -> String {
        let allowed = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard (1...120).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({
                  allowed.contains($0)
              })
        else {
            throw CollaborationAuditError.exportInvalid(
                "export id is invalid")
        }
        return value
    }

    private func line<T: Encodable>(_ value: T) throws -> Data {
        var data = try CollaborationJSON.encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(
            repeating: "=",
            count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

private extension CollaborationAuditRecord {
    var summary: CollaborationAuditSummary {
        CollaborationAuditSummary(
            sequence: sequence,
            eventID: eventID,
            timestamp: timestamp,
            actor: actor,
            channelID: channelID,
            eventKind: body.auditKind,
            commandFingerprint: commandFingerprint,
            causationID: causationID,
            hash: hash)
    }
}

extension CollaborationAuditBody {
    var auditKind: String {
        switch self {
        case .channelCreated: return "channel_created"
        case .channelCreatedAndLinked:
            return "channel_created_and_linked"
        case .endpointsLinked: return "endpoints_linked"
        case .endpointsLinkedAndParticipantsJoined:
            return "endpoints_linked_and_participants_joined"
        case .endpointLeft: return "endpoint_left"
        case .membershipUpdated: return "membership_updated"
        case .participantJoined: return "participant_joined"
        case .responsibilityClaimed: return "responsibility_claimed"
        case .responsibilityReleased: return "responsibility_released"
        case .planReplaced: return "plan_replaced"
        case .messagePosted: return "message_posted"
        case .proposalPrepared: return "proposal_prepared"
        case .proposalTransitioned: return "proposal_transitioned"
        case .commandNoOp: return "command_no_op"
        }
    }
}

struct CollaborationAuditControlRequest: Codable, Equatable, Sendable {
    enum Operation: String, Codable, Sendable {
        case query
        case export
        case verify
    }

    let v: Int
    let op: Operation
    var query: CollaborationAuditQuery?
    var exportID: String?

    init(
        v: Int = 1,
        op: Operation,
        query: CollaborationAuditQuery? = nil,
        exportID: String? = nil
    ) {
        self.v = v
        self.op = op
        self.query = query
        self.exportID = exportID
    }
}

enum CollaborationAuditControlCodec {
    static let maximumDecodedBytes = 16 * 1024

    private struct ResponseEnvelope: Codable {
        let v: Int
        let ok: Bool
        let page: CollaborationAuditPage?
        let export: CollaborationAuditExportReceipt?
        let verification: CollaborationAuditVerification?
        let error: ErrorEnvelope?
    }

    private struct ErrorEnvelope: Codable {
        let code: String
        let message: String
    }

    static func encode(_ request: CollaborationAuditControlRequest) -> String? {
        guard let data = try? CollaborationJSON.encoder.encode(request),
              data.count <= maximumDecodedBytes
        else { return nil }
        return base64URL(data)
    }

    static func execute(
        _ encoded: String,
        service: CollaborationAuditService
    ) -> String {
        do {
            let request = try decode(encoded)
            guard request.v == 1 else {
                return response(
                    error: "unsupported_version",
                    message:
                        "Audit request version \(request.v) is unsupported.")
            }
            switch request.op {
            case .query:
                return response(page: try service.query(
                    request.query ?? CollaborationAuditQuery()))
            case .export:
                return response(export: try service.export())
            case .verify:
                guard let exportID = request.exportID else {
                    return response(
                        error: "invalid_request",
                        message: "Audit verify requires exportID.")
                }
                return response(verification: try service.verify(
                    exportID: exportID))
            }
        } catch {
            return response(
                error: "audit_rejected",
                message: String(describing: error))
        }
    }

    private static func decode(
        _ encoded: String
    ) throws -> CollaborationAuditControlRequest {
        guard encoded.utf8.count
            <= ((maximumDecodedBytes + 2) / 3) * 4 + 4,
              let data = decodeBase64URL(encoded),
              data.count <= maximumDecodedBytes,
              let request = try? CollaborationJSON.decoder.decode(
                  CollaborationAuditControlRequest.self,
                  from: data)
        else {
            throw CollaborationAuditError.invalidQuery(
                "request must be bounded base64url JSON")
        }
        return request
    }

    private static func response(
        page: CollaborationAuditPage? = nil,
        export: CollaborationAuditExportReceipt? = nil,
        verification: CollaborationAuditVerification? = nil
    ) -> String {
        encodeResponse(ResponseEnvelope(
            v: 1,
            ok: true,
            page: page,
            export: export,
            verification: verification,
            error: nil))
    }

    private static func response(
        error: String,
        message: String
    ) -> String {
        encodeResponse(ResponseEnvelope(
            v: 1,
            ok: false,
            page: nil,
            export: nil,
            verification: nil,
            error: ErrorEnvelope(code: error, message: message)))
    }

    private static func encodeResponse(
        _ envelope: ResponseEnvelope
    ) -> String {
        let data = (try? CollaborationJSON.encoder.encode(envelope))
            ?? Data("{\"v\":1,\"ok\":false}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(
            repeating: "=",
            count: (4 - base64.utf8.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

//
//  PosterBoardRegistry.swift
//  AirCard-iOS
//
//  iOS 27 PosterBoard configuration registry support.
//

import Foundation
import SQLite3
import AirliftFFI

struct PosterBoardRegistration {
    let uuid: String
    let provider: String
    let role: String

    init(uuid: String, provider: String, role: String = "PRPosterRoleLockScreen") {
        self.uuid = uuid
        self.provider = provider
        self.role = role
    }
}

enum PosterBoardRegistryError: LocalizedError {
    case extractFailed(String)
    case invalidDatabase
    case sqlite(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .extractFailed(let message):
            return "Failed to read PosterBoard registry: \(message)"
        case .invalidDatabase:
            return "PosterBoard registry is not a valid SQLite database."
        case .sqlite(let message):
            return "PosterBoard registry update failed: \(message)"
        case .writeFailed(let message):
            return "Failed to write PosterBoard registry: \(message)"
        }
    }
}

final class PosterBoardRegistry {
    static let shared = PosterBoardRegistry()

    private let registryFileName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

    private init() {}

    func register(
        registrations: [PosterBoardRegistration],
        containerPath: String,
        structureVersion: Int,
        pairingPath: String,
        log: @escaping (String) -> Void
    ) async throws {
        guard !registrations.isEmpty else { return }

        let dataStoreDir = "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/\(structureVersion)"
        let remoteRegistryPath = "\(dataStoreDir)/\(registryFileName)"

        log("\n🗃 Reading PosterBoard registry…")
        let originalData = try await extractRemoteFile(
            pairingPath: pairingPath,
            devicePath: remoteRegistryPath
        )

        guard originalData.count > 100,
              String(decoding: originalData.prefix(16), as: UTF8.self).hasPrefix("SQLite format 3") else {
            throw PosterBoardRegistryError.invalidDatabase
        }

        saveRecoveryCopy(originalData, log: log)

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard_registry_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let dbURL = workDir.appendingPathComponent(registryFileName)
        try originalData.write(to: dbURL, options: .atomic)

        log("  🧩 Registering \(registrations.count) wallpaper configuration(s)…")
        try mutateDatabase(at: dbURL, registrations: registrations, log: log)

        let updatedData = try Data(contentsOf: dbURL)
        guard updatedData.count > 100 else {
            throw PosterBoardRegistryError.invalidDatabase
        }

        do {
            try await writeRemoteRegistry(
                data: updatedData,
                pairingPath: pairingPath,
                targetDirectory: dataStoreDir
            )
        } catch {
            log("  ⚠️ Registry write failed; attempting to restore the original database…")
            try? await writeRemoteRegistry(
                data: originalData,
                pairingPath: pairingPath,
                targetDirectory: dataStoreDir
            )
            throw error
        }

        log("  ✅ PosterBoard central registry updated")
    }

    private func saveRecoveryCopy(_ data: Data, log: @escaping (String) -> Void) {
        do {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let backupDir = docs.appendingPathComponent("PosterBoardRegistryBackup", isDirectory: true)
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let backupURL = backupDir.appendingPathComponent(registryFileName)
            try data.write(to: backupURL, options: .atomic)
            log("  🛟 Original registry backed up inside AirCard Documents")
        } catch {
            log("  ⚠️ Could not save local registry backup: \(error.localizedDescription)")
        }
    }

    private func extractRemoteFile(
        pairingPath: String,
        devicePath: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outData: UnsafeMutablePointer<UInt8>? = nil
                var outLen: Int = 0
                var outError: UnsafeMutablePointer<CChar>? = nil

                let rc = pairingPath.withCString { pairC in
                    devicePath.withCString { pathC in
                        al_airlift_extract(
                            pairC,
                            pathC,
                            nil,
                            nil,
                            &outData,
                            &outLen,
                            &outError
                        )
                    }
                }

                let errorText: String? = outError.map { ptr in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }

                guard rc == 0 else {
                    continuation.resume(
                        throwing: PosterBoardRegistryError.extractFailed(
                            errorText ?? "AirLift extract returned code \(rc)"
                        )
                    )
                    return
                }

                guard let ptr = outData else {
                    continuation.resume(throwing: PosterBoardRegistryError.extractFailed("No data returned"))
                    return
                }

                let data = Data(bytes: ptr, count: outLen)
                al_afc_free_bytes(ptr, outLen)
                continuation.resume(returning: data)
            }
        }
    }

    private func writeRemoteRegistry(
        data: Data,
        pairingPath: String,
        targetDirectory: String
    ) async throws {
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard_registry_write_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageDir) }

        try data.write(to: stageDir.appendingPathComponent(registryFileName), options: .atomic)

        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairC in
                    stageDir.path.withCString { srcC in
                        targetDirectory.withCString { targetC in
                            al_exploit_write_dir(
                                pairC,
                                srcC,
                                targetC,
                                nil,
                                nil,
                                &outError
                            )
                        }
                    }
                }

                let errorText: String? = outError.map { ptr in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }

                if rc == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: PosterBoardRegistryError.writeFailed(
                            errorText ?? "AirLift write returned code \(rc)"
                        )
                    )
                }
            }
        }
    }

    private func mutateDatabase(
        at url: URL,
        registrations: [PosterBoardRegistration],
        log: @escaping (String) -> Void
    ) throws {
        var db: OpaquePointer? = nil
        let openFlags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, openFlags, nil) == SQLITE_OK, let db else {
            throw PosterBoardRegistryError.sqlite("sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        // Force all changes into the main database file. This avoids needing to
        // transport a local -wal/-shm pair back to the device.
        try exec(db, "PRAGMA journal_mode=DELETE;")
        try exec(db, "PRAGMA synchronous=FULL;")
        try exec(db, "BEGIN IMMEDIATE TRANSACTION;")

        do {
            for registration in registrations {
                let uuid = quote(registration.uuid)
                let provider = quote(registration.provider)
                let role = quote(registration.role)

                try exec(
                    db,
                    "INSERT INTO poster (UUID, providerId) VALUES (\(uuid), \(provider));"
                )

                let currentSortKey = try scalarInt64(
                    db,
                    "SELECT COALESCE(MAX(roleSortKey), 0) FROM posterRoleMembership WHERE roleId=\(role);"
                )
                let nextSortKey = currentSortKey + 1

                try exec(
                    db,
                    "INSERT INTO posterRoleMembership (posterUUID, roleId, roleSortKey) " +
                    "VALUES (\(uuid), \(role), \(nextSortKey));"
                )

                let now = Date().timeIntervalSinceReferenceDate
                let usagePayload = String(
                    format: "{\"creationDate\":%.6f,\"lastModifiedDate\":%.6f,\"extensionAvailable\":true,\"attributeType\":\"PRPosterRoleAttributeTypeUsageMetadata\"}",
                    now,
                    now
                )

                try exec(
                    db,
                    "INSERT INTO posterAttributes " +
                    "(posterUUID, roleId, attributeIdentifier, attributePayload) VALUES (" +
                    "\(uuid), \(role), 'PRPosterRoleAttributeTypeUsageMetadata', \(quote(usagePayload)));"
                )

                log("    • \(registration.provider) / \(registration.uuid) (sortKey \(nextSortKey))")
            }

            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }

        let integrity = try scalarText(db, "PRAGMA integrity_check;")
        guard integrity.lowercased() == "ok" else {
            throw PosterBoardRegistryError.sqlite("integrity_check: \(integrity)")
        }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
                sqlite3_free(errorMessage)
            } else {
                message = String(cString: sqlite3_errmsg(db))
            }
            throw PosterBoardRegistryError.sqlite(message)
        }
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PosterBoardRegistryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PosterBoardRegistryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw PosterBoardRegistryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw PosterBoardRegistryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

//
//  PosterBoardRecovery.swift
//  AirCard-iOS
//
//  Recovery-only UI for rebuilding a clean PosterBoard registry on iOS 27.
//

import SwiftUI
import Foundation
import SQLite3
import AirliftFFI

enum PosterBoardRecoveryError: LocalizedError {
    case noPairing
    case invalidContainer
    case extract(String)
    case sqlite(String)
    case write(String)
    case verification(String)

    var errorDescription: String? {
        switch self {
        case .noPairing:
            return "No active pairing file. Pair the device first."
        case .invalidContainer:
            return "PosterBoard container could not be detected."
        case .extract(let message):
            return "Could not read PosterBoard data: \(message)"
        case .sqlite(let message):
            return "SQLite error: \(message)"
        case .write(let message):
            return "Could not write PosterBoard data: \(message)"
        case .verification(let message):
            return "Verification failed: \(message)"
        }
    }
}

final class PosterBoardRecoveryEngine {
    static let shared = PosterBoardRecoveryEngine()

    private let registryName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"

    private init() {}

    func makeSnapshot(
        pairingPath: String,
        containerPath: String,
        log: @escaping (String) -> Void
    ) async throws -> [URL] {
        let dataStore = "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/61"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let prefix = "PosterBoard-RESCUE-\(stamp)"

        log("📦 Exporting current PosterBoard registry before reset…")

        let mainPath = "\(dataStore)/\(registryName)"
        let main = try await extractRemoteFile(pairingPath: pairingPath, devicePath: mainPath)
        guard main.count > 100 else {
            throw PosterBoardRecoveryError.extract("registry file is unexpectedly small")
        }

        var urls: [URL] = []
        let mainURL = docs.appendingPathComponent("\(prefix)-registry.sqlite3")
        try main.write(to: mainURL, options: .atomic)
        urls.append(mainURL)
        log("  ✅ Saved \(mainURL.lastPathComponent)")

        for suffix in ["-wal", "-shm"] {
            let remote = mainPath + suffix
            do {
                let data = try await extractRemoteFile(pairingPath: pairingPath, devicePath: remote)
                let local = docs.appendingPathComponent("\(prefix)-registry.sqlite3\(suffix)")
                try data.write(to: local, options: .atomic)
                urls.append(local)
                log("  ✅ Saved \(local.lastPathComponent) (\(data.count) bytes)")
            } catch {
                log("  ℹ️ \(suffix) not available; continuing")
            }
        }

        let noteURL = docs.appendingPathComponent("\(prefix)-README.txt")
        let note = """
PosterBoard recovery snapshot
Created: \(Date())
Container: \(containerPath)
Registry source: \(mainPath)

This snapshot was captured before rebuilding the PosterBoard registry.
"""
        try Data(note.utf8).write(to: noteURL, options: .atomic)
        urls.append(noteURL)

        return urls
    }

    func rebuildCleanRegistry(
        pairingPath: String,
        containerPath: String,
        log: @escaping (String) -> Void
    ) async throws -> [URL] {
        let snapshots = try await makeSnapshot(
            pairingPath: pairingPath,
            containerPath: containerPath,
            log: log
        )

        log("\n🧹 Building a fresh minimal PosterBoard registry…")
        let freshData = try createFreshRegistryData()
        try validateDatabase(data: freshData)
        log("  ✅ Fresh registry integrity_check = ok")

        let dataStore = "\(containerPath)/Library/Application Support/PRBPosterExtensionDataStore/61"
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard_recovery_write_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stageDir) }

        let stagedDB = stageDir.appendingPathComponent(registryName)
        try freshData.write(to: stagedDB, options: .atomic)

        log("📝 Replacing only the central registry with the clean database…")
        try await writeRemoteDirectory(
            pairingPath: pairingPath,
            sourceDirectory: stageDir.path,
            targetDirectory: dataStore
        )

        log("🔎 Reading the registry back for verification…")
        let readBack = try await extractRemoteFile(
            pairingPath: pairingPath,
            devicePath: "\(dataStore)/\(registryName)"
        )
        try validateDatabase(data: readBack)
        log("  ✅ Device registry read-back integrity_check = ok")

        try await writeRefreshPreferences(
            pairingPath: pairingPath,
            containerPath: containerPath
        )
        log("  ✅ PosterBoard refresh preference staged")

        log("\n⚠️ Old unreferenced configuration folders are intentionally left untouched.")
        log("   The clean registry no longer points to them, avoiding risky recursive deletion.")
        log("\n🔄 Requesting a full device restart so PosterBoard can reseed clean state…")
        try await restartDevice(pairingPath: pairingPath)
        log("✅ Restart request sent")

        return snapshots
    }

    private func createFreshRegistryData() throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard_fresh_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let dbURL = dir.appendingPathComponent(registryName)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &db, flags, nil) == SQLITE_OK, let db else {
            throw PosterBoardRecoveryError.sqlite("sqlite3_open_v2 failed")
        }
        defer { sqlite3_close(db) }

        try exec(db, "PRAGMA journal_mode=DELETE;")
        try exec(db, "PRAGMA synchronous=FULL;")
        try exec(db, "PRAGMA foreign_keys=ON;")

        let schema = """
CREATE TABLE "poster" ("posterId" INTEGER PRIMARY KEY AUTOINCREMENT, "UUID" TEXT UNIQUE ON CONFLICT ROLLBACK, "providerId" TEXT NOT NULL ON CONFLICT ROLLBACK);
CREATE TABLE "posterRoles" ("roleIdentifier" TEXT PRIMARY KEY ON CONFLICT ROLLBACK UNIQUE ON CONFLICT ROLLBACK NOT NULL ON CONFLICT ROLLBACK, "displayName" NOT NULL ON CONFLICT ROLLBACK UNIQUE ON CONFLICT ROLLBACK);
CREATE TABLE "posterRoleMembership" ("posterUUID" TEXT NOT NULL ON CONFLICT ROLLBACK, "roleId" TEXT NOT NULL ON CONFLICT ROLLBACK, "roleSortKey" INTEGER NOT NULL, CONSTRAINT posters FOREIGN KEY (posterUUID) REFERENCES poster(UUID) ON DELETE CASCADE, CONSTRAINT roles FOREIGN KEY (roleId) REFERENCES posterRoles(roleIdentifier) ON DELETE CASCADE);
CREATE TABLE "posterMetadata" ("key" TEXT NOT NULL ON CONFLICT ROLLBACK UNIQUE ON CONFLICT ROLLBACK PRIMARY KEY, "value" TEXT NOT NULL ON CONFLICT ROLLBACK);
CREATE TABLE "posterAttributes" ("posterUUID" TEXT NOT NULL ON CONFLICT ROLLBACK, "roleId" TEXT NOT NULL ON CONFLICT ROLLBACK, "attributeIdentifier" TEXT NOT NULL ON CONFLICT ROLLBACK, "attributePayload" TEXT NOT NULL ON CONFLICT ROLLBACK, CONSTRAINT posters FOREIGN KEY (posterUUID) REFERENCES poster(UUID) ON DELETE CASCADE, CONSTRAINT roles FOREIGN KEY (roleId) REFERENCES posterRoles(roleIdentifier) ON DELETE CASCADE, UNIQUE (posterUUID, roleID, attributeIdentifier));
INSERT INTO posterRoles VALUES ('PRPosterRoleLockScreen','Lock Screen');
INSERT INTO posterRoles VALUES ('PRPosterRoleAmbient','PRPosterRoleAmbient');
INSERT INTO posterMetadata VALUES ('version','2');
INSERT INTO posterMetadata VALUES ('deviceClass','0');
"""
        try exec(db, schema)
        try exec(db, "PRAGMA user_version=2;")

        let integrity = try scalarText(db, "PRAGMA integrity_check;")
        guard integrity.lowercased() == "ok" else {
            throw PosterBoardRecoveryError.sqlite("fresh registry integrity_check: \(integrity)")
        }

        sqlite3_close(db)
        return try Data(contentsOf: dbURL)
    }

    private func validateDatabase(data: Data) throws {
        guard data.count > 100,
              String(decoding: data.prefix(16), as: UTF8.self).hasPrefix("SQLite format 3") else {
            throw PosterBoardRecoveryError.verification("not a valid SQLite database")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard_verify_\(UUID().uuidString).sqlite3")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw PosterBoardRecoveryError.sqlite("could not open verification copy")
        }
        defer { sqlite3_close(db) }

        let integrity = try scalarText(db, "PRAGMA integrity_check;")
        guard integrity.lowercased() == "ok" else {
            throw PosterBoardRecoveryError.verification("integrity_check: \(integrity)")
        }

        for table in ["poster", "posterRoles", "posterRoleMembership", "posterMetadata", "posterAttributes"] {
            let count = try scalarInt64(
                db,
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(table)';"
            )
            guard count == 1 else {
                throw PosterBoardRecoveryError.verification("missing required table \(table)")
            }
        }
    }

    private func writeRefreshPreferences(
        pairingPath: String,
        containerPath: String
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posterboard_recovery_pref_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plist: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": false,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp"
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try data.write(
            to: dir.appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist"),
            options: .atomic
        )

        try await writeRemoteDirectory(
            pairingPath: pairingPath,
            sourceDirectory: dir.path,
            targetDirectory: "\(containerPath)/Library/Preferences"
        )
    }

    private func extractRemoteFile(
        pairingPath: String,
        devicePath: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outData: UnsafeMutablePointer<UInt8>?
                var outLen: Int = 0
                var outError: UnsafeMutablePointer<CChar>?

                let rc = pairingPath.withCString { pairC in
                    devicePath.withCString { pathC in
                        al_airlift_extract(pairC, pathC, nil, nil, &outData, &outLen, &outError)
                    }
                }

                let errorText = outError.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }

                guard rc == 0, let ptr = outData else {
                    continuation.resume(
                        throwing: PosterBoardRecoveryError.extract(
                            errorText ?? "AirLift extract returned code \(rc)"
                        )
                    )
                    return
                }

                let data = Data(bytes: ptr, count: outLen)
                al_afc_free_bytes(ptr, outLen)
                continuation.resume(returning: data)
            }
        }
    }

    private func writeRemoteDirectory(
        pairingPath: String,
        sourceDirectory: String,
        targetDirectory: String
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>?
                let rc = pairingPath.withCString { pairC in
                    sourceDirectory.withCString { sourceC in
                        targetDirectory.withCString { targetC in
                            al_exploit_write_dir(
                                pairC,
                                sourceC,
                                targetC,
                                nil,
                                nil,
                                &outError
                            )
                        }
                    }
                }

                let errorText = outError.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }

                if rc == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: PosterBoardRecoveryError.write(
                            errorText ?? "AirLift write returned code \(rc)"
                        )
                    )
                }
            }
        }
    }

    private func restartDevice(pairingPath: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>?
                let rc = pairingPath.withCString { pairC in
                    al_device_respring(pairC, nil, nil, &outError)
                }

                let errorText = outError.map { ptr -> String in
                    let value = String(cString: ptr)
                    al_string_free(ptr)
                    return value
                }

                if rc == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(
                        throwing: PosterBoardRecoveryError.write(
                            errorText ?? "Restart request returned code \(rc)"
                        )
                    )
                }
            }
        }
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message: String
            if let errorMessage {
                message = String(cString: errorMessage)
                sqlite3_free(errorMessage)
            } else {
                message = String(cString: sqlite3_errmsg(db))
            }
            throw PosterBoardRecoveryError.sqlite(message)
        }
    }

    private func scalarText(_ db: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PosterBoardRecoveryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else {
            throw PosterBoardRecoveryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
    }

    private func scalarInt64(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw PosterBoardRecoveryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw PosterBoardRecoveryError.sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}

struct RecoveryRootView: View {
    var body: some View {
        TabView {
            PairingTab()
                .tabItem {
                    Label("Pairing", systemImage: "antenna.radiowaves.left.and.right")
                }

            PosterBoardRecoveryView()
                .tabItem {
                    Label("Recovery", systemImage: "lifepreserver.fill")
                }
        }
    }
}

struct PosterBoardRecoveryView: View {
    @EnvironmentObject private var vm: AppViewModel

    @State private var logLines: [String] = []
    @State private var running = false
    @State private var showResetConfirmation = false
    @State private var snapshotURLs: [URL] = []
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("PosterBoard Recovery", systemImage: "lifepreserver.fill")
                        .font(.headline)
                    Text("Recovery build only. It does not install .tendies wallpapers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Before running") {
                    Text("Close Settings and leave the Lock Screen wallpaper editor before using recovery.")
                    Text("A rescue copy of the current registry is required before the reset is allowed.")
                        .foregroundStyle(.secondary)
                }

                Section("Recovery") {
                    Button {
                        Task { await exportSnapshot() }
                    } label: {
                        Label("Export Current Registry Snapshot", systemImage: "square.and.arrow.up")
                    }
                    .disabled(running)

                    Button(role: .destructive) {
                        showResetConfirmation = true
                    } label: {
                        Label("Rebuild Clean PosterBoard Registry", systemImage: "arrow.counterclockwise.circle.fill")
                    }
                    .disabled(running)

                    if running {
                        HStack {
                            ProgressView()
                            Text("Working…")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("This replaces the central PosterBoard registry with a clean minimal database, verifies it, stages refresh preferences, then requests a full device restart. Existing unreferenced wallpaper folders are left on disk but are no longer registered.")
                }

                if !logLines.isEmpty {
                    Section {
                        CompactLogView(
                            title: "Recovery Log (\(logLines.count) lines)",
                            lines: logLines,
                            onClear: { logLines.removeAll() }
                        )
                    }
                }
            }
            .navigationTitle("PosterBoard Recovery")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Rebuild PosterBoard registry?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Rebuild & Restart", role: .destructive) {
                    Task { await rebuild() }
                }
            } message: {
                Text("This removes all current PosterBoard registry entries. The device will restart after the new registry passes verification.")
            }
            .sheet(isPresented: $showShare) {
                ShareSheet(items: snapshotURLs)
            }
        }
    }

    @MainActor
    private func append(_ line: String) {
        logLines.append(line)
    }

    private func resolveContext() async throws -> (String, String) {
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw PosterBoardRecoveryError.noPairing
        }

        let container = try await TendiesEngine.shared.detectPosterBoardContainer(
            pairingPath: pairingPath
        )
        guard !container.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PosterBoardRecoveryError.invalidContainer
        }
        return (pairingPath, container)
    }

    private func exportSnapshot() async {
        await MainActor.run {
            running = true
            logLines = []
        }
        defer {
            Task { @MainActor in running = false }
        }

        do {
            let (pairingPath, container) = try await resolveContext()
            await MainActor.run {
                append("📍 PosterBoard: \(container)")
            }

            let urls = try await PosterBoardRecoveryEngine.shared.makeSnapshot(
                pairingPath: pairingPath,
                containerPath: container,
                log: { line in
                    DispatchQueue.main.async { append(line) }
                }
            )

            await MainActor.run {
                snapshotURLs = urls
                append("✅ Snapshot complete. Opening share sheet…")
                showShare = true
            }
        } catch {
            await MainActor.run {
                append("❌ \(error.localizedDescription)")
            }
        }
    }

    private func rebuild() async {
        await MainActor.run {
            running = true
            logLines = []
        }
        defer {
            Task { @MainActor in running = false }
        }

        do {
            let (pairingPath, container) = try await resolveContext()
            await MainActor.run {
                append("📍 PosterBoard: \(container)")
            }

            _ = try await PosterBoardRecoveryEngine.shared.rebuildCleanRegistry(
                pairingPath: pairingPath,
                containerPath: container,
                log: { line in
                    DispatchQueue.main.async { append(line) }
                }
            )
        } catch {
            await MainActor.run {
                append("❌ \(error.localizedDescription)")
            }
        }
    }
}

//
//  TendiesEngine.swift
//  AirCard-iOS
//
//  Engine for parsing, extracting, and flashing PosterBoard .tendies wallpapers.
//

import UIKit
import Foundation
import AirliftFFI

public final class TendiesEngine {
    public static let shared = TendiesEngine()

    public static var tendiesStorageDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tendies", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Import & Parse

    public func importTendie(from sourceURL: URL) async throws -> TendieItem {
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = sourceURL.lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let destinationURL = Self.tendiesStorageDirectory.appendingPathComponent(fileName)

        if sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                let fileData = try Data(contentsOf: sourceURL)
                try fileData.write(to: destinationURL, options: .atomic)
            }
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NSError(
                domain: "TendiesEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to store wallpaper file at \(destinationURL.path)"]
            )
        }

        // Staging extraction to inspect contents
        let tempExtractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_inspect_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempExtractDir)
        }

        let extractRC = destinationURL.path.withCString { arcC in
            tempExtractDir.path.withCString { dstC in
                al_zip_extract_all(arcC, dstC)
            }
        }

        guard extractRC == 0 else {
            throw NSError(
                domain: "TendiesEngine",
                code: Int(extractRC),
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract .tendies zip archive (code \(extractRC))"]
            )
        }

        // Analyze file structure
        var isContainer = false
        var unsafeContainer = false
        var descriptorCount = 0
        var posterType: TendiePosterType = .collections

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: tempExtractDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var candidateImages: [(url: URL, score: Int)] = []

        while let itemURL = enumerator?.nextObject() as? URL {
            let pathLower = itemURL.path.lowercased()
            let nameLower = itemURL.lastPathComponent.lowercased()

            if pathLower.contains("__macosx") || nameLower == ".ds_store" {
                continue
            }

            if pathLower.contains("/container/") || pathLower.hasSuffix("/container") {
                isContainer = true
                posterType = .container
                if nameLower.contains("pbfposterextensiondatastoresqlitedatabase.sqlite3") {
                    unsafeContainer = true
                }
            }

            if pathLower.contains("descriptor") || pathLower.contains("descriptors") {
                if pathLower.contains("video") || pathLower.contains("photos") {
                    posterType = .suggestedPhotos
                } else if pathLower.contains("mercury") {
                    posterType = .mercury
                } else if posterType != .container {
                    posterType = .collections
                }
            }

            // Count descriptors by finding .wallpaper or sub-descriptor folders
            if nameLower.hasSuffix(".wallpaper") || nameLower == "wallpaper.plist" {
                descriptorCount += 1
            }

            // Image discovery
            let ext = itemURL.pathExtension.lowercased()
            if ["heic", "png", "jpg", "jpeg"].contains(ext) {
                var score = 10
                if pathLower.contains("proxy") || pathLower.contains("adjusted") {
                    score += 90
                } else if pathLower.contains("background") || pathLower.contains("settling") {
                    score += 70
                } else if pathLower.contains("preview") || pathLower.contains("thumb") {
                    score += 50
                } else if pathLower.contains("asset.resource") {
                    score += 40
                }
                candidateImages.append((itemURL, score))
            }
        }

        if descriptorCount == 0 {
            descriptorCount = 1
        }

        // Pick best preview image
        candidateImages.sort { $0.score > $1.score }
        var previewData: Data? = nil

        for candidate in candidateImages {
            if let img = UIImage(contentsOfFile: candidate.url.path) {
                let thumb = self.downsample(image: img, maxDimension: 600)
                if let jpeg = thumb.jpegData(compressionQuality: 0.85) {
                    previewData = jpeg
                    break
                }
            }
        }

        return TendieItem(
            name: baseName,
            fileName: fileName,
            relativePath: fileName,
            isContainer: isContainer,
            unsafeContainer: unsafeContainer,
            descriptorCount: descriptorCount,
            posterType: posterType,
            previewImageData: previewData,
            dateImported: Date(),
            isSelected: true
        )
    }

    // MARK: - Downsample Thumbnail

    private func downsample(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Auto-detect PosterBoard Container

    public func detectPosterBoardContainer(pairingPath: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outContainer: UnsafeMutablePointer<CChar>? = nil
                var outError: UnsafeMutablePointer<CChar>? = nil

                let rc = pairingPath.withCString { pairC in
                    "com.apple.PosterBoard".withCString { bundleC in
                        al_find_app_container(pairC, bundleC, nil, nil, &outContainer, &outError)
                    }
                }

                if rc == 0, let p = outContainer {
                    let containerStr = String(cString: p)
                    al_string_free(p)
                    continuation.resume(returning: containerStr)
                } else {
                    let errStr = outError.flatMap { p in
                        let s = String(cString: p)
                        al_string_free(p)
                        return s
                    } ?? "Failed to find PosterBoard container"
                    continuation.resume(throwing: NSError(
                        domain: "TendiesEngine",
                        code: Int(rc),
                        userInfo: [NSLocalizedDescriptionKey: errStr]
                    ))
                }
            }
        }
    }

    // MARK: - Send Respring Signal via Tunnel

    public func sendRespringSignal(pairingPath: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pC in
                    al_device_respring(pC, nil, nil, &outError)
                }
                if let p = outError {
                    al_string_free(p)
                }
                continuation.resume(returning: rc == 0)
            }
        }
    }

    // MARK: - Flash Tendies to Device

    public func flashTendies(
        items: [TendieItem],
        containerPath: String,
        resetProtections: Bool,
        pairingPath: String,
        log: @escaping (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !items.isEmpty else {
            log("⚠️ No wallpapers selected to flash")
            return
        }

        var normalizedContainer = containerPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedContainer.hasSuffix("/") {
            normalizedContainer = String(normalizedContainer.dropLast())
        }
        if normalizedContainer.isEmpty {
            throw NSError(
                domain: "TendiesEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PosterBoard Container path is required."]
            )
        }

        let majorVer = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let structVersion = (majorVer <= 16) ? 59 : 61
        let useConfigurations = majorVer >= 27

        log("🚀 Starting PosterBoard injection into \(normalizedContainer)")
        log("ℹ️ Target PosterBoard structure version: \(structVersion) (iOS \(majorVer))")
        if useConfigurations {
            log("ℹ️ iOS 27 mode: configurations + central PosterBoard registry")
        }

        let totalItems = Double(items.count)
        var registrations: [PosterBoardRegistration] = []

        for (itemIndex, item) in items.enumerated() {
            log("\n📦 [\(itemIndex + 1)/\(items.count)] Processing '\(item.name)'…")

            let tempStageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tendie_flash_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempStageDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempStageDir)
            }

            let extractRC = item.fileURL.path.withCString { arcC in
                tempStageDir.path.withCString { dstC in
                    al_zip_extract_all(arcC, dstC)
                }
            }
            guard extractRC == 0 else {
                log("❌ Failed to extract '\(item.name)'")
                continue
            }

            log("  🖼 Locating wallpaper descriptors/configurations…")
            let descriptors = findDescriptorsWithExtensions(
                in: tempStageDir,
                defaultExt: item.posterType.extensionBundleId
            )
            log("  ✨ Found \(descriptors.count) wallpaper item(s) to install")

            for (descIndex, descItem) in descriptors.enumerated() {
                let targetUUID = UUID().uuidString.uppercased()
                let randomizedID = Int.random(in: 10000...99999)
                let provider = inferProvider(in: descItem.url, fallback: descItem.ext)

                if useConfigurations {
                    let descriptorID = try prepareConfiguration(
                        in: descItem.url,
                        fallbackID: randomizedID
                    )
                    log(
                        "  [\(descIndex + 1)/\(descriptors.count)] Configuration \(targetUUID) " +
                        "(descriptor: \(descriptorID)) for \(provider)…"
                    )

                    let targetParentDir =
                        "\(normalizedContainer)/Library/Application Support/" +
                        "PRBPosterExtensionDataStore/\(structVersion)/Extensions/" +
                        "\(provider)/configurations"

                    try await injectDescriptorFolder(
                        folderURL: descItem.url,
                        targetParentDir: targetParentDir,
                        destName: targetUUID,
                        pairingPath: pairingPath,
                        log: log
                    )

                    registrations.append(
                        PosterBoardRegistration(
                            uuid: targetUUID,
                            provider: provider
                        )
                    )
                } else {
                    log(
                        "  [\(descIndex + 1)/\(descriptors.count)] Descriptor \(targetUUID) " +
                        "(ID: \(randomizedID)) for \(provider)…"
                    )

                    updatePlistIdentifiers(in: descItem.url, randomizedID: randomizedID)

                    let targetParentDir =
                        "\(normalizedContainer)/Library/Application Support/" +
                        "PRBPosterExtensionDataStore/\(structVersion)/Extensions/" +
                        "\(provider)/descriptors"

                    try await injectDescriptorFolder(
                        folderURL: descItem.url,
                        targetParentDir: targetParentDir,
                        destName: targetUUID,
                        pairingPath: pairingPath,
                        log: log
                    )
                }
            }

            progress(Double(itemIndex + 1) / (totalItems + 1))
        }

        if useConfigurations && !registrations.isEmpty {
            try await PosterBoardRegistry.shared.register(
                registrations: registrations,
                containerPath: normalizedContainer,
                structureVersion: structVersion,
                pairingPath: pairingPath,
                log: log
            )
        }

        // Force PosterBoard to reload its store after both configuration files
        // and the central registry have been updated.
        log("\n🔄 Forcing PosterBoard cache refresh and file protections reset…")
        let stagePrefDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_pref_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagePrefDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagePrefDir)
        }

        let prefPlistURL = stagePrefDir
            .appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist")
        let prefDict: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": false,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp"
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
            ]
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: prefDict,
            format: .binary,
            options: 0
        )
        try plistData.write(to: prefPlistURL)

        let targetPrefDir = "\(normalizedContainer)/Library/Preferences"
        try await writeDirectoryTree(
            sourceBaseDir: stagePrefDir,
            targetBaseDir: targetPrefDir,
            pairingPath: pairingPath,
            log: log
        )

        // Also write to mobile global preferences for daemon lookup.
        let mobilePrefDir = "/var/mobile/Library/Preferences"
        try? await writeDirectoryTree(
            sourceBaseDir: stagePrefDir,
            targetBaseDir: mobilePrefDir,
            pairingPath: pairingPath,
            log: log
        )
        log("✅ PosterBoard preferences staged for reload")

        progress(1.0)
        log(
            "\n🎉 Wallpapers injected and registered successfully. " +
            "After NeoSpring, open Lock Screen settings or long-press the Lock Screen."
        )
    }

    // MARK: - Tree Writer Helper

    private func writeDirectoryTree(
        sourceBaseDir: URL,
        targetBaseDir: String,
        pairingPath: String,
        log: @escaping (String) -> Void
    ) async throws {
        let fileManager = FileManager.default

        // Gather all directories that contain files
        var dirsToWrite: Set<URL> = []
        if let enumerator = fileManager.enumerator(
            at: sourceBaseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let itemURL = enumerator.nextObject() as? URL {
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir {
                    dirsToWrite.insert(itemURL.deletingLastPathComponent())
                }
            }
        }

        // If no subfiles, write the source dir itself if not empty
        if dirsToWrite.isEmpty {
            let files = (try? fileManager.contentsOfDirectory(atPath: sourceBaseDir.path)) ?? []
            if !files.isEmpty {
                dirsToWrite.insert(sourceBaseDir)
            }
        }

        let canonicalSource = sourceBaseDir.resolvingSymlinksInPath().path

        for dir in dirsToWrite {
            let canonicalDir = dir.resolvingSymlinksInPath().path
            var relPath = ""
            if canonicalDir.hasPrefix(canonicalSource) {
                relPath = String(canonicalDir.dropFirst(canonicalSource.count))
                relPath = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            let targetDir: String
            if relPath.isEmpty {
                targetDir = targetBaseDir
            } else {
                targetDir = "\(targetBaseDir)/\(relPath)"
            }

            log("  Writing to \(targetDir)…")

            var writeOk = false
            var errDesc: String? = nil

            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    var outError: UnsafeMutablePointer<CChar>? = nil
                    let rc = pairingPath.withCString { pairC in
                        dir.path.withCString { srcC in
                            targetDir.withCString { tgtC in
                                al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                    guard let msg = msg else { return }
                                    let line = String(cString: msg)
                                    DispatchQueue.main.async {
                                        AppViewModel.shared?.tendiesFlashLog.append("    " + line)
                                    }
                                }, nil, &outError)
                            }
                        }
                    }
                    if let p = outError {
                        errDesc = String(cString: p)
                        al_string_free(p)
                    }
                    writeOk = (rc == 0)
                    cont.resume()
                }
            }

            if !writeOk {
                throw NSError(
                    domain: "TendiesEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to write directory: \(errDesc ?? "exploit error")"]
                )
            }
        }
    }

    // MARK: - iOS 27 Configuration Preparation

    private func prepareConfiguration(in folderURL: URL, fallbackID: Int) throws -> String {
        let fileManager = FileManager.default
        let roleURL = folderURL.appendingPathComponent("com.apple.posterkit.role.identifier")
        let descriptorURL = folderURL
            .appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")

        let role: String = {
            if let value = try? String(contentsOf: roleURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
            return "PRPosterRoleLockScreen"
        }()

        let descriptorID = deriveDescriptorIdentifier(
            in: folderURL,
            fallbackID: fallbackID
        )

        try Data(role.utf8).write(to: roleURL, options: .atomic)
        try Data(descriptorID.utf8).write(to: descriptorURL, options: .atomic)
        return descriptorID
    }

    private func deriveDescriptorIdentifier(in folderURL: URL, fallbackID: Int) -> String {
        let directURL = folderURL
            .appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")

        if let value = try? String(contentsOf: directURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return value
        }

        if let metadataID = descriptorIdentifierFromSuggestionMetadata(in: folderURL) {
            return metadataID
        }

        let fileManager = FileManager.default
        if let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let url = enumerator.nextObject() as? URL {
                let name = url.lastPathComponent

                if name.hasSuffix("Wallpaper.plist"),
                   let data = try? Data(contentsOf: url),
                   let object = try? PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                   ),
                   let plist = object as? [String: Any] {
                    if let id = plist["identifier"] as? Int {
                        return String(id)
                    }
                    if let id = plist["identifier"] as? NSNumber {
                        return id.stringValue
                    }
                    if let id = plist["identifier"] as? String, !id.isEmpty {
                        return id
                    }
                }

                if url.pathExtension.lowercased() == "wallpaper" {
                    let prefix = name.split(separator: ".").first.map(String.init) ?? ""
                    if !prefix.isEmpty {
                        return prefix
                    }
                }
            }
        }

        return String(fallbackID)
    }

    private func descriptorIdentifierFromSuggestionMetadata(in folderURL: URL) -> String? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent ==
                    "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist",
                  let data = try? Data(contentsOf: url),
                  let object = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) else {
                continue
            }

            let strings = collectStrings(in: object)
            for value in strings {
                let prefix = value.split(separator: ".").first.map(String.init) ?? value
                if prefix.count >= 3 && prefix.allSatisfy({ $0.isNumber }) {
                    return prefix
                }
            }
        }

        return nil
    }

    private func collectStrings(in object: Any) -> [String] {
        if let string = object as? String {
            return [string]
        }
        if let array = object as? [Any] {
            return array.flatMap { collectStrings(in: $0) }
        }
        if let dict = object as? [String: Any] {
            return Array(dict.keys) + dict.values.flatMap { collectStrings(in: $0) }
        }
        return []
    }

    private func inferProvider(in folderURL: URL, fallback: String) -> String {
        if let metadataProvider = providerFromSuggestionMetadata(in: folderURL) {
            return metadataProvider
        }

        let lower = folderURL.path.lowercased()
        if lower.contains("com.apple.mercuryposter") || lower.contains("mercury") {
            return "com.apple.MercuryPoster"
        }
        if lower.contains("photosposterprovider") ||
           lower.contains("video-descriptor") ||
           lower.contains("video-descriptors") {
            return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
        }
        if lower.contains("collectionsposter") {
            return "com.apple.WallpaperKit.CollectionsPoster"
        }

        if fallback == "com.apple.PosterBoard" {
            return "com.apple.WallpaperKit.CollectionsPoster"
        }
        return fallback
    }

    private func providerFromSuggestionMetadata(in folderURL: URL) -> String? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent ==
                    "com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist",
                  let data = try? Data(contentsOf: url),
                  let object = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) else {
                continue
            }

            if let provider = findProviderString(in: object) {
                return provider
            }
        }

        return nil
    }

    private func findProviderString(in object: Any) -> String? {
        if let string = object as? String,
           string.hasPrefix("com.apple."),
           string.contains("Poster") {
            return string
        }

        if let array = object as? [Any] {
            for value in array {
                if let result = findProviderString(in: value) {
                    return result
                }
            }
        }

        if let dict = object as? [String: Any] {
            for value in dict.values {
                if let result = findProviderString(in: value) {
                    return result
                }
            }
        }

        return nil
    }

    // MARK: - Plist Identifier Randomization (Matches Nugget implementation)

    private func updatePlistIdentifiers(in folderURL: URL, randomizedID: Int) {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        while let fileURL = enumerator.nextObject() as? URL {
            let fileName = fileURL.lastPathComponent

            if fileName == "com.apple.posterkit.provider.descriptor.identifier" {
                try? "\(randomizedID)".data(using: .utf8)?.write(to: fileURL)
            } else if fileName == "com.apple.posterkit.provider.contents.userInfo" {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any] {
                    plist["wallpaperRepresentingIdentifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
            } else if fileName.hasSuffix("Wallpaper.plist") {
                if let data = try? Data(contentsOf: fileURL),
                   var plist = (try? PropertyListSerialization.propertyList(from: data, options: .mutableContainers, format: nil)) as? [String: Any] {
                    plist["identifier"] = randomizedID
                    if let updated = try? PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0) {
                        try? updated.write(to: fileURL)
                    }
                }
            }
        }
    }

    // MARK: - Folder Injector Helper (Single Atomic Move via AirTraffic)

    private func injectDescriptorFolder(
        folderURL: URL,
        targetParentDir: String,
        destName: String,
        pairingPath: String,
        log: @escaping (String) -> Void
    ) async throws {
        log("  📦 Injecting '\(destName)' into \(targetParentDir)…")
        var errDesc: String? = nil
        let ok: Bool = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairC in
                    folderURL.path.withCString { folderC in
                        targetParentDir.withCString { parentC in
                            destName.withCString { destC in
                                al_exploit_inject_folder(
                                    pairC,
                                    folderC,
                                    parentC,
                                    destC,
                                    { _, msg in
                                        guard let msg = msg else { return }
                                        let line = String(cString: msg)
                                        DispatchQueue.main.async {
                                            AppViewModel.shared?.tendiesFlashLog.append("    " + line)
                                        }
                                    },
                                    nil,
                                    &outError
                                )
                            }
                        }
                    }
                }
                if let p = outError {
                    errDesc = String(cString: p)
                    al_string_free(p)
                }
                cont.resume(returning: rc == 0)
            }
        }

        if !ok {
            throw NSError(
                domain: "TendiesEngine",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to inject descriptor: \(errDesc ?? "exploit error")"]
            )
        }
    }

    // MARK: - Find Descriptors With Targeted Extensions

    private func findDescriptorsWithExtensions(
        in rootURL: URL,
        defaultExt: String
    ) -> [(ext: String, url: URL)] {
        let fileManager = FileManager.default
        let recognizedFolders: Set<String> = [
            "descriptors",
            "descriptor",
            "ordered-descriptors",
            "ordered-descriptor",
            "video-descriptors",
            "video-descriptor",
            "configurations"
        ]

        var results: [(ext: String, url: URL)] = []
        var seenPaths = Set<String>()

        func providerForContainer(_ container: URL) -> String {
            let components = container.pathComponents
            if let index = components.lastIndex(of: "Extensions"),
               index + 1 < components.count {
                let candidate = components[index + 1]
                if candidate.hasPrefix("com.apple.") {
                    return candidate
                }
            }

            let lower = container.path.lowercased()
            if lower.contains("mercury") {
                return "com.apple.MercuryPoster"
            }
            if lower.contains("video") || lower.contains("photos") {
                return "com.apple.PhotosUIPrivate.PhotosPosterProvider"
            }
            if defaultExt == "com.apple.PosterBoard" {
                return "com.apple.WallpaperKit.CollectionsPoster"
            }
            return defaultExt
        }

        if let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let directory = enumerator.nextObject() as? URL {
                let isDirectory =
                    (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDirectory else { continue }

                let folderName = directory.lastPathComponent.lowercased()
                guard recognizedFolders.contains(folderName) else { continue }

                let provider = providerForContainer(directory)
                let children = (try? fileManager.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []

                var addedChild = false
                for child in children {
                    let childIsDirectory =
                        (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard childIsDirectory,
                          !child.lastPathComponent.hasPrefix("."),
                          child.lastPathComponent != "__MACOSX" else {
                        continue
                    }

                    let canonical = child.standardizedFileURL.path
                    if seenPaths.insert(canonical).inserted {
                        results.append((ext: provider, url: child))
                    }
                    addedChild = true
                }

                // Some hand-made packages put the descriptor contents directly
                // inside a singular descriptor folder rather than under a UUID.
                if !addedChild,
                   fileManager.fileExists(
                    atPath: directory.appendingPathComponent("versions").path
                   ) {
                    let canonical = directory.standardizedFileURL.path
                    if seenPaths.insert(canonical).inserted {
                        results.append((ext: provider, url: directory))
                    }
                }
            }
        }

        if !results.isEmpty {
            return results
        }

        // Single-descriptor packages can place the descriptor at the archive root.
        if fileManager.fileExists(atPath: rootURL.appendingPathComponent("versions").path) ||
           fileManager.fileExists(
                atPath: rootURL
                    .appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier")
                    .path
           ) {
            return [(ext: inferProvider(in: rootURL, fallback: defaultExt), url: rootURL)]
        }

        // Last resort: find immediate folders that look like descriptor roots.
        let topLevel = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for sub in topLevel {
            let isDirectory =
                (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }

            let hasVersions = fileManager.fileExists(
                atPath: sub.appendingPathComponent("versions").path
            )
            let isUUID = UUID(uuidString: sub.lastPathComponent) != nil
            if hasVersions || isUUID {
                results.append(
                    (ext: inferProvider(in: sub, fallback: defaultExt), url: sub)
                )
            }
        }

        if results.isEmpty {
            return [(ext: inferProvider(in: rootURL, fallback: defaultExt), url: rootURL)]
        }
        return results
    }

}

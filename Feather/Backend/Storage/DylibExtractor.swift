//
//  DylibExtractionError.swift
//  Feather
//
//  Created by David Wojcik III on 10/7/25.
//

import Foundation
import Zip

enum DylibExtractionError: Error {
    case invalidIPA
    case extractionFailed
    case noPayloadFound
    case fileAccessError
    case invalidAppBundle
}

class DylibExtractor {
    
    /// Extract all dylibs from an IPA file or .app bundle
    static func extractDylibs(from url: URL, appFolderName: String = "Default") async throws -> [DylibInfo] {
        // Check if it's a .app bundle or .ipa file
        if url.pathExtension.lowercased() == "app" {
            return try await extractDylibsFromAppBundle(url, appFolderName: appFolderName)
        } else if url.pathExtension.lowercased() == "ipa" {
            return try await extractDylibsFromIPA(url, appFolderName: appFolderName)
        } else {
            throw DylibExtractionError.invalidAppBundle
        }
    }
    
    /// Extract dylibs directly from an already-extracted .app bundle
    private static func extractDylibsFromAppBundle(_ appBundle: URL, appFolderName: String) async throws -> [DylibInfo] {
        var dylibs: [DylibInfo] = []
        
        guard FileManager.default.fileExists(atPath: appBundle.path) else {
            throw DylibExtractionError.invalidAppBundle
        }
        
        // Recursively search for dylibs in the app bundle
        let enumerator = FileManager.default.enumerator(
            at: appBundle,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let path = fileURL.path
            let relativePath = fileURL.path.replacingOccurrences(
                of: appBundle.path + "/",
                with: ""
            )
            
            // Check if it's a dylib
            let isDylib = fileURL.pathExtension == "dylib" ||
                         (path.contains(".framework/") &&
                          !path.hasSuffix("/") &&
                          fileURL.lastPathComponent == fileURL.deletingPathExtension().lastPathComponent)
            
            guard isDylib else { continue }
            
            // Get file size
            let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard let isRegularFile = resourceValues?.isRegularFile, isRegularFile else { continue }
            let fileSize = resourceValues?.fileSize ?? 0
            
            // Create permanent location in app's Documents/ExtractedDylibs/AppName
            let dylibsDir = FileManager.default.urls(for: .documentDirectory,
                                                    in: .userDomainMask)[0]
                .appendingPathComponent("ExtractedDylibs")
                .appendingPathComponent(appFolderName)
            
            try FileManager.default.createDirectory(at: dylibsDir,
                                                   withIntermediateDirectories: true)
            
            let fileName = fileURL.lastPathComponent
            let permanentURL = dylibsDir.appendingPathComponent(fileName)
            
            // Copy to permanent location
            if FileManager.default.fileExists(atPath: permanentURL.path) {
                try FileManager.default.removeItem(at: permanentURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: permanentURL)
            
            let dylibInfo = DylibInfo(
                name: fileName,
                originalPath: appBundle.lastPathComponent + "/" + relativePath,
                size: Int64(fileSize),
                extractedURL: permanentURL
            )
            
            dylibs.append(dylibInfo)
        }
        
        return dylibs
    }
    
    /// Extract all dylibs from an IPA file
    private static func extractDylibsFromIPA(_ ipaURL: URL, appFolderName: String) async throws -> [DylibInfo] {
        var dylibs: [DylibInfo] = []
        
        // Create temporary directory for extraction
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        
        try FileManager.default.createDirectory(at: tempDir,
                                               withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        // Unzip the IPA to temp directory
        do {
            try Zip.unzipFile(ipaURL, destination: tempDir, overwrite: true, password: nil)
        } catch {
            throw DylibExtractionError.invalidIPA
        }
        
        // Find the .app bundle in Payload
        let payloadDir = tempDir.appendingPathComponent("Payload")
        guard FileManager.default.fileExists(atPath: payloadDir.path) else {
            throw DylibExtractionError.noPayloadFound
        }
        
        let payloadContents = try FileManager.default.contentsOfDirectory(
            at: payloadDir,
            includingPropertiesForKeys: nil
        )
        
        guard let appBundle = payloadContents.first(where: { $0.pathExtension == "app" }) else {
            throw DylibExtractionError.noPayloadFound
        }
        
        // Use the common extraction method
        return try await extractDylibsFromAppBundle(appBundle, appFolderName: appFolderName)
    }
    
    /// Get all previously extracted dylibs
    static func getExtractedDylibs() throws -> [DylibInfo] {
        let dylibsDir = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask)[0]
            .appendingPathComponent("ExtractedDylibs")
        
        guard FileManager.default.fileExists(atPath: dylibsDir.path) else {
            return []
        }
        
        let files = try FileManager.default.contentsOfDirectory(
            at: dylibsDir,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        
        return try files.compactMap { url in
            guard url.pathExtension == "dylib" ||
                  !url.pathExtension.isEmpty else {
                return nil
            }
            
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            let size = Int64(resourceValues.fileSize ?? 0)
            
            return DylibInfo(
                name: url.lastPathComponent,
                originalPath: url.lastPathComponent,
                size: size,
                extractedURL: url
            )
        }
    }
    
    /// Delete an extracted dylib
    static func deleteDylib(_ info: DylibInfo) throws {
        guard let url = info.extractedURL else { return }
        try FileManager.default.removeItem(at: url)
    }
}

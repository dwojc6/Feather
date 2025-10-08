//
//  LibraryAppIconView.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import SwiftUI
import NimbleExtensions
import NimbleViews

// MARK: - View
struct LibraryCellView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.editMode) private var editMode

    var certInfo: Date.ExpirationInfo? {
        Storage.shared.getCertificate(from: app)?.expiration?.expirationInfo()
    }
    
    var certRevoked: Bool {
        Storage.shared.getCertificate(from: app)?.revoked == true
    }
    
    var app: AppInfoPresentable
    @Binding var selectedInfoAppPresenting: AnyApp?
    @Binding var selectedSigningAppPresenting: AnyApp?
    @Binding var selectedInstallAppPresenting: AnyApp?
    @Binding var selectedAppUUIDs: Set<String>
    
    // Dylib picker state
    @State private var dylibPickerData: DylibPickerData?
    
    struct DylibPickerData: Identifiable {
        let id = UUID()
        var extractedDylibs: [DylibInfo]
        var selectedDylibs: Set<UUID>
        var appName: String
        var extractionFolder: URL
    }
    
    // MARK: Selections
    private var _isSelected: Bool {
        guard let uuid = app.uuid else { return false }
        return selectedAppUUIDs.contains(uuid)
    }
    
    private func _toggleSelection() {
        guard let uuid = app.uuid else { return }
        if selectedAppUUIDs.contains(uuid) {
            selectedAppUUIDs.remove(uuid)
        } else {
            selectedAppUUIDs.insert(uuid)
        }
    }
    
    // MARK: Body
    var body: some View {
        let isRegular = horizontalSizeClass != .compact
        let isEditing = editMode?.wrappedValue == .active
        
        HStack(spacing: 18) {
            if isEditing {
                Button {
                    _toggleSelection()
                } label: {
                    Image(systemName: _isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(_isSelected ? .accentColor : .secondary)
                        .font(.title2)
                }
                .buttonStyle(.borderless)
            }
            
            FRAppIconView(app: app, size: 57)
            
            NBTitleWithSubtitleView(
                title: app.name ?? .localized("Unknown"),
                subtitle: _desc,
                linelimit: 0
            )
            
            if !isEditing {
                _buttonActions(for: app)
            }
        }
        .padding(isRegular ? 12 : 0)
        .background(
            isRegular
            ? RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(_isSelected && isEditing ? Color.accentColor.opacity(0.1) : Color(.quaternarySystemFill))
            : nil
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isEditing {
                _toggleSelection()
            }
        }
        .swipeActions {
            if !isEditing {
                _actions(for: app)
            }
        }
        .contextMenu {
            if !isEditing {
                _contextActions(for: app)
                Divider()
                _contextActionsExtra(for: app)
                Divider()
                _actions(for: app)
            }
        }
        .sheet(item: $dylibPickerData) { data in
            DylibPickerView(
                dylibs: data.extractedDylibs,
                selectedDylibs: Binding(
                    get: { data.selectedDylibs },
                    set: { newValue in
                        if var currentData = dylibPickerData {
                            currentData.selectedDylibs = newValue
                            dylibPickerData = currentData
                        }
                    }
                ),
                appName: data.appName,
                onSave: {
                    if let pickerData = dylibPickerData {
                        finalizeDylibSelection(data: pickerData)
                    }
                    dylibPickerData = nil
                },
                onCancel: {
                    if let pickerData = dylibPickerData {
                        try? FileManager.default.removeItem(at: pickerData.extractionFolder)
                    }
                    dylibPickerData = nil
                }
            )
        }
    }
    
    private var _desc: String {
        if let version = app.version, let id = app.identifier {
            return "\(version) • \(id)"
        } else {
            return .localized("Unknown")
        }
    }
}


// MARK: - Extension: View
extension LibraryCellView {
    @ViewBuilder
    private func _actions(for app: AppInfoPresentable) -> some View {
        Button(.localized("Delete"), systemImage: "trash", role: .destructive) {
            Storage.shared.deleteApp(for: app)
        }
    }
    
    @ViewBuilder
    private func _contextActions(for app: AppInfoPresentable) -> some View {
        Button(.localized("Get Info"), systemImage: "info.circle") {
            selectedInfoAppPresenting = AnyApp(base: app)
        }
    }
    
    @ViewBuilder
    private func _contextActionsExtra(for app: AppInfoPresentable) -> some View {
        if app.isSigned {
            if let id = app.identifier {
                Button(.localized("Open"), systemImage: "app.badge.checkmark") {
                    UIApplication.openApp(with: id)
                }
            }
            Button(.localized("Install"), systemImage: "square.and.arrow.down") {
                selectedInstallAppPresenting = AnyApp(base: app)
            }
            Button(.localized("Re-sign"), systemImage: "signature") {
                selectedSigningAppPresenting = AnyApp(base: app)
            }
            Button(.localized("Export"), systemImage: "square.and.arrow.up") {
                selectedInstallAppPresenting = AnyApp(base: app, archive: true)
            }
        } else {
            Button(.localized("Install"), systemImage: "square.and.arrow.down") {
                selectedInstallAppPresenting = AnyApp(base: app)
            }
            Button(.localized("Sign"), systemImage: "signature") {
                selectedSigningAppPresenting = AnyApp(base: app)
            }
            Button("Extract Dylibs", systemImage: "doc.zipper") {
                Task {
                    await extractDylibsFromApp(app)
                }
            }
        }
    }
    
    @ViewBuilder
    private func _buttonActions(for app: AppInfoPresentable) -> some View {
        Group {
            if app.isSigned {
                Button {
                    selectedInstallAppPresenting = AnyApp(base: app)
                } label: {
                    FRExpirationPillView(
                        title: .localized("Install"),
                        revoked: certRevoked,
                        expiration: certInfo
                    )
                }
            } else {
                Button {
                    selectedSigningAppPresenting = AnyApp(base: app)
                } label: {
                    FRExpirationPillView(
                        title: .localized("Sign"),
                        revoked: false,
                        expiration: nil
                    )
                }
            }
        }
        .buttonStyle(.borderless)
    }
    
    // MARK: - Dylib Extraction
    private func extractDylibsFromApp(_ app: AppInfoPresentable) async {
        // Use the Storage helper to get the app directory
        guard let appBundleURL = Storage.shared.getAppDirectory(for: app) else {
            print("Could not get app directory")
            return
        }
        
        // The appBundleURL is already pointing to the .app bundle
        print("Using app bundle at: \(appBundleURL.path)")
        
        // Get the app name for the folder
        let appName = app.name ?? "Unknown"
        let sanitizedAppName = appName.replacingOccurrences(of: "/", with: "-")
        
        do {
            let allDylibs = try await DylibExtractor.extractDylibs(from: appBundleURL, appFolderName: sanitizedAppName)
            
            // Filter to only include .dylib files
            let dylibsOnly = allDylibs.filter { $0.name.lowercased().hasSuffix(".dylib") }
            
            print("Successfully extracted \(dylibsOnly.count) dylibs (filtered from \(allDylibs.count) total files) from \(app.name ?? "app")")
            
            let dylibsDir = FileManager.default.urls(for: .documentDirectory,
                                                     in: .userDomainMask)[0]
                .appendingPathComponent("ExtractedDylibs")
                .appendingPathComponent(sanitizedAppName)
            
            if FileManager.default.fileExists(atPath: dylibsDir.path), !dylibsOnly.isEmpty {
                // Delete all non-.dylib files that were extracted
                let allExtractedFiles = allDylibs.filter { !$0.name.lowercased().hasSuffix(".dylib") }
                for file in allExtractedFiles {
                    if let url = file.extractedURL {
                        try? FileManager.default.removeItem(at: url)
                        print("Removed non-dylib file: \(file.name)")
                    }
                }
                
                // Create data object and show sheet
                await MainActor.run {
                    self.dylibPickerData = DylibPickerData(
                        extractedDylibs: dylibsOnly,
                        selectedDylibs: Set(dylibsOnly.map { $0.id }),
                        appName: sanitizedAppName,
                        extractionFolder: dylibsDir
                    )
                }
            } else if dylibsOnly.isEmpty {
                print("No .dylib files found in extraction")
            }
        } catch {
            await MainActor.run {
                print("Failed to extract dylibs: \(error)")
                // You could show an error alert here
            }
        }
    }
    
    private func finalizeDylibSelection(data: DylibPickerData) {
        // Delete unselected dylibs
        for dylib in data.extractedDylibs {
            if !data.selectedDylibs.contains(dylib.id), let url = dylib.extractedURL {
                try? FileManager.default.removeItem(at: url)
                print("Deleted: \(dylib.name)")
            }
        }
        
        print("Kept \(data.selectedDylibs.count) dylibs")
        showFolderInFiles(url: data.extractionFolder)
    }

    private func showFolderInFiles(url: URL) {
        if let sharedURL = url.toSharedDocumentsURL() {
            UIApplication.open(sharedURL)
        }
    }
}

// MARK: - Dylib Picker View
struct DylibPickerView: View {
    let dylibs: [DylibInfo]
    @Binding var selectedDylibs: Set<UUID>
    let appName: String
    let onSave: () -> Void
    let onCancel: () -> Void
    
    var body: some View {
        NavigationView {
            List {
                Section {
                    ForEach(dylibs) { dylib in
                        Button {
                            if selectedDylibs.contains(dylib.id) {
                                selectedDylibs.remove(dylib.id)
                            } else {
                                selectedDylibs.insert(dylib.id)
                            }
                        } label: {
                            HStack {
                                Image(systemName: selectedDylibs.contains(dylib.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedDylibs.contains(dylib.id) ? .blue : .gray)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(dylib.name)
                                        .font(.body)
                                    
                                    Text(dylib.formattedSize)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Select Dylibs to Keep")
                } footer: {
                    Text("\(selectedDylibs.count) of \(dylibs.count) selected")
                }
            }
            .navigationTitle("Extract from \(appName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave()
                    }
                    .disabled(selectedDylibs.isEmpty)
                }
                
                ToolbarItem(placement: .bottomBar) {
                    HStack {
                        Button(selectedDylibs.count == dylibs.count ? "Deselect All" : "Select All") {
                            if selectedDylibs.count == dylibs.count {
                                selectedDylibs.removeAll()
                            } else {
                                selectedDylibs = Set(dylibs.map { $0.id })
                            }
                        }
                        
                        Spacer()
                    }
                }
            }
        }
    }
}

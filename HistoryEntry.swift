//
//  ContentView.swift
//  FileSorter
//
//  Created by Cameron Brooks on 6/11/25.
//

import FoundationModels
import SwiftUI
import AppKit
import CoreData
import Combine

struct HistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let timestamp: Date
}

// MARK: - File tree

@Generable
enum ActionType: String, CaseIterable {
    case move_file
    case rename_folder
}

@Generable
struct FileSortAction {
    @Guide(description: "The type of action to perform.")
    let action: ActionType
    @Guide(description: "The name of the source file or folder to be acted upon.")
    let source: String
    @Guide(description: "The destination path for a move_file action, relative to the current directory.")
    let destination: String?
    @Guide(description: "The new name for a rename_folder action.")
    let name: String?
}

@Generable
struct FileOrganizationPlan {
    @Guide(description: "The list of file organization actions to perform.")
    let actions: [FileSortAction]
    @Guide(description: "A brief, one-sentence explanation of the strategy.")
    let strategy: String
}


// MARK: - View‑model
@MainActor
@available(macOS 26.0, *)
final class LLMViewModel: ObservableObject {
    @Published var response: String = ""
    @Published var isBusy = false
    @Published var errorMessage: String?
    @Published var moveProgress: String? = nil
    @Published var statusMessage: String? = nil
    
    var session: LanguageModelSession
    let reliableGenerationOptions = GenerationOptions(sampling: .greedy, temperature: 0.1)
    
    init() {
        self.session = LanguageModelSession()
    }
}

// MARK: - ContentView
struct ContentView: View {
    @StateObject private var llm = {
        if #available(macOS 26.0, *) {
            return LLMViewModel()
        } else {
            fatalError("Foundation Models requires macOS 26 or later.")
        }
    }()
    
    @State private var selectedURL: URL? = nil
    @State private var history: [HistoryEntry] = []
    
    var body: some View {
        VStack(spacing: 20) {
            GroupBox("Select a folder to sort") {
                VStack(spacing: 8) {
                    Button("Choose Folder…", action: openFolderDialog)
                    Button("Start Full Organization Process") {
                        if let url = selectedURL {
                            Task { await startFullOrganization(from: url) }
                        }
                    }
                    .disabled(selectedURL == nil || llm.isBusy)
                    Text(llm.statusMessage ?? "No folder selected.").foregroundColor(.secondary).italic()
                    if llm.isBusy { ProgressView("Organizing...") }
                }
            }
            if !history.isEmpty {
                Divider()
                GroupBox("History Log") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(history) { entry in
                                    Text("\(entry.timestamp.formatted(date: .omitted, time: .standard)) — \(entry.message)")
                                        .font(.caption).foregroundColor(.secondary).id(entry.id)
                                }
                            }
                        }
                        .onChange(of: history.count) { _ in proxy.scrollTo(history.last?.id, anchor: .bottom) }
                    }
                    .frame(maxHeight: 250)
                }
            }
        }
        .padding().frame(minWidth: 500, minHeight: 400)
    }
}

// MARK: - FULL WORKFLOW ENGINE
extension ContentView {
    
    func openFolderDialog() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            self.selectedURL = url
            llm.statusMessage = "Selected: \(url.lastPathComponent)"
            logHistory("Selected folder: \(url.path)")
        }
    }
    
    func logHistory(_ message: String) {
        DispatchQueue.main.async {
            let newEntry = HistoryEntry(message: message, timestamp: Date())
            if history.last?.message != newEntry.message { history.append(newEntry) }
            llm.statusMessage = message
        }
    }
    
    // --- TOP-LEVEL CONTROLLER ---
    func startFullOrganization(from rootURL: URL) async {
        DispatchQueue.main.async { llm.isBusy = true }
        logHistory("--- Starting Phase 1: Initial Sorting ---")
        await organizeDirectory(rootURL)
        logHistory("--- Phase 1 Complete ---")
        logHistory("--- Starting Phase 2: Zettelkasten Refinement ---")
        await runZettelkastenRefinement(on: rootURL)
        logHistory("--- Phase 2 Complete. Organization finished. ---")
        DispatchQueue.main.async { llm.isBusy = false }
    }
    
    // ‼️ FIX: Rebuilt PHASE 1 ENGINE with a strictly sequential loop.
    func organizeDirectory(_ directoryURL: URL) async {
        let fileManager = FileManager.default
        let initialSubdirs = (try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) ?? []
        for subdir in initialSubdirs { await organizeDirectory(subdir) }
        
        logHistory("Processing Directory: \(directoryURL.lastPathComponent)")
        var passCount = 0
        
        // This new loop is sequential: it gets the *first* file, processes it, then repeats.
        while let firstLooseFile = getLooseFiles(in: directoryURL)?.first, passCount < 50 { // Safety break increased
            passCount += 1
            await processSingleFile(firstLooseFile, in: directoryURL)
        }
        
        // Evaluation and Garbage Collection run once all loose files are handled.
        await evaluateDirectoryStructure(directoryURL)
        performGarbageCollection(in: directoryURL)
        
        logHistory("Finished Directory: \(directoryURL.lastPathComponent)")
    }

    func getLooseFiles(in directoryURL: URL) -> [URL]? {
        let fileManager = FileManager.default
        let allItems = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return allItems?.filter { !( (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true) }
    }
    
    // --- PHASE 1A: File processing using schema-guided generation ---
    func processSingleFile(_ fileURL: URL, in directoryURL: URL) async {
        let fileName = fileURL.lastPathComponent
        let prompt = "A file named \"\(fileName)\" is in the directory \"\(directoryURL.lastPathComponent)\". Create a plan with a single 'move_file' action to put it in a logically named subfolder."
        logHistory("AI Query for file: \(fileName)")
        do {
            let response = try await llm.session.respond(to: prompt, generating: FileOrganizationPlan.self, options: llm.reliableGenerationOptions)
            await executePlan(from: response.content.actions, in: directoryURL, for: .file(fileName))
        } catch { logHistory("AI Error (file: \(fileName)): \(error.localizedDescription)") }
    }
    
    // --- PHASE 1B: Evaluation using schema-guided generation ---
    func evaluateDirectoryStructure(_ directoryURL: URL) async {
        let fileManager = FileManager.default
        let subdirs = (try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey]).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) ?? []
        if subdirs.count < 2 { return }
        
        let folderList = subdirs.map { $0.lastPathComponent }.joined(separator: ", ")
        let prompt = "EVALUATION: The directory \"\(directoryURL.lastPathComponent)\" now contains subfolders: [\(folderList)]. Create a plan to consolidate or rename these folders. Use 'rename_folder' actions only."
        logHistory("Evaluation Phase: Reviewing folders [\(folderList)]")
        do {
            let response = try await llm.session.respond(to: prompt, generating: FileOrganizationPlan.self, options: llm.reliableGenerationOptions)
            await executePlan(from: response.content.actions, in: directoryURL, for: .directory)
        } catch { logHistory("AI Error (evaluation): \(error.localizedDescription)") }
    }

    // --- PHASE 2 ENGINE ---
    func runZettelkastenRefinement(on directoryURL: URL) async { /* ... */ }
    
    // --- GARBAGE COLLECTION ---
    func performGarbageCollection(in directoryURL: URL) {
        let fileManager = FileManager.default
        guard let subdirs = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]).filter({ (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) else { return }
        
        for dir in subdirs {
            if let contents = try? fileManager.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                do {
                    try fileManager.removeItem(at: dir)
                    logHistory("Garbage Collection: Removed empty folder '\(dir.lastPathComponent)'.")
                } catch {
                    logHistory("GC Error: Could not remove empty folder '\(dir.lastPathComponent)'.")
                }
            }
        }
    }
    
    // --- UNIVERSAL EXECUTION ENGINE ---
    enum ContextType { case file(String), directory }
    
    func executePlan(from actions: [FileSortAction], in directoryURL: URL, for context: ContextType) async {
        if actions.isEmpty { logHistory("No changes suggested by AI."); return }
        let fileManager = FileManager.default
        
        for action in actions {
            let sourceName = action.source
            
            if case .file(let expectedFile) = context, !sourceName.contains(expectedFile) {
                logHistory("AI Error: Plan for '\(sourceName)' ignored because query was for '\(expectedFile)'.")
                continue
            }
            
            let sourceURL = directoryURL.appendingPathComponent(sourceName)
            if !fileManager.fileExists(atPath: sourceURL.path) {
                logHistory("Skipping action for '\(sourceName)': item no longer at source.")
                continue
            }

            do {
                switch action.action {
                case .move_file:
                    if let destPath = action.destination {
                        var destURL = directoryURL.appendingPathComponent(destPath)
                        var isDir: ObjCBool = false
                        if fileManager.fileExists(atPath: destURL.path, isDirectory: &isDir), isDir.boolValue {
                            destURL.appendPathComponent(sourceName)
                        }
                        try fileManager.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try fileManager.moveItem(at: sourceURL, to: destURL)
                        logHistory("Moved '\(sourceName)' to '\(destURL.path.replacingOccurrences(of: directoryURL.path, with: ""))'")
                    }
                case .rename_folder:
                    if let newName = action.name {
                        let destURL = directoryURL.appendingPathComponent(newName)
                        try fileManager.moveItem(at: sourceURL, to: destURL)
                        logHistory("Renamed folder '\(sourceName)' to '\(newName)'")
                    }
                }
            } catch {
                logHistory("File System Error for action '\(action.action.rawValue)' on '\(sourceName)': \(error.localizedDescription)")
            }
        }
    }
}

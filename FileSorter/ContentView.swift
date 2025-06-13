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

// MARK: - File tree

struct FileSortAction: Codable, Equatable {
    let action: String
    let name: String?
    let source: String?
    let destination: String?
}

final class FileNode: Identifiable {
    let id = UUID()
    let name: String
    let url: URL
    let isDirectory: Bool
    let size: Int?          // bytes; nil for dirs
    let modifiedDate: Date?
    var children: [FileNode] = []
    
    init(name: String,
         url: URL,
         isDirectory: Bool,
         size: Int?,
         modifiedDate: Date?) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedDate = modifiedDate
    }
}

func buildFileTreeSummary(from node: FileNode) -> String {
    var result = node.name + "/" + "\n" // root folder name with trailing slash
    func recurse(_ fileNode: FileNode, _ indentLevel: Int) {
        let indent = String(repeating: "    ", count: indentLevel) // 4 spaces per indent level
        for child in fileNode.children {
            if child.isDirectory {
                // Mark directories with a trailing slash
                result += indent + child.name + "/\n"
                recurse(child, indentLevel + 1) // recursive call to handle subfolder contents
            } else {
                // List files with their name (extension included)
                result += indent + child.name + "\n"
            }
        }
    }
    recurse(node, 1)
    return result
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
    let generationOptions = GenerationOptions(maximumResponseTokens: 4096)
    
    init() {
        // You can pass `instructions:` here if you want a system prompt.
        self.session = LanguageModelSession()
    }
    
    func send(_ prompt: String) {
        Task {
            do {
                isBusy = true
                defer { isBusy = false }
                
                // Use schema-guided generation if prompt suggests a plan or actions
                if prompt.localizedCaseInsensitiveContains("plan") || prompt.localizedCaseInsensitiveContains("action") {
                    // Request structured response as an array of FileSortAction
                    let actions = try await session.respond(
                        to: prompt,
                        options: generationOptions
                    )
                    DispatchQueue.main.async {
                        self.response = "Received response: \(actions.content)"
                    }
                    // You can handle `actions` as needed here or expose them to UI
                } else {
                    let reply = try await session.respond(to: prompt, options: generationOptions)
                    response = reply.content
                }
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                // Fresh session, keep only the last meaningful exchange.
                let instructions = session.transcript.entries.first
                let last = session.transcript.entries.last
                let condensed = Transcript(entries: [instructions, last].compactMap { $0 })
                let newSession = LanguageModelSession(transcript: condensed)
                self.session = newSession
                send(prompt)                                  // retry once
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }
    
    /*
    // Old parseSortingPlan method commented out as schema-guided is now used.
    func parseSortingPlan(from response: String) -> [[String: String]]? {
        // Extract JSON array from the response (it might have extra text)
        guard let jsonStart = response.firstIndex(of: "["),
              let jsonEnd = response.lastIndex(of: "]") else {
            print("No JSON array found in response")
            return nil
        }
        
        let jsonString = String(response[jsonStart...jsonEnd])
        guard let jsonData = jsonString.data(using: .utf8) else { return nil }
        
        do {
            let actions = try JSONSerialization.jsonObject(with: jsonData) as? [[String: Any]]
            // Convert to string dictionary for easier handling
            return actions?.compactMap { dict in
                var stringDict: [String: String] = [:]
                for (key, value) in dict {
                    if let stringValue = value as? String {
                        stringDict[key] = stringValue
                    }
                }
                return stringDict.isEmpty ? nil : stringDict
            }
        } catch {
            print("JSON parsing error: \(error)")
            return nil
        }
    }
    */
    
    func parseFolderPlan(from text: String) -> [String: [String]] {
        // Heuristic: Each line mentioning a folder and file types
        // e.g. "Create an 'Images' folder and move all PNG, JPG..."
        // Regex for folder name and file types/extensions
        var result: [String: [String]] = [:]
        let lines = text.split(separator: "\n").map(String.init)
        let folderPattern = try! NSRegularExpression(pattern: "(?:create|Create|add|Add)[^']*'([^']+)' folder.*?(move|Move)?[\\w\\s]*((?:\\*\\.[a-zA-Z0-9]+|\\.[a-zA-Z0-9]+|[A-Z]+ files?)(?:,? ?[A-Z]+ files?)*)", options: [])
        for line in lines {
            let nsline = line as NSString
            let matches = folderPattern.matches(in: line, options: [], range: NSRange(location: 0, length: nsline.length))
            for match in matches {
                if match.numberOfRanges >= 3 {
                    let folderName = nsline.substring(with: match.range(at: 1))
                    let filePart = match.range(at: 3).location != NSNotFound ? nsline.substring(with: match.range(at: 3)) : ""
                    // Extract extensions like ".jpg", "*.md", or upper-case file types
                    let extPattern = try! NSRegularExpression(pattern: "\\.\\w+|\\*\\.\\w+|[A-Z]{2,4}", options: [])
                    let extMatches = extPattern.matches(in: filePart, options: [], range: NSRange(location: 0, length: (filePart as NSString).length))
                    let exts = extMatches.map { (filePart as NSString).substring(with: $0.range) }
                    if !folderName.isEmpty && !exts.isEmpty {
                        result[folderName] = exts
                    }
                }
            }
        }
        return result
    }
    
    func pacedMoveFiles(plan: [String: [String]], in rootURL: URL) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var movedCount = 0
            var errorCount = 0
            var createdFolders = Set<String>()
            do {
                let files = try fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                for (folder, patterns) in plan {
                    let folderURL = rootURL.appendingPathComponent(folder)
                    if !fileManager.fileExists(atPath: folderURL.path) {
                        try? fileManager.createDirectory(at: folderURL, withIntermediateDirectories: false)
                        createdFolders.insert(folder)
                        DispatchQueue.main.async {
                            self.moveProgress = "Created folder: \(folder)"
                        }
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                    for fileURL in files {
                        let fileName = fileURL.lastPathComponent
                        let ext = fileURL.pathExtension.uppercased()
                        let matches = patterns.contains { pat in
                            if pat.hasPrefix(".*") { return fileName.lowercased().hasSuffix(pat.dropFirst(2).lowercased()) }
                            if pat.hasPrefix(".") { return "." + ext.lowercased() == pat.lowercased() }
                            return ext == pat.uppercased() || fileName.uppercased().contains(pat.uppercased())
                        }
                        guard matches else { continue }
                        let destURL = folderURL.appendingPathComponent(fileName)
                        do {
                            try fileManager.moveItem(at: fileURL, to: destURL)
                            movedCount += 1
                            DispatchQueue.main.async {
                                self.moveProgress = "Moved \(fileName) to \(folder)/"
                            }
                        } catch {
                            errorCount += 1
                        }
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                }
                DispatchQueue.main.async {
                    self.moveProgress = "Completed: \(movedCount) files moved to \(createdFolders.count) folders, \(errorCount) errors."
                    self.statusMessage = "Organization complete! Moved \(movedCount) file(s)."
                }
            } catch {
                DispatchQueue.main.async {
                    self.moveProgress = "Scan error: \(error.localizedDescription)"
                    self.statusMessage = "Failed to scan folder."
                }
            }
        }
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
    
    @State private var promptText = ""
    @State private var aiPlanText: String = ""
    @State private var rootFileNode: FileNode? = nil // holds the scanned folder tree
    @State private var moveProgress: String? = nil
    
    var body: some View {
        VStack(spacing: 20) {
            
            // ---------- LLM demo ----------
            GroupBox("LLM API Test") {
                VStack(spacing: 12) {
                    TextField("Enter prompt…", text: $promptText)
                        .textFieldStyle(.roundedBorder)
                    
                    Button("Send") {
                        llm.send(promptText)
                    }
                    .disabled(promptText.isEmpty)
                    
                    if llm.isBusy { ProgressView() }
                    
                    if !llm.response.isEmpty {
                        Text(llm.response)
                            .padding()
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    if let err = llm.errorMessage {
                        Text(err).foregroundColor(.red)
                    }
                }
            }
            
            Divider()
            
            // ---------- Folder scan ----------
            GroupBox("Select a folder to scan") {
                VStack(spacing: 8) {
                    Button("Choose Folder…", action: openFolderDialog)
                    
                    Button("Sort Files with AI") {
                        sortFiles()
                    }
                    .disabled(rootFileNode == nil)
                    
                    Text(llm.statusMessage ?? "No folder selected.")
                        .foregroundColor(.secondary)
                        .italic()
                    
                    if let progress = moveProgress ?? llm.moveProgress {
                        Text(progress).foregroundColor(.blue).font(.callout)
                    }
                    
                    if !aiPlanText.isEmpty {
                        Text("AI Plan:")
                            .font(.subheadline).bold()
                        ScrollView {
                            Text(aiPlanText)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }
                        .frame(maxHeight: 200)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.2))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 600)
        .onChange(of: llm.moveProgress) { _, newValue in
            moveProgress = newValue
        }
    }
}

// MARK: - Folder scan helpers
extension ContentView {
    
    func scanFolder(at url: URL) {
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        
        let rootNode = FileNode(name: url.lastPathComponent,
                                url: url,
                                isDirectory: true,
                                size: nil,
                                modifiedDate: nil)
        var nodeStack: [FileNode] = [rootNode]
        
        if let enumerator = fileManager.enumerator(at: url,
                                                   includingPropertiesForKeys: resourceKeys,
                                                   options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                do {
                    let values = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                    let depth = enumerator.level
                    
                    let node = FileNode(name: fileURL.lastPathComponent,
                                        url: fileURL,
                                        isDirectory: values.isDirectory ?? false,
                                        size: values.fileSize,
                                        modifiedDate: values.contentModificationDate)
                    
                    if depth < nodeStack.count - 1 {
                        nodeStack.removeLast(nodeStack.count - 1 - depth)
                    }
                    nodeStack.last?.children.append(node)
                    if node.isDirectory { nodeStack.append(node) }
                    
                    let indent = String(repeating: "  ", count: depth)
                    let icon = node.isDirectory ? "📁" : "📄"
                    let sizeInfo = node.size.map { " - \($0) bytes" } ?? ""
                    print("\(indent)\(icon) \(node.name)\(sizeInfo)")
                } catch {
                    print("Error reading \(fileURL.path): \(error)")
                }
            }
            
            print("Completed scanning \(rootNode.name). Found \(rootNode.children.count) items at top level.")
            self.rootFileNode = rootNode   // retain the file tree for later use
        }
    }
    
    func openFolderDialog() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder"
        panel.prompt = "Select"
        // Disable multiple selection to reduce system warnings
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        
        if panel.runModal() == .OK {
            Task { @MainActor in
                let urls = panel.urls
                llm.statusMessage = urls.isEmpty
                    ? "Selection cancelled."
                    : "Selected a folder."
            }
            panel.urls.forEach(scanFolder(at:))
        }
    }
    
    func sortFiles() {
        guard let root = rootFileNode else { return }
        let instructionText = """
Organize the files in the provided folder structure in a clear, logical way, grouping similar files into appropriately-named folders (e.g., any file). Only create new folders if they help with organization. For each folder, move files of matching type or category into it, and do not move files unnecessarily. Respond ONLY with a valid JSON array of actions, each in this format:
[
  {"action": "create_folder", "name": "<folder_name_that_describes_contents>"},
  {"action": "move_file", "source": "<file>.<type>", "destination": "<folder_name_that_describes_contents>/<file>.<type>"}
]
No explanation, no extra text, no markdown.
"""
        let fileTreeSummary = buildFileTreeSummary(from: root)
        let promptText = "Folder structure:\n\(fileTreeSummary)"
        aiPlanText = "" // clear from previous
        llm.statusMessage = "Analyzing folder..."
        Task {
            do {
                let actions = try await llm.session.respond(
                    to: instructionText + "\n" + promptText,
                    options: llm.generationOptions
                )
                let content = actions.content
                print("Raw AI output: \(actions.content)")
                guard let data = content.data(using: .utf8) else {
                    DispatchQueue.main.async {
                        llm.statusMessage = "AI did not return valid UTF-8 JSON."
                    }
                    return
                }
                let decoder = JSONDecoder()
                let decodedActions = try decoder.decode([FileSortAction].self, from: data)
                let planDescription = decodedActions.map {
                    var desc = "Action: \($0.action)"
                    if let name = $0.name { desc += ", Name: \(name)" }
                    if let source = $0.source { desc += ", Source: \(source)" }
                    if let dest = $0.destination { desc += ", Destination: \(dest)" }
                    return desc
                }.joined(separator: "\n")
                DispatchQueue.main.async {
                    aiPlanText = planDescription
                }
                if let rootURL = rootFileNode?.url {
                    executeSortingPlan(decodedActions, rootURL: rootURL)
                }
            } catch {
                print("AI generation or decoding failed: \(error)")
                DispatchQueue.main.async {
                    llm.statusMessage = "AI failed to generate a valid JSON plan: \(error.localizedDescription)"
                }
            }
        }
    }
    
    // Execute the sorting plan
    func executeSortingPlan(_ plan: [FileSortAction], rootURL: URL) {
        let fileManager = FileManager.default
        var createdFolders = Set<String>()
        var movedCount = 0
        var errorCount = 0
        
        for action in plan {
            switch action.action {
            case "create_folder":
                if let folderName = action.name {
                    let folderURL = rootURL.appendingPathComponent(folderName)
                    if !fileManager.fileExists(atPath: folderURL.path) {
                        do {
                            try fileManager.createDirectory(at: folderURL,
                                                          withIntermediateDirectories: true)
                            createdFolders.insert(folderName)
                            print("Created folder: \(folderName)")
                        } catch {
                            print("Failed to create folder \(folderName): \(error)")
                            errorCount += 1
                        }
                    }
                }
            
            case "move_file":
                if let source = action.source,
                   let destination = action.destination {
                    let sourceURL = rootURL.appendingPathComponent(source)
                    let destURL = rootURL.appendingPathComponent(destination)
                    
                    // Ensure destination directory exists
                    let destDir = destURL.deletingLastPathComponent()
                    try? fileManager.createDirectory(at: destDir,
                                                   withIntermediateDirectories: true)
                    
                    do {
                        try fileManager.moveItem(at: sourceURL, to: destURL)
                        movedCount += 1
                        print("Moved: \(source) → \(destination)")
                    } catch {
                        print("Failed to move \(source): \(error)")
                        errorCount += 1
                    }
                }
            
            default:
                print("Unknown action: \(action.action)")
            }
        }
        
        // Update status
        var status = "Organization complete! "
        if movedCount > 0 {
            status += "Moved \(movedCount) file\(movedCount == 1 ? "" : "s"). "
        }
        if createdFolders.count > 0 {
            status += "Created \(createdFolders.count) folder\(createdFolders.count == 1 ? "" : "s"). "
        }
        if errorCount > 0 {
            status += "\(errorCount) error\(errorCount == 1 ? "" : "s") occurred."
        }
        
        llm.statusMessage = status
        
        while let fileURL = enumerator?.nextObject() as? URL {
            let parentURL = fileURL.deletingLastPathComponent()
            guard let parentNode = nodeLookup[parentURL] else { continue }
            let isDir = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let node = FileNode(name: fileURL.lastPathComponent, url: fileURL, isDirectory: isDir, parent: parentNode)
            parentNode.children.append(node)
            if isDir { nodeLookup[fileURL] = node }
        }
        return rootNode
    }

    private func getDirectoriesBottomUp(from root: FileNode) -> [FileNode] {
        var directories: [FileNode] = []
        func traverse(_ node: FileNode) {
            guard node.isDirectory else { return }
            node.children.forEach { traverse($0) }
            directories.append(node)
        }
        traverse(root)
        return directories
    }
    
    private func buildTreeSummary(from node: FileNode, level: Int = 0) -> String {
        var result = String(repeating: "  ", count: level) + node.name + "/\n"
        for child in node.children {
            if child.isDirectory {
                result += buildTreeSummary(from: child, level: level + 1)
            } else {
                result += String(repeating: "  ", count: level + 1) + child.name + "\n"
            }
        }
        await moveFiles(in: root)
        // All moves done – update status on main thread
        DispatchQueue.main.async {
            self.llm.statusMessage = "Files organized by type successfully!"
        }
    }
}


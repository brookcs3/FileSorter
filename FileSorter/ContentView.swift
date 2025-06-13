//
//  ContentView.swift
//  FileSorter
//
//  Created by Cameron Brooks on 6/11/25.
//

import SwiftUI
import AppKit
import Combine
import FoundationModels         // macOS 26 SDK

struct Transcript {
    enum Entry: Equatable {
        case user(String)
        case assistant(String)
        
        var text: String {
            switch self {
            case .user(let msg): return msg
            case .assistant(let msg): return msg
            }
        }
    }
    
    private(set) var history: [Entry] = []
    
    mutating func append(_ entry: Entry) {
        history.append(entry)
    }
}

/// Splits a large summary string into batches of maxTokensOrChars size (approximation).
func splitSummaryIntoBatches(_ summary: String, maxTokensOrChars: Int) -> [String] {
    // Split by lines for easier chunking
    let lines = summary.components(separatedBy: .newlines)
    var batches: [String] = []
    var currentBatch: [String] = []
    var currentLength = 0
    for line in lines {
        let lineLen = line.count + 1 // Include newline char
        if currentLength + lineLen > maxTokensOrChars, !currentBatch.isEmpty {
            batches.append(currentBatch.joined(separator: "\n"))
            currentBatch = []
            currentLength = 0
        }
        currentBatch.append(line)
        currentLength += lineLen
    }
    if !currentBatch.isEmpty {
        batches.append(currentBatch.joined(separator: "\n"))
    }
    return batches
}

struct FileNode: Equatable, Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    var children: [FileNode] = []
}

func buildFileTreeSummary(from node: FileNode, maxTokensOrChars: Int) -> [String] {
    var result = node.name + "/" + "\n" // root folder name with trailing slash
    func recurse(_ fileNode: FileNode, _ indentLevel: Int) {
        let indent = String(repeating: "    ", count: indentLevel) // 4 spaces per indent level
        for child in fileNode.children {
            if child.isDirectory {
                result += indent + child.name + "/\n"
                recurse(child, indentLevel + 1)
            } else {
                result += indent + child.name + "\n"
            }
        }
    }
    recurse(node, 1)
    return splitSummaryIntoBatches(result, maxTokensOrChars: maxTokensOrChars)
}

// MARK: - History ----------------------------------------------------------

struct HistoryEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let message: String
}

// MARK: - AI‑Plan Types ----------------------------------------------------

enum SortAction: String, Codable { case create_folder, move_file, rename_folder }

struct FileSortAction: Codable, Equatable {
    let action: SortAction
    let source: String
    let destination: String?
    let name: String?
}

// MARK: - View‑Model -------------------------------------------------------

@MainActor
@available(macOS 26.0, *)
final class LLMViewModel: ObservableObject {
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var transcript = Transcript()

    public var maximumResponseTokens: Int?

    var generationOptions: GenerationOptions {
        if let maxTokens = maximumResponseTokens {
            return GenerationOptions(maximumResponseTokens: maxTokens)
        } else {
            return GenerationOptions()
        }
    }

    /// Stateless helper; each call spins a fresh session.
    func respond(to prompt: String) async throws -> String {
        self.transcript.append(.user(prompt))
        let session = LanguageModelSession()
        let response = try await session.respond(to: prompt, options: generationOptions)
        self.transcript.append(.assistant(response.content))
        return response.content
    }
}

// MARK: - Main View --------------------------------------------------------

@available(macOS 26.0, *)
struct ContentView: View {
    //   UI
    @StateObject private var llm = LLMViewModel()
    @State private var rootURL: URL?
    @State private var history: [HistoryEntry] = []
    @State private var rootFileNode: FileNode? = nil // will store the scanned folder tree

    // Janitor background task
    @State private var periodicTask: Task<Void, Never>? = nil
    private let cleanupInterval: Duration = .seconds(180)

    // ---------------------------------------------------------------------

    var body: some View {
        VStack(spacing: 20) {

            // ─── Folder Picker ────────────────────────────────────────────
            GroupBox("Folder to sort") {
                VStack(spacing: 12) {
                    Button("Choose Folder…",   action: chooseFolder)
                    Button("Organize Files by Type") {
                        sortFiles()
                    }
                    .disabled(rootFileNode == nil || llm.isBusy)
                    Button("Start Organization") {
                        guard let url = rootURL else { return }
                        Task { await startOrganization(at: url) }
                    }
                    .disabled(rootURL == nil || llm.isBusy)

                    if let info = llm.statusMessage {
                        Text(info).italic().foregroundColor(.secondary)
                    }
                    if llm.isBusy { ProgressView() }
                }
            }

            // ─── History Log ─────────────────────────────────────────────
            if !history.isEmpty {
                Divider()
                GroupBox("History") {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(history) { entry in
                                    Text(entry.timestamp.formatted(date: .omitted,
                                                                   time: .standard)
                                         + " — " + entry.message)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .id(entry.id)
                                }
                            }
                        }
                        .onChange(of: history.count) { _ in
                            proxy.scrollTo(history.last?.id, anchor: .bottom)
                        }
                    }
                    .frame(maxHeight: 240)
                }
            }
        }
        .padding()
        .frame(minWidth: 540, minHeight: 500)
    }
}

// MARK: - UI Helpers -------------------------------------------------------

@available(macOS 26.0, *)
private extension ContentView {

    func log(_ msg: String) {
        history.append(.init(message: msg))
        llm.statusMessage = msg
        print(msg)                       // dev console
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = rootURL ?? FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            rootURL = url
            UserDefaults.standard.url(forKey: "LastRootURL")
            log("Selected folder: \(url.path)")
            
            Task {
                // Compose tool property info string for prompt context
                var toolInfo = """
                This tool organizes files by sorting and renaming folders based on file extensions and folder semantics.
                """
                // TODO: Append tool description, includesSchemaInInstructions, parameters strings if available here.

                // Append transcript of prior LLM interactions if available here.
                let transcriptText = (llm.transcript.history.map { $0.text }).joined(separator: "\n")
                let promptContext = toolInfo + "\nPrevious conversation:\n" + transcriptText
                
                if let tree = await scanFolderWithLLM(at: url, promptContext: promptContext) {
                    await MainActor.run {
                        self.rootFileNode = tree
                        let maxTokensOrChars: Int
                        if let vm = self.llm as? LLMViewModel {
                            maxTokensOrChars = (vm.generationOptions.maximumResponseTokens ?? 4096) / 5
                        } else {
                            maxTokensOrChars = 4096 / 5
                        }
                        let batches = buildFileTreeSummary(from: tree, maxTokensOrChars: maxTokensOrChars)
                        for (i, batch) in batches.enumerated() {
                            log("Folder tree batch \(i + 1)/\(batches.count):\n" + batch)
                        }
                    }
                } else {
                    // fallback to original scan
                    DispatchQueue.global(qos: .userInitiated).async {
                        let tree = scanFolder(at: url)
                        DispatchQueue.main.async {
                            self.rootFileNode = tree
                            let maxTokensOrChars: Int
                            if let vm = self.llm as? LLMViewModel {
                                maxTokensOrChars = (vm.generationOptions.maximumResponseTokens ?? 4096) / 5
                            } else {
                                maxTokensOrChars = 4096 / 5
                            }
                            let batches = buildFileTreeSummary(from: tree, maxTokensOrChars: maxTokensOrChars)
                            for (i, batch) in batches.enumerated() {
                                log("Folder tree batch \(i + 1)/\(batches.count):\n" + batch)
                            }
                        }
                    }
                }
            }
        }
    }
    
    func scanFolder(at url: URL) -> FileNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return FileNode(name: url.lastPathComponent, isDirectory: false)
        }
        if !isDir.boolValue {
            return FileNode(name: url.lastPathComponent, isDirectory: false)
        }
        // Directory - recurse children
        let childrenURLs = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var childrenNodes: [FileNode] = []
        for childURL in childrenURLs {
            let childNode = scanFolder(at: childURL)
            childrenNodes.append(childNode)
        }
        return FileNode(name: url.lastPathComponent, isDirectory: true, children: childrenNodes)
    }

    /// An LLM-powered directory scanner that summarizes directory contents and attempts to interpret its structure using AI.
    /// Falls back to scanFolder(at:) if unable to parse a valid structure.
    func scanFolderWithLLM(at url: URL, promptContext: String? = nil) async -> FileNode? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return FileNode(name: url.lastPathComponent, isDirectory: false)
        }
        
        // Gather directory contents summary
        let childrenURLs = (try? fm.contentsOfDirectory(at: url,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles])) ?? []
        
        // Build summary string for prompt
        var summaryLines: [String] = []
        for child in childrenURLs {
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                summaryLines.append("\(child.lastPathComponent)/")
            } else {
                summaryLines.append(child.lastPathComponent)
            }
        }
        let summary = summaryLines.joined(separator: "\n")

        // Compose prompt for LLM
        var prompt = ""
        if let context = promptContext {
            prompt += context + "\n\n"
        }
        prompt += """
        You are analyzing the folder structure of: \(url.lastPathComponent)
        The contents are:
        \(summary)

        Please provide a JSON representation of this folder as a nested structure:
        {
            "name": "folderName",
            "isDirectory": true,
            "children": [
                {"name": "childName", "isDirectory": bool, "children": [...]}
            ]
        }
        Only output valid JSON.
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, options: GenerationOptions())
            let data = Data(response.content.utf8)

            // Decode JSON to FileNode-like structure
            struct RawNode: Decodable {
                let name: String
                let isDirectory: Bool
                let children: [RawNode]?
            }

            let rawNode = try JSONDecoder().decode(RawNode.self, from: data)

            func convert(_ raw: RawNode) -> FileNode {
                FileNode(name: raw.name, isDirectory: raw.isDirectory, children: raw.children?.map(convert) ?? [])
            }
            return convert(rawNode)

        } catch {
            // Fallback to manual scan on error
            await MainActor.run {
                log("⚠️ LLM scan error: \(error.localizedDescription), falling back to local scan.")
            }
            return scanFolder(at: url)
        }
    }
    
    func sortFiles() {
        // Will implement AI sorting here in the next steps
        print("Sorting files by type...")
    }
}
// ==========================================================================
// MARK: - Organization Pipeline
// ==========================================================================

@available(macOS 26.0, *)
private extension ContentView {

    // Entry point ----------------------------------------------------------

    func startOrganization(at root: URL) async {
        guard periodicTask == nil else { return }      // prevent re‑entry
        llm.isBusy = true
        log("▶︎ Phase 1: Iterative sort")

        // (1) Spawn janitor
        periodicTask = Task.detached(priority: .background) { [root, cleanupInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: cleanupInterval)
                Task {
                    await runJanitor(on: root)
                }
            }
        }

        // (2) Main two‑phase algorithm
        await organizeDirectory(root)
        log("✓ Phase 1 complete")

        log("▶︎ Phase 2: Zettelkasten refinement")
        await zettelkastenRefine(root)
        log("✓ Phase 2 complete")

        // (3) Clean up
        periodicTask?.cancel()
        periodicTask = nil
        llm.isBusy = false
        log("✔︎ Done!")
    }

    // ---------------------------------------------------------------------
    // Phase 1 – Recursive file moves + evaluation
    // ---------------------------------------------------------------------

    func organizeDirectory(_ dir: URL) async {
        // Recurse into a snapshot of current sub‑directories
        let initialSubs = subdirectories(of: dir)
        for sub in initialSubs { await organizeDirectory(sub) }

        // Loop passes until no loose files remain
        var pass = 0
        while true {
            pass += 1
            let loose = looseFiles(in: dir)
            guard !loose.isEmpty else { break }
            log("Pass \(pass) in \(dir.lastPathComponent) (\(loose.count) files)")
            for file in loose { await processFile(file, in: dir) }
            await evaluateDirectory(dir)
            if pass >= 10 { log("❗️Safety break in \(dir.lastPathComponent)"); break }
        }

        // Example usage of new helpers (not active in pipeline yet):
        // let planText = "<plan text from LLM here>"
        // let extToFolder = parsePlan(plan: planText, fileList: looseFiles(in: dir))
        // await performPacedMoves(extToFolder: extToFolder, files: looseFiles(in: dir), in: dir)
    }

    func looseFiles(in dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { !( (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? true) }
    }

    func subdirectories(of dir: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }


    // --- single file prompt ---------------------------------------------

    func processFile(_ file: URL, in dir: URL) async {
        let name = file.lastPathComponent
        let prompt = """
        You are a file organization assistant. A file named "\(name)" is in folder "\(dir.lastPathComponent)".
        
        Based on the file extension and name, suggest an appropriate folder to organize it into.
        
        You must respond with ONLY a valid JSON array in this exact format:
        [{"action":"move_file","source":"\(name)","destination":"<FolderName>/\(name)","name":null}]
        
        Do not include any other text, explanations, or formatting. Only return the JSON array.
        
        Example response:
        [{"action":"move_file","source":"document.pdf","destination":"Documents/document.pdf","name":null}]
        """
        var retryCount = 0
        let maxRetries = 2
        
        while retryCount <= maxRetries {
            do {
                let raw = try await llm.respond(to: prompt)
                try executePlan(raw, in: dir, expectedFile: name)
                break // Success, exit retry loop
            } catch { 
                retryCount += 1
                log("⚠️ AI error (attempt \(retryCount)): \(error.localizedDescription)")
                
                if retryCount <= maxRetries {
                    log("🕐 Waiting 2 seconds before retry...")
                    try? await Task.sleep(for: .seconds(2))
                } else {
                    log("❌ Max retries reached for \(name)")
                }
            }
        }
    }

    // --- evaluation prompt ----------------------------------------------

    func evaluateDirectory(_ dir: URL) async {
        let subs = subdirectories(of: dir)
        guard subs.count > 1 else { return }
        let names = subs.map(\.lastPathComponent).joined(separator: ", ")
        let prompt = """
        You are a file organization assistant. Folder "\(dir.lastPathComponent)" contains these subfolders: [\(names)].
        
        Analyze if any folders should be renamed for better organization. If no changes are needed, return an empty array.
        
        You must respond with ONLY a valid JSON array in this exact format:
        [{"action":"rename_folder","source":"OldName","destination":null,"name":"NewName"}]
        
        Or if no changes needed:
        []
        
        Do not include any other text, explanations, or formatting. Only return the JSON array.
        """
        do {
            let raw = try await llm.respond(to: prompt)
            try executePlan(raw, in: dir, expectedFile: nil)
        } catch { log("⚠️ Eval error: \(error.localizedDescription)") }
    }

    // ---------------------------------------------------------------------
    // Phase 2 – Zettelkasten refinement
    // ---------------------------------------------------------------------

    func zettelkastenRefine(_ dir: URL) async {
        let subs = subdirectories(of: dir)
        for sub in subs { await zettelkastenRefine(sub) }      // post‑order

        guard !subs.isEmpty else { return }
        let names = subs.map(\.lastPathComponent).joined(separator: ", ")
        let prompt = """
        You are a file organization assistant. Parent folder "\(dir.lastPathComponent)" contains: [\(names)].
        
        Analyze if folders should be renamed or consolidated for better semantic organization. If no changes are needed, return an empty array.
        
        You must respond with ONLY a valid JSON array in this exact format:
        [{"action":"rename_folder","source":"OldName","destination":null,"name":"NewName"}]
        
        Or if no changes needed:
        []
        
        Do not include any other text, explanations, or formatting. Only return the JSON array.
        """
        do {
            let raw = try await llm.respond(to: prompt)
            try executePlan(raw, in: dir, expectedFile: nil)
        } catch { log("⚠️ Zettel error: \(error.localizedDescription)") }
    }

    // ---------------------------------------------------------------------
    // Janitor – periodic bottom clean‑up
    // ---------------------------------------------------------------------

    func runJanitor(on root: URL) async {
        let leaves = leafDirectories(from: root)
        guard !leaves.isEmpty else { return }
        log("🧹 Janitor pass (\(leaves.count) leaf dir[s])")
        for leaf in leaves { await organizeDirectory(leaf) }
    }

    func leafDirectories(from root: URL) -> [URL] {
        var leaves: [URL] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.isDirectoryKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }

        for case let url as URL in en {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
               subdirectories(of: url).isEmpty {
                leaves.append(url)
            }
        }
        return leaves.isEmpty ? [root] : leaves
    }

    // ---------------------------------------------------------------------
    // New Helpers: parsePlan and performPacedMoves
    // ---------------------------------------------------------------------

    /**
     Parses an LLM-generated plan text to produce a mapping from file extensions to destination folder names.
     
     The plan text may be in semi-structured, human-friendly formats such as markdown lists, bullet points, or plain text, possibly containing folder names in bold (`**Folder**`), quoted ("Folder" or 'Folder'), or as the first word of a line. The function heuristically extracts folder names and associates them with the relevant file extensions or file names it finds mentioned in each line.

     - The mapping is case-insensitive for extensions (lowercased, without dot).
     - For each folder name found, extensions matching those present in `fileList` are mapped to the folder.
     - Additionally, if a file name from `fileList` is mentioned in a line, that file's extension is mapped to the folder name from that line.

     ## Example Input
         1. **PDFs**: All `.pdf` files
         2. "Images": jpg, png, jpeg
         3. Documents – docx, txt, 'notes.txt'

     - Parameters:
        - plan: The plan as returned from the LLM, containing folder/extension groupings (in markdown, bullet, or similar text).
        - fileList: The list of current files (as URLs) in the directory to be organized. Only extensions present in this list are mapped.
     - Returns: A dictionary mapping file extensions (lowercased, dot-stripped) to the destination folder names extracted from the plan text.
     - Note: Lines that do not mention any known extension or file name are ignored. The mapping is robust to mixed formats, but ambiguous or malformed lines may be skipped silently.
     */
    func parsePlan(plan: String, fileList: [URL]) -> [String: String] {
        var mapping: [String: String] = [:]

        let fileExtensions = Set(fileList.compactMap { ext in
            let lowered = ext.pathExtension.lowercased()
            return lowered.isEmpty ? nil : lowered
        })

        let lowercasedFileNames = Set(fileList.map { $0.lastPathComponent.lowercased() })

        // Split the plan into lines
        let lines = plan.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // Attempt to extract folder name from the line

            // 1) Try markdown bold: **FolderName**
            var folderName: String? = nil
            if let boldStart = trimmed.range(of: "**"), let boldEnd = trimmed.range(of: "**", options: [], range: boldStart.upperBound..<trimmed.endIndex) {
                folderName = String(trimmed[boldStart.upperBound..<boldEnd.lowerBound])
            }

            // 2) Else try quoted folder name: "FolderName" or 'FolderName'
            if folderName == nil {
                if let quoteStart = trimmed.firstIndex(where: { "\"'".contains($0) }),
                   let quoteEnd = trimmed[trimmed.index(after: quoteStart)...].firstIndex(of: trimmed[quoteStart]) {
                    folderName = String(trimmed[trimmed.index(after: quoteStart)..<quoteEnd])
                }
            }

            // 3) Else fallback: pick first word after number or bullet (like after '1.' or '-')
            if folderName == nil {
                // Find first word after digit or bullet
                let pattern = #"^[\s\d\.\-\*\+]*([A-Za-z0-9_\- ]+)"#
                if let regex = try? NSRegularExpression(pattern: pattern, options: []),
                   let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: trimmed.utf16.count)),
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: trimmed) {
                    folderName = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            guard let folder = folderName, !folder.isEmpty else {
                continue
            }

            // Find extensions mentioned in the line
            var foundExtensions: Set<String> = []

            // Tokenize the line by non-alphanumeric chars to capture extensions as words
            let tokens = trimmed.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            for token in tokens {
                if fileExtensions.contains(token) {
                    foundExtensions.insert(token)
                }
            }

            // Map extensions to folder
            for ext in foundExtensions {
                mapping[ext] = folder
            }

            // Additionally try to map by file name:
            // If any file name matches a substring in the line (case-insensitive), map that file's extension to folder
            for fileURL in fileList {
                let fileNameLower = fileURL.lastPathComponent.lowercased()
                if trimmed.lowercased().contains(fileNameLower) {
                    let ext = fileURL.pathExtension.lowercased()
                    if !ext.isEmpty {
                        mapping[ext] = folder
                    }
                }
            }
        }
        return mapping
    }

    /// Moves files into folders as specified by the extension-to-folder mapping, with a 500ms pause between moves.
    /// - Parameters:
    ///   - extToFolder: Dictionary mapping file extension to folder name.
    ///   - files: Array of file URLs to move.
    ///   - dir: Root directory URL where the files and folders reside.
    func performPacedMoves(extToFolder: [String: String], files: [URL], in dir: URL) async {
        let fm = FileManager.default

        for file in files {
            let ext = file.pathExtension.lowercased()
            if let folderName = extToFolder[ext] {
                let destFolder = dir.appendingPathComponent(folderName, isDirectory: true)
                let destURL = destFolder.appendingPathComponent(file.lastPathComponent)

                do {
                    try fm.createDirectory(at: destFolder, withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destURL.path) {
                        try fm.removeItem(at: destURL)  // overwrite if exists
                    }
                    try fm.moveItem(at: file, to: destURL)
                    await MainActor.run {
                        log("Moved «\(file.lastPathComponent)» → \(folderName)")
                    }
                    try await Task.sleep(for: .milliseconds(500))
                } catch {
                    await MainActor.run {
                        log("⚠️ Move error: \(error.localizedDescription) for file \(file.lastPathComponent)")
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------------
    // Plan execution -------------------------------------------------------

    func executePlan(_ raw: String, in dir: URL, expectedFile: String?) throws {
        // Log the raw response for debugging
        log("🔍 AI Response: \(raw.prefix(100))...")
        
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]") else {
            log("⚠️ Plan rejected: no JSON array found in response")
            return
        }
        let json = raw[start...end]
        let data = Data(String(json).utf8)

        let actions = try JSONDecoder().decode([FileSortAction].self, from: data)
        let fm = FileManager.default

        for act in actions {
            switch act.action {

            case .move_file:
                guard expectedFile == nil || act.source == expectedFile else { continue }
                guard let dest = act.destination else { continue }
                let srcURL = dir.appendingPathComponent(act.source)
                let dstURL = dir.appendingPathComponent(dest)

                do {
                    try fm.createDirectory(at: dstURL.deletingLastPathComponent(),
                                           withIntermediateDirectories: true)
                } catch {
                    // Directory might already exist, that's ok
                }
                try? fm.removeItem(at: dstURL)            // overwrite if exists
                do {
                    try fm.moveItem(at: srcURL, to: dstURL)
                    log("Moved «\(act.source)» → \(dstURL.lastPathComponent)")
                } catch {
                    log("⚠️ Move failed: \(error.localizedDescription) for \(act.source)")
                }

            case .rename_folder:
                guard let newName = act.name else { continue }
                let srcURL = dir.appendingPathComponent(act.source)
                let dstURL = dir.appendingPathComponent(newName)
                try? fm.removeItem(at: dstURL)
                try fm.moveItem(at: srcURL, to: dstURL)
                log("Renamed «\(act.source)» → «\(newName)»")

            case .create_folder:
                let newURL = dir.appendingPathComponent(act.source)
                try fm.createDirectory(at: newURL, withIntermediateDirectories: true)
                log("Created folder «\(act.source)»")
            }
        }
    }
}
// ==========================================================================
#if DEBUG
@available(macOS 13.0, *)
#Preview {
    if #available(macOS 26.0, *) {
        ContentView()
    } else {
        Text("Requires macOS 26.0")
    }
}
#endif


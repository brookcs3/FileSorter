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

// MARK: - View‑model

@MainActor
@available(macOS 26.0, *)
final class LLMViewModel: ObservableObject {
    @Published var response: String = ""
    @Published var isBusy = false
    @Published var errorMessage: String?
    
    private var session: LanguageModelSession
    
    init() {
        // You can pass `instructions:` here if you want a system prompt.
        self.session = LanguageModelSession()
    }
    
    func send(_ prompt: String) {
        Task {
            do {
                isBusy = true
                defer { isBusy = false }
                
                let reply = try await session.respond(to: prompt)
                response = reply.content
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
    @State private var statusMessage = "No folder selected."
    
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
                    Text(statusMessage)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }
        }
        .padding()
        .frame(minWidth: 500, minHeight: 600)
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
        }
    }
    
    func openFolderDialog() {
        let panel = NSOpenPanel()
        panel.title = "Choose Folder"
        panel.prompt = "Select"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        
        if panel.runModal() == .OK {
            Task { @MainActor in
                let urls = panel.urls
                statusMessage = urls.isEmpty
                ? "Selection cancelled."
                : "Selected \(urls.count) folder\(urls.count > 1 ? "s" : "")."
            }
            panel.urls.forEach(scanFolder(at:))
        }
    }
}

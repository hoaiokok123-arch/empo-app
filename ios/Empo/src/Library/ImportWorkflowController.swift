import Foundation
import Observation
import SwiftUI

struct QueuedImportRequest: Identifiable, Hashable, Sendable {
    let id: UUID
    let sourceURL: URL
    let archiveName: String

    init(id: UUID = UUID(), sourceURL: URL, archiveName: String? = nil) {
        self.id = id
        self.sourceURL = sourceURL
        self.archiveName = archiveName ?? sourceURL.deletingPathExtension().lastPathComponent
    }
}

struct ImportSelection: Hashable, Sendable {
    let relativePath: String
    let displayName: String

    init(relativePath: String, displayName: String) {
        self.relativePath = relativePath
        self.displayName = displayName
    }

    init(choice: GameImportValidator.ImportRootChoice) {
        self.init(relativePath: choice.relativePath, displayName: choice.title)
    }
}

struct ImportRootPrompt: Identifiable {
    let request: QueuedImportRequest
    let choices: [GameImportValidator.ImportRootChoice]

    var id: UUID { request.id }
}

struct ImportWorkflowAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ImportPreparedSource: Hashable, Sendable {
    let workingURL: URL
    let cleanupDirectoryURL: URL?

    func cleanup() {
        guard let cleanupDirectoryURL else { return }
        try? FileManager.default.removeItem(at: cleanupDirectoryURL)
    }
}

struct ImportWorkflowSession {
    enum State {
        case staging
        case probing
        case awaitingChoice([GameImportValidator.ImportRootChoice])
        case launching
    }

    let request: QueuedImportRequest
    var preparedSource: ImportPreparedSource?
    var state: State
}

@MainActor @Observable
final class ImportWorkflowController {
    private(set) var currentSession: ImportWorkflowSession?
    private(set) var alert: ImportWorkflowAlert?

    @ObservationIgnored private var queue: [QueuedImportRequest] = []
    @ObservationIgnored private var resolutionTask: Task<Void, Never>?
    @ObservationIgnored private var library: GameLibrary?

    var activePrompt: ImportRootPrompt? {
        guard let currentSession else { return nil }
        guard case .awaitingChoice(let choices) = currentSession.state else { return nil }
        return ImportRootPrompt(request: currentSession.request, choices: choices)
    }

    var importButtonPhase: ImportButton.Phase {
        if activePrompt != nil {
            return .multipleGames
        }
        if currentSession != nil || library?.pendingImports.isEmpty == false {
            return .validating
        }
        return .idle
    }

    func configure(library: GameLibrary) {
        self.library = library
    }

    func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls.map { QueuedImportRequest(sourceURL: $0) })
        startNextResolutionIfPossible()
    }

    func dismissAlert() {
        alert = nil
    }

    func dismissPrompt() {
        cancelChoice()
    }

    func cancelChoice() {
        guard let currentSession else { return }
        guard case .awaitingChoice = currentSession.state else { return }

        currentSession.preparedSource?.cleanup()
        self.currentSession = nil
        startNextResolutionIfPossible()
    }

    func confirmChoice(_ choices: [GameImportValidator.ImportRootChoice]) {
        guard let currentSession else { return }
        guard case .awaitingChoice = currentSession.state else { return }

        launchImports(
            choices.map(ImportSelection.init(choice:)),
            for: currentSession.request.id
        )
    }

    func cancelValidation() {
        queue.removeAll()
        cancelCurrentResolution()
        guard let library else { return }
        for id in library.pendingImports.keys {
            library.cancelPendingImport(id)
        }
    }

    private func startNextResolutionIfPossible() {
        guard currentSession == nil else { return }
        guard !queue.isEmpty else { return }

        beginResolution(for: queue.removeFirst())
    }

    private func beginResolution(for request: QueuedImportRequest) {
        currentSession = ImportWorkflowSession(request: request, state: .staging)

        resolutionTask = Task {
            do {
                let preparedSource = try await ImportWorkflowService.prepareSource(for: request)
                guard isCurrentSession(request.id) else {
                    preparedSource.cleanup()
                    return
                }

                currentSession?.preparedSource = preparedSource
                currentSession?.state = .probing

                let choices = try await ImportWorkflowService.probeChoices(for: preparedSource)
                guard isCurrentSession(request.id) else {
                    preparedSource.cleanup()
                    return
                }

                if choices.count > 1 {
                    currentSession?.state = .awaitingChoice(choices)
                    resolutionTask = nil
                } else {
                    launchImports(choices.map(ImportSelection.init(choice:)), for: request.id)
                }
            } catch is CancellationError {
                guard isCurrentSession(request.id) else { return }
                currentSession?.preparedSource?.cleanup()
                currentSession = nil
                resolutionTask = nil
                startNextResolutionIfPossible()
            } catch {
                guard isCurrentSession(request.id) else { return }

                currentSession?.preparedSource?.cleanup()
                currentSession = nil
                resolutionTask = nil
                presentError(
                    title: "Couldn't import \(quoted(request.archiveName))",
                    message: error.localizedDescription
                )
                startNextResolutionIfPossible()
            }
        }
    }

    private func launchImports(_ selections: [ImportSelection], for requestID: UUID) {
        guard var currentSession else { return }
        guard currentSession.request.id == requestID else { return }
        guard let preparedSource = currentSession.preparedSource else {
            self.currentSession = nil
            resolutionTask = nil
            startNextResolutionIfPossible()
            return
        }

        currentSession.state = .launching
        self.currentSession = currentSession
        resolutionTask = nil

        startImports(
            from: preparedSource,
            archiveName: currentSession.request.archiveName,
            selections: selections
        )

        self.currentSession = nil
        startNextResolutionIfPossible()
    }

    private func startImports(
        from preparedSource: ImportPreparedSource,
        archiveName: String,
        selections: [ImportSelection]
    ) {
        guard !selections.isEmpty else {
            preparedSource.cleanup()
            return
        }

        guard let library else {
            preparedSource.cleanup()
            presentError(
                title: "Couldn't import \(quoted(archiveName))",
                message: "Import system is unavailable right now."
            )
            return
        }

        let completionTracker = ImportCompletionTracker(count: selections.count) {
            preparedSource.cleanup()
        }

        for selection in selections {
            startImport(
                with: library,
                from: preparedSource.workingURL,
                archiveName: archiveName,
                selection: selection,
                completionTracker: completionTracker
            )
        }
    }

    private func startImport(
        with library: GameLibrary,
        from url: URL,
        archiveName: String,
        selection: ImportSelection,
        completionTracker: ImportCompletionTracker
    ) {
        let accessing = url.startAccessingSecurityScopedResource()

        library.importGame(
            from: url,
            preferredGameRootRelativePath: selection.relativePath,
            preferredDisplayName: selection.displayName
        ) { error in
            if accessing { url.stopAccessingSecurityScopedResource() }

            if let error {
                self.presentError(
                    title: "Couldn't import \(quoted(archiveName))",
                    message: error.localizedDescription
                )
            } else {
                Haptics.impact()
            }

            completionTracker.finishOne()
        }
    }

    private func cancelCurrentResolution() {
        guard let currentSession else { return }

        resolutionTask?.cancel()
        resolutionTask = nil
        currentSession.preparedSource?.cleanup()
        self.currentSession = nil
        startNextResolutionIfPossible()
    }

    private func isCurrentSession(_ requestID: UUID) -> Bool {
        currentSession?.request.id == requestID
    }

    private func presentError(title: String, message: String) {
        alert = ImportWorkflowAlert(title: title, message: message)
    }
}

private final class ImportCompletionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private let onComplete: @Sendable () -> Void

    init(count: Int, onComplete: @escaping @Sendable () -> Void) {
        remaining = count
        self.onComplete = onComplete
    }

    func finishOne() {
        let shouldComplete: Bool = lock.withLock {
            remaining -= 1
            return remaining == 0
        }

        if shouldComplete {
            onComplete()
        }
    }
}

private enum ImportWorkflowService {
    static func prepareSource(for request: QueuedImportRequest) async throws -> ImportPreparedSource {
        try await Task(priority: .userInitiated) {
            try prepareSourceSync(for: request)
        }
        .value
    }

    static func probeChoices(
        for preparedSource: ImportPreparedSource
    ) async throws -> [GameImportValidator.ImportRootChoice] {
        try await Task(priority: .userInitiated) {
            try probeChoicesSync(for: preparedSource)
        }
        .value
    }

    private static func prepareSourceSync(for request: QueuedImportRequest) throws -> ImportPreparedSource {
        let url = request.sourceURL
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        guard ArchiveExtractor.Format(extension: url.pathExtension) != nil else {
            return ImportPreparedSource(
                workingURL: url,
                cleanupDirectoryURL: nil
            )
        }

        let fm = FileManager.default
        let archiveCopyDirectoryURL = try ImportTemporaryDirectory.makeScopedDirectory(
            kind: .stagedArchive,
            fm: fm
        )
        let archiveCopyURL = archiveCopyDirectoryURL.appendingPathComponent(url.lastPathComponent)
        var copied = false
        defer {
            if !copied {
                try? fm.removeItem(at: archiveCopyDirectoryURL)
            }
        }

        try fm.copyItem(at: url, to: archiveCopyURL)
        copied = true

        return ImportPreparedSource(workingURL: archiveCopyURL, cleanupDirectoryURL: archiveCopyDirectoryURL)
    }

    private static func probeChoicesSync(
        for preparedSource: ImportPreparedSource
    ) throws -> [GameImportValidator.ImportRootChoice] {
        let url = preparedSource.workingURL
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        return try GameImportValidator.importRootChoices(for: url)
    }
}

private func quoted(_ value: String) -> String {
    "\"\(value)\""
}

extension NSLock {
    fileprivate func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

import AppKit
import Foundation
import UniformTypeIdentifiers
import Darwin

private struct WindowsChapterFile {
    let number: Int
    let dataFile: URL
}

private struct PatchInstallResult {
    let status: String
    let terminalOutput: String
}

private struct PatchSaveChoice {
    let instanceName: String?
}

private struct GameInstance: Identifiable {
    let id: UUID
    let name: String
    let chapter: Int
    let createdAt: Date
    let fileURL: URL
}

private struct GameInstanceMetadata: Codable {
    let id: UUID
    let name: String
    let chapter: Int
    let createdAt: Date
}

@MainActor
private final class PatchDropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var isHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedXdelta(from: sender) != nil else { return [] }
        isHighlighted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            isHighlighted = false
            needsDisplay = true
        }
        guard let url = droppedXdelta(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        path.lineWidth = isHighlighted ? 2 : 1
        (isHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    private func droppedXdelta(from sender: NSDraggingInfo) -> URL? {
        guard let files = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
        files.count == 1,
        let file = files.first,
        file.pathExtension.lowercased() == "xdelta",
        file.isFileURL else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return file
    }
}

@MainActor
private final class SongDropView: NSView {
    var onDrop: ((URL) -> Void)?
    private var isHighlighted = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedSong(from: sender) != nil else { return [] }
        isHighlighted = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isHighlighted = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer {
            isHighlighted = false
            needsDisplay = true
        }
        guard let url = droppedSong(from: sender) else { return false }
        onDrop?(url)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        path.lineWidth = isHighlighted ? 2 : 1
        (isHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.stroke()
    }

    private func droppedSong(from sender: NSDraggingInfo) -> URL? {
        guard let files = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
        files.count == 1,
        let file = files.first,
        file.pathExtension.lowercased() == "ogg",
        file.isFileURL else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return file
    }
}

private final class OperationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func attach(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func detach() {
        lock.lock()
        process = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning {
            process.terminate()
        }
    }

}

@MainActor
private final class InstallerWindow: NSObject, NSApplicationDelegate {
    private let fileManager = FileManager.default
    private let appSupportKey = "WindowsDeltarunePath"
    private var windowsFolder: URL?
    private var patchFiles: [URL] = []
    private var macApps: [URL] = []
    private var gameInstances: [GameInstance] = []
    private var activeCancellation: OperationCancellation?
    private var terminateAfterCancellation = false
    private let chapterPicker = NSPopUpButton()
    private let instancePicker = NSPopUpButton()
    private let macPicker = NSPopUpButton()
    private let windowsPathLabel = NSTextField(wrappingLabelWithString: "Not selected")
    private let patchPathLabel = NSTextField(wrappingLabelWithString: "No mod selected")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Choose a patch and your Windows game folder to begin.")
    private let terminalTextView = NSTextView()
    private let installButton = NSButton(title: "Patch Selected Chapter", target: nil, action: nil)
    private let importInstanceButton = NSButton(title: "Import game.ios…", target: nil, action: nil)
    private let applyInstanceButton = NSButton(title: "Apply Instance", target: nil, action: nil)
    private let removeInstanceButton = NSButton(title: "Remove Instance", target: nil, action: nil)
    private let showInstancesButton = NSButton(title: "Show All Instances in Finder", target: nil, action: nil)
    private let importSongButton = NSButton(title: "Import Custom Song…", target: nil, action: nil)
    private let cancelPatchButton = NSButton(title: "Cancel Installation", target: nil, action: nil)
    private let backupOriginalButton = NSButton(title: "Back Up All Original Mac Files", target: nil, action: nil)
    private let restoreOriginalButton = NSButton(title: "Restore Original", target: nil, action: nil)
    private let restoreAllOriginalButton = NSButton(title: "Restore All Original Mac Files", target: nil, action: nil)
    private let copyConsoleButton = NSButton(title: "Copy Console", target: nil, action: nil)
    private let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        installApplicationMenu()
        buildWindow()
        discoverMacApps()
        if let savedPath = UserDefaults.standard.string(forKey: appSupportKey),
           fileManager.fileExists(atPath: savedPath),
           !windowsChapterFiles(in: URL(fileURLWithPath: savedPath, isDirectory: true)).isEmpty {
            windowsFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            UserDefaults.standard.removeObject(forKey: appSupportKey)
        }
        updateLabels()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if macApps.isEmpty {
            chooseMacApp()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func installApplicationMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit DELTARUNE Mod Installer",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        window.title = "DELTARUNE Mod Installer"
        window.isReleasedWhenClosed = false

        let title = NSTextField(labelWithString: "Install a DELTARUNE mod")
        title.font = .boldSystemFont(ofSize: 23)

        let intro = NSTextField(wrappingLabelWithString:
            "Choose an .xdelta patch and the matching Windows game source. Patched files are saved as named instances.")
        intro.maximumNumberOfLines = 3

        let windowsButton = NSButton(title: "Choose Windows game folder…", target: self, action: #selector(chooseWindowsFolder))
        windowsButton.bezelStyle = .rounded
        windowsPathLabel.maximumNumberOfLines = 2

        let patchButton = NSButton(title: "Choose mod files…", target: self, action: #selector(choosePatch))
        patchButton.bezelStyle = .rounded
        patchPathLabel.maximumNumberOfLines = 2

        let chapterLabel = NSTextField(labelWithString: "Chapter to patch:")
        chapterLabel.font = .boldSystemFont(ofSize: 13)
        chapterPicker.translatesAutoresizingMaskIntoConstraints = false
        chapterPicker.controlSize = .regular
        chapterPicker.widthAnchor.constraint(equalToConstant: 240).isActive = true
        chapterPicker.target = self
        chapterPicker.action = #selector(chapterSelectionChanged)

        let macLabel = NSTextField(labelWithString: "Mac DELTARUNE game files:")
        macLabel.font = .boldSystemFont(ofSize: 13)
        macPicker.translatesAutoresizingMaskIntoConstraints = false
        macPicker.controlSize = .regular
        macPicker.widthAnchor.constraint(equalToConstant: 650).isActive = true
        macPicker.target = self
        macPicker.action = #selector(macTargetSelectionChanged)
        let chooseMacButton = NSButton(title: "Choose Mac path…", target: self, action: #selector(chooseMacApp))
        chooseMacButton.bezelStyle = .rounded

        let windowsRow = horizontalRow(windowsButton, windowsPathLabel)
        let patchRow = horizontalRow(patchButton, patchPathLabel)
        patchRow.translatesAutoresizingMaskIntoConstraints = false
        let patchDropView = PatchDropView()
        patchDropView.translatesAutoresizingMaskIntoConstraints = false
        patchDropView.onDrop = { [weak self] url in
            guard let self else { return }
            self.patchFiles = [url]
            self.updateLabels()
            self.statusLabel.stringValue = "Selected .xdelta mod: \(url.lastPathComponent)"
        }
        patchDropView.addSubview(patchRow)
        NSLayoutConstraint.activate([
            patchRow.leadingAnchor.constraint(equalTo: patchDropView.leadingAnchor, constant: 10),
            patchRow.trailingAnchor.constraint(equalTo: patchDropView.trailingAnchor, constant: -10),
            patchRow.centerYAnchor.constraint(equalTo: patchDropView.centerYAnchor),
            patchDropView.heightAnchor.constraint(equalToConstant: 58)
        ])
        let chapterRow = horizontalRow(chapterLabel, chapterPicker)
        let instanceLabel = NSTextField(labelWithString: "Saved instances:")
        instanceLabel.font = .boldSystemFont(ofSize: 13)
        instancePicker.translatesAutoresizingMaskIntoConstraints = false
        instancePicker.controlSize = .regular
        instancePicker.widthAnchor.constraint(equalToConstant: 240).isActive = true
        importInstanceButton.target = self
        importInstanceButton.action = #selector(importInstance)
        importInstanceButton.bezelStyle = .rounded
        applyInstanceButton.target = self
        applyInstanceButton.action = #selector(applySelectedInstance)
        applyInstanceButton.bezelStyle = .rounded
        let instanceRow = horizontalRow(instanceLabel, instancePicker, importInstanceButton, applyInstanceButton)
        removeInstanceButton.target = self
        removeInstanceButton.action = #selector(removeSelectedInstance)
        removeInstanceButton.bezelStyle = .rounded
        showInstancesButton.target = self
        showInstancesButton.action = #selector(showAllInstancesInFinder)
        showInstancesButton.bezelStyle = .rounded
        let instanceManagementRow = horizontalRow(removeInstanceButton, showInstancesButton)
        let songDropView = SongDropView()
        songDropView.translatesAutoresizingMaskIntoConstraints = false
        songDropView.onDrop = { [weak self] url in
            self?.installCustomSong(from: url)
        }
        importSongButton.target = self
        importSongButton.action = #selector(chooseCustomSong)
        importSongButton.bezelStyle = .rounded
        let songDropLabel = NSTextField(labelWithString: "Choose or drop an .ogg file to add it to the game’s shared mus folder.")
        songDropView.addSubview(importSongButton)
        songDropView.addSubview(songDropLabel)
        importSongButton.translatesAutoresizingMaskIntoConstraints = false
        songDropLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            songDropView.heightAnchor.constraint(equalToConstant: 48),
            importSongButton.leadingAnchor.constraint(equalTo: songDropView.leadingAnchor, constant: 10),
            importSongButton.centerYAnchor.constraint(equalTo: songDropView.centerYAnchor),
            songDropLabel.leadingAnchor.constraint(equalTo: importSongButton.trailingAnchor, constant: 12),
            songDropLabel.trailingAnchor.constraint(lessThanOrEqualTo: songDropView.trailingAnchor, constant: -10),
            songDropLabel.centerYAnchor.constraint(equalTo: songDropView.centerYAnchor)
        ])
        let macRow = horizontalRow(macPicker, chooseMacButton)
        backupOriginalButton.target = self
        backupOriginalButton.action = #selector(backUpOriginalMacFile)
        backupOriginalButton.bezelStyle = .rounded
        restoreOriginalButton.target = self
        restoreOriginalButton.action = #selector(restoreOriginalMacFile)
        restoreOriginalButton.bezelStyle = .rounded
        restoreAllOriginalButton.target = self
        restoreAllOriginalButton.action = #selector(restoreAllOriginalMacFiles)
        restoreAllOriginalButton.bezelStyle = .rounded
        let originalRow = horizontalRow(backupOriginalButton, restoreOriginalButton, restoreAllOriginalButton)
        updateOriginalButtons()

        installButton.target = self
        installButton.action = #selector(installPatch)
        installButton.bezelStyle = .rounded
        installButton.keyEquivalent = "\r"
        installButton.controlSize = .large
        installButton.widthAnchor.constraint(equalToConstant: 280).isActive = true
        cancelPatchButton.target = self
        cancelPatchButton.action = #selector(cancelInstallation)
        cancelPatchButton.bezelStyle = .rounded
        cancelPatchButton.isEnabled = false
        let patchActionRow = horizontalRow(installButton, cancelPatchButton)

        statusLabel.maximumNumberOfLines = 4
        statusLabel.stringValue = "Choose a mod and chapter."
        let outputLabel = NSTextField(labelWithString: "CLI output (stdout and stderr):")
        outputLabel.font = .boldSystemFont(ofSize: 13)
        let outputScrollView = NSScrollView()
        outputScrollView.hasVerticalScroller = true
        outputScrollView.hasHorizontalScroller = true
        outputScrollView.borderType = .bezelBorder
        outputScrollView.drawsBackground = true
        outputScrollView.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.1, alpha: 1)
        terminalTextView.isEditable = false
        terminalTextView.isSelectable = true
        terminalTextView.drawsBackground = false
        terminalTextView.textColor = NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.72, alpha: 1)
        terminalTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        terminalTextView.string = ""
        terminalTextView.minSize = NSSize(width: 0, height: 150)
        terminalTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        terminalTextView.isVerticallyResizable = true
        terminalTextView.isHorizontallyResizable = true
        terminalTextView.textContainer?.widthTracksTextView = false
        outputScrollView.documentView = terminalTextView
        outputScrollView.heightAnchor.constraint(equalToConstant: 155).isActive = true
        copyConsoleButton.target = self
        copyConsoleButton.action = #selector(copyConsoleOutput)
        copyConsoleButton.bezelStyle = .rounded
        let outputHeader = horizontalRow(outputLabel, copyConsoleButton)
        outputHeader.widthAnchor.constraint(equalToConstant: 660).isActive = true

        let stack = NSStackView(views: [
            title, intro, separator(), windowsRow, patchDropView, chapterRow, instanceRow, instanceManagementRow,
            songDropView, macLabel, macRow,
            originalRow, patchActionRow, statusLabel, outputHeader, outputScrollView
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(7, after: title)
        stack.setCustomSpacing(4, after: macLabel)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
            intro.widthAnchor.constraint(equalToConstant: 660),
            statusLabel.widthAnchor.constraint(equalToConstant: 660),
            windowsRow.widthAnchor.constraint(equalToConstant: 660),
            patchDropView.widthAnchor.constraint(equalToConstant: 660),
            chapterRow.widthAnchor.constraint(equalToConstant: 660),
            instanceRow.widthAnchor.constraint(equalToConstant: 660),
            instanceManagementRow.widthAnchor.constraint(equalToConstant: 660),
            songDropView.widthAnchor.constraint(equalToConstant: 660),
            macRow.widthAnchor.constraint(equalToConstant: 660),
            originalRow.widthAnchor.constraint(equalToConstant: 660),
            patchActionRow.widthAnchor.constraint(equalToConstant: 660),
            outputScrollView.widthAnchor.constraint(equalToConstant: 660)
        ])
        window.contentView = content
    }

    private func horizontalRow(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        return row
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 660).isActive = true
        return box
    }

    @objc private func chooseWindowsFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Windows DELTARUNE files"
        panel.message = "Choose your copied Windows game folder containing chapterN_win/data.win. Do not choose the Mac folder containing chapterN_mac."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if let windowsFolder { panel.directoryURL = windowsFolder }
        while panel.runModal() == .OK, let url = panel.url {
            guard !windowsChapterFiles(in: url).isEmpty else {
                let macChapterCount = chapterDirectories(in: url, suffix: "_mac").count
                if macChapterCount > 0 {
                    showError("This is the Mac game folder: it contains chapterN_mac folders, not the Windows source files. Choose the Windows DELTARUNE copy with chapterN_win/data.win folders. The Mac destination is selected separately below.")
                } else {
                    showError("No chapterN_win/data.win files were found. Choose the copied Windows DELTARUNE folder that contains folders such as chapter1_win and chapter3_win.")
                }
                continue
            }
            windowsFolder = url
            UserDefaults.standard.set(url.path, forKey: appSupportKey)
            updateLabels()
            return
        }
    }

    @objc private func choosePatch() {
        let panel = NSOpenPanel()
        panel.title = "Choose DELTARUNE mod files"
        panel.message = "Choose one .xdelta patch."
        panel.allowedContentTypes = [UTType(filenameExtension: "xdelta") ?? .data]
        panel.allowsOtherFileTypes = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let patchFile = patchFiles.first { panel.directoryURL = patchFile.deletingLastPathComponent() }
        guard panel.runModal() == .OK else { return }
        patchFiles = panel.urls
        updateLabels()
    }

    @objc private func chooseMacApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Mac DELTARUNE path"
        panel.message = "Choose a folder containing chapter1_mac, chapter2_mac, etc., or choose DELTARUNE.app."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        let defaultGameFolder = defaultMacGameFolder()
        if fileManager.fileExists(atPath: defaultGameFolder.path) {
            panel.directoryURL = defaultGameFolder.deletingLastPathComponent()
        }
        while panel.runModal() == .OK, let url = panel.url {
            let selectedApps = validMacApps(at: url)
            if !selectedApps.isEmpty {
                macApps = uniqueURLs(selectedApps + macApps)
                UserDefaults.standard.set(selectedApps[0].path, forKey: "MacDeltaruneAppPath")
                updateLabels(selecting: selectedApps[0])
                return
            }
            showError("No Mac DELTARUNE files were found there. Choose a folder with chapterN_mac folders, the Steam DELTARUNE folder, or DELTARUNE.app.")
        }
    }

    @objc private func installPatch() {
        guard let patch = patchFiles.first,
              patch.pathExtension.lowercased() == "xdelta" else {
            showError("Choose one .xdelta patch.")
            return
        }
        guard fileManager.fileExists(atPath: patch.path) else {
            showError("The selected mod file no longer exists.")
            return
        }
        guard macPicker.indexOfSelectedItem >= 0,
              macPicker.indexOfSelectedItem < macApps.count else {
            showError("No Mac DELTARUNE target was found. Choose a folder with chapterN_mac folders or a DELTARUNE.app.")
            return
        }
        let macApp = macApps[macPicker.indexOfSelectedItem]
        guard let selectedChapter = chapterPicker.selectedItem?.representedObject as? Int,
              chapterDirectories(in: resourcesDirectory(for: macApp), suffix: "_mac").contains(selectedChapter) else {
            showError("Choose a chapter to patch.")
            return
        }
        guard let windowsFolder else {
            showError("Choose the Windows DELTARUNE source folder before applying an .xdelta patch.")
            return
        }
        guard let chapterSource = windowsChapterFiles(in: windowsFolder).first(where: { $0.number == selectedChapter }) else {
            showError("No Windows chapter\(selectedChapter)_win/data.win source was found. Choose the copied Windows DELTARUNE folder containing the matching chapter.")
            return
        }
        let suggestedName = patch.deletingPathExtension().lastPathComponent
        guard let patchSaveChoice = requestPatchSaveChoice(
            chapter: selectedChapter,
            defaultName: suggestedName
        ) else {
            return
        }
        let instanceName = patchSaveChoice.instanceName
        if let instanceName {
            do {
                try ensureUniqueInstanceName(instanceName, chapter: selectedChapter)
            } catch {
                showError(error.localizedDescription)
                return
            }
        }

        let cancellation = OperationCancellation()
        terminateAfterCancellation = false
        activeCancellation = cancellation
        installButton.isEnabled = false
        statusLabel.stringValue = "Checking the xdelta patch against Chapter \(selectedChapter)…"
        terminalTextView.string = ""
        installButton.title = "Patching…"
        cancelPatchButton.isEnabled = true
        setInstanceControlsEnabled(false)

        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.findMatchingChapter(
                        chapters: [chapterSource],
                        patch: patch,
                        appURL: macApp,
                        instanceName: instanceName,
                        cancellation: cancellation
                    )
                }.value
                self?.activeCancellation = nil
                self?.cancelPatchButton.isEnabled = false
                self?.statusLabel.stringValue = result.status
                self?.terminalTextView.string = result.terminalOutput
                self?.terminalTextView.scrollToEndOfDocument(nil)
                self?.statusLabel.stringValue += " Click Done to finish Installer."
                self?.reloadInstances()
                if let instanceName {
                    self?.selectInstance(named: instanceName)
                }
                self?.installButton.title = "Done — Finish Installer"
                self?.installButton.action = #selector(InstallerWindow.finishInstaller)
                self?.installButton.isEnabled = true
            } catch {
                self?.activeCancellation = nil
                self?.cancelPatchButton.isEnabled = false
                let wasCancelled = cancellation.isCancelled || (error as? InstallerError)?.isCancelled == true
                self?.statusLabel.stringValue = wasCancelled
                    ? "Installation cancelled. The installer will close after stopping the current operation."
                    : "Patch failed. Correct the selections and try again."
                if let installerError = error as? InstallerError {
                    self?.terminalTextView.string = installerError.terminalOutput
                } else {
                    self?.terminalTextView.string = ""
                }
                self?.terminalTextView.scrollToEndOfDocument(nil)
                self?.installButton.title = "Patch Selected Chapter"
                self?.installButton.action = #selector(InstallerWindow.installPatch)
                self?.installButton.isEnabled = true
            }
            if self?.terminateAfterCancellation == true {
                self?.terminateAfterCancellation = false
                NSApp.terminate(nil)
                return
            }
            self?.setInstanceControlsEnabled(true)
            self?.updateOriginalButtons()
        }
    }

    @objc private func cancelInstallation() {
        guard let activeCancellation else { return }
        terminateAfterCancellation = true
        cancelPatchButton.isEnabled = false
        installButton.isEnabled = false
        statusLabel.stringValue = "Cancelling installation and stopping the current operation…"
        activeCancellation.cancel()
    }

    @objc private func copyConsoleOutput() {
        let output = terminalTextView.string
        guard !output.isEmpty else {
            statusLabel.stringValue = "The console is empty."
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output, forType: .string)
        statusLabel.stringValue = "Console output copied."
    }

    @objc private func chapterSelectionChanged() {
        reloadInstances()
        updateOriginalButtons()
    }

    @objc private func macTargetSelectionChanged() {
        updateChapterPicker()
        updateOriginalButtons()
    }

    @objc private func backUpOriginalMacFile() {
        terminalTextView.string = ""
        guard let target = selectedMacTarget() else {
            showError("Choose a Mac DELTARUNE target first.")
            return
        }
        do {
            let result = try Self.backUpOriginalMacFiles(appURL: target)
            statusLabel.stringValue = result.status
            terminalTextView.string = result.terminalOutput
            updateOriginalButtons()
        } catch {
            statusLabel.stringValue = "Could not back up all original Mac game files."
            terminalTextView.string = (error as? InstallerError)?.terminalOutput ?? ""
            showError(error.localizedDescription)
        }
    }

    @objc private func restoreOriginalMacFile() {
        guard let target = selectedMacTarget(),
              let chapter = chapterPicker.selectedItem?.representedObject as? Int else {
            showError("Choose a Mac DELTARUNE target and chapter first.")
            return
        }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Restore the original Chapter \(chapter) game file?"
        confirmation.informativeText = "The current game.ios will be replaced by game.ios.original without creating another backup."
        confirmation.addButton(withTitle: "Restore Original")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        terminalTextView.string = ""
        do {
            let result = try Self.restoreOriginalMacFile(appURL: target, chapter: chapter)
            statusLabel.stringValue = result.status
            terminalTextView.string = result.terminalOutput
            updateOriginalButtons()
        } catch {
            statusLabel.stringValue = "Could not restore the original Mac game file."
            terminalTextView.string = ""
            showError(error.localizedDescription)
        }
    }

    @objc private func restoreAllOriginalMacFiles() {
        guard let target = selectedMacTarget() else {
            showError("Choose a Mac DELTARUNE target first.")
            return
        }
        let resources = resourcesDirectory(for: target)
        let chapters = chapterDirectories(in: resources, suffix: "_mac").filter { chapter in
            fileManager.fileExists(
                atPath: resources.appendingPathComponent("chapter\(chapter)_mac/game.ios.original").path
            )
        }
        guard !chapters.isEmpty else {
            showError("No original game.ios backups were found in the selected Mac target.")
            return
        }
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Restore all original Mac game files?"
        confirmation.informativeText = "This replaces Chapters \(chapters.map(String.init).joined(separator: ", ")) game.ios files with their game.ios.original backups. No additional backups will be created."
        confirmation.addButton(withTitle: "Restore All")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        terminalTextView.string = ""
        do {
            let result = try Self.restoreOriginalMacFiles(appURL: target)
            statusLabel.stringValue = result.status
            updateOriginalButtons()
        } catch {
            statusLabel.stringValue = "Could not restore all original Mac game files."
            showError(error.localizedDescription)
            updateOriginalButtons()
        }
    }

    private func selectedMacTarget() -> URL? {
        guard macPicker.indexOfSelectedItem >= 0,
              macPicker.indexOfSelectedItem < macApps.count else { return nil }
        return macApps[macPicker.indexOfSelectedItem]
    }

    private func updateOriginalButtons() {
        importSongButton.isEnabled = activeCancellation == nil && selectedMacTarget() != nil
        guard activeCancellation == nil else {
            backupOriginalButton.isEnabled = false
            restoreOriginalButton.isEnabled = false
            restoreAllOriginalButton.isEnabled = false
            return
        }
        guard let target = selectedMacTarget() else {
            backupOriginalButton.isEnabled = false
            restoreOriginalButton.isEnabled = false
            restoreAllOriginalButton.isEnabled = false
            return
        }
        let resources = resourcesDirectory(for: target)
        let chapters = chapterDirectories(in: resources, suffix: "_mac")
        backupOriginalButton.isEnabled = chapters.contains { chapter in
            fileManager.fileExists(
                atPath: resources.appendingPathComponent("chapter\(chapter)_mac/game.ios").path
            )
        }
        restoreAllOriginalButton.isEnabled = chapters.contains { chapter in
            fileManager.fileExists(
                atPath: resources.appendingPathComponent("chapter\(chapter)_mac/game.ios.original").path
            )
        }
        guard let chapter = chapterPicker.selectedItem?.representedObject as? Int else {
            restoreOriginalButton.isEnabled = false
            return
        }
        let folder = resources.appendingPathComponent("chapter\(chapter)_mac", isDirectory: true)
        restoreOriginalButton.isEnabled = fileManager.fileExists(atPath: folder.appendingPathComponent("game.ios.original").path)
    }

    @objc private func importInstance() {
        terminalTextView.string = ""
        guard let chapter = chapterPicker.selectedItem?.representedObject as? Int else {
            showError("Choose a chapter before importing a game.ios instance.")
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Import a patched game.ios"
        panel.message = "Choose an existing patched game.ios or backup file for Chapter \(chapter)."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            let suggestedName = source.deletingPathExtension().lastPathComponent
            guard let name = requestInstanceName(
                title: "Name this instance",
                message: "Save this file as a Chapter \(chapter) instance.",
                defaultValue: suggestedName
            ) else { return }
            let saved = try saveInstance(from: source, name: name, chapter: chapter)
            reloadInstances()
            selectInstance(id: saved.id)
            terminalTextView.string = ""
            statusLabel.stringValue = "Instance imported. Select it and click Apply Instance to activate it."
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func removeSelectedInstance() {
        guard instancePicker.indexOfSelectedItem >= 0,
              instancePicker.indexOfSelectedItem < gameInstances.count else {
            showError("Choose a saved instance to remove.")
            return
        }
        let instance = gameInstances[instancePicker.indexOfSelectedItem]
        let confirmation = NSAlert()
        confirmation.alertStyle = .warning
        confirmation.messageText = "Remove this saved instance?"
        confirmation.informativeText = "“\(instance.name)” for Chapter \(instance.chapter) will be permanently deleted from this Mac. If it is active, the current game file will not be changed."
        confirmation.addButton(withTitle: "Remove Instance")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Self.removeInstance(instance, fileManager: fileManager)
            reloadInstances()
            statusLabel.stringValue = "Removed instance “\(instance.name)” from Chapter \(instance.chapter)."
        } catch {
            showError("Could not remove the saved instance: \(error.localizedDescription)")
        }
    }

    @objc private func showAllInstancesInFinder() {
        do {
            let root = try Self.instanceRoot(fileManager: fileManager)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(root) else {
                showError("Finder could not open the saved instances folder:\n\(root.path)")
                return
            }
            statusLabel.stringValue = "Opened all saved instances in Finder."
        } catch {
            showError("Could not open the saved instances folder: \(error.localizedDescription)")
        }
    }

    @objc private func chooseCustomSong() {
        let panel = NSOpenPanel()
        panel.title = "Choose a custom song"
        panel.message = "Choose an .ogg file to copy into the selected DELTARUNE target’s shared mus folder."
        panel.allowedContentTypes = [UTType(filenameExtension: "ogg") ?? .audio]
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        installCustomSong(from: url)
    }

    private func installCustomSong(from source: URL) {
        guard let target = selectedMacTarget() else {
            showError("Choose the Mac DELTARUNE target before importing a custom song.")
            return
        }
        guard source.pathExtension.lowercased() == "ogg" else {
            showError("Custom songs must be .ogg files.")
            return
        }
        do {
            guard let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
                  sourceAttributes[.type] as? FileAttributeType == .typeRegular,
                  (sourceAttributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                throw InstallerError.installFailed("The selected song is missing, empty, or not a regular file.", terminalOutput: "")
            }
            let musicFolder = resourcesDirectory(for: target).appendingPathComponent("mus", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: musicFolder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw InstallerError.installFailed(
                    "The selected DELTARUNE target does not contain its shared mus folder.",
                    terminalOutput: ""
                )
            }
            let destination = musicFolder.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw InstallerError.installFailed(
                    "A song named “\(source.lastPathComponent)” already exists in mus. Rename your song before importing it; existing music is never overwritten.",
                    terminalOutput: ""
                )
            }
            let staged = musicFolder.appendingPathComponent(".custom-song-\(UUID().uuidString).tmp")
            do {
                try fileManager.copyItem(at: source, to: staged)
                guard let stagedAttributes = try? fileManager.attributesOfItem(atPath: staged.path),
                      stagedAttributes[.type] as? FileAttributeType == .typeRegular,
                      (stagedAttributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
                    throw InstallerError.installFailed("The copied song is empty or invalid.", terminalOutput: "")
                }
                try fileManager.moveItem(at: staged, to: destination)
            } catch {
                try? fileManager.removeItem(at: staged)
                throw error
            }
            statusLabel.stringValue = "Added “\(source.lastPathComponent)” to the shared mus folder. Your mod can reference it by filename."
        } catch {
            showError("Could not add the custom song: \(error.localizedDescription)")
        }
    }

    @objc private func applySelectedInstance() {
        guard instancePicker.indexOfSelectedItem >= 0,
              instancePicker.indexOfSelectedItem < gameInstances.count else {
            showError("Choose a saved instance to apply, or import a patched game.ios first.")
            return
        }
        guard macPicker.indexOfSelectedItem >= 0,
              macPicker.indexOfSelectedItem < macApps.count else {
            showError("Choose a Mac DELTARUNE target before applying an instance.")
            return
        }
        let instance = gameInstances[instancePicker.indexOfSelectedItem]
        let macApp = macApps[macPicker.indexOfSelectedItem]
        guard chapterDirectories(in: resourcesDirectory(for: macApp), suffix: "_mac").contains(instance.chapter) else {
            showError("The selected Mac target does not contain chapter\(instance.chapter)_mac.")
            return
        }

        installButton.isEnabled = false
        statusLabel.stringValue = "Applying instance \"\(instance.name)\" to Chapter \(instance.chapter)…"
        terminalTextView.string = ""
        let cancellation = OperationCancellation()
        terminateAfterCancellation = false
        activeCancellation = cancellation
        cancelPatchButton.isEnabled = true
        installButton.title = "Applying…"
        setInstanceControlsEnabled(false)

        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.activateInstance(instance, appURL: macApp, cancellation: cancellation)
                }.value
                self?.activeCancellation = nil
                self?.cancelPatchButton.isEnabled = false
                self?.statusLabel.stringValue = result.status
                self?.terminalTextView.string = result.terminalOutput
                self?.terminalTextView.scrollToEndOfDocument(nil)
                self?.installButton.title = "Done — Finish Installer"
                self?.installButton.action = #selector(InstallerWindow.finishInstaller)
                self?.installButton.isEnabled = true
            } catch {
                self?.activeCancellation = nil
                self?.cancelPatchButton.isEnabled = false
                self?.statusLabel.stringValue = cancellation.isCancelled
                    ? "Installation cancelled. The installer will close after stopping the current operation."
                    : "Instance could not be applied. The saved instance was kept."
                self?.terminalTextView.string = (error as? InstallerError)?.terminalOutput ?? ""
                self?.terminalTextView.scrollToEndOfDocument(nil)
                self?.installButton.isEnabled = true
            }
            if self?.terminateAfterCancellation == true {
                self?.terminateAfterCancellation = false
                NSApp.terminate(nil)
                return
            }
            self?.setInstanceControlsEnabled(true)
        }
    }

    @objc private func finishInstaller() {
        NSApp.terminate(nil)
    }

    private func discoverMacApps() {
        let defaultFolder = defaultMacGameFolder()
        var steamRoots: [URL] = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Steam", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".steam/steam", isDirectory: true)
        ]
        let initialRoots = steamRoots
        for root in initialRoots {
            let vdf = root.appendingPathComponent("steamapps/libraryfolders.vdf")
            guard let contents = try? String(contentsOf: vdf, encoding: .utf8) else { continue }
            let pattern = #""path"\s*"((?:\\.|[^"])*)""#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(contents.startIndex..., in: contents)
            for match in regex.matches(in: contents, range: range) where match.numberOfRanges > 1 {
                guard let valueRange = Range(match.range(at: 1), in: contents) else { continue }
                let path = String(contents[valueRange]).replacingOccurrences(of: "\\\\", with: "\\")
                steamRoots.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }

        var found = validMacApps(at: defaultFolder)
        for root in uniqueURLs(steamRoots) {
            let common = root.appendingPathComponent("steamapps/common", isDirectory: true)
            guard let gameFolders = try? fileManager.contentsOfDirectory(
                at: common,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for gameFolder in gameFolders where !gameFolder.path.contains("__MACOSX") {
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: gameFolder,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for app in contents where app.pathExtension.lowercased() == "app" {
                    found.append(contentsOf: validMacApps(at: app))
                }
            }
        }
        macApps = uniqueURLs(found)

        if let savedPath = UserDefaults.standard.string(forKey: "MacDeltaruneAppPath"),
           let saved = macApps.first(where: { $0.path == savedPath }) {
            macApps.removeAll { $0.path == saved.path }
            macApps.insert(saved, at: 0)
        } else if let preferred = macApps.first(where: {
            $0.standardizedFileURL == defaultFolder.standardizedFileURL
                || $0.deletingLastPathComponent().standardizedFileURL == defaultFolder.standardizedFileURL
        }) {
            macApps.removeAll { $0.path == preferred.path }
            macApps.insert(preferred, at: 0)
        } else {
            macApps.sort { lhs, rhs in
                return lhs.path.localizedCaseInsensitiveCompare(rhs.path) == .orderedAscending
            }
        }
    }

    private func defaultMacGameFolder() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam/steamapps/common/DELTARUNE", isDirectory: true)
    }

    private func validMacApps(at path: URL) -> [URL] {
        if path.pathExtension.lowercased() == "app" {
            return hasMacChapters(in: path) ? [path] : []
        }
        if hasMacChapters(in: path) {
            return [path]
        }

        guard let enumerator = fileManager.enumerator(
            at: path,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        var candidates: [URL] = []
        while let candidate = enumerator.nextObject() as? URL {
            if candidate.pathExtension.lowercased() == "app" {
                candidates.append(candidate)
            }
        }
        return candidates.filter { hasMacChapters(in: $0) }
    }

    private func hasMacChapters(in app: URL) -> Bool {
        !chapterDirectories(in: resourcesDirectory(for: app), suffix: "_mac").isEmpty
    }

    private func windowsChapterFiles(in root: URL) -> [WindowsChapterFile] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var result: [WindowsChapterFile] = []
        while let file = enumerator.nextObject() as? URL {
            let folderName = file.deletingLastPathComponent().lastPathComponent
            guard file.lastPathComponent.lowercased() == "data.win",
                  folderName.range(
                    of: #"^chapter([0-9]+)_win(?:dows)?$"#,
                    options: [.regularExpression, .caseInsensitive]
                  ) != nil,
                  let chapterRange = folderName.range(
                    of: #"(?<=chapter)[0-9]+(?=_win(?:dows)?)"#,
                    options: [.regularExpression, .caseInsensitive]
                  ),
                  let chapter = Int(folderName[chapterRange]) else {
                continue
            }
            result.append(WindowsChapterFile(number: chapter, dataFile: file))
        }
        return result.sorted { $0.dataFile.path < $1.dataFile.path }
    }

    private func updateLabels(selecting selected: URL? = nil) {
        windowsPathLabel.stringValue = windowsFolder?.path ?? "Not selected"
        patchPathLabel.stringValue = patchFiles.isEmpty
            ? "No mod selected — drop one .xdelta file here"
            : patchFiles.map(\.lastPathComponent).joined(separator: ", ")
        macPicker.removeAllItems()
        for app in macApps {
            let chapters = chapterDirectories(in: resourcesDirectory(for: app), suffix: "_mac")
                .map { "Chapter \($0)" }.joined(separator: ", ")
            let name = app.lastPathComponent
            let title = "\(name) — \(chapters)"
            macPicker.addItem(withTitle: title)
            macPicker.lastItem?.representedObject = app.path
        }
        if let selected, let index = macApps.firstIndex(where: { $0.path == selected.path }) {
            macPicker.selectItem(at: index)
        } else if macPicker.numberOfItems > 0 {
            macPicker.selectItem(at: 0)
        }
        updateChapterPicker()
        updateOriginalButtons()
    }

    private func updateChapterPicker() {
        let previousSelection = chapterPicker.selectedItem?.representedObject as? Int
        chapterPicker.removeAllItems()
        let windowsChapters = windowsFolder.map { windowsChapterFiles(in: $0).map(\.number) } ?? []
        let macChapters = selectedMacTarget().map {
            chapterDirectories(in: resourcesDirectory(for: $0), suffix: "_mac")
        } ?? []
        for chapter in Set(windowsChapters + macChapters).sorted() {
            chapterPicker.addItem(withTitle: "Chapter \(chapter)")
            chapterPicker.lastItem?.representedObject = chapter
        }
        if let previousSelection,
           let index = (0..<chapterPicker.numberOfItems).first(where: {
               chapterPicker.item(at: $0)?.representedObject as? Int == previousSelection
           }) {
            chapterPicker.selectItem(at: index)
        } else if chapterPicker.numberOfItems > 0 {
            chapterPicker.selectItem(at: 0)
        }
        reloadInstances()
    }

    private func reloadInstances() {
        guard let chapter = chapterPicker.selectedItem?.representedObject as? Int else {
            gameInstances = []
            instancePicker.removeAllItems()
            applyInstanceButton.isEnabled = false
            removeInstanceButton.isEnabled = false
            return
        }
        do {
            gameInstances = try Self.loadInstances(chapter: chapter, fileManager: fileManager)
            let previousID = instancePicker.selectedItem?.representedObject as? UUID
            instancePicker.removeAllItems()
            for instance in gameInstances {
                instancePicker.addItem(withTitle: instance.name)
                instancePicker.lastItem?.representedObject = instance.id
            }
            if let previousID,
               let index = gameInstances.firstIndex(where: { $0.id == previousID }) {
                instancePicker.selectItem(at: index)
            } else if instancePicker.numberOfItems > 0 {
                instancePicker.selectItem(at: 0)
            }
            applyInstanceButton.isEnabled = !gameInstances.isEmpty
            removeInstanceButton.isEnabled = !gameInstances.isEmpty
        } catch {
            gameInstances = []
            instancePicker.removeAllItems()
            applyInstanceButton.isEnabled = false
            removeInstanceButton.isEnabled = false
            showError("Could not load saved instances: \(error.localizedDescription)")
        }
    }

    private func setInstanceControlsEnabled(_ enabled: Bool) {
        instancePicker.isEnabled = enabled
        importInstanceButton.isEnabled = enabled
        applyInstanceButton.isEnabled = enabled && !gameInstances.isEmpty
        removeInstanceButton.isEnabled = enabled && !gameInstances.isEmpty
        showInstancesButton.isEnabled = enabled
        importSongButton.isEnabled = enabled && selectedMacTarget() != nil
        chapterPicker.isEnabled = enabled
        backupOriginalButton.isEnabled = enabled
        restoreOriginalButton.isEnabled = enabled
        restoreAllOriginalButton.isEnabled = enabled
        if enabled {
            updateOriginalButtons()
        }
    }

    private func selectInstance(named name: String) {
        guard let instance = gameInstances.first(where: { $0.name == name }) else { return }
        selectInstance(id: instance.id)
    }

    private func selectInstance(id: UUID) {
        guard let index = gameInstances.firstIndex(where: { $0.id == id }) else { return }
        instancePicker.selectItem(at: index)
    }

    private func requestInstanceName(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(string: defaultValue)
        nameField.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showError("Instance name cannot be empty.")
            return nil
        }
        return name
    }

    private func requestPatchSaveChoice(chapter: Int, defaultName: String) -> PatchSaveChoice? {
        let alert = NSAlert()
        alert.messageText = "Patch Chapter \(chapter)"
        alert.informativeText = "Choose whether to keep this patch in your saved instances. The patched file will be applied either way."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")

        let saveCheckbox = NSButton(checkboxWithTitle: "Save patched file as an instance", target: nil, action: nil)
        saveCheckbox.state = .on
        let nameField = NSTextField(string: defaultName)
        nameField.placeholderString = "Instance name"
        nameField.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let accessory = NSStackView(views: [saveCheckbox, nameField])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        alert.accessoryView = accessory
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        guard saveCheckbox.state == .on else {
            return PatchSaveChoice(instanceName: nil)
        }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showError("Instance name cannot be empty.")
            return nil
        }
        return PatchSaveChoice(instanceName: name)
    }

    private func ensureUniqueInstanceName(_ name: String, chapter: Int) throws {
        let existing = try Self.loadInstances(chapter: chapter, fileManager: fileManager)
        guard !existing.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw InstallerError.instanceNameExists(name, chapter: chapter)
        }
    }

    private func saveInstance(from source: URL, name: String, chapter: Int) throws -> GameInstance {
        try ensureUniqueInstanceName(name, chapter: chapter)
        return try Self.createInstance(from: source, name: name, chapter: chapter, fileManager: fileManager)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Could not install the mod"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private func resourcesDirectory(for app: URL) -> URL {
        Self.resourcesDirectory(for: app, fileManager: fileManager)
    }

    private func chapterDirectories(in resources: URL, suffix: String) -> [Int] {
        Self.chapterDirectories(in: resources, suffix: suffix, fileManager: fileManager)
    }

    nonisolated private static func resourcesDirectory(for target: URL, fileManager: FileManager) -> URL {
        if target.pathExtension.lowercased() == "app" {
            return target.appendingPathComponent("Contents/Resources", isDirectory: true)
        }
        if !chapterDirectories(in: target, suffix: "_mac", fileManager: fileManager).isEmpty {
            return target
        }
        let nestedResources = target.appendingPathComponent("Contents/Resources", isDirectory: true)
        if !chapterDirectories(in: nestedResources, suffix: "_mac", fileManager: fileManager).isEmpty {
            return nestedResources
        }
        return target
    }

    nonisolated private static func chapterDirectories(
        in resources: URL,
        suffix: String,
        fileManager: FileManager
    ) -> [Int] {
        guard let children = try? fileManager.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return children.compactMap { child in
            guard child.lastPathComponent.range(
                of: #"^chapter([0-9]+)\#(suffix)$"#,
                options: [.regularExpression, .caseInsensitive]
            ) != nil,
                  let match = child.lastPathComponent.range(
                    of: #"(?<=chapter)[0-9]+(?=\#(suffix))"#,
                    options: [.regularExpression, .caseInsensitive]
                  ) else { return nil }
            return Int(child.lastPathComponent[match])
        }.sorted()
    }

    nonisolated private static func findMatchingChapter(
        chapters: [WindowsChapterFile],
        patch: URL,
        appURL: URL,
        instanceName: String?,
        cancellation: OperationCancellation
    ) throws -> PatchInstallResult {
        let fileManager = FileManager.default
        let resources = resourcesDirectory(for: appURL, fileManager: fileManager)
        let xdelta = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/xdelta3").path
        let work = fileManager.temporaryDirectory
            .appendingPathComponent("DeltaruneModInstaller-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: work) }

        guard let chapter = chapters.first else {
            throw InstallerError.patchFailed("No Windows chapter source was selected.", terminalOutput: "")
        }
        guard !cancellation.isCancelled else {
            throw InstallerError.cancelled(terminalOutput: "")
        }
        let output = work.appendingPathComponent("patched.bin")
        let arguments = ["-d", "-s", chapter.dataFile.path, patch.path, output.path]
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xdelta)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            cancellation.attach(process)
        } catch {
            throw InstallerError.patchToolUnavailable(
                error.localizedDescription,
                terminalOutput: ""
            )
        }
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        cancellation.detach()
        let cliOutput = String(decoding: outputData, as: UTF8.self)
        let terminalOutput = cliOutput

        guard !cancellation.isCancelled else {
            throw InstallerError.cancelled(terminalOutput: terminalOutput)
        }
        guard process.terminationStatus == 0 else {
            throw InstallerError.patchFailed(
                "xdelta3 rejected the patch for Chapter \(chapter.number).",
                terminalOutput: terminalOutput
            )
        }
        guard fileManager.fileExists(atPath: output.path),
              ((try? fileManager.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
            throw InstallerError.patchFailed(
                "xdelta3 reported success but did not create a non-empty patched output.",
                terminalOutput: terminalOutput
            )
        }

        let chapterNumber = chapter.number
        let destinationFolder = resources.appendingPathComponent("chapter\(chapterNumber)_mac", isDirectory: true)
        guard fileManager.fileExists(atPath: destinationFolder.path) else {
            throw InstallerError.installFailed(
                "The xdelta patch succeeded, but chapter\(chapterNumber)_mac was not found.",
                terminalOutput: terminalOutput
            )
        }
        do {
            guard !cancellation.isCancelled else {
                throw InstallerError.cancelled(terminalOutput: terminalOutput)
            }
            let instance: GameInstance
            if let instanceName {
                instance = try createInstance(
                    from: output,
                    name: instanceName,
                    chapter: chapterNumber,
                    fileManager: fileManager
                )
            } else {
                instance = GameInstance(
                    id: UUID(),
                    name: patch.deletingPathExtension().lastPathComponent,
                    chapter: chapterNumber,
                    createdAt: Date(),
                    fileURL: output
                )
            }
            guard !cancellation.isCancelled else {
                throw InstallerError.cancelled(
                    terminalOutput: terminalOutput
                )
            }
            let activation = try activateInstance(
                instance,
                appURL: appURL,
                terminalOutput: terminalOutput,
                cancellation: cancellation
            )
            return PatchInstallResult(
                status: instanceName.map {
                    "SUCCESS — Chapter \(chapterNumber) was patched and installed as instance “\($0)”."
                } ?? "SUCCESS — Chapter \(chapterNumber) was patched and applied without saving an instance.",
                terminalOutput: activation.terminalOutput
            )
        } catch {
            if let installerError = error as? InstallerError {
                throw installerError
            }
            throw InstallerError.installFailed(
                "The patch succeeded, but the named instance could not be saved or installed: \(error.localizedDescription)",
                terminalOutput: terminalOutput
            )
        }
    }


    nonisolated private static func instanceRoot(fileManager: FileManager) throws -> URL {
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw InstallerError.instanceStorageUnavailable("Could not locate this user's Application Support folder.")
        }
        return support.appendingPathComponent("DELTARUNE Mod Installer/Instances", isDirectory: true)
    }

    nonisolated private static func createInstance(
        from source: URL,
        name: String,
        chapter: Int,
        fileManager: FileManager
    ) throws -> GameInstance {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw InstallerError.instanceStorageUnavailable("The selected game.ios file is missing, empty, or not a regular file.")
        }
        let instances = try loadInstances(chapter: chapter, fileManager: fileManager)
        guard !instances.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw InstallerError.instanceNameExists(name, chapter: chapter)
        }

        let metadata = GameInstanceMetadata(id: UUID(), name: name, chapter: chapter, createdAt: Date())
        let directory = try instanceRoot(fileManager: fileManager)
            .appendingPathComponent("Chapter \(chapter)", isDirectory: true)
            .appendingPathComponent(metadata.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let instanceFile = directory.appendingPathComponent("game.ios")
            try fileManager.copyItem(at: source, to: instanceFile)
            let data = try PropertyListEncoder().encode(metadata)
            try data.write(to: directory.appendingPathComponent("Instance.plist"), options: .atomic)
            return GameInstance(
                id: metadata.id,
                name: metadata.name,
                chapter: chapter,
                createdAt: metadata.createdAt,
                fileURL: instanceFile
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw InstallerError.instanceStorageUnavailable("Could not save instance “\(name)”: \(error.localizedDescription)")
        }
    }

    nonisolated private static func loadInstances(
        chapter: Int,
        fileManager: FileManager
    ) throws -> [GameInstance] {
        let directory = try instanceRoot(fileManager: fileManager)
            .appendingPathComponent("Chapter \(chapter)", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var result: [GameInstance] = []
        for child in children {
            let metadataURL = child.appendingPathComponent("Instance.plist")
            let instanceFile = child.appendingPathComponent("game.ios")
            let data = try Data(contentsOf: metadataURL)
            let metadata = try PropertyListDecoder().decode(GameInstanceMetadata.self, from: data)
            guard metadata.chapter == chapter,
                  fileManager.fileExists(atPath: instanceFile.path),
                  ((try? fileManager.attributesOfItem(atPath: instanceFile.path)[.size] as? NSNumber)?.intValue ?? 0) > 0 else {
                throw InstallerError.instanceStorageUnavailable("Saved instance metadata or game.ios is invalid at \(child.path).")
            }
            result.append(GameInstance(
                id: metadata.id,
                name: metadata.name,
                chapter: chapter,
                createdAt: metadata.createdAt,
                fileURL: instanceFile
            ))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated private static func removeInstance(
        _ instance: GameInstance,
        fileManager: FileManager
    ) throws {
        let root = try instanceRoot(fileManager: fileManager)
            .appendingPathComponent("Chapter \(instance.chapter)", isDirectory: true)
        let directory = instance.fileURL.deletingLastPathComponent().standardizedFileURL
        let expectedDirectory = root.appendingPathComponent(instance.id.uuidString, isDirectory: true).standardizedFileURL
        guard directory == expectedDirectory,
              directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw InstallerError.instanceStorageUnavailable("The saved instance path is outside its expected chapter folder.")
        }
        try fileManager.removeItem(at: directory)
    }

    nonisolated private static func activateInstance(
        _ instance: GameInstance,
        appURL: URL,
        terminalOutput initialOutput: String = "",
        cancellation: OperationCancellation? = nil
    ) throws -> PatchInstallResult {
        let fileManager = FileManager.default
        guard cancellation?.isCancelled != true else {
            throw InstallerError.cancelled(terminalOutput: initialOutput)
        }
        let resources = resourcesDirectory(for: appURL, fileManager: fileManager)
        let destinationFolder = resources.appendingPathComponent("chapter\(instance.chapter)_mac", isDirectory: true)
        guard fileManager.fileExists(atPath: destinationFolder.path) else {
            throw InstallerError.installFailed(
                "The selected Mac target does not contain chapter\(instance.chapter)_mac.",
                terminalOutput: initialOutput
            )
        }

        let destination = destinationFolder.appendingPathComponent("game.ios")
        let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
        if attributes?[.type] != nil,
           attributes?[.type] as? FileAttributeType != .typeRegular {
            throw InstallerError.installFailed(
                "The existing game.ios is not a regular file and was left untouched.",
                terminalOutput: initialOutput
            )
        }

        let terminalOutput = initialOutput
        if fileManager.fileExists(atPath: destination.path) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let backupURL = destinationFolder.appendingPathComponent(
                "game.ios.backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
            )
            do {
                try fileManager.copyItem(at: destination, to: backupURL)
            } catch {
                throw InstallerError.installFailed(
                    "Could not back up the current game.ios: \(error.localizedDescription)",
                    terminalOutput: terminalOutput
                )
            }
        }

        guard cancellation?.isCancelled != true else {
            throw InstallerError.cancelled(
                terminalOutput: terminalOutput
            )
        }
        let staged = destinationFolder.appendingPathComponent(".game.ios-\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: instance.fileURL, to: staged)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            guard cancellation?.isCancelled != true else {
                throw InstallerError.cancelled(
                    terminalOutput: terminalOutput
                )
            }
            guard rename(staged.path, destination.path) == 0 else {
                throw InstallerError.installFailed(
                    "Could not activate the instance: \(String(cString: strerror(errno)))",
                    terminalOutput: terminalOutput
                )
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            if let installerError = error as? InstallerError { throw installerError }
            throw InstallerError.installFailed(
                "Could not activate the saved instance: \(error.localizedDescription)",
                terminalOutput: terminalOutput
            )
        }

        return PatchInstallResult(
            status: "SUCCESS — Instance “\(instance.name)” is active in Chapter \(instance.chapter).",
            terminalOutput: terminalOutput
        )
    }

    nonisolated private static func backUpOriginalMacFiles(appURL: URL) throws -> PatchInstallResult {
        let fileManager = FileManager.default
        let resources = resourcesDirectory(for: appURL, fileManager: fileManager)
        let chapters = chapterDirectories(in: resources, suffix: "_mac", fileManager: fileManager)
        let files = chapters.map { chapter in
            (
                chapter: chapter,
                active: resources.appendingPathComponent("chapter\(chapter)_mac/game.ios"),
                backup: resources.appendingPathComponent("chapter\(chapter)_mac/game.ios.original")
            )
        }.filter { fileManager.fileExists(atPath: $0.active.path) }

        guard !files.isEmpty else {
            throw InstallerError.installFailed(
                "No chapterN_mac/game.ios files were found in the selected Mac target.",
                terminalOutput: ""
            )
        }

        for file in files {
            try validateGameFile(file.active, label: "Active Chapter \(file.chapter) Mac game.ios")
            if fileManager.fileExists(atPath: file.backup.path) {
                guard let attributes = try? fileManager.attributesOfItem(atPath: file.backup.path),
                      attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw InstallerError.installFailed(
                        "The existing Chapter \(file.chapter) original backup is not a regular file and was left untouched:\n\(file.backup.path)",
                        terminalOutput: ""
                    )
                }
            }
        }

        var stagedFiles: [(chapter: Int, active: URL, backup: URL, staged: URL)] = []
        defer {
            for file in stagedFiles {
                try? fileManager.removeItem(at: file.staged)
            }
        }
        for file in files {
            let staged = file.backup.deletingLastPathComponent()
                .appendingPathComponent(".game.ios.original-\(UUID().uuidString).tmp")
            do {
                try fileManager.copyItem(at: file.active, to: staged)
                try validateGameFile(staged, label: "Staged Chapter \(file.chapter) original backup")
                stagedFiles.append((file.chapter, file.active, file.backup, staged))
            } catch {
                try? fileManager.removeItem(at: staged)
                throw InstallerError.installFailed(
                    "Could not stage the Chapter \(file.chapter) backup: \(error.localizedDescription)",
                    terminalOutput: ""
                )
            }
        }

        var completed: [Int] = []
        for file in stagedFiles {
            guard rename(file.staged.path, file.backup.path) == 0 else {
                let completedList = completed.isEmpty
                    ? "none"
                    : completed.map(String.init).joined(separator: ", ")
                throw InstallerError.installFailed(
                    "Could not replace the Chapter \(file.chapter) backup: \(String(cString: strerror(errno))). Backups already refreshed for Chapters \(completedList).",
                    terminalOutput: ""
                )
            }
            completed.append(file.chapter)
        }

        for file in stagedFiles {
            try validateGameFile(file.backup, label: "Backed-up Chapter \(file.chapter) Mac game.ios")
        }
        return PatchInstallResult(
            status: "Original Mac files backed up for Chapters \(completed.map(String.init).joined(separator: ", ")).",
            terminalOutput: ""
        )
    }

    nonisolated private static func restoreOriginalMacFile(
        appURL: URL,
        chapter: Int
    ) throws -> PatchInstallResult {
        let fileManager = FileManager.default
        let resources = resourcesDirectory(for: appURL, fileManager: fileManager)
        let chapterFolder = resources.appendingPathComponent("chapter\(chapter)_mac", isDirectory: true)
        let activeFile = chapterFolder.appendingPathComponent("game.ios")
        let originalFile = chapterFolder.appendingPathComponent("game.ios.original")
        guard fileManager.fileExists(atPath: chapterFolder.path) else {
            throw InstallerError.installFailed(
                "The selected Mac target does not contain chapter\(chapter)_mac.",
                terminalOutput: ""
            )
        }
        try validateGameFile(originalFile, label: "Original backup")
        let terminalOutput = ""
        let attributes = try? fileManager.attributesOfItem(atPath: activeFile.path)
        if attributes?[.type] != nil,
           attributes?[.type] as? FileAttributeType != .typeRegular {
            throw InstallerError.installFailed(
                "The current game.ios is not a regular file and was left untouched.",
                terminalOutput: terminalOutput
            )
        }

        let staged = chapterFolder.appendingPathComponent(".game.ios-restore-\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: originalFile, to: staged)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
            guard rename(staged.path, activeFile.path) == 0 else {
                throw InstallerError.installFailed(
                    "Could not restore the original game.ios: \(String(cString: strerror(errno)))",
                    terminalOutput: terminalOutput
                )
            }
        } catch {
            try? fileManager.removeItem(at: staged)
            if let installerError = error as? InstallerError { throw installerError }
            throw InstallerError.installFailed(
                "Could not restore the original game.ios: \(error.localizedDescription)",
                terminalOutput: terminalOutput
            )
        }
        return PatchInstallResult(
            status: "Original Mac game file restored for Chapter \(chapter).",
            terminalOutput: terminalOutput
        )
    }

    nonisolated private static func restoreOriginalMacFiles(appURL: URL) throws -> PatchInstallResult {
        let fileManager = FileManager.default
        let resources = resourcesDirectory(for: appURL, fileManager: fileManager)
        let chapters = chapterDirectories(in: resources, suffix: "_mac", fileManager: fileManager)
            .filter { chapter in
                fileManager.fileExists(
                    atPath: resources.appendingPathComponent("chapter\(chapter)_mac/game.ios.original").path
                )
            }
        guard !chapters.isEmpty else {
            throw InstallerError.installFailed(
                "No original game.ios backups were found in the selected Mac target.",
                terminalOutput: ""
            )
        }

        var restored: [Int] = []
        for chapter in chapters {
            do {
                _ = try restoreOriginalMacFile(appURL: appURL, chapter: chapter)
                restored.append(chapter)
            } catch {
                let restoredList = restored.isEmpty
                    ? "none"
                    : restored.map(String.init).joined(separator: ", ")
                throw InstallerError.installFailed(
                    "Could not restore Chapter \(chapter): \(error.localizedDescription). Chapters already restored: \(restoredList).",
                    terminalOutput: ""
                )
            }
        }
        return PatchInstallResult(
            status: "Original Mac files restored for Chapters \(restored.map(String.init).joined(separator: ", ")).",
            terminalOutput: ""
        )
    }

    nonisolated private static func validateGameFile(_ file: URL, label: String) throws {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw InstallerError.installFailed(
                "\(label) is missing, empty, or not a regular file.",
                terminalOutput: ""
            )
        }
    }

    nonisolated private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
    }

}

private enum InstallerError: LocalizedError {
    case patchToolUnavailable(String, terminalOutput: String)
    case patchFailed(String, terminalOutput: String)
    case installFailed(String, terminalOutput: String)
    case cancelled(terminalOutput: String)
    case instanceNameExists(String, chapter: Int)
    case instanceStorageUnavailable(String)

    var terminalOutput: String {
        switch self {
        case .patchToolUnavailable(_, let output),
             .patchFailed(_, let output),
             .installFailed(_, let output):
            return output
        case .cancelled(let output):
            return output
        case .instanceNameExists, .instanceStorageUnavailable:
            return ""
        }
    }

    var errorDescription: String? {
        switch self {
        case .patchToolUnavailable(let reason, _):
            return "The bundled patch engine could not start: \(reason)"
        case .patchFailed(let reason, _), .installFailed(let reason, _):
            return reason
        case .cancelled:
            return "Patch cancelled."
        case .instanceNameExists(let name, let chapter):
            return "An instance named “\(name)” already exists for Chapter \(chapter). Choose a different name."
        case .instanceStorageUnavailable(let reason):
            return reason
        }
    }

    var isCancelled: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

@main
private struct DeltaruneModInstaller {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = InstallerWindow()
        application.delegate = delegate
        application.run()
    }
}

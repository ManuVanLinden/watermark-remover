import AppKit
import UniformTypeIdentifiers

let preset = NSRect(x: 0.785, y: 0.89, width: 0.093, height: 0.056)

final class SelectionCanvas: NSView {
    var picture: NSImage? { didSet { needsDisplay = true } }
    var selection = preset { didSet { needsDisplay = true } }
    var changed: (() -> Void)?
    var locked = false
    private var anchor: NSPoint?
    override var isFlipped: Bool { true }
    var pictureRect: NSRect {
        guard let image = picture else { return bounds.insetBy(dx: 24, dy: 24) }
        let scale = min((bounds.width - 32) / image.size.width, (bounds.height - 32) / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
        bounds.fill()
        guard let image = picture else {
            let text = "Add a video to select its watermark area"
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.lightGray, .font: NSFont.systemFont(ofSize: 16)]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2), withAttributes: attrs)
            return
        }
        let frame = pictureRect
        image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let box = NSRect(x: frame.minX + selection.minX * frame.width,
                         y: frame.minY + selection.minY * frame.height,
                         width: selection.width * frame.width, height: selection.height * frame.height)
        NSColor.systemOrange.withAlphaComponent(0.22).setFill()
        box.fill()
        NSColor.systemOrange.setStroke()
        let outline = NSBezierPath(rect: box)
        outline.lineWidth = 2
        outline.stroke()
    }
    private func normalized(_ event: NSEvent) -> NSPoint {
        let p = convert(event.locationInWindow, from: nil), r = pictureRect
        return NSPoint(x: min(0.995, max(0.005, (p.x-r.minX)/r.width)),
                       y: min(0.995, max(0.005, (p.y-r.minY)/r.height)))
    }
    override func mouseDown(with event: NSEvent) {
        guard !locked, picture != nil, pictureRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        anchor = normalized(event)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let a = anchor else { return }
        let b = normalized(event)
        selection = NSRect(x: min(a.x,b.x), y: min(a.y,b.y), width: max(0.003,abs(a.x-b.x)), height: max(0.003,abs(a.y-b.y)))
        changed?()
    }
    override func mouseUp(with event: NSEvent) { anchor = nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let canvas = SelectionCanvas()
    let filesMenu = NSPopUpButton()
    let modeMenu = NSPopUpButton()
    let summary = NSTextField(wrappingLabelWithString: "Choose one or more videos. Originals are always preserved.")
    let regionLabel = NSTextField(wrappingLabelWithString: "")
    let explanation = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "Ready")
    let progress = NSProgressIndicator()
    let start = NSButton(title: "Export videos", target: nil, action: nil)
    let add = NSButton(title: "Add videos…", target: nil, action: nil)
    let clear = NSButton(title: "Clear", target: nil, action: nil)
    let reset = NSButton(title: "Reset sparkle preset", target: nil, action: nil)
    let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    let reveal = NSButton(title: "Show exports", target: nil, action: nil)
    var files: [URL] = []
    var process: Process?
    var outputs: [URL] = []
    var errors: [String] = []
    var previewID = UUID()
    var wasCancelled = false
    var busy: Bool { process != nil }

    func label(_ string: String, size: CGFloat, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: string)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return field
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard window == nil else { return }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1050, height: 760),
                          styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        window.title = "Watermark Remover"
        window.minSize = NSSize(width: 850, height: 760)
        window.center()
        let root = NSStackView()
        root.orientation = .horizontal
        root.spacing = 20
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor)])
        let sidebar = NSStackView()
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        sidebar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        root.addArrangedSubview(sidebar)
        root.addArrangedSubview(canvas)
        canvas.widthAnchor.constraint(greaterThanOrEqualToConstant: 440).isActive = true
        canvas.heightAnchor.constraint(equalTo: root.heightAnchor, constant: -48).isActive = true
        sidebar.addArrangedSubview(label("Watermark Remover", size: 26, bold: true))
        sidebar.addArrangedSubview(summary)
        let buttons = NSStackView(views: [add,clear])
        buttons.spacing = 8
        sidebar.addArrangedSubview(buttons)
        sidebar.addArrangedSubview(filesMenu)
        sidebar.addArrangedSubview(label("Draw a rectangle around the complete watermark, including a small margin. The same relative area is applied to every selected video.", size: 13))
        sidebar.addArrangedSubview(reset)
        regionLabel.textColor = .secondaryLabelColor
        regionLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sidebar.addArrangedSubview(regionLabel)
        modeMenu.addItems(withTitles: ["Retouch · keep full frame", "Crop · keep original aspect ratio"])
        sidebar.addArrangedSubview(modeMenu)
        sidebar.addArrangedSubview(explanation)
        explanation.textColor = .secondaryLabelColor
        explanation.font = .systemFont(ofSize: 12)
        sidebar.addArrangedSubview(label("Exports are saved beside each source in “Watermark Remover Exports”. Everything stays on this Mac.", size: 12))
        sidebar.addArrangedSubview(start)
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        sidebar.addArrangedSubview(progress)
        sidebar.addArrangedSubview(status)
        sidebar.addArrangedSubview(NSStackView(views: [cancel,reveal]))
        for view in [summary, filesMenu, regionLabel, modeMenu, explanation, progress, status] as [NSView] {
            view.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        for field in sidebar.arrangedSubviews.compactMap({ $0 as? NSTextField }) {
            field.preferredMaxLayoutWidth = 300
            field.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        for (button, action) in [(add,#selector(addVideos)), (clear,#selector(clearVideos)),
            (reset,#selector(resetSelection)), (start,#selector(exportVideos)),
            (cancel,#selector(cancelExport)), (reveal,#selector(showExports))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        start.keyEquivalent = "\r"
        filesMenu.target = self
        filesMenu.action = #selector(loadPreview)
        modeMenu.target = self
        modeMenu.action = #selector(modeChanged)
        canvas.changed = { [weak self] in self?.updateRegion() }
        buildMenu()
        updateRegion()
        modeChanged()
        updateControls()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        let submenu = NSMenu()
        submenu.addItem(withTitle: "About Watermark Remover", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        submenu.addItem(.separator())
        submenu.addItem(withTitle: "Quit Watermark Remover", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = submenu
        menu.addItem(app)
        NSApp.mainMenu = menu
    }
    func updateControls() {
        add.isEnabled = !busy
        clear.isEnabled = !busy && !files.isEmpty
        filesMenu.isEnabled = !busy && !files.isEmpty
        modeMenu.isEnabled = !busy
        reset.isEnabled = !busy
        canvas.locked = busy
        start.isEnabled = !busy && !files.isEmpty && canvas.picture != nil
        start.title = "Export \(files.count) video\(files.count == 1 ? "" : "s")"
        cancel.isEnabled = busy
        reveal.isEnabled = !outputs.isEmpty
        summary.stringValue = files.isEmpty ? "Choose one or more videos. Originals are always preserved." : "\(files.count) video\(files.count == 1 ? "" : "s") selected. Originals are always preserved."
    }
    @objc func updateRegion() {
        let r = canvas.selection
        regionLabel.stringValue = String(format: "Left %.1f%% · Top %.1f%%\nWidth %.1f%% · Height %.1f%%", r.minX*100,r.minY*100,r.width*100,r.height*100)
    }
    @objc func resetSelection() { canvas.selection = preset; updateRegion() }
    @objc func modeChanged() {
        explanation.stringValue = modeMenu.indexOfSelectedItem == 0
            ? "Fills the selected area using nearby pixels. A softened patch can remain on moving or detailed backgrounds."
            : "Crops past the selected area and scales back to the original resolution. Removes picture around the edges."
    }
    @objc func addVideos() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "webm") ?? .movie, UTType(filenameExtension: "mkv") ?? .movie]
        if panel.runModal() == .OK { addFiles(panel.urls) }
    }
    func addFiles(_ urls: [URL]) {
        guard !busy else { return }
        for url in urls where !files.contains(url) { files.append(url) }
        filesMenu.removeAllItems()
        for (index, url) in files.enumerated() { filesMenu.addItem(withTitle: "\(index + 1). \(url.lastPathComponent)") }
        updateControls()
        loadPreview()
    }
    @objc func clearVideos() {
        previewID = UUID()
        files = []
        filesMenu.removeAllItems()
        canvas.picture = nil
        updateControls()
    }
    func executable(_ name: String) -> String? {
        ["/opt/homebrew/bin/\(name)","/usr/local/bin/\(name)","/usr/bin/\(name)"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
    @objc func loadPreview() {
        guard files.indices.contains(filesMenu.indexOfSelectedItem) else { return }
        guard let ffmpeg = executable("ffmpeg") else { alert("FFmpeg is missing", "Install it using: brew install ffmpeg"); return }
        let url = files[filesMenu.indexOfSelectedItem]
        let identifier = UUID()
        previewID = identifier
        canvas.picture = nil
        status.stringValue = "Loading preview…"
        updateControls()
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process(), pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: ffmpeg)
            task.arguments = ["-v","error","-nostdin","-i",url.path,"-frames:v","1","-vf","scale=800:800:force_original_aspect_ratio=decrease,setsar=1","-f","image2pipe","-vcodec","png","pipe:1"]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                DispatchQueue.main.async {
                    guard self.previewID == identifier else { return }
                    self.canvas.picture = NSImage(data: data)
                    self.status.stringValue = self.canvas.picture == nil ? "Could not preview this video." : "Draw around the watermark, then export."
                    self.updateControls()
                }
            } catch {
                DispatchQueue.main.async {
                    guard self.previewID == identifier else { return }
                    self.status.stringValue = error.localizedDescription
                    self.updateControls()
                }
            }
        }
    }
    @objc func exportVideos() {
        guard !busy, !files.isEmpty, let python = executable("python3"),
              let script = Bundle.main.path(forResource: "remove_watermark", ofType: "py") else {
            alert("Cannot start", "Python 3 or the bundled processor is missing."); return
        }
        let r = canvas.selection
        let region = [r.minX,r.minY,r.width,r.height].map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), Double($0)) }.joined(separator: ",")
        let task = Process(), pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: python)
        task.arguments = [script,"--json","--mode",modeMenu.indexOfSelectedItem == 0 ? "retouch" : "crop","--region",region] + files.map(\.path)
        task.standardOutput = pipe
        task.standardError = pipe
        outputs = []
        errors = []
        wasCancelled = false
        progress.doubleValue = 0
        process = task
        updateControls()
        status.stringValue = "Starting export…"
        do { try task.run() } catch {
            process = nil
            updateControls()
            alert("Could not start", error.localizedDescription)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeSubrange(...newline)
                    if let item = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                        DispatchQueue.main.async { self.handleEvent(item) }
                    } else if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                        DispatchQueue.main.async { self.errors.append(text) }
                    }
                }
            }
            task.waitUntilExit()
            DispatchQueue.main.async {
                self.process = nil
                if self.wasCancelled {
                    self.status.stringValue = "Cancelled. \(self.outputs.count) completed export(s) kept."
                } else if task.terminationStatus != 0 || !self.errors.isEmpty {
                    self.status.stringValue = "Finished with errors. \(self.outputs.count) exported."
                    self.alert("Some videos could not be exported", self.errors.joined(separator: "\n\n").isEmpty ? "The processor stopped unexpectedly." : self.errors.joined(separator: "\n\n"))
                } else {
                    self.progress.doubleValue = 1
                    self.status.stringValue = "Done. \(self.outputs.count) video(s) exported."
                }
                self.updateControls()
            }
        }
    }
    func handleEvent(_ item: [String: Any]) {
        switch item["event"] as? String {
        case "start":
            let name = URL(fileURLWithPath: item["input"] as? String ?? "").lastPathComponent
            status.stringValue = "Exporting \(item["index"] ?? "")/\(item["total"] ?? ""): \(name)"
        case "progress": progress.doubleValue = item["fraction"] as? Double ?? 0
        case "done":
            if let path = item["output"] as? String { outputs.append(URL(fileURLWithPath: path)) }
        case "error": errors.append(item["message"] as? String ?? "Unknown error")
        case "cancelled": wasCancelled = true
        default: break
        }
    }
    @objc func cancelExport() { wasCancelled = true; process?.terminate(); status.stringValue = "Cancelling…" }
    @objc func showExports() { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
    func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if window == nil { applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification)) }
        addFiles(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy {
            let dialog = NSAlert()
            dialog.messageText = "Cancel the active export and quit?"
            dialog.informativeText = "Completed exports and original videos will be kept."
            dialog.addButton(withTitle: "Keep exporting")
            dialog.addButton(withTitle: "Cancel and quit")
            if dialog.runModal() == .alertFirstButtonReturn { return .terminateCancel }
            process?.terminate()
            process?.waitUntilExit()
        }
        return .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()

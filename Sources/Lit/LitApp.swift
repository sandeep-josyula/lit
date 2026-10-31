import SwiftUI
import AppKit
import LitCore

@main
struct LitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = EditorModel.shared

    var body: some Scene {
        Window("LIT", id: "main") {
            EditorView(model: model)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About LIT") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: Brand.tagline + "\n\nFree and open source (MIT License).\nlit collects no data and never connects to the internet.",
                                                     attributes: [.font: NSFont.systemFont(ofSize: 11)]),
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { model.showOpenPanel() }.keyboardShortcut("o")
                Button("Build Panorama…") { model.choosePanoramaFrames() }.keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Export JPEG…") { model.showExportSheet = true }
                    .keyboardShortcut("e")
                    .disabled(model.source == nil)
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
                Button("Redo") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
            // No text-editing extras (Find, Spelling, Substitutions, Speech…): nothing to write here.
            CommandGroup(replacing: .textEditing) {}
            // No sidebar toggle or empty help book.
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .help) {}
            CommandGroup(after: .toolbar) {
                Button("Zoom In") { model.zoomIn() }.keyboardShortcut("=")
                Button("Zoom Out") { model.zoomOut() }.keyboardShortcut("-")
                Button("Fit in Window") { model.zoomToFit() }.keyboardShortcut("0")
                Button("Actual Pixels (100%)") { model.zoomToActualPixels() }.keyboardShortcut("1")
                Divider()
                Button("Flip Background Black / White  (B)") { model.background = model.background.next }
            }
            CommandMenu("Photo") {
                Button("Edit Tool  (E)") { model.tool = .edit }
                Button("Linear Gradient  (G)") { model.tool = .gradient }
                Button("Crop  (C)") { model.tool = .crop }
                Button("Dust Specks  (D)") { model.tool = .dust }
                Divider()
                Button("Toggle Before / After  ( \\ )") { model.showOriginal.toggle() }
                Button("Show Gradient Overlay  (O)") { model.showMaskOverlay.toggle() }
                Button("Show Clipping  (J)") {
                    let show = !(model.clipHighlights && model.clipShadows)
                    model.clipHighlights = show
                    model.clipShadows = show
                }
                Divider()
                Button("Reset All Edits") { model.resetAll() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(model.source == nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var menuObserver: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Keep macOS from adding Start Dictation and Emoji & Symbols to the Edit menu.
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
    }

    /// Keeps the menus lean. The Edit menu holds only what a photo editor uses: Undo / Redo, and
    /// Cut / Copy / Paste / Select All for the few number fields. macOS adds more on its own
    /// (Writing Tools, AutoFill, dictation…), so this runs again whenever a menu item is added.
    private func trimMenus() {
        guard let main = NSApp.mainMenu else { return }
        if let edit = main.items.first(where: { $0.title == "Edit" })?.submenu {
            let keep: Set<String> = ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"]
            for item in edit.items.reversed() where !item.isSeparatorItem && !keep.contains(item.title) {
                edit.removeItem(item)
            }
        }
        // An empty Help menu has nothing to offer.
        if let help = main.items.first(where: { $0.title == "Help" }),
           help.submenu?.items.allSatisfy(\.isSeparatorItem) ?? true {
            main.removeItem(help)
        }
        // Separators: none at the ends, never two in a row.
        for menu in main.items.compactMap(\.submenu) {
            var previousWasSeparator = true
            for item in menu.items {
                if item.isSeparatorItem {
                    if previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = true }
                } else {
                    previousWasSeparator = false
                }
            }
            if let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        trimMenus()
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trimMenus() }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        installKeyMonitor()
        MainActor.assumeIsolated { EditorModel.shared.warmUp() }
        MainActor.assumeIsolated { runSnapshotIfRequested() }
        // Developer aid: `LIT --dump-menus` prints the menu bar and quits.
        if CommandLine.arguments.contains("--dump-menus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for top in NSApp.mainMenu?.items ?? [] {
                    let items = top.submenu?.items.map { $0.isSeparatorItem ? "—" : $0.title } ?? []
                    print(top.title + ": " + items.joined(separator: " | "))
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Developer aid: `LIT --snapshot <photo> <out.png> [gradient]` renders the
    /// editor window offscreen and quits. Used to check layout without screen access.
    @MainActor private func runSnapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 else { return }
        let model = EditorModel.shared
        let welcome = args[i + 1] == "none"   // snapshot the empty window
        if !welcome { model.open(URL(fileURLWithPath: args[i + 1])) }
        // Opening is asynchronous: set up the requested state once the photo is in.
        func setUp() {
            guard welcome || model.source != nil else {
                return DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { setUp() }
            }
            if args.contains("crop") {
                model.tool = .crop
                model.setCropAspect(args.contains("pano") ? .pano : .wide)
            }
            if args.contains("straighten") {
                model.tool = .crop
                model.beginStraighten()
                model.setStraighten(6)
            }
            if args.contains("dust") {
                model.tool = .dust
                model.addDustSpot(at: CGPoint(x: 0.45, y: 0.12))
                model.showDustView = args.contains("find")
            }
            if args.contains("clip") {
                model.adjustments.exposure = 1.5
                model.clipHighlights = true
                model.clipShadows = true
            }
            if args.count > i + 3, args[i + 3] == "gradient" {
                model.tool = .gradient
                let id = model.addGradient(start: CGPoint(x: 0.3, y: 0.05), end: CGPoint(x: 0.4, y: 0.5))
                model.updateMask(id) { $0.local.exposure = -1.2; $0.local.temperature = -30 }
                model.showMaskOverlay = args.contains("overlay")
            }
        }
        setUp()
        if args.contains("white") { model.background = .white }
        if args.contains("black") { model.background = .black }
        let out = URL(fileURLWithPath: args[i + 2])
        func attempt(_ n: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard welcome || (model.preview != nil && model.source != nil) || n > 20 else { return attempt(n + 1) }
                if args.contains("zoom") {
                    model.canvasSize = CGSize(width: 1140, height: 862)
                    model.setZoom(model.zoom100, anchor: CGPoint(x: 570, y: 520))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (args.contains("zoom") || args.contains("clip") ? 3 : 0.8)) {
                    let renderer = ImageRenderer(content: EditorView(model: model).frame(width: 1440, height: 900))
                    renderer.scale = 1
                    // ImageRenderer can't draw ScrollView contents, so render the panel body separately.
                    let panel = ImageRenderer(content: VStack(spacing: 0) {
                        switch model.tool {
                        case .gradient: MaskPanel(model: model)
                        case .crop: CropPanel(model: model)
                        case .dust: DustPanel(model: model)
                        case .edit: EditSections(model: model)
                        }
                    }.frame(width: 290).background(Theme.panel).preferredColorScheme(.dark))
                    panel.scale = 1
                    let images = [(renderer.cgImage, out),
                                  (panel.cgImage, out.deletingPathExtension().appendingPathExtension("panel.png"))]
                    for (cg, url) in images {
                        if let cg {
                            try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: url)
                        }
                    }
                    NSApp.terminate(nil)
                }
            }
        }
        attempt(0)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { EditorModel.shared.confirmLeavingPanorama() } ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { EditorModel.shared.handle(urls: urls) }
    }

    /// Single-key shortcuts (Camera Raw style) — only when no text field is being edited.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            if NSApp.keyWindow?.attachedSheet != nil || NSApp.modalWindow != nil { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option])
            guard mods.isEmpty else { return event }
            let handled: Bool = MainActor.assumeIsolated {
                let m = EditorModel.shared
                guard m.source != nil else { return false }
                // Space held = hand tool (pan) in any tool.
                if event.keyCode == 49 {
                    m.spaceHeld = event.type == .keyDown
                    return true
                }
                guard event.type == .keyDown else { return false }
                switch event.keyCode {
                case 123, 124: // ← → nudge the slider under the pointer
                    guard let nudge = SliderKeys.nudge else { return false }
                    nudge(event.keyCode == 123 ? -1 : 1, event.modifierFlags.contains(.shift))
                    return true
                case 51, 117: // delete, forward delete
                    if let id = m.selectedMaskID { m.deleteMask(id); return true }
                    if let id = m.selectedSpotID { m.deleteSpot(id); return true }
                    return false
                case 53: // escape
                    if m.selectedMaskID != nil { m.selectedMaskID = nil }
                    else if m.selectedSpotID != nil { m.selectedSpotID = nil }
                    else { m.tool = .edit }
                    return true
                case 36, 76: // return, enter: finish cropping
                    if m.tool == .crop { m.tool = .edit; return true }
                    return false
                default: break
                }
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "g": m.tool = .gradient
                case "e": m.tool = .edit
                case "\\": m.showOriginal.toggle()
                case "o": m.showMaskOverlay.toggle()
                case "c": m.tool = .crop
                case "d": m.tool = .dust
                case "[": if m.tool == .dust { m.nudgeDustBrush(1 / 1.2) } else { return false }
                case "]": if m.tool == .dust { m.nudgeDustBrush(1.2) } else { return false }
                case "z": m.toggleZoom()
                case "b": m.background = m.background.next
                case "j":
                    let show = !(m.clipHighlights && m.clipShadows)
                    m.clipHighlights = show
                    m.clipShadows = show
                case "x": if m.tool == .crop { m.rotateCropShape() } else { return false }
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }

        // Two-finger scroll / mouse wheel over the photo pans when zoomed; ⌘-scroll zooms.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated {
                let m = EditorModel.shared
                guard m.source != nil, let window = event.window, window == NSApp.mainWindow,
                      let content = window.contentView else { return event }
                let p = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                let frame = m.canvasFrameInWindow
                guard frame.contains(p) else { return event }
                let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
                if event.modifierFlags.contains(.command) {
                    let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 60 : event.scrollingDeltaY / 6
                    m.setZoom(m.zoom * pow(1.25, dy), anchor: local)
                    return nil
                }
                guard m.zoom > 1.01 else { return event }
                let k: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                m.pan(by: CGSize(width: event.scrollingDeltaX * k, height: event.scrollingDeltaY * k))
                return nil
            }
        }
    }
}

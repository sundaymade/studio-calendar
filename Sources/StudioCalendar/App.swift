import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// Borderless window that sits on the desktop: above the Finder icons, below every app window.
final class DesktopWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !NSApp.isActive {
            NSApp.activate()
            makeKey()
        }
        super.sendEvent(event)
    }
}

@main
@MainActor
enum Main {
    static var delegate: AppDelegate?
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render"), i + 2 < args.count {
            Preview.run(mode: args[i + 1], out: args[i + 2], dark: args.contains("--dark"))
            return
        }
        let app = NSApplication.shared
        let d = AppDelegate()
        delegate = d
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var window: DesktopWindow!
    private let store = CalendarStore()
    private let ui = UIState()
    private let chat = ChatModel()
    private let focusGuard = FocusGuard()
    private let meetingNotes = MeetingNotes()
    private let ritual = Ritual()
    /// The morning/evening screen brought the calendar to the front, so closing it sends it back.
    private var ritualRaised = false
    private var ticker: Timer?
    private var statusItem: NSStatusItem!
    private var keyMonitor: Any?

    private static var desktopLevel: NSWindow.Level {
        NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        chat.store = store
        chat.ui = ui
        ritual.store = store
        ritual.ui = ui
        ritual.notes = meetingNotes
        meetingNotes.ui = ui
        ritual.onClose = { [weak self] in
            guard let self else { return }
            if self.ritualRaised { self.setPeek(false) }
            self.ritualRaised = false
        }
        let root = RootView()
            .environmentObject(store)
            .environmentObject(ui)
            .environmentObject(chat)
            .environmentObject(ritual)

        window = DesktopWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.level = Self.desktopLevel
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        layoutWindow()
        window.orderFront(nil)
        setupEditMenu()

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layoutWindow() }
        }
        nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.setPeek(false) }
        }
        nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.ui.visible = self.window.occlusionState.contains(.visible)
            }
        }

        setupStatusItem()
        // ⌃⌥K: calendar to the front and back. ⌃⌥Space: ask Claude from anywhere.
        HotKeys.shared.register(keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey) { [weak self] in
            Task { @MainActor in self?.setPeek(!(self?.ui.peek ?? true)) }
        }
        HotKeys.shared.register(keyCode: kVK_Space, modifiers: controlKey | optionKey) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.setPeek(true)
                self.ui.focusPromptTick += 1
            }
        }
        // ⌃⌥J: join the call that is on now. ⌃⌥S: screenshot a chat, Claude puts it in the calendar.
        HotKeys.shared.register(keyCode: kVK_ANSI_J, modifiers: controlKey | optionKey) { [weak self] in
            Task { @MainActor in self?.joinNow() }
        }
        HotKeys.shared.register(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey) { [weak self] in
            Task { @MainActor in self?.screenshotToClaude() }
        }
        // ⌃⌥C: free times for WhatsApp onto the clipboard.
        HotKeys.shared.register(keyCode: kVK_ANSI_C, modifiers: controlKey | optionKey) { [weak self] in
            Task { @MainActor in self?.copyFreeTimes(sound: true) }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Back at the Mac in the morning: the plan shows right away.
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    self?.tick()
                }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event)
        }
        Task { await store.requestAccess() }
    }

    // MARK: window

    /// Largest display by default, or the one picked in the menu.
    private var chosenScreen: NSScreen? {
        let name = UserDefaults.standard.string(forKey: "screenName")
        if let name, let s = NSScreen.screens.first(where: { $0.localizedName == name }) { return s }
        return NSScreen.screens.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private func layoutWindow() {
        guard let screen = chosenScreen else { return }
        window.setFrame(screen.frame, display: true)
        let f = screen.frame, v = screen.visibleFrame
        ui.insets = EdgeInsets(top: f.maxY - v.maxY, leading: v.minX - f.minX, bottom: v.minY - f.minY, trailing: f.maxX - v.maxX)
    }

    /// Bring the calendar in front of all windows, or send it back to the desktop.
    private func setPeek(_ on: Bool) {
        guard ui.peek != on else { return }
        ui.peek = on
        window.level = on ? .floating : Self.desktopLevel
        if on {
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: actions

    /// Every 30 s: Do Not Disturb for focus blocks. Once a day, when you are at the Mac:
    /// the morning plan (from 6:00 until noon) and the evening check (from 18:00).
    private func tick() {
        focusGuard.tick(store)
        if store.authorized { meetingNotes.tick(store) }
        guard store.authorized, !ritual.isOpen else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < 120 else { return }
        let d = UserDefaults.standard
        let hour = Calendar.current.component(.hour, from: Date())
        let today = Fmt.iso.string(from: Calendar.current.startOfDay(for: Date()))
        // For automations: `defaults write works.sonntag.studiocalendar openNow morning` (or evening).
        if let now = d.string(forKey: "openNow") {
            d.removeObject(forKey: "openNow")
            openRitual(now == "evening" ? .evening : .morning)
            return
        }
        let morning = d.object(forKey: "morningHour") as? Int ?? 6
        let evening = d.object(forKey: "eveningHour") as? Int ?? 18
        if hour >= morning, hour < 12, d.string(forKey: "lastMorning") != today {
            d.set(today, forKey: "lastMorning")
            openRitual(.morning)
        } else if hour >= evening, d.string(forKey: "lastEvening") != today {
            d.set(today, forKey: "lastEvening")
            openRitual(.evening)
        }
    }

    private func openRitual(_ mode: Ritual.Mode) {
        ui.closeAll()
        chat.close()
        if !ui.peek { ritualRaised = true }
        setPeek(true)
        ritual.open(mode)
    }

    private func copyFreeTimes(sound: Bool = false) {
        guard let text = store.freeTimeMessage() else {
            ui.flash("No free hour in the next days")
            return
        }
        ChatModel.copy(text)
        ui.flash("Copied: " + text)
        if sound { NSSound(named: "Pop")?.play() }
    }

    private func joinNow() {
        guard let ev = store.joinable else {
            ui.flash("No call right now")
            return
        }
        if store.join(ev) { ui.flash("Joining “\(ev.title)”") }
    }

    private func screenshotToClaude() {
        guard ScreenGrab.allowed else {
            ScreenGrab.askPermission()
            setPeek(true)
            ui.flash("Allow Screen Recording for Studio Calendar, then press ⌃⌥S again")
            return
        }
        ScreenGrab.capture { [weak self] img in
            guard let self, let img else { return }
            self.setPeek(true)
            self.ui.closeAll()
            self.chat.attach(image: img)
            self.chat.send("")
            self.ui.focusPromptTick += 1
        }
    }

    // MARK: keyboard

    private func handleKey(_ e: NSEvent) -> NSEvent? {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let key = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let typing = window.firstResponder is NSTextView

        if cmd && !shift && key == "v" {
            if let img = Clip.image() {
                chat.attach(image: img)
                ui.closeAll()
                ui.focusPromptTick += 1
                return nil
            }
            if ui.promptFocused, let text = Clip.longText() {
                chat.attach(text: text)
                return nil
            }
        }
        if cmd {
            switch key {
            case "n": ui.popover = nil; ui.showHelp = false; ui.showQuickAdd = true; return nil
            case "k":
                if shift { chat.reset(); ui.flash("New chat") } else { ui.closeAll(); ui.focusPromptTick += 1 }
                return nil
            case "c" where shift: copyFreeTimes(); return nil
            case "/": ui.showHelp.toggle(); return nil
            case "r": store.refreshCalendars(); store.reload(); ui.flash("Refreshed"); return nil
            case "1": ui.span = .day; ui.offset = 0; return nil
            case "2": ui.span = .three; ui.offset = 0; return nil
            case "3": ui.span = .week; ui.offset = 0; return nil
            default: break
            }
            if e.keyCode == UInt16(kVK_Delete), let p = ui.popover, p.event.editable {
                if store.delete(p.event) { ui.flash("Deleted “\(p.event.title)”") }
                ui.popover = nil
                return nil
            }
        }
        if ritual.isOpen {
            if e.keyCode == UInt16(kVK_Escape) {
                if typing { window.makeFirstResponder(nil) } else { ritual.close() }
                return nil
            }
            if !typing, e.keyCode == UInt16(kVK_Return) || e.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
                ritual.primary()
                return nil
            }
            return typing || cmd ? e : nil
        }
        if e.keyCode == UInt16(kVK_Escape) {
            if ui.closeOverlays() { return nil }
            if chat.hasAttachment { chat.clearAttachments(); return nil }
            if chat.isOpen { chat.close(); return nil }
            if typing { window.makeFirstResponder(nil); return nil }
            if ui.peek { setPeek(false); return nil }
            return nil
        }
        if !typing && flags.isDisjoint(with: [.command, .control, .option]) {
            switch e.keyCode {
            case UInt16(kVK_LeftArrow): ui.offset -= 1; return nil
            case UInt16(kVK_RightArrow): ui.offset += 1; return nil
            default: break
            }
            switch key {
            case "t": ui.offset = 0; return nil
            case "j": joinNow(); return nil
            case "m": openRitual(.morning); return nil
            case "e": openRitual(.evening); return nil
            case "n": ui.showQuickAdd = true; return nil
            case "d": ui.span = .day; ui.offset = 0; return nil
            case "w": ui.span = .week; ui.offset = 0; return nil
            case "?": ui.showHelp.toggle(); return nil
            case "/": ui.focusPromptTick += 1; return nil
            default: break
            }
        }
        return e
    }

    // MARK: menu bar

    /// The app has no visible menu bar, so ⌘V/⌘C/⌘X/⌘A/⌘Z need a hidden Edit menu to reach text fields.
    /// Without it, pasting text (by hand or from dictation like VoiceInk) does nothing.
    private func setupEditMenu() {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "Studio Calendar")
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Bring to Front      ⌃⌥K", #selector(menuPeek)))
        menu.addItem(item("Ask Claude          ⌃⌥Space", #selector(menuAsk)))
        menu.addItem(item("Screenshot to Claude  ⌃⌥S", #selector(menuGrab)))
        menu.addItem(item("Plan My Day", #selector(menuPlan)))
        menu.addItem(item("Copy Free Times     ⌃⌥C", #selector(menuFree)))
        menu.addItem(item("Morning Plan        M", #selector(menuMorning)))
        menu.addItem(item("Evening Check       E", #selector(menuEvening)))
        let join = item("Join Call           ⌃⌥J", #selector(menuJoin))
        join.isEnabled = store.joinable != nil
        menu.addItem(join)
        menu.addItem(item("New Event", #selector(menuNew)))
        menu.addItem(item("Keyboard Shortcuts", #selector(menuHelp)))
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show Calendars", action: nil, keyEquivalent: "")
        let showMenu = NSMenu()
        let addTo = NSMenuItem(title: "Add Events To", action: nil, keyEquivalent: "")
        let addMenu = NSMenu()
        var lastSource = ""
        for cal in store.calendars {
            if cal.source.title != lastSource {
                if !lastSource.isEmpty { showMenu.addItem(.separator()) }
                let header = NSMenuItem(title: cal.source.title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                showMenu.addItem(header)
                lastSource = cal.source.title
            }
            let s = item("  " + cal.title, #selector(menuToggleCalendar(_:)))
            s.representedObject = cal.calendarIdentifier
            s.state = store.shownIDs.contains(cal.calendarIdentifier) ? .on : .off
            showMenu.addItem(s)
            if cal.allowsContentModifications {
                let a = item(cal.title + "  (" + cal.source.title + ")", #selector(menuTarget(_:)))
                a.representedObject = cal.calendarIdentifier
                a.state = store.targetID == cal.calendarIdentifier ? .on : .off
                addMenu.addItem(a)
            }
        }
        show.submenu = showMenu
        addTo.submenu = addMenu
        menu.addItem(show)
        menu.addItem(addTo)

        let display = NSMenuItem(title: "Display", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let current = window.screen?.localizedName
        for s in NSScreen.screens {
            let d = item(s.localizedName, #selector(menuScreen(_:)))
            d.representedObject = s.localizedName
            d.state = s.localizedName == current ? .on : .off
            displayMenu.addItem(d)
        }
        display.submenu = displayMenu
        menu.addItem(display)

        let login = item("Launch at Login", #selector(menuLogin(_:)))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Refresh", #selector(menuRefresh)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Studio Calendar", #selector(menuQuit)))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc private func menuPeek() { setPeek(!ui.peek) }
    @objc private func menuAsk() { setPeek(true); ui.focusPromptTick += 1 }
    @objc private func menuGrab() { screenshotToClaude() }
    @objc private func menuPlan() { setPeek(true); chat.send("Plan my day") }
    @objc private func menuFree() { copyFreeTimes() }
    @objc private func menuMorning() { openRitual(.morning) }
    @objc private func menuEvening() { openRitual(.evening) }
    @objc private func menuJoin() { joinNow() }
    @objc private func menuNew() { setPeek(true); ui.showQuickAdd = true }
    @objc private func menuHelp() { setPeek(true); ui.showHelp = true }
    @objc private func menuRefresh() { store.refreshCalendars(); store.reload() }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuToggleCalendar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if store.shownIDs.contains(id) {
            if store.shownIDs.count > 1 { store.shownIDs.remove(id) }
        } else {
            store.shownIDs.insert(id)
        }
    }

    @objc private func menuTarget(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        store.targetID = id
        store.shownIDs.insert(id)
        ui.flash("New events go to \(store.calendarName)")
    }

    @objc private func menuScreen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        UserDefaults.standard.set(name, forKey: "screenName")
        layoutWindow()
    }

    @objc private func menuLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            ui.flash("Launch at login: \(error.localizedDescription)")
        }
    }
}

import AppKit
import UniformTypeIdentifiers

/// Images and long text coming in by ⌘V, drag and drop, or ⌃⌥S.
enum Clip {
    /// A screenshot on the clipboard, or a copied image file. Nil when there is plain text to paste.
    static func image(_ pb: NSPasteboard = .general) -> NSImage? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], let url = urls.first {
            guard isImage(url) else { return nil }
            return NSImage(contentsOf: url)
        }
        if let s = pb.string(forType: .string), !s.isEmpty { return nil }
        return pb.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage
    }

    /// Text worth showing as an attachment (a copied chat or mail) rather than squeezing into one line.
    /// Dictation (one paragraph, even a long one) goes straight into the field.
    static func longText(_ pb: NSPasteboard = .general) -> String? {
        guard let s = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let lines = s.split(whereSeparator: \.isNewline).count
        return lines >= 3 || s.count > 1200 ? s : nil
    }

    static func isImage(_ url: URL) -> Bool {
        guard url.isFileURL, let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .image)
    }
}

enum Drop {
    static func load(_ providers: [NSItemProvider], done: @escaping @MainActor (NSImage) -> Void) {
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, Clip.isImage(url), let img = NSImage(contentsOf: url) else { return }
                    Task { @MainActor in done(img) }
                }
                return
            }
            if p.canLoadObject(ofClass: NSImage.self) {
                _ = p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage else { return }
                    Task { @MainActor in done(img) }
                }
                return
            }
        }
    }
}

/// ⌃⌥S: drag over a chat, Claude reads it. Uses the system's own screenshot tool.
enum ScreenGrab {
    /// macOS asks once for Screen Recording. Without it the shot would only show the wallpaper.
    static var allowed: Bool { CGPreflightScreenCaptureAccess() }

    static func askPermission() { _ = CGRequestScreenCaptureAccess() }

    static func capture(done: @escaping @MainActor (NSImage?) -> Void) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("studio-grab-\(UUID().uuidString).png")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", file.path]
        p.terminationHandler = { _ in
            let img = (try? Data(contentsOf: file)).flatMap(NSImage.init(data:))
            try? FileManager.default.removeItem(at: file)
            Task { @MainActor in done(img) }
        }
        do { try p.run() } catch { Task { @MainActor in done(nil) } }
    }
}

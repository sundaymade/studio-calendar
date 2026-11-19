import AppKit
import SwiftUI

/// `StudioCalendar --render morning|plan|evening out.png [--dark]` draws the morning or evening screen
/// off screen with your real calendar, for checking the layout without showing anything.
@MainActor
enum Preview {
    static func run(mode: String, out: String, dark: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let store = CalendarStore()
        let ui = UIState()
        let chat = ChatModel()
        let ritual = Ritual()
        ritual.store = store
        ritual.ui = ui
        Task { @MainActor in
            await store.requestAccess()
            ritual.open(mode == "evening" ? .evening : .morning)
            if mode == "evening" {   // sample recap items, only in this picture
                ritual.meetingActions = [
                    MeetingNotes.Action(text: "Send the offer", owner: Profile.name, meeting: "Meeting · Alex", project: ""),
                    MeetingNotes.Action(text: "Set up the test account", owner: "Alex", meeting: "Meeting · Alex", project: "", take: true)]
            }
            if mode == "plan" { ritual.previewPlan() }
            let view = RitualView()
                .environmentObject(store).environmentObject(ui).environmentObject(chat).environmentObject(ritual)
                .environment(\.theme, Theme(dark: dark))
                .frame(width: 1512, height: 982)
            let r = ImageRenderer(content: view)
            r.scale = 1
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: out))
            }
            exit(0)
        }
        app.run()
    }
}

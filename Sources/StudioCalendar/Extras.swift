import AppKit
import SwiftUI

// MARK: - Shortcuts

struct ShortcutsCard: View {
    @Environment(\.theme) var th

    private let rows: [(String, String)] = [
        ("⌘N  or  N", "New event, just type: “Lunch tomorrow 1pm 45 min”"),
        ("⌘ + drag", "Draw an event straight into the grid"),
        ("⌘K  or  /", "Talk to Claude, your planner"),
        ("⌘V  ·  drop", "Screenshot of a chat in, Claude adds the meeting"),
        ("⌃⌥S", "Screenshot to Claude, from any app"),
        ("⌃⌥C  ·  ⌘⇧C", "Free times as a message, on the clipboard"),
        ("M  ·  E", "Morning plan, evening check (open by themselves)"),
        ("↩ (empty prompt)", "Apply Claude’s suggestion"),
        ("⌘⇧K", "New chat"),
        ("⌘1 ⌘2 ⌘3  ·  D W", "Day, 3 days, week"),
        ("← →  ·  T", "Previous, next, today"),
        ("Click event", "Rename or delete it (⌘⌫ deletes)"),
        ("J  ·  ⌃⌥J", "Join the call that is on now"),
        ("⌃⌥K", "Calendar to the front and back, from any app"),
        ("⌃⌥Space", "Ask Claude from any app"),
        ("⌘R", "Refresh"),
        ("esc", "Close whatever is open"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label11(text: "Keyboard")
                .padding(.bottom, 12)
            ForEach(rows, id: \.0) { r in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(r.0).font(Theme.mono(13)).foregroundStyle(th.fg).frame(width: 190, alignment: .leading)
                    Text(r.1).font(.system(size: 14)).foregroundStyle(th.fg)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .top) { Rectangle().fill(th.hair).frame(height: 1) }
            }
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 16, trailing: 24))
        .frame(width: 640)
        .background(th.card)
        .overlay(Rectangle().stroke(th.fg, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 40, y: 20)
    }
}

// MARK: - Critter

/// A small square fellow who lives on the prompt line. Walks around, looks at what you
/// type, bounces while Claude thinks, hops when something lands in the calendar, and
/// sleeps at night.
struct Critter: View {
    @EnvironmentObject var ui: UIState
    @EnvironmentObject var chat: ChatModel
    @Environment(\.theme) var th
    let width: CGFloat
    let typing: Bool

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 14.0, paused: !ui.visible || reduceMotion)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let hour = Calendar.current.component(.hour, from: tl.date)
            let asleep = (hour >= 23 || hour < 6) && !typing && !chat.busy
            let state = pose(t: t, asleep: asleep)
            let sinceJump = t - ui.critterJumpAt
            let hop = sinceJump < 0.7 ? sin(sinceJump / 0.7 * .pi) * 22 : 0
            let think = chat.busy ? abs(sin(t * 7)) * 4 : 0
            Canvas { ctx, size in
                draw(ctx, state: state, asleep: asleep)
            }
            .frame(width: 26, height: 22)
            .offset(x: state.x, y: -(hop + think))
        }
        .frame(width: width, height: 22, alignment: .topLeading)
    }

    private struct Pose { var x: CGFloat; var dir: CGFloat; var step: Int }

    private func pose(t: TimeInterval, asleep: Bool) -> Pose {
        let range = max(width - 90, 20)
        if asleep { return Pose(x: 6, dir: 1, step: 0) }
        if typing { return Pose(x: range + 20, dir: -1, step: 0) }
        if reduceMotion { return Pose(x: range * 0.6, dir: -1, step: 0) }
        // 30 s loop: walk right 11 s, rest 4 s, walk left 11 s, rest 4 s.
        let p = t.truncatingRemainder(dividingBy: 30)
        let stepFrame = Int(t * 6) % 2
        switch p {
        case ..<11: return Pose(x: range * CGFloat(p / 11), dir: 1, step: stepFrame)
        case ..<15: return Pose(x: range, dir: 1, step: 0)
        case ..<26: return Pose(x: range * CGFloat(1 - (p - 15) / 11), dir: -1, step: stepFrame)
        default: return Pose(x: 0, dir: -1, step: 0)
        }
    }

    private func draw(_ ctx: GraphicsContext, state: Pose, asleep: Bool) {
        let ink = th.fg, paper = th.bg
        // body
        ctx.fill(Path(CGRect(x: 4, y: 5, width: 16, height: 12)), with: .color(ink))
        // tuft
        ctx.fill(Path(CGRect(x: 10, y: 2, width: 3, height: 3)), with: .color(ink))
        // eyes
        let look = state.dir * 1.5
        if asleep {
            ctx.fill(Path(CGRect(x: 8, y: 10, width: 3, height: 1)), with: .color(paper))
            ctx.fill(Path(CGRect(x: 13, y: 10, width: 3, height: 1)), with: .color(paper))
            ctx.draw(Text("z").font(Theme.mono(9)).foregroundColor(ink), at: CGPoint(x: 23, y: 3))
        } else {
            ctx.fill(Path(CGRect(x: 8.5 + look, y: 8, width: 2.5, height: 3)), with: .color(paper))
            ctx.fill(Path(CGRect(x: 13.5 + look, y: 8, width: 2.5, height: 3)), with: .color(paper))
        }
        // legs
        let a: CGFloat = state.step == 0 ? 4 : 2
        let b: CGFloat = state.step == 0 ? 2 : 4
        ctx.fill(Path(CGRect(x: 7, y: 17, width: 2, height: a)), with: .color(ink))
        ctx.fill(Path(CGRect(x: 15, y: 17, width: 2, height: b)), with: .color(ink))
    }
}

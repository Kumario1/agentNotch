import AppKit
import SwiftUI

// Sizes computed by NotchController from the physical notch.
struct NotchMetrics: Equatable {
    var notchWidth: CGFloat
    var collapsed: CGSize
    var expanded: CGSize
}

// UI-only state; separate from usage data so hover doesn't touch the store.
import Observation
@Observable final class NotchState {
    var expanded = false
    var selectedSessionID: String? = nil
}

// The Apple-notch silhouette: concave flares at the top outer corners (wallpaper
// peeks over them, like the real notch meeting the bezel) + convex rounded bottom.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + topRadius, y: r.minY + topRadius),
                       control: CGPoint(x: r.minX + topRadius, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + topRadius, y: r.maxY - bottomRadius))
        p.addQuadCurve(to: CGPoint(x: r.minX + topRadius + bottomRadius, y: r.maxY),
                       control: CGPoint(x: r.minX + topRadius, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topRadius - bottomRadius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - topRadius, y: r.maxY - bottomRadius),
                       control: CGPoint(x: r.maxX - topRadius, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - topRadius, y: r.minY + topRadius))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY),
                       control: CGPoint(x: r.maxX - topRadius, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Palette (warm Claude tones from the reference)

private let peach = Color(red: 0.93, green: 0.65, blue: 0.46)        // ring / bar fill
private let claudeOrange = Color(red: 0.90, green: 0.56, blue: 0.36) // asterisk mark — 2026 logo: more orange, less red
private let codexAccent = Color(white: 0.78)                         // Codex stays neutral; orange theme is Claude-only
private let dangerRed = Color(red: 0.90, green: 0.28, blue: 0.28)

// Remaining percent: low remaining is danger; otherwise keep product color.
private func usageColor(_ fraction: Double, _ product: Product) -> Color {
    if fraction <= 0.15 { return dangerRed }
    return product == .claude ? claudeOrange : codexAccent
}

// Real behind-window translucency: SwiftUI materials only blur within their own
// window, so this samples the desktop/windows underneath via NSVisualEffectView.
// Masked with a stretchable notch-shape image (Apple says use maskImage, not a
// layer mask, for behind-window blending).
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.maskImage = notchMaskImage(topRadius: 10, bottomRadius: 28)
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private func notchMaskImage(topRadius: CGFloat, bottomRadius: CGFloat) -> NSImage {
    let size = NSSize(width: 120, height: 100)
    let img = NSImage(size: size, flipped: true) { rect in
        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
        ctx.addPath(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).path(in: rect).cgPath)
        ctx.setFillColor(.black)
        ctx.fillPath()
        return true
    }
    // Stretch the middle, keep the shaped corners crisp at any view size.
    img.capInsets = NSEdgeInsets(top: 45, left: 45, bottom: 45, right: 45)
    img.resizingMode = .stretch
    return img
}

// MARK: - Root: one hierarchy, spring-morphed between states.
// The panel window is always expanded-size; only this shape animates.

struct NotchRootView: View {
    var store: UsageStore
    var ui: NotchState
    var m: NotchMetrics

    var body: some View {
        let exp = ui.expanded
        ZStack(alignment: .top) {
            // Always-present translucent stack; a black cover camouflages it as the
            // notch when collapsed and fades out on expand (the translucency reveal).
            BehindWindowBlur()
                .opacity(exp ? 1 : 0)
            NotchShape(topRadius: exp ? 10 : 6, bottomRadius: exp ? 28 : 13)
                .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.15, blue: 0.11),
                                              Color(red: 0.20, green: 0.11, blue: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(exp ? 0.42 : 0)
            NotchShape(topRadius: exp ? 10 : 6, bottomRadius: exp ? 28 : 13)
                .fill(.black)
                .opacity(exp ? 0 : 1)
            // Content zooms with the shape as one unit (Dynamic Island style):
            // outgoing content scales toward the incoming state, incoming scales into place.
            if exp {
                ExpandedContent(store: store, ui: ui)
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            } else {
                CollapsedContent(store: store, notchWidth: m.notchWidth)
                    .transition(.scale(scale: 1.15, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: exp ? m.expanded.width : m.collapsed.width,
               height: exp ? m.expanded.height : m.collapsed.height)
        // Nothing ever draws outside the silhouette mid-morph.
        .clipShape(NotchShape(topRadius: exp ? 10 : 6, bottomRadius: exp ? 28 : 13))
        // .smooth = critically damped spring: one continuous motion, settles with zero wiggle.
        .animation(.smooth(duration: 0.45), value: exp)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Shared pieces (matched between both layouts)

// Rounded-square Claude mark, like the reference's app tiles.
private struct ClaudeTile: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Color(red: 0.23, green: 0.13, blue: 0.10))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "asterisk")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(claudeOrange)
            )
            .frame(width: size, height: size)
    }
}

// Rounded-square Codex mark, same tile language as ClaudeTile.
private struct CodexTile: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Color(white: 0.13))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                ZStack {
                    ForEach(0..<6, id: \.self) { i in
                        Capsule()
                            .fill(.white.opacity(0.88))
                            .frame(width: size * 0.10, height: size * 0.34)
                            .offset(y: -size * 0.13)
                            .rotationEffect(.degrees(Double(i) * 60))
                    }
                    Circle()
                        .fill(Color(white: 0.13))
                        .frame(width: size * 0.20, height: size * 0.20)
                }
            )
            .frame(width: size, height: size)
    }
}

@ViewBuilder private func productTile(_ p: Product, size: CGFloat) -> some View {
    switch p {
    case .claude: ClaudeTile(size: size)
    case .codex: CodexTile(size: size)
    }
}

// Radial ring gauge: dark coin, peach arc, percentage in the middle.
private struct RingGauge: View {
    let fraction: Double
    let product: Product
    var size: CGFloat = 24

    private let lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().fill(Color(white: 0.09))
            Circle()
                .stroke(.white.opacity(0.13), lineWidth: lineWidth)
                .padding(lineWidth / 2)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(usageColor(fraction, product), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
            Text(verbatim: "\(Int(fraction * 100))")
                .font(.system(size: size * 0.36, weight: .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white.opacity(0.9))
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Collapsed layout: per-product tile + ring in each wing

private struct CollapsedContent: View {
    var store: UsageStore
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            wing(.claude).frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth) // the physical notch sits here
            wing(.codex).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func wing(_ p: Product) -> some View {
        HStack(spacing: 8) {
            productTile(p, size: 24)
            if let a = store.activeAccount(p), let pct = a.windows.map(\.percent).min() {
                RingGauge(fraction: min(max(pct / 100, 0), 1), product: p)
            } else {
                RingGauge(fraction: 0, product: p).opacity(0.3)
            }
        }
    }
}

// MARK: - Expanded layout: live sessions

private struct ExpandedContent: View {
    var store: UsageStore
    var ui: NotchState

    var body: some View {
        let sessions = store.sessions
        let selected = sessions.first { $0.id == ui.selectedSessionID }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LIVE SESSIONS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                Text(verbatim: "\(sessions.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(peach.opacity(0.9))
            }
            .padding(.bottom, 8)

            ZStack(alignment: .top) {
                if let selected {
                    SessionControl(session: selected) {
                        withAnimation(.smooth(duration: 0.32)) { ui.selectedSessionID = nil }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else if sessions.isEmpty {
                    EmptySessions()
                        .transition(.opacity)
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(sessions) { session in
                                SessionRow(session: session) {
                                    withAnimation(.smooth(duration: 0.32)) { ui.selectedSessionID = session.id }
                                }
                                Divider().overlay(.white.opacity(0.08))
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                }
            }
            .animation(.smooth(duration: 0.32), value: ui.selectedSessionID)
        }
        .padding(.horizontal, 24)
        .padding(.top, 40) // clear the physical notch / camera area
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct EmptySessions: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("no real sessions")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("start Claude Code or Codex and live rows appear here")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, minHeight: 210)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 14) {
                SessionTile(session: session)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(verbatim: session.title)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(verbatim: session.detail)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.55, green: 0.63, blue: 1.0))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    HStack(spacing: 8) {
                        Text(verbatim: "↑\(compactCount(session.inputTokens))")
                        Text(verbatim: "↓\(compactCount(session.outputTokens))")
                    }
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                }
                Spacer(minLength: 10)
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(verbatim: shortAge(session.lastActivity))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 48, alignment: .trailing)
                }
            }
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionControl: View {
    let session: AgentSession
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: 3, height: 28)
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                SessionTile(session: session, size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: session.title)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(verbatim: session.detail)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.55, green: 0.63, blue: 1.0))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
            }

            HStack(spacing: 10) {
                MetricPill(label: "IN", value: compactCount(session.inputTokens))
                MetricPill(label: "OUT", value: compactCount(session.outputTokens))
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    MetricPill(label: "AGE", value: shortAge(session.lastActivity))
                }
            }

            HStack(spacing: 8) {
                ControlButton(icon: "folder", title: "Open") {
                    if let cwd = session.cwd {
                        NSWorkspace.shared.open(URL(fileURLWithPath: cwd, isDirectory: true))
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.transcriptPath)])
                    }
                }
                ControlButton(icon: "doc.text.magnifyingglass", title: "Transcript") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.transcriptPath)])
                }
                ControlButton(icon: "doc.on.doc", title: "Copy ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.sessionID ?? session.id, forType: .string)
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.08))
        )
    }
}

private struct SessionTile: View {
    let session: AgentSession
    var size: CGFloat = 60

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            .fill(tileColor)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 1)
            )
            .overlay(
                Text(verbatim: String(session.title.prefix(1)).uppercased())
                    .font(.system(size: size * 0.38, weight: .heavy))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
    }

    private var tileColor: LinearGradient {
        let colors: [Color] = session.product == .claude
            ? [Color(red: 0.84, green: 0.30, blue: 0.56), Color(red: 0.56, green: 0.24, blue: 0.74)]
            : [Color(red: 0.45, green: 0.50, blue: 0.58), Color(red: 0.30, green: 0.34, blue: 0.40)]
        return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

private struct MetricPill: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: label).foregroundStyle(.white.opacity(0.42))
            Text(verbatim: value).foregroundStyle(.white.opacity(0.82))
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}

private struct ControlButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.82))
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.09)))
    }
}

private func compactCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

private func shortAge(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}

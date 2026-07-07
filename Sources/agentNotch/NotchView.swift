import SwiftUI

// Sizes computed by NotchController from the physical notch.
struct NotchMetrics: Equatable {
    var notchWidth: CGFloat
    var collapsed: CGSize
    var expanded: CGSize
}

// UI-only state; separate from usage data so hover doesn't touch the store.
import Observation
@Observable final class NotchState { var expanded = false }

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
private let claudeOrange = Color(red: 0.85, green: 0.47, blue: 0.34) // asterisk mark
private let dangerRed = Color(red: 0.90, green: 0.28, blue: 0.28)

// Claude orange until the window is nearly full, then red.
private func usageColor(_ fraction: Double) -> Color {
    fraction < 0.85 ? claudeOrange : dangerRed
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
                                              Color(red: 0.22, green: 0.10, blue: 0.18)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .opacity(exp ? 0.42 : 0)
            NotchShape(topRadius: exp ? 10 : 6, bottomRadius: exp ? 28 : 13)
                .fill(.black)
                .opacity(exp ? 0 : 1)
            // Content zooms with the shape as one unit (Dynamic Island style):
            // outgoing content scales toward the incoming state, incoming scales into place.
            if exp {
                ExpandedContent(store: store)
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
                Image(systemName: "terminal")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
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
                .stroke(usageColor(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
            Text("\(Int(fraction * 100))")
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
            if let a = store.activeAccount(p), let pct = a.maxPercent {
                RingGauge(fraction: min(max(pct / 100, 0), 1))
            } else {
                RingGauge(fraction: 0).opacity(0.3)
            }
        }
    }
}

// MARK: - Expanded layout: one card per account

private struct ExpandedContent: View {
    var store: UsageStore

    var body: some View {
        let s = store.snapshot
        VStack(alignment: .leading, spacing: 10) {
            Text("AGENT LIMITS")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.45))
            if store.accounts.isEmpty {
                Text("waiting for account data…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ForEach(store.accounts) { AccountRow(account: $0) }
            HStack {
                Text(s.lastProject ?? "no activity yet")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(peach.opacity(0.9))
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let a = s.lastActivity {
                    Text(a, style: .relative)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 40) // clear the physical notch / camera area
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AccountRow: View {
    let account: AccountUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                productTile(account.product, size: 26)
                Text(account.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if let asOf = account.asOf, Date().timeIntervalSince(asOf) > 300 {
                    (Text("as of ") + Text(asOf, style: .relative) + Text(" ago"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            if let status = account.status {
                Text(status)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(dangerRed.opacity(0.9))
            } else {
                ForEach(account.windows, id: \.name) { w in
                    WindowBarRow(window: w)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.07))
        )
    }
}

private struct WindowBarRow: View {
    let window: LimitWindow

    var body: some View {
        let f = min(max(window.percent / 100, 0), 1)
        HStack(spacing: 10) {
            Text(window.name)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 36, alignment: .leading)
            Capsule().fill(.white.opacity(0.15))
                .overlay(alignment: .leading) {
                    GeometryReader { g in
                        Capsule().fill(usageColor(f))
                            .frame(width: max(g.size.width * f, f > 0 ? 6 : 0))
                    }
                }
                .frame(height: 6)
            Text("\(Int(window.percent.rounded()))%")
                .font(.system(size: 13, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.white)
                .frame(width: 40, alignment: .trailing)
            if let r = window.resetsAt, r > .now {
                Text(timerInterval: Date.now...r, countsDown: true)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 62, alignment: .trailing)
            } else {
                Text("—")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
                    .frame(width: 62, alignment: .trailing)
            }
        }
    }
}

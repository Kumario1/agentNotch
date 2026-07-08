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
    var selectedProduct: Product? = nil
    var selectedAccountID: String? = nil
    var bouncing = false
    var collectingFeedback = false   // typing a deny reason — pauses the approval key monitor
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
private let codexAccent = Color(white: 0.78)
private let cursorAccent = Color(red: 0.55, green: 0.63, blue: 1.0)
private let dangerRed = Color(red: 0.90, green: 0.28, blue: 0.28)

// Remaining percent: low remaining is danger; otherwise keep product color.
private func usageColor(_ fraction: Double, _ product: Product) -> Color {
    if fraction <= 0.15 { return dangerRed }
    switch product {
    case .claude: return claudeOrange
    case .codex: return codexAccent
    case .cursor: return cursorAccent
    }
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
    var onOpenSettings: () -> Void = {}
    var onApprovalDecision: (String, ApprovalDecision, String?) -> Void = { _, _, _ in }
    var onSwitchClaudeAccount: (String) -> Void = { _ in }

    var body: some View {
        // Expansion is hover-driven only. A pending approval no longer force-expands;
        // instead the resting (collapsed) notch bounces for attention until opened.
        let exp = ui.expanded
        let shouldBounce = store.currentApproval != nil && !exp
        ZStack(alignment: .top) {
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
            if exp {
                ExpandedContent(
                    store: store,
                    ui: ui,
                    onOpenSettings: onOpenSettings,
                    onApprovalDecision: onApprovalDecision,
                    onSwitchClaudeAccount: onSwitchClaudeAccount)
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            } else if let approval = store.currentApproval {
                CollapsedApproval(request: approval, notchWidth: m.notchWidth)
                    .transition(.scale(scale: 1.15, anchor: .top).combined(with: .opacity))
            } else {
                CollapsedContent(store: store, notchWidth: m.notchWidth)
                    .transition(.scale(scale: 1.15, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(width: exp ? m.expanded.width : m.collapsed.width,
               height: exp ? m.expanded.height : m.collapsed.height)
        .clipShape(NotchShape(topRadius: exp ? 10 : 6, bottomRadius: exp ? 28 : 13))
        .animation(.snappy(duration: 0.28), value: exp)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Attention "bounce": the notch hugs the top screen edge, so it can't move up.
        // Instead it swells downward/outward from the pinned top edge and pulses back.
        // Uniform scale keeps the "APPROVE" text crisp (a y-only stretch distorts it).
        // Only while resting with a pending approval; opening it (or deciding) settles.
        .scaleEffect(ui.bouncing ? 1.16 : 1.0, anchor: .top)
        .animation(shouldBounce
                   ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true)
                   : .snappy(duration: 0.24),
                   value: ui.bouncing)
        .onChange(of: shouldBounce) { _, bounce in ui.bouncing = bounce }
        .onAppear { ui.bouncing = shouldBounce }
    }
}

// MARK: - Shared pieces (matched between both layouts)

// Brand logos bundled as resources (Sources/agentNotch/Resources). Loaded once;
// nil if a resource is missing, so tiles fall back to their drawn glyph.
private enum Brand {
    static let claude = load("claude")
    static let codex = load("codex")
    static let cursor = load("cursor")
    private static func load(_ name: String) -> Image? {
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let ns = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: ns)
    }
}

// Rounded-square product tile: brand logo over a per-product background, with a
// drawn-glyph fallback if the image resource is unavailable.
private struct BrandTile<Fallback: View>: View {
    var size: CGFloat
    var bg: Color
    var image: Image?
    var inset: CGFloat = 0.16
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
        shape
            .fill(bg)
            .overlay {
                if let image {
                    image.resizable().scaledToFit().padding(size * inset)
                } else {
                    fallback()
                }
            }
            .overlay(shape.stroke(.white.opacity(0.08), lineWidth: 1))
            .frame(width: size, height: size)
            .clipShape(shape)
    }
}

// Orange pixel logo on the warm dark tile (logo art is transparent).
private struct ClaudeTile: View {
    var size: CGFloat = 26
    var body: some View {
        BrandTile(size: size, bg: Color(red: 0.23, green: 0.13, blue: 0.10),
                  image: Brand.claude, inset: 0.12) {
            Image(systemName: "asterisk")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(claudeOrange)
        }
    }
}

// Black cloud/prompt logo (transparent art) → light tile so it reads.
private struct CodexTile: View {
    var size: CGFloat = 26
    var body: some View {
        BrandTile(size: size, bg: Color(white: 0.95), image: Brand.codex, inset: 0.14) {
            Text(verbatim: ">_")
                .font(.system(size: size * 0.42, weight: .bold, design: .monospaced))
                .foregroundStyle(.black.opacity(0.85))
        }
    }
}

@ViewBuilder private func productTile(_ p: Product, size: CGFloat) -> some View {
    switch p {
    case .claude: ClaudeTile(size: size)
    case .codex: CodexTile(size: size)
    case .cursor: CursorTile(size: size)
    }
}

// Cube logo ships with its own cream background → fill the tile edge-to-edge.
private struct CursorTile: View {
    var size: CGFloat = 26
    var body: some View {
        BrandTile(size: size, bg: Color(red: 0.95, green: 0.94, blue: 0.90),
                  image: Brand.cursor, inset: 0) {
            CursorCube().frame(width: size * 0.56, height: size * 0.60)
        }
    }
}

// Three shaded faces of an isometric cube (top, left, right — like Cursor's logo).
private struct CursorCube: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let mid = CGPoint(x: w / 2, y: h / 2)
            let top = CGPoint(x: w / 2, y: 0)
            let bottom = CGPoint(x: w / 2, y: h)
            let ul = CGPoint(x: 0, y: h * 0.25), ur = CGPoint(x: w, y: h * 0.25)
            let ll = CGPoint(x: 0, y: h * 0.75), lr = CGPoint(x: w, y: h * 0.75)
            face([top, ur, mid, ul], .white.opacity(0.95))   // top
            face([ul, mid, bottom, ll], .white.opacity(0.55)) // left
            face([mid, ur, lr, bottom], .white.opacity(0.30)) // right
        }
    }

    private func face(_ pts: [CGPoint], _ color: Color) -> some View {
        Path { p in
            p.move(to: pts[0])
            pts.dropFirst().forEach { p.addLine(to: $0) }
            p.closeSubpath()
        }
        .fill(color)
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
        let accounts = store.topActiveAccounts(limit: 2)
        HStack(spacing: 0) {
            wing(accounts.first).frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth)
            wing(accounts.count > 1 ? accounts[1] : nil).frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func wing(_ account: AccountUsage?) -> some View {
        HStack(spacing: 7) {
            if let account {
                productTile(account.product, size: 24)
                if account.status == nil, !account.windows.isEmpty {
                    // Every window (5H and 7D), each ring labeled underneath.
                    ForEach(Array(account.windows.prefix(2)), id: \.name) { window in
                        VStack(spacing: 1) {
                            RingGauge(fraction: min(max(window.percent / 100, 0), 1),
                                      product: account.product, size: 20)
                            Text(verbatim: window.name)
                                .font(.system(size: 6.5, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.52))
                        }
                    }
                } else {
                    Circle()
                        .fill(cursorAccent.opacity(0.7))
                        .frame(width: 8, height: 8)
                }
            } else {
                Circle().fill(.white.opacity(0.08)).frame(width: 24, height: 24)
            }
        }
    }
}

// MARK: - Collapsed layout: pending-approval alert (replaces the gauges while waiting)

private struct CollapsedApproval: View {
    let request: ApprovalRequest
    let notchWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                productTile(request.product, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: request.toolName)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(verbatim: "needs approval")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: notchWidth)
            HStack(spacing: 5) {
                Text(verbatim: "APPROVE")
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(peach)
                    .shadow(color: peach.opacity(0.6), radius: 5)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(peach)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Expanded layout: live sessions

private struct ExpandedContent: View {
    var store: UsageStore
    var ui: NotchState
    var onOpenSettings: () -> Void
    var onApprovalDecision: (String, ApprovalDecision, String?) -> Void
    var onSwitchClaudeAccount: (String) -> Void

    var body: some View {
        let sessions = store.sessions.filter { !store.hiddenSessionIDs.contains($0.id) }
        let visibleSessions = ui.selectedProduct.map { product in sessions.filter { $0.product == product } } ?? sessions
        let selected = visibleSessions.first { $0.id == ui.selectedSessionID }
        let productAccounts = filteredAccounts(store.accounts, selectedProduct: ui.selectedProduct)
        let account = summaryAccount(productAccounts, selectedAccountID: ui.selectedAccountID)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(verbatim: store.currentApproval != nil ? "APPROVAL NEEDED" : "\(visibleSessions.count) SESSIONS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(store.currentApproval != nil ? peach : .white.opacity(0.58))
                Spacer()
                HStack(spacing: 16) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape.fill")
                    }
                    .buttonStyle(.plain)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.bottom, 12)

            if let approval = store.currentApproval {
                ApprovalCard(request: approval, ui: ui, onDecision: onApprovalDecision)
                    .padding(.bottom, 12)
            } else {
                HStack(spacing: 8) {
                    ProductFilterChip(symbol: "*", title: "all", selected: ui.selectedProduct == nil) {
                        withAnimation(.smooth(duration: 0.22)) {
                            ui.selectedSessionID = nil
                            ui.selectedProduct = nil
                            ui.selectedAccountID = nil
                        }
                    }
                    ProductFilterChip(symbol: "*", title: "claude", selected: ui.selectedProduct == .claude) {
                        withAnimation(.smooth(duration: 0.22)) {
                            ui.selectedSessionID = nil
                            ui.selectedProduct = .claude
                            ui.selectedAccountID = nil
                        }
                    }
                    ProductFilterChip(symbol: ">_", title: "codex", selected: ui.selectedProduct == .codex) {
                        withAnimation(.smooth(duration: 0.22)) {
                            ui.selectedSessionID = nil
                            ui.selectedProduct = .codex
                            ui.selectedAccountID = nil
                        }
                    }
                    ProductFilterChip(symbol: "⬡", title: "cursor", selected: ui.selectedProduct == .cursor) {
                        withAnimation(.smooth(duration: 0.22)) {
                            ui.selectedSessionID = nil
                            ui.selectedProduct = .cursor
                            ui.selectedAccountID = nil
                        }
                    }
                }
                .padding(.bottom, 14)

                if let account {
                    if productAccounts.count > 1 {
                        AccountSelector(
                            accounts: productAccounts,
                            selectedID: account.id,
                            activeClaudeAccountID: store.activeClaudeAccountID) { id in
                            withAnimation(.smooth(duration: 0.22)) {
                                ui.selectedAccountID = id
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    AccountSummaryCard(
                        account: account,
                        isActive: account.product == .claude && account.id == store.activeClaudeAccountID,
                        onSwitch: account.product == .claude ? { onSwitchClaudeAccount(account.id) } : nil)
                        .padding(.bottom, 8)
                }

                ZStack(alignment: .top) {
                    if let selected {
                        SessionControl(session: selected) {
                            withAnimation(.smooth(duration: 0.32)) { ui.selectedSessionID = nil }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else if visibleSessions.isEmpty {
                        EmptySessions()
                            .transition(.opacity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(visibleSessions) { session in
                                    SessionRow(
                                        session: session,
                                        pinned: store.pinnedSessionIDs.contains(session.id),
                                        onTogglePin: { store.togglePin(session.id) },
                                        onHide: { withAnimation(.smooth(duration: 0.25)) { store.setHidden(session.id, true) } }
                                    ) {
                                        // Open the session where it lives: expand the card
                                        // and bring the hosting terminal/app forward.
                                        withAnimation(.smooth(duration: 0.32)) { ui.selectedSessionID = session.id }
                                        focusSession(session)
                                    }
                                    Divider().overlay(.white.opacity(0.09))
                                }
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                    }
                }
                .animation(.smooth(duration: 0.32), value: ui.selectedSessionID)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private func filteredAccounts(_ accounts: [AccountUsage], selectedProduct: Product?) -> [AccountUsage] {
    accounts.filter { selectedProduct == nil || $0.product == selectedProduct }
}

private func summaryAccount(_ accounts: [AccountUsage], selectedAccountID: String?) -> AccountUsage? {
    if let selectedAccountID,
       let picked = accounts.first(where: { $0.id == selectedAccountID }) {
        return picked
    }
    return accounts.max { $0.activityStamp < $1.activityStamp }
}

private struct AccountSelector: View {
    let accounts: [AccountUsage]
    let selectedID: String
    let activeClaudeAccountID: String?
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(accounts) { account in
                    Button {
                        onSelect(account.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: shortAccountLabel(account.label))
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            if account.product == .claude, account.id == activeClaudeAccountID {
                                Text(verbatim: "LIVE")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundStyle(claudeOrange)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(.white.opacity(account.id == selectedID ? 0.16 : 0.07))
                                .overlay(Capsule().stroke(
                                    .white.opacity(account.id == selectedID ? 0.24 : 0.10), lineWidth: 1))
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(account.id == selectedID ? .white : .white.opacity(0.62))
                }
            }
        }
    }
}

private struct ProductFilterChip: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(verbatim: symbol)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? peach : .white.opacity(0.42))
                Text(verbatim: title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? .white : .white.opacity(0.58))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(.white.opacity(selected ? 0.14 : 0.07))
                    .overlay(Capsule().stroke(.white.opacity(selected ? 0.20 : 0.10), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AccountSummaryCard: View {
    let account: AccountUsage
    var isActive = false
    var onSwitch: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 12) {
                productTile(account.product, size: 30)
                HStack(spacing: 4) {
                    Text(verbatim: productName(account.product))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: "/ \(shortAccountLabel(account.label))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.43))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isActive {
                    Text(verbatim: "ACTIVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(claudeOrange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(claudeOrange.opacity(0.18)))
                } else if let onSwitch, account.status == nil {
                    Button(action: onSwitch) {
                        Text(verbatim: "Switch")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.9))
                    .background(Capsule().fill(.white.opacity(0.14)))
                }
            }

            if let status = account.status {
                Text(verbatim: status)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.62))
                    .lineLimit(1)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(account.windows.prefix(2)), id: \.name) { window in
                        LimitProgressRow(window: window, product: account.product)
                    }
                }
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
        )
    }
}

private struct LimitProgressRow: View {
    let window: LimitWindow
    let product: Product

    var body: some View {
        let fraction = min(max(window.percent / 100, 0), 1)
        HStack(spacing: 12) {
            Text(verbatim: window.name)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.56))
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    Capsule()
                        .fill(usageColor(fraction, product))
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            Text(verbatim: "\(Int(window.percent.rounded()))%")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 42, alignment: .trailing)
        }
    }
}

private struct EmptySessions: View {
    var body: some View {
        VStack(spacing: 6) {
            Text("No sessions")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
            Text("Claude Code, Codex, or Cursor will appear here")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

private struct ApprovalCard: View {
    let request: ApprovalRequest
    var ui: NotchState
    let onDecision: (String, ApprovalDecision, String?) -> Void
    @State private var showFeedback = false
    @State private var reason = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                productTile(request.product, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: request.toolName)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: request.sessionTitle)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
            }
            Text(verbatim: request.summary)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(4)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.35)))

            HStack(spacing: 8) {
                ApprovalButton(title: "Always Allow", shortcut: "⌥A", style: .outline) {
                    onDecision(request.id, .always, nil)
                }
                ApprovalButton(title: "Allow", shortcut: "⌘A", style: .primary) {
                    onDecision(request.id, .allow, nil)
                }
            }
            if showFeedback {
                TextField("Why deny? Claude will see this.", text: $reason, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .lineLimit(1...3)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35)))
                    .focused($fieldFocused)
                    .onSubmit(sendDeny)
                HStack(spacing: 8) {
                    ApprovalButton(title: "Cancel", shortcut: "", style: .outline) {
                        showFeedback = false; reason = ""
                    }
                    ApprovalButton(title: "Send deny", shortcut: "⏎", style: .primary, action: sendDeny)
                }
            } else {
                Button { showFeedback = true; fieldFocused = true } label: {
                    Text("Deny with feedback")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(peach.opacity(0.35), lineWidth: 1))
        )
        .onChange(of: showFeedback) { _, v in ui.collectingFeedback = v }
        .onChange(of: request.id) { _, _ in showFeedback = false; reason = "" }
        .onDisappear { ui.collectingFeedback = false }
    }

    private func sendDeny() {
        onDecision(request.id, .deny, reason.isEmpty ? nil : reason)
        showFeedback = false
        reason = ""
    }
}

private struct ApprovalButton: View {
    enum Style { case primary, outline }
    let title: String
    let shortcut: String
    let style: Style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(verbatim: title)
                Text(verbatim: shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(style == .primary ? .black.opacity(0.5) : .white.opacity(0.4))
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(style == .primary ? Color.white : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(style == .outline ? peach.opacity(0.7) : .clear, lineWidth: 1)
                    )
            )
            .foregroundStyle(style == .primary ? .black : peach)
        }
        .buttonStyle(.plain)
    }
}

private struct SessionRow: View {
    let session: AgentSession
    var pinned = false
    var onTogglePin: () -> Void = {}
    var onHide: () -> Void = {}
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                productTile(session.product, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if pinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(peach.opacity(0.8))
                        }
                        Text(verbatim: session.title)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(verbatim: session.detail)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(peach)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if session.inputTokens + session.outputTokens > 0 {
                        HStack(spacing: 8) {
                            Text(verbatim: "↑\(compactCount(session.inputTokens))")
                            Text(verbatim: "↓\(compactCount(session.outputTokens))")
                        }
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                    }
                }
                Spacer(minLength: 10)
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(verbatim: shortAge(session.lastActivity))
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(width: 42, alignment: .trailing)
                }
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin", action: onTogglePin)
            Button("Dismiss", systemImage: "eye.slash", action: onHide)
        }
    }
}

private struct SessionControl: View {
    let session: AgentSession
    let close: () -> Void
    @State private var confirmingStop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: 3, height: 28)
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                productTile(session.product, size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(verbatim: session.title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let model = shortModel(session.model) {
                            Text(verbatim: model)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(peach)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(peach.opacity(0.14)))
                        }
                    }
                    Text(verbatim: session.detail)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(peach)
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
                if session.inputTokens + session.outputTokens > 0 {
                    MetricPill(label: "IN", value: compactCount(session.inputTokens))
                    MetricPill(label: "OUT", value: compactCount(session.outputTokens))
                }
                if let cost = estimatedCost(session) {
                    MetricPill(label: "COST", value: cost)
                }
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    MetricPill(label: "AGE", value: shortAge(session.lastActivity))
                }
            }

            if !session.todos.isEmpty { TodoList(todos: session.todos) }
            if !session.activity.isEmpty { ActivityFeed(activity: session.activity) }

            HStack(spacing: 8) {
                ControlButton(icon: "macwindow", title: "Focus") { focusSession(session) }
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
            }
            HStack(spacing: 8) {
                ControlButton(icon: "doc.on.doc", title: "Copy ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.sessionID ?? session.id, forType: .string)
                }
                Button {
                    if confirmingStop { stopSession(session); confirmingStop = false }
                    else { confirmingStop = true }
                } label: {
                    Label(confirmingStop ? "Confirm stop?" : "Interrupt", systemImage: "stop.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .foregroundStyle(confirmingStop ? .white : dangerRed)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(confirmingStop ? dangerRed : dangerRed.opacity(0.14)))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
        )
        .onChange(of: session.id) { _, _ in confirmingStop = false }
    }
}

// Live checklist — appears only when the session has TodoWrite data (tasks enabled).
private struct TodoList: View {
    let todos: [TodoItem]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(todos.prefix(5).enumerated()), id: \.offset) { _, item in
                HStack(spacing: 7) {
                    Image(systemName: todoIcon(item.status))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(todoColor(item.status))
                        .frame(width: 14)
                    Text(verbatim: item.text)
                        .font(.system(size: 12, weight: item.status == "in_progress" ? .semibold : .regular))
                        .foregroundStyle(item.status == "completed" ? .white.opacity(0.4) : .white.opacity(0.85))
                        .strikethrough(item.status == "completed")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
            }
            if todos.count > 5 {
                Text(verbatim: "+\(todos.count - 5) more")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.22)))
    }
}

// Recent tool-call / activity timeline (newest first) — the "watch it work" feed.
private struct ActivityFeed: View {
    let activity: [ActivityEntry]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(activity.suffix(6).reversed().enumerated()), id: \.offset) { _, entry in
                HStack(spacing: 8) {
                    Text(verbatim: shortAge(entry.at))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                        .frame(width: 30, alignment: .leading)
                    Text(verbatim: entry.text)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.22)))
    }
}

private func todoIcon(_ status: String) -> String {
    switch status {
    case "completed": return "checkmark.square.fill"
    case "in_progress": return "arrowtriangle.forward.square.fill"
    default: return "square"
    }
}

private func todoColor(_ status: String) -> Color {
    switch status {
    case "completed": return peach.opacity(0.7)
    case "in_progress": return peach
    default: return .white.opacity(0.4)
    }
}

// MARK: - Jump to the app hosting a session

// Find the CLI process for this session (product binary + matching cwd), walk up
// its parents to the owning GUI app (Terminal, iTerm, Cursor, VS Code, …) and
// bring it forward. ponytail: terminals get app-level focus, not the exact tab.
private func focusSession(_ session: AgentSession) {
    DispatchQueue.global(qos: .userInitiated).async {
        if let pid = hostPid(for: session), let app = owningApp(of: pid) {
            DispatchQueue.main.async { app.activate() }
            return
        }
        // Cursor's in-app agent has no CLI process — the app itself is the session.
        if session.product == .cursor,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "Cursor" }) {
            DispatchQueue.main.async { app.activate() }
            return
        }
        // Session process is gone: reveal the working folder instead.
        DispatchQueue.main.async {
            if let cwd = session.cwd {
                NSWorkspace.shared.open(URL(fileURLWithPath: cwd, isDirectory: true))
            }
        }
    }
}

private func shellOut(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

private func hostPid(for session: AgentSession) -> pid_t? {
    let binary: String
    switch session.product {
    case .claude: binary = "claude"
    case .codex: binary = "codex"
    case .cursor: binary = "cursor-agent"
    }
    var pids: [pid_t] = []
    for line in shellOut("/bin/ps", ["-axo", "pid=,comm="]).split(whereSeparator: \.isNewline) {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard let sp = t.firstIndex(of: " "), let pid = pid_t(t[..<sp]) else { continue }
        let comm = t[t.index(after: sp)...].trimmingCharacters(in: .whitespaces)
        if URL(fileURLWithPath: comm).lastPathComponent == binary { pids.append(pid) }
    }
    guard let cwd = session.cwd, pids.count > 1 else { return pids.first }
    // lsof -Fpn emits "p<pid>" then "n<cwd>" pairs; pick the pid whose cwd matches.
    let out = shellOut("/usr/sbin/lsof",
                       ["-a", "-d", "cwd", "-p", pids.map(String.init).joined(separator: ","), "-Fpn"])
    var current: pid_t?
    for line in out.split(whereSeparator: \.isNewline) {
        if line.hasPrefix("p") { current = pid_t(line.dropFirst()) }
        else if line.hasPrefix("n"), String(line.dropFirst()) == cwd, let match = current { return match }
    }
    return pids.first // ponytail: several sessions in one cwd → first one wins
}

private func owningApp(of pid: pid_t) -> NSRunningApplication? {
    var p = pid
    for _ in 0..<15 {
        if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular {
            return app
        }
        let ppid = shellOut("/bin/ps", ["-o", "ppid=", "-p", "\(p)"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let next = pid_t(ppid), next > 1 else { return nil }
        p = next
    }
    return nil
}

// Interrupt the CLI process backing this session (≈ Esc / Ctrl-C). Reuses hostPid's
// ps/lsof cwd match. ponytail: SIGINT (not SIGTERM) cancels the current turn rather than
// killing the session; "first match wins" for a shared cwd (see hostPid).
private func stopSession(_ session: AgentSession) {
    DispatchQueue.global(qos: .userInitiated).async {
        if let pid = hostPid(for: session) { kill(pid, SIGINT) }
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

// Rough per-1M-token USD prices. Hardcoded and will go stale — a tunable knob, not an
// engine. ponytail: applied to the blended input count (incl. cheap cache reads), so the
// figure over-estimates a little — hence the "~". Split cache tokens out for precision.
private let modelPrices: [(match: String, inPer1M: Double, outPer1M: Double)] = [
    ("opus", 15, 75),
    ("sonnet", 3, 15),
    ("haiku", 0.8, 4),
    ("gpt-5", 1.25, 10),
    ("o3", 2, 8),
]

private func shortModel(_ raw: String?) -> String? {
    guard let raw = raw?.lowercased() else { return nil }
    for (m, name) in [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku"), ("gpt-5", "GPT-5"), ("o3", "o3")] {
        if raw.contains(m) { return name }
    }
    return nil
}

private func estimatedCost(_ session: AgentSession) -> String? {
    guard let raw = session.model?.lowercased(),
          session.inputTokens + session.outputTokens > 0,
          let p = modelPrices.first(where: { raw.contains($0.match) }) else { return nil }
    let cost = Double(session.inputTokens) / 1_000_000 * p.inPer1M
             + Double(session.outputTokens) / 1_000_000 * p.outPer1M
    return String(format: "~$%.2f", cost)
}

private func productName(_ product: Product) -> String {
    switch product {
    case .claude: return "Claude Code"
    case .codex: return "Codex"
    case .cursor: return "Cursor"
    }
}

private func shortAccountLabel(_ label: String) -> String {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.split(separator: "@").first ?? Substring(trimmed))
}

private func shortAge(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return "\(s)s" }
    if s < 3600 { return "\(s / 60)m" }
    if s < 86_400 { return "\(s / 3600)h" }
    return "\(s / 86_400)d"
}

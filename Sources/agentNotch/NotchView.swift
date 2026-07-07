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
    var onApprovalDecision: (String, ApprovalDecision) -> Void = { _, _ in }
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
    case .cursor: CursorTile(size: size)
    }
}

// Rounded-square Cursor mark.
private struct CursorTile: View {
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(Color(red: 0.12, green: 0.14, blue: 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(cursorAccent)
            )
            .frame(width: size, height: size)
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
        HStack(spacing: 8) {
            if let account {
                productTile(account.product, size: 24)
                if let pct = account.windows.map(\.percent).min(), account.status == nil {
                    RingGauge(fraction: min(max(pct / 100, 0), 1), product: account.product)
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
    var onApprovalDecision: (String, ApprovalDecision) -> Void
    var onSwitchClaudeAccount: (String) -> Void

    var body: some View {
        let sessions = store.sessions
        let visibleSessions = ui.selectedProduct.map { product in sessions.filter { $0.product == product } } ?? sessions
        let selectedIndex = visibleSessions.firstIndex { $0.id == ui.selectedSessionID }
        let selected = selectedIndex.map { visibleSessions[$0] }
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
                ApprovalCard(request: approval, onDecision: onApprovalDecision)
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
                    ProductFilterChip(symbol: "</>", title: "cursor", selected: ui.selectedProduct == .cursor) {
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
                        SessionControl(session: selected, tintIndex: selectedIndex ?? 0) {
                            withAnimation(.smooth(duration: 0.32)) { ui.selectedSessionID = nil }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    } else if visibleSessions.isEmpty {
                        EmptySessions()
                            .transition(.opacity)
                    } else {
                        ScrollView(showsIndicators: false) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(visibleSessions.enumerated()), id: \.element.id) { index, session in
                                    SessionRow(session: session, tintIndex: index) {
                                        withAnimation(.smooth(duration: 0.32)) { ui.selectedSessionID = session.id }
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
    let onDecision: (String, ApprovalDecision) -> Void

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
                    onDecision(request.id, .always)
                }
                ApprovalButton(title: "Allow", shortcut: "⌘A", style: .primary) {
                    onDecision(request.id, .allow)
                }
            }
            Button {
                onDecision(request.id, .deny)
            } label: {
                Text("Deny with feedback")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(peach.opacity(0.35), lineWidth: 1))
        )
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
    let tintIndex: Int
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                SessionTile(session: session, tintIndex: tintIndex)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
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
    }
}

private struct SessionControl: View {
    let session: AgentSession
    let tintIndex: Int
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Capsule()
                .fill(.white.opacity(0.22))
                .frame(width: 3, height: 28)
                .frame(maxWidth: .infinity)
            HStack(spacing: 12) {
                SessionTile(session: session, size: 42, tintIndex: tintIndex)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: session.title)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
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
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white.opacity(0.08))
        )
    }
}

private struct SessionTile: View {
    let session: AgentSession
    var size: CGFloat = 30
    var tintIndex: Int

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
        let palettes = [
            [Color(red: 0.09, green: 0.66, blue: 0.70), Color(red: 0.06, green: 0.51, blue: 0.63)],
            [Color(red: 0.86, green: 0.61, blue: 0.12), Color(red: 0.76, green: 0.42, blue: 0.08)],
            [Color(red: 0.65, green: 0.31, blue: 0.84), Color(red: 0.45, green: 0.22, blue: 0.73)],
            [Color(red: 0.82, green: 0.26, blue: 0.57), Color(red: 0.52, green: 0.20, blue: 0.73)]
        ]
        let colors = palettes[tintIndex % palettes.count]
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

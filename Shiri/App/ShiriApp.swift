import SwiftUI
import UIKit
import ShiriCore

@main
struct ShiriApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsLaunch = LaunchBrandView.animatesOnLaunch
    var body: some Scene {
        WindowGroup {
            AppRootView().environmentObject(model).tint(Paper.accent)
                .accessibilityHidden(showsLaunch)
                .overlay {
                    if showsLaunch {
                        LaunchBrandView(animates: true, didFinish: { showsLaunch = false })
                            .transition(.opacity).zIndex(1)
                    }
                }
                .overlay {
                    if model.preferences.hidesAppWhenInactive && scenePhase != .active && !showsLaunch { ZStack { Paper.background.ignoresSafeArea(); VStack(spacing: 16) { ShiriBrandMark(size: 48); Text("拾日").font(Paper.title(38)); Text("收好小事，也收好日子。").font(.subheadline) }.foregroundColor(Paper.secondary) }.accessibilityLabel("拾日隐私保护") }
                }
                .preferredColorScheme(model.preferences.colorScheme == .system ? nil : model.preferences.colorScheme == .dark ? .dark : .light)
                .task { await model.start() }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task { await model.refresh() } }
                }
        }
    }
}

/// A sunrise and gathering paper cards introduce the brand while storage opens in parallel.
struct LaunchBrandView: View {
    var showsProgress = false
    var animates = false
    var didFinish: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var appeared = false

    static var animatesOnLaunch: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-launch-animation") { return true }
        if arguments.contains("--uitesting") || NSClassFromString("XCTestCase") != nil { return false }
        #endif
        return true
    }

    @State private var sunHasRisen = false
    @State private var cardsHaveGathered = false
    @State private var nameIsVisible = false

    var body: some View {
        ZStack {
            PaperSurface().ignoresSafeArea()
            VStack(spacing: 0) {
                ShiriLaunchArtwork(
                    sunHasRisen: !animates || sunHasRisen,
                    cardsHaveGathered: !animates || cardsHaveGathered
                )
                .padding(.bottom, 28)
                HStack(spacing: 3) {
                    Text("拾")
                    Text("日")
                        .offset(y: animates && !nameIsVisible && !reduceMotion ? 7 : 0)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.35).delay(0.08), value: nameIsVisible)
                }
                .font(Paper.title(36)).foregroundColor(Paper.ink)
                .opacity(animates && !nameIsVisible ? 0 : 1)
                .offset(y: animates && !nameIsVisible && !reduceMotion ? 10 : 0)
                .padding(.bottom, 13)
                Group {
                    if showsProgress { ProgressView("正在打开你的卡片") }
                    else { Text("收好小事，也收好日子。").tracking(1) }
                }
                .font(Paper.text(14)).foregroundColor(Paper.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .opacity(animates && !nameIsVisible ? 0 : 1)
            }
            .padding(.horizontal, 32).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(showsProgress ? "拾日，正在打开你的卡片" : "拾日，收好小事，也收好日子。")
        .accessibilityIdentifier(showsProgress ? "launchLoading" : "launchBrand")
        .background {
            if animates {
                LaunchFirstFrameProbe(isEnabled: true) {
                    guard !appeared else { return }
                    appeared = true
                }.frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .task(id: appeared) {
            guard animates, appeared else { return }
            do {
                if reduceMotion {
                    // Respect reduced motion: reveal the completed mark without moving its layers.
                    withAnimation(.easeOut(duration: 0.12)) {
                        sunHasRisen = true; cardsHaveGathered = true; nameIsVisible = true
                    }
                    try await Task.sleep(nanoseconds: 320_000_000)
                } else {
                    withAnimation(.easeOut(duration: 0.58)) { sunHasRisen = true }
                    try await Task.sleep(nanoseconds: 160_000_000)
                    withAnimation(.spring(response: 0.68, dampingFraction: 0.86)) { cardsHaveGathered = true }
                    try await Task.sleep(nanoseconds: 380_000_000)
                    withAnimation(.easeOut(duration: 0.35)) { nameIsVisible = true }
                    try await Task.sleep(nanoseconds: 660_000_000)
                }
            } catch { return }
            withAnimation(.easeOut(duration: reduceMotion ? 0.12 : 0.22)) { didFinish?() }
        }
    }
}

/// Native layers let the sun rise behind the paper instead of scaling a static app icon.
private struct ShiriLaunchArtwork: View {
    var sunHasRisen: Bool
    var cardsHaveGathered: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let terracotta = Color(hex: "BC6049")
    private var showCards: Bool { cardsHaveGathered || reduceMotion }
    private var showSun: Bool { sunHasRisen || reduceMotion }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "CA7860"), terracotta, Color(hex: "A9503D")], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 160, height: 160)
                .shadow(color: terracotta.opacity(0.15), radius: 15, y: 7)
                .opacity(showSun ? 1 : 0)
            Circle()
                .fill(LinearGradient(colors: [Color(hex: "F2CB8B"), Color(hex: "E9B56A")], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 54, height: 54)
                .offset(x: 91, y: showSun ? 20 : 67)
                .opacity(showSun ? 1 : 0)
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "F7EFD6"), Color(hex: "E6D9B8")], startPoint: .top, endPoint: .bottom))
                .frame(width: 86, height: 99)
                .rotationEffect(.degrees(showCards ? -9 : -22))
                .offset(x: showCards ? 30 : 8, y: showCards ? 48 : 64)
                .opacity(showCards ? 1 : 0)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "FFFAEA"), Color(hex: "F6EDCF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 86, height: 105)
                    .shadow(color: Color(hex: "713B24").opacity(0.16), radius: 3, y: 3)
                Capsule().fill(terracotta).frame(width: 49, height: 9).offset(x: 18, y: 34)
                ShiriLaunchFold()
                    .fill(LinearGradient(colors: [Color(hex: "E0D0AA"), Color(hex: "FFFBEA")], startPoint: .bottomLeading, endPoint: .topTrailing))
                    .frame(width: 29, height: 31).offset(x: 57, y: 74)
            }
            .frame(width: 86, height: 105, alignment: .topLeading)
            .rotationEffect(.degrees(showCards ? 0 : 12))
            .offset(x: showCards ? 46 : 68, y: showCards ? 39 : 59)
            .opacity(showCards ? 1 : 0)
        }
        .frame(width: 160, height: 160, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

private struct ShiriLaunchFold: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addQuadCurve(to: CGPoint(x: rect.width, y: 0), control: CGPoint(x: rect.width * 0.72, y: rect.height * 0.88))
            path.addQuadCurve(to: CGPoint(x: rect.width * 0.25, y: rect.height * 0.35), control: CGPoint(x: rect.width * 0.82, y: rect.height * 0.25))
            path.addQuadCurve(to: CGPoint(x: 0, y: rect.height), control: CGPoint(x: rect.width * 0.1, y: rect.height * 0.44))
        }
    }
}

/// A SwiftUI task may start while the system launch snapshot still covers the first frame.
/// Wait for this window to be active and enter its display loop before starting the short animation.
private struct LaunchFirstFrameProbe: UIViewRepresentable {
    var isEnabled: Bool
    var onReady: () -> Void

    func makeUIView(context: Context) -> LaunchFirstFrameView { LaunchFirstFrameView() }
    func updateUIView(_ uiView: LaunchFirstFrameView, context: Context) {
        uiView.onReady = onReady
        uiView.isEnabled = isEnabled
    }
    static func dismantleUIView(_ uiView: LaunchFirstFrameView, coordinator: ()) { uiView.stopWaiting() }
}

private final class LaunchFirstFrameView: UIView {
    var onReady: () -> Void = {}
    var isEnabled = false { didSet { updateWaiting() } }
    private var displayLink: CADisplayLink?
    private var visibleFrames = 0
    private var delivered = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateWaiting()
    }

    private func updateWaiting() {
        guard isEnabled, window != nil, !delivered else { stopWaiting(); return }
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayFrame))
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func displayFrame() {
        guard window?.windowScene?.activationState == .foregroundActive else { visibleFrames = 0; return }
        visibleFrames += 1
        guard visibleFrames >= 2 else { return }
        delivered = true
        stopWaiting()
        onReady()
    }

    func stopWaiting() {
        displayLink?.invalidate()
        displayLink = nil
        visibleFrames = 0
    }
}

import SwiftUI

/// First-launch tutorial (4 illustrated pages) ending in the accuracy disclaimer.
/// First launch (`replay == false`): the last page's "I understand" sets `disclaimerAccepted`, which closes the
/// cover in App.swift. Replay (Settings): the last page just closes.
struct OnboardingView: View {
    var replay = false
    @AppStorage("onboardingCompleted") private var onboardingCompleted = false
    @AppStorage("disclaimerAccepted") private var disclaimerAccepted = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0

    private static let pages: [TutorialPage.Content] = [
        .init(image: "Tutorial1", accent: .aim, title: "Aim at the item",
              body: "Point your iPhone at the box until the frame locks on. iPhones with LiDAR measure with LiDAR; other iPhones use the camera.",
              alt: "Phone aiming at a box"),
        .init(image: "Tutorial2", accent: .orbit, title: "Walk around it",
              body: "Circle the item slowly, keeping it in view, until every segment of the ring lights up.",
              alt: "Phones circling a box with a lit ring"),
        .init(image: "Tutorial3", accent: .check, title: "Get the dimensions",
              body: "Length, width and height are calculated for you. Check them and adjust if needed.",
              alt: "Box with measured dimension lines"),
        .init(image: "Tutorial4", accent: .share, title: "Save & export",
              body: "Add items to inbound orders, then share reports as CSV or PDF.",
              alt: "Report sheet with CSV and PDF export"),
    ]
    private var last: Int { Self.pages.count }  // index of the disclaimer page

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                if page < last { Button("Skip") { go(last) }.font(.headline).tint(.brand) }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 20)

            TabView(selection: $page) {
                ForEach(Self.pages.indices, id: \.self) { i in
                    TutorialPage(content: Self.pages[i], active: page == i).tag(i)
                }
                disclaimerPage.tag(last)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))

            HStack(spacing: 8) {
                ForEach(0...last, id: \.self) { i in
                    Capsule().fill(i == page ? Color.brand : Color.secondary.opacity(0.3))
                        .frame(width: i == page ? 20 : 8, height: 8)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3), value: page)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Page \(page + 1) of \(last + 1)"))

            Group {
                if page < last {
                    Button("Next") { go(page + 1) }
                } else if replay {
                    Button("Done") { dismiss() }
                } else {
                    Button("I understand") { onboardingCompleted = true; disclaimerAccepted = true }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background(Color.canvas)
    }

    private func go(_ i: Int) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.25) : .default) { page = i }
    }

    private var disclaimerPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 44)).foregroundStyle(Color.warn)
                    .accessibilityHidden(true)
                Text("Accuracy notice").font(.title2.weight(.bold)).foregroundStyle(.brand)
                DisclaimerText()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Single source of the disclaimer text (onboarding last page + Settings → About → Disclaimer).
struct DisclaimerText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measurements are estimates produced from your iPhone's sensors (LiDAR) or camera.")
            Text("Accuracy is not guaranteed. It varies with the device, the object's shape and material, lighting, surroundings and scanning technique.")
            Text("Camera measuring, used on iPhones without LiDAR, is less precise: roughly ±3 cm in our tests.")
            Text("Verify critical dimensions with a tape measure before relying on them, for example for freight charges, packing or customs.")
            Text("You use the app and its results at your own responsibility and risk. The developer accepts no liability for any loss or damage arising from use of the measurements.")
        }
        .font(.body)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct DisclaimerView: View {
    var body: some View {
        ScrollView {
            DisclaimerText().padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Disclaimer")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One illustrated page: spring entry on becoming active, gentle idle float, small animated accent badge.
/// Reduce Motion: fades only (no spring, float or badge motion).
private struct TutorialPage: View {
    enum Accent { case aim, orbit, check, share }
    struct Content {
        let image: String
        let accent: Accent
        let title: LocalizedStringResource
        let body: LocalizedStringResource
        let alt: LocalizedStringResource
    }

    let content: Content
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        // Centered when it fits; scrolls at large Dynamic Type sizes.
        ViewThatFits(in: .vertical) {
            page
            ScrollView { page }.scrollBounceBehavior(.basedOnSize)
        }
        .onChange(of: active, initial: true) { _, a in
            guard a else { shown = false; return }  // TabView pre-renders neighbours: animate only when active
            withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .spring(response: 0.55, dampingFraction: 0.7)) { shown = true }
        }
    }

    private var page: some View {
        VStack(spacing: 20) {
            TimelineView(.animation(paused: !active || reduceMotion)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                Image(content.image).resizable().scaledToFit()
                    .accessibilityLabel(Text(content.alt))
                    .overlay(alignment: .topTrailing) {
                        AccentBadge(accent: content.accent, active: active && shown).accessibilityHidden(true)
                    }
                    .offset(y: reduceMotion ? 0 : 6 * sin(t * 2 * .pi / 3.5))  // gentle float
            }
            .frame(maxWidth: 400, maxHeight: 300)
            .scaleEffect(shown || reduceMotion ? 1 : 0.85)
            .offset(y: shown || reduceMotion ? 0 : 24)
            .opacity(shown ? 1 : 0)

            VStack(spacing: 8) {
                Text(content.title).font(.title2.weight(.bold)).foregroundStyle(.brand)
                Text(content.body).font(.body).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}

/// Small badge echoing the scan UI: brackets + laser line (aim), filling SectorRing (orbit), symbol pop (check/share).
private struct AccentBadge: View {
    let accent: TutorialPage.Accent
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var covered = [Bool](repeating: false, count: 12)
    @State private var pop = false

    var body: some View {
        content
            .frame(width: 64, height: 64)
            .background(.ultraThinMaterial, in: Circle())
            .task(id: active) { await run() }
    }

    @ViewBuilder private var content: some View {
        switch accent {
        case .aim:
            ZStack {
                Brackets(arm: 8).stroke(Color.scan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 32, height: 32)
                TimelineView(.animation(paused: !active || reduceMotion)) { ctx in
                    let u = (sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi / 2.2) + 1) / 2
                    Capsule().fill(Color.scan).frame(width: 28, height: 2)
                        .shadow(color: .scan, radius: 3)
                        .offset(y: reduceMotion ? 0 : (u - 0.5) * 24)
                }
            }
        case .orbit:
            SectorRing(covered: covered, done: !covered.contains(false))
        case .check, .share:
            Image(systemName: accent == .check ? "checkmark.circle.fill" : "square.and.arrow.up.circle.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white, accent == .check ? Color.scan : Color.accent)
                .scaleEffect(pop || reduceMotion ? 1 : 0.3)
                .opacity(pop ? 1 : 0)
        }
    }

    private func run() async {
        covered = [Bool](repeating: false, count: 12); pop = false
        guard active else { return }
        switch accent {
        case .aim: return
        case .orbit:
            if reduceMotion { covered = covered.map { _ in true }; return }
            for i in covered.indices {
                guard await pause(0.15) else { return }
                covered[i] = true
            }
        case .check, .share:
            guard await pause(0.35) else { return }
            withAnimation(reduceMotion ? .easeIn(duration: 0.25) : .spring(response: 0.35, dampingFraction: 0.5)) { pop = true }
        }
    }
}

#Preview { OnboardingView() }

import SwiftUI

// In-camera scan guidance (replaces the ScanAim / ScanOrbit hint cards):
// aim = laser sweep + reticle (+ face chip + lock progress ring), lock = reticle snap + ✓,
// scan = rotating orbit arrow that flies into the coverage ring, done = ring sweep + ✓ (SectorRing).
// Reduce Motion: no sweep / rotation / flight / scaling, only static states and opacity.

/// Full-bleed overlay; must be laid out over the whole screen so its center == depth-map center.
/// `ringCenter`: SectorRing center in the `ScanGuidance.space` coordinate space (orbit arrow fly-in target).
struct ScanGuidance: View {
    static let space = "scanHUD"

    let phase: ScanSession.Phase
    let surface: SurfaceHint?
    let progress: Double
    var ringCenter: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = Stage.none

    private enum Stage { case none, locked, orbit, flown }

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(Self.space))
            let target = ringCenter.map { CGSize(width: $0.x - frame.midX, height: $0.y - frame.midY) } ?? .zero
            ZStack {
                ZStack { if phase == .aim { LaserSweep() } }
                    .animation(.easeOut(duration: 0.3), value: phase)  // laser fades; reticle -> LockBurst stays instant
                if phase == .aim { AimReticle(surface: surface, progress: progress) }
                if stage == .locked { LockBurst() }
                if stage == .orbit || stage == .flown {
                    OrbitArrow(flown: stage == .flown, target: target)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .allowsHitTesting(false)
        .task(id: phase) {
            guard phase == .scan else { stage = .none; return }
            stage = .locked
            guard await pause(0.6) else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { stage = .orbit }
            guard await pause(2.5) else { return }
            withAnimation(.easeIn(duration: reduceMotion ? 0.3 : 0.55)) { stage = .flown }
            guard await pause(0.6) else { return }
            withAnimation(.easeOut(duration: 0.2)) { stage = .none }
        }
    }
}

/// Sleep; false if cancelled (`try? await Task.sleep` would swallow the cancellation and carry on).
func pause(_ seconds: Double) async -> Bool {
    (try? await Task.sleep(for: .seconds(seconds))) != nil
}

/// Thin laser line sweeping top -> bottom -> top (2.2 s per pass, ease-in-out) with a speed-scaled
/// fading trail, over a static edge vignette.
struct LaserSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let pass = 2.2
    private static let trail = Gradient(colors: [Color.scan.opacity(0), Color.scan.opacity(0.28)])
    private static let vignette = Gradient(colors: [.clear, .black.opacity(0.35)])

    var body: some View {
        ZStack {
            RadialGradient(gradient: Self.vignette, center: .center, startRadius: 160, endRadius: 520)
            if !reduceMotion {
                TimelineView(.animation) { ctx in
                    Canvas { g, size in
                        let x = (ctx.date.timeIntervalSinceReferenceDate / Self.pass).truncatingRemainder(dividingBy: 2)
                        let down = x < 1, u = down ? x : 2 - x
                        let y = size.height * u * u * (3 - 2 * u)              // smoothstep ease-in-out
                        let len = 30 + 110 * 4 * u * (1 - u)                   // trail ~ speed
                        let tail = down ? y - len : y + len
                        let trail = CGRect(x: 0, y: min(y, tail), width: size.width, height: len)
                        g.fill(Path(trail), with: .linearGradient(Self.trail, startPoint: CGPoint(x: 0, y: tail),
                                                                  endPoint: CGPoint(x: 0, y: y)))
                        var glow = g
                        glow.addFilter(.blur(radius: 6))
                        glow.fill(Path(CGRect(x: 0, y: y - 3, width: size.width, height: 6)), with: .color(.scan.opacity(0.8)))
                        g.fill(Path(CGRect(x: 0, y: y - 0.75, width: size.width, height: 1.5)), with: .color(.scan))
                    }
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Four corner brackets.
struct Brackets: Shape {
    var arm: CGFloat = 16
    func path(in r: CGRect) -> Path {
        var p = Path()
        for (c, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1, 1),
                            (CGPoint(x: r.minX, y: r.maxY), 1, -1), (CGPoint(x: r.maxX, y: r.maxY), -1, -1)] {
            p.move(to: CGPoint(x: c.x, y: c.y + dy * arm))
            p.addLine(to: c)
            p.addLine(to: CGPoint(x: c.x + dx * arm, y: c.y))
        }
        return p
    }
}

struct AimReticle: View {
    let surface: SurfaceHint?
    let progress: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let found = surface != nil
        ZStack {
            Brackets()
                .stroke(found ? Color.scan : .white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .frame(width: 84, height: 84)
                .phaseAnimator(reduceMotion || found ? [false] : [false, true]) { v, big in
                    v.scaleEffect(big ? 1.06 : 1)
                } animation: { _ in .easeInOut(duration: 1.2) }
                .scaleEffect(found && !reduceMotion ? 0.76 : 1)
            Circle().fill(found ? Color.scan : .white).frame(width: 6, height: 6)
            Circle().stroke(.white.opacity(0.25), lineWidth: 4).frame(width: 108, height: 108)
                .opacity(found ? 1 : 0)
            Circle().trim(from: 0, to: found ? progress : 0)
                .stroke(Color.scan, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 108, height: 108)
                .opacity(found ? 1 : 0)
                .animation(found ? .linear(duration: 0.2) : .easeOut(duration: 0.15), value: progress)
            if let surface {
                Label(surface == .top ? "检测到箱顶，保持不动" : "检测到侧面，保持不动",
                      systemImage: surface == .top ? "square.topthird.inset.filled" : "square.leadingthird.inset.filled")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .offset(y: 92)  // below the ring; offset keeps the reticle centered
                    .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.9)))
                    .id(surface)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 2)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.35, dampingFraction: 0.6), value: surface)
        .accessibilityElement(children: .combine)
    }
}

/// Lock confirmation: solid green brackets snap 1 -> 1.25 -> 0 while a ✓ pops and fades.
struct LockBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var go = false

    private struct V { var brackets = 1.0, check = 0.3, checkOpacity = 1.0 }

    var body: some View {
        let rm = reduceMotion
        return Color.clear.keyframeAnimator(initialValue: V(), trigger: go) { _, k in
            ZStack {
                Brackets().stroke(Color.scan, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                    .frame(width: 84 * 0.76, height: 84 * 0.76)
                    .scaleEffect(rm ? 1 : k.brackets)
                    .opacity(rm ? k.checkOpacity : 1)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white, Color.scan)
                    .scaleEffect(rm ? 1 : k.check)
                    .opacity(k.checkOpacity)
            }
        } keyframes: { _ in
            KeyframeTrack(\.brackets) {
                CubicKeyframe(1.25, duration: 0.15)
                CubicKeyframe(0, duration: 0.25)
            }
            KeyframeTrack(\.check) {
                SpringKeyframe(1.15, duration: 0.25, spring: .bouncy)
                SpringKeyframe(1, duration: 0.15)
            }
            KeyframeTrack(\.checkOpacity) {
                LinearKeyframe(1, duration: 0.35)
                LinearKeyframe(0, duration: 0.25)
            }
        }
        .onAppear { go = true }
        .accessibilityHidden(true)
    }
}

/// ~300° arc with an arrowhead (clockwise in screen space, like walking around the box).
struct OrbitArc: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), rad = min(r.width, r.height) / 2
        let end = Angle.degrees(-90 + 300)
        var p = Path()
        p.addArc(center: c, radius: rad, startAngle: .degrees(-90), endAngle: end, clockwise: false)
        // Arrowhead at the arc end, pointing along the clockwise tangent.
        let tip = CGPoint(x: c.x + rad * cos(end.radians), y: c.y + rad * sin(end.radians))
        let t = CGVector(dx: -sin(end.radians), dy: cos(end.radians)), n = CGVector(dx: cos(end.radians), dy: sin(end.radians))
        let h: CGFloat = 16, w: CGFloat = 12
        p.move(to: CGPoint(x: tip.x - t.dx * h + n.dx * w, y: tip.y - t.dy * h + n.dy * w))
        p.addLine(to: CGPoint(x: tip.x + t.dx * 4, y: tip.y + t.dy * 4))
        p.addLine(to: CGPoint(x: tip.x - t.dx * h - n.dx * w, y: tip.y - t.dy * h - n.dy * w))
        return p
    }
}

struct OrbitArrow: View {
    let flown: Bool
    let target: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let size: CGFloat = 200, ring: CGFloat = 60

    var body: some View {
        let fly = flown && !reduceMotion
        ZStack {
            TimelineView(.animation(paused: reduceMotion)) { ctx in
                OrbitArc()
                    .stroke(Color.scan.opacity(0.75), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .frame(width: Self.size, height: Self.size)
                    .rotationEffect(.degrees(reduceMotion ? 0
                        : ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3 * 360))
            }
            .shadow(color: .scan.opacity(0.6), radius: 6)
            .scaleEffect(fly ? Self.ring / Self.size : 1)
            .offset(fly ? target : .zero)
            .opacity(flown ? (fly ? 0.3 : 0) : 1)
            Text("绕着物体慢慢走一圈")
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .offset(y: Self.size / 2 + 36)
                .opacity(flown ? 0 : 1)
        }
        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.6)))
    }
}

/// Reports the coverage ring's center (in `ScanGuidance.space`) for the orbit-arrow fly-in.
struct RingCenterKey: PreferenceKey {
    static var defaultValue: CGPoint?
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) { value = nextValue() ?? value }
}

/// 12 arc segments, one per 30° azimuth sector around the box (not rotated to the camera heading).
/// Newly covered segment pops; `done` runs one bright sweep around the ring, then shows ✓.
struct SectorRing: View {
    let covered: [Bool]
    var done = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop: Int?
    @State private var sweep: CGFloat = 0
    @State private var check = false

    var body: some View {
        let n = covered.filter { $0 }.count
        ZStack {
            ZStack {
                ForEach(covered.indices, id: \.self) { i in
                    let c = CGFloat(covered.count)
                    Circle().trim(from: (CGFloat(i) + 0.08) / c, to: (CGFloat(i) + 0.92) / c)
                        .stroke(covered[i] ? Color.scan : Color.secondary.opacity(0.35), lineWidth: 6)
                        .scaleEffect(pop == i ? 1.15 : 1)
                }
                if done && !check && !reduceMotion {
                    Circle().trim(from: max(0, sweep - 0.25), to: sweep)
                        .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .shadow(color: .scan, radius: 4)
                }
            }
            .rotationEffect(.degrees(-90))
            if check {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white, Color.scan)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            } else {
                Text("\(n)/\(covered.count)").font(.num(.caption2))
            }
        }
        .frame(width: 60, height: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done ? "扫描完成" : "已覆盖 \(n)/\(covered.count) 个方向")
        .onChange(of: covered) { old, new in
            guard !reduceMotion, old.count == new.count,
                  let i = new.indices.first(where: { new[$0] && !old[$0] }) else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pop = i }
            Task { @MainActor in
                guard await pause(0.18) else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { pop = nil }
            }
        }
        .onChange(of: done, initial: true) { _, d in
            sweep = 0; check = false
            guard d else { return }
            if reduceMotion { withAnimation(.easeIn(duration: 0.2)) { check = true }; return }
            withAnimation(.easeInOut(duration: 0.7)) { sweep = 1 } completion: {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { check = true }
            }
        }
    }
}

#if DEBUG
/// Fake-state cycle: aim → detected → locked → scanning → done.
struct ScanGuidanceDemo: View {
    @State private var phase = ScanSession.Phase.aim
    @State private var surface: SurfaceHint?
    @State private var progress = 0.0
    @State private var covered = [Bool](repeating: false, count: 12)
    @State private var ring: CGPoint?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.gray, .brown.opacity(0.6)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            ScanGuidance(phase: phase, surface: surface, progress: progress, ringCenter: ring).ignoresSafeArea()
            VStack {
                Spacer()
                SectorRing(covered: covered, done: phase == .done)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: RingCenterKey.self,
                                               value: CGPoint(x: g.frame(in: .named(ScanGuidance.space)).midX,
                                                              y: g.frame(in: .named(ScanGuidance.space)).midY))
                    })
                    .padding(32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial)
            }
        }
        .coordinateSpace(name: ScanGuidance.space)
        .onPreferenceChange(RingCenterKey.self) { ring = $0 }
        .environment(\.colorScheme, .dark)
        .task {
            while !Task.isCancelled {
                phase = .aim; surface = nil; progress = 0; covered = Array(repeating: false, count: 12)
                guard await pause(2.5) else { return }
                surface = .top
                for p in stride(from: 0.0, through: 0.95, by: 0.19) { progress = p; guard await pause(0.2) else { return } }
                progress = 1; phase = .scan; covered[0] = true
                guard await pause(3.8) else { return }
                for i in 1..<12 { covered[i] = true; guard await pause(0.4) else { return } }
                phase = .done
                guard await pause(2.5) else { return }
            }
        }
    }
}

#Preview("Scan guidance") { ScanGuidanceDemo() }
#endif

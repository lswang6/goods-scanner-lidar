import SwiftUI
import BoxMeasureKit

// In-camera scan guidance (replaces the ScanAim / ScanOrbit hint cards):
// camera mode, no floor yet = perspective floor grid + phone-tilt hint (FloorGrid);
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
    /// Camera mode only; nil = LiDAR.
    var cameraStage: ScanSession.CameraStage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var stage = Stage.none

    private enum Stage { case none, locked, orbit, flown }

    var body: some View {
        GeometryReader { geo in
            let frame = geo.frame(in: .named(Self.space))
            let target = ringCenter.map { CGSize(width: $0.x - frame.midX, height: $0.y - frame.midY) } ?? .zero
            ZStack {
                let floor = phase == .aim && cameraStage == .findingFloor
                ZStack {
                    if floor { FloorGrid().transition(.opacity) }
                    else if phase == .aim { LaserSweep().transition(.opacity) }
                }
                .animation(.easeOut(duration: 0.3), value: phase)  // laser fades; reticle -> LockBurst stays instant
                .animation(.easeInOut(duration: 0.4), value: floor)
                if phase == .aim && !floor { AimReticle(surface: surface, progress: progress) }
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
                let (text, icon): (LocalizedStringKey, String) = switch surface {
                case .top: ("Top detected, hold still", "square.topthird.inset.filled")
                case .side: ("Side detected, hold still", "square.leadingthird.inset.filled")
                case .object: ("Object detected, hold still", "shippingbox.fill")
                }
                Label(text, systemImage: icon)
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
            Text("Walk slowly around the item")
                .font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .offset(y: Self.size / 2 + 36)
                .opacity(flown ? 0 : 1)
        }
        .transition(.opacity.combined(with: .scale(scale: reduceMotion ? 1 : 0.6)))
    }
}

/// Camera mode before ARKit has a floor plane: a perspective floor grid revealed by a band sweeping away from
/// the viewer (2.4 s per pass), and a phone glyph tilting down toward the floor.
/// Reduce Motion: static grid fading in, static tilted phone.
struct FloorGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    private static let pass = 2.4, rows = 10, cols = 9

    var body: some View {
        ZStack {
            if reduceMotion {
                Canvas { g, size in Self.draw(&g, size, sweep: nil) }
                    .opacity(shown ? 1 : 0)
                    .onAppear { withAnimation(.easeIn(duration: 0.6)) { shown = true } }
            } else {
                TimelineView(.animation) { ctx in
                    Canvas { g, size in
                        Self.draw(&g, size, sweep: ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.pass) / Self.pass)
                    }
                }
            }
            Image(systemName: "iphone.gen3")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.4), radius: 3)
                .phaseAnimator(reduceMotion ? [true] : [false, true]) { v, tilted in
                    v.rotation3DEffect(.degrees(tilted ? 40 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.6)
                } animation: { _ in .easeInOut(duration: 1.4) }
                .offset(y: -40)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// Grid on the lower 55 % of the screen; depth rows at y = horizon + span / z (z = 1 at the bottom edge).
    /// `sweep` 0...1: rows nearer than the band are revealed, the band itself glows. nil: whole grid, static.
    private static func draw(_ g: inout GraphicsContext, _ size: CGSize, sweep: Double?) {
        let horizon = size.height * 0.45, span = size.height - horizon, cx = size.width / 2
        let zMax = 6.0, zSweep = sweep.map { 1 + (zMax - 1) * $0 } ?? zMax
        func y(_ z: Double) -> CGFloat { horizon + span / z }
        func fade(_ z: Double) -> Double { z <= zSweep ? 0.55 * (1 - (z - 1) / zMax) : 0.06 }
        for i in 0...rows {
            let z = 1 + (zMax - 1) * Double(i) / Double(rows)
            g.stroke(Path { p in p.move(to: CGPoint(x: 0, y: y(z))); p.addLine(to: CGPoint(x: size.width, y: y(z))) },
                     with: .color(.scan.opacity(fade(z))), lineWidth: 1.5)
        }
        // Columns: lines on the floor converging toward the vanishing point, revealed up to the band.
        for j in 0...cols {
            let x = (Double(j) / Double(cols) - 0.5) * 3 * size.width   // floor x at z = 1 (wider than the screen)
            let far = min(zSweep, zMax)
            g.stroke(Path { p in p.move(to: CGPoint(x: cx + x, y: y(1))); p.addLine(to: CGPoint(x: cx + x / far, y: y(far))) },
                     with: .color(.scan.opacity(0.4)), lineWidth: 1.5)
        }
        guard sweep != nil else { return }
        var glow = g
        glow.addFilter(.blur(radius: 5))
        let band = Path(CGRect(x: 0, y: y(zSweep) - 2, width: size.width, height: 4))
        glow.fill(band, with: .color(.scan.opacity(0.8)))
        g.fill(Path(CGRect(x: 0, y: y(zSweep) - 0.75, width: size.width, height: 1.5)), with: .color(.scan))
    }
}

/// Reports the coverage ring's center (in `ScanGuidance.space`) for the orbit-arrow fly-in.
struct RingCenterKey: PreferenceKey {
    static var defaultValue: CGPoint?
    static func reduce(value: inout CGPoint?, nextValue: () -> CGPoint?) { value = nextValue() ?? value }
}

/// 12 arc segments, one per 30° azimuth sector around the box (not rotated to the camera heading).
/// Newly covered segment pops; `done` runs one bright sweep around the ring, then shows ✓.
/// `needed` (camera mode, before the first estimate): any `needed` sectors must be covered first. Segments are
/// absolute azimuth, so the threshold is shown as a count: an inner half-circle track filling k/needed, center k/needed.
struct SectorRing: View {
    let covered: [Bool]
    var done = false
    var needed: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pop: Int?
    @State private var sweep: CGFloat = 0
    @State private var check = false

    var body: some View {
        let n = covered.filter { $0 }.count
        let gate = needed.flatMap { n < $0 ? $0 : nil }
        ZStack {
            ZStack {
                if let gate {
                    let half = CGFloat(gate) / CGFloat(covered.count)
                    Circle().trim(from: 0, to: half)
                        .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 3]))
                        .padding(9)
                    Circle().trim(from: 0, to: half * CGFloat(n) / CGFloat(gate))
                        .stroke(Color.scan, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .padding(9)
                        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: n)
                    Capsule().fill(.white).frame(width: 8, height: 2)   // threshold tick at the half circle (radial)
                        .offset(x: -21)
                }
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
                Text("\(n)/\(gate ?? covered.count)").font(.num(.caption2))
            }
        }
        .frame(width: 60, height: 60)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(done ? Text("Scan complete")
                            : gate.map { Text("\(n) of \($0) directions needed to measure") }
                            ?? Text("\(n) of \(covered.count) directions covered"))
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
/// Scan screen without AR (simulator / previews / render tests): guidance + status capsule + ScanCard over a
/// fake camera backdrop. `cameraStage` nil = LiDAR.
struct ScanStageScreen: View {
    var phase = ScanSession.Phase.aim
    var surface: SurfaceHint?
    var progress = 0.0
    var cameraStage: ScanSession.CameraStage?
    var sectors = [Bool](repeating: false, count: ScanSession.sectorCount)
    var median: BoxEstimate?
    var status = ""
    @State private var ring: CGPoint?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.45), Color(red: 0.45, green: 0.35, blue: 0.25)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScanGuidance(phase: phase, surface: surface, progress: progress, ringCenter: ring, cameraStage: cameraStage)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                Text(status).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                ScanCard(phase: phase, cameraStage: cameraStage, sectors: sectors, median: median,
                         spread: median == nil ? 0 : 0.012, sampleCount: median == nil ? 0 : 3, shots: median == nil ? 0 : 2)
            }
            .padding(16)
        }
        .coordinateSpace(name: ScanGuidance.space)
        .onPreferenceChange(RingCenterKey.self) { ring = $0 }
        .environment(\.colorScheme, .dark)
    }

    static let demoBox = BoxEstimate(length: 0.402, width: 0.301, height: 0.298, center: .zero, yaw: 0, planeY: 0, pointCount: 0)

    /// Fixed camera-mode stages (previews, render tests).
    static var cameraStages: [(name: String, screen: ScanStageScreen)] {
        let some = (0..<12).map { $0 < 4 }, half = (0..<12).map { $0 < 6 }, nine = (0..<12).map { $0 < 9 }
        return [
            ("c1-finding-floor", .init(cameraStage: .findingFloor, status: ScanSession.floorHint)),
            ("c2-searching", .init(cameraStage: .searching, status: ScanSession.cameraAimHint)),
            ("c3-locking", .init(surface: .object, progress: 0.6, cameraStage: .locking(0.6),
                                 status: String(localized: "Hold steady on the item for 1 second…"))),
            ("c4-collecting", .init(phase: .scan, cameraStage: .collecting(covered: 4, needed: 6), sectors: some,
                                    status: String(localized: "Keep walking: \(2) more directions to measure"))),
            ("c5-measuring-wait", .init(phase: .scan, cameraStage: .measuring, sectors: half,
                                        status: ScanSession.remainingHint(3, camera: true))),
            ("c6-measuring", .init(phase: .scan, cameraStage: .measuring, sectors: nine, median: demoBox,
                                   status: String(localized: "Coverage complete, refining the size…"))),
            ("c7-done", .init(phase: .done, cameraStage: .done, sectors: Array(repeating: true, count: 12), median: demoBox,
                              status: String(localized: "Done"))),
        ]
    }
}

/// Fake-state cycle. LiDAR: aim → detected → locked → scanning → done. Camera: finding floor → searching →
/// locking → collecting (to 6/12) → measuring → done. ScanView shows it on the simulator with `-scanGuidanceDemo`.
struct ScanGuidanceDemo: View {
    var camera = true
    @State private var s = ScanStageScreen()

    var body: some View {
        s.task {
            while !Task.isCancelled {
                let ok = camera ? await cameraCycle() : await lidarCycle()
                guard ok else { return }
            }
        }
    }

    private func lidarCycle() async -> Bool {
        s = ScanStageScreen(status: ScanSession.aimHint)
        guard await pause(2.5) else { return false }
        s.surface = .top
        for p in stride(from: 0.0, through: 0.95, by: 0.19) { s.progress = p; guard await pause(0.2) else { return false } }
        s.progress = 1; s.phase = .scan; s.sectors[0] = true
        guard await pause(3.8) else { return false }
        for i in 1..<12 {
            s.sectors[i] = true
            if i == 5 { s.median = ScanStageScreen.demoBox }
            guard await pause(0.4) else { return false }
        }
        s.phase = .done
        return await pause(2.5)
    }

    private func cameraCycle() async -> Bool {
        let needed = ScanSession.cameraMinSectors
        s = ScanStageScreen(cameraStage: .findingFloor, status: ScanSession.floorHint)
        guard await pause(3) else { return false }
        s.cameraStage = .searching; s.status = ScanSession.cameraAimHint
        guard await pause(2.5) else { return false }
        s.surface = .object; s.status = String(localized: "Hold steady on the item for 1 second…")
        for p in stride(from: 0.0, through: 0.95, by: 0.19) {
            s.progress = p; s.cameraStage = .locking(p)
            guard await pause(0.2) else { return false }
        }
        s.progress = 1; s.phase = .scan; s.sectors[0] = true
        s.cameraStage = .collecting(covered: 1, needed: needed)
        s.status = String(localized: "Locked, walk slowly around the item")
        guard await pause(3.8) else { return false }
        for i in 1..<12 {
            s.sectors[i] = true
            let n = i + 1, left = needed - n
            s.cameraStage = left > 0 ? .collecting(covered: n, needed: needed) : .measuring
            s.status = left > 0 ? String(localized: "Keep walking: \(left) more directions to measure")
                : ScanSession.remainingHint(max(0, ScanSession.finishSectors - n), camera: true)
            if n == needed + 1 { s.median = ScanStageScreen.demoBox }
            guard await pause(0.6) else { return false }
        }
        s.phase = .done; s.cameraStage = .done; s.status = String(localized: "Done")
        return await pause(2.5)
    }
}

#Preview("Scan guidance · camera") { ScanGuidanceDemo() }
#Preview("Scan guidance · LiDAR") { ScanGuidanceDemo(camera: false) }
#Preview("Camera stages") {
    TabView { ForEach(ScanStageScreen.cameraStages, id: \.name) { $0.screen } }.tabViewStyle(.page)
}
#endif

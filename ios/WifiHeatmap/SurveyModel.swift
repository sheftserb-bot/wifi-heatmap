import ARKit
import SwiftUI
import UIKit

/// Live survey: follows the phone's position with ARKit and runs speed tests.
@MainActor
final class SurveyModel: ObservableObject {
    @Published var survey: Survey
    @Published var livePos: Vec2?
    @Published var heading: Double = 0
    @Published var trackingText = "Starting camera…"
    @Published var trackingOK = false
    @Published var busy = false
    @Published var progressText: String?
    @Published var lastResult: Sample?
    @Published var autoMode = false
    @Published var autoHint: String?
    @Published var heat: HeatLayer?
    @Published var metric: Metric = .down { didSet { rebuildHeat() } }
    var thresholds = Thresholds.current { didSet { if thresholds != oldValue { rebuildHeat() } } }
    @Published var planImage: UIImage?
    /// First point of the 2-point alignment (camera position + tapped plan spot).
    @Published var alignFirst: AlignPoint?
    @Published var alignMessage: String?

    struct AlignPoint { let world: Vec2; let plan: Vec2 }

    var needsAlignment: Bool { survey.needsAlignment ?? false }
    private var lastWorld: Vec2?

    let session: ARSession
    private let store: SurveyStore
    private var keepAlive: AnyObject?
    private var pendingConfig: ARConfiguration?
    private var timer: Timer?
    private var history: [(t: TimeInterval, p: Vec2)] = []
    private let sessionStart = Date()
    private var trailStart: Int
    private var startSetThisSession = false
    private let tester = SpeedTester()

    init(survey: Survey, store: SurveyStore, session: ARSession, keepAlive: AnyObject?, configuration: ARConfiguration?) {
        self.survey = survey
        self.store = store
        self.session = session
        self.keepAlive = keepAlive
        self.pendingConfig = configuration
        self.trailStart = survey.trail.count
        if let f = survey.planImageFile { planImage = UIImage(contentsOfFile: store.imageURL(f).path) }
        rebuildHeat()
    }

    /// Open a saved survey (or a new one without a scan). Uses the saved world map,
    /// if any, so ARKit can recognise the space and put you back on the plan.
    static func open(_ survey: Survey, store: SurveyStore) -> SurveyModel {
        let config = ARWorldTrackingConfiguration()
        config.worldAlignment = .gravity
        if survey.hasWorldMap,
           let data = try? Data(contentsOf: store.worldMapURL(survey.id)),
           let map = try? NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: data) {
            config.initialWorldMap = map
        }
        return SurveyModel(survey: survey, store: store, session: ARSession(), keepAlive: nil, configuration: config)
    }

    // MARK: Lifecycle

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        if let c = pendingConfig {
            session.run(c, options: [.resetTracking, .removeExistingAnchors])
            pendingConfig = nil
        } else {
            // Came straight from a scan: save a world map early so the survey can be resumed later.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await self?.saveWorldMap()
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func finish() async {
        timer?.invalidate(); timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        save()
        if trackingOK { await saveWorldMap() }
        session.pause()
        keepAlive = nil
    }

    func save() { store.save(survey) }

    private func saveWorldMap() async {
        let url = store.worldMapURL(survey.id)
        let ok: Bool = await withCheckedContinuation { cont in
            session.getCurrentWorldMap { map, _ in
                guard let map,
                      let data = try? NSKeyedArchiver.archivedData(withRootObject: map, requiringSecureCoding: true)
                else { cont.resume(returning: false); return }
                cont.resume(returning: (try? data.write(to: url, options: .atomic)) != nil)
            }
        }
        if ok && !survey.hasWorldMap {
            survey.hasWorldMap = true
            save()
        }
    }

    // MARK: Tracking

    private func tick() {
        guard let frame = session.currentFrame else { return }
        let cam = frame.camera
        switch cam.trackingState {
        case .normal:
            trackingOK = true; trackingText = "Tracking"
        case .notAvailable:
            trackingOK = false; trackingText = "Position tracking not available"
        case .limited(let reason):
            trackingOK = false
            switch reason {
            case .initializing: trackingText = "Starting… move the phone slowly"
            case .relocalizing: trackingText = "Finding your position… walk around the scanned area, camera forward"
            case .excessiveMotion: trackingText = "Moving too fast"
            case .insufficientFeatures: trackingText = "Too little detail — point the camera at the room"
            @unknown default: trackingText = "Tracking limited"
            }
        @unknown default:
            trackingOK = false; trackingText = "Tracking limited"
        }
        guard trackingOK else { return }

        let t = cam.transform
        lastWorld = Vec2(x: Double(t.columns.3.x), y: Double(t.columns.3.z))
        if needsAlignment { livePos = nil; return }
        let p = survey.toPlan(worldX: Double(t.columns.3.x), z: Double(t.columns.3.z))
        let f = Vec2(x: -Double(t.columns.2.x), y: -Double(t.columns.2.z)).rotated(by: survey.rotation)
        if f.length > 0.1 { heading = atan2(f.y, f.x) }
        livePos = p

        if survey.start == nil { survey.start = p; startSetThisSession = true }
        if survey.trail.last.map({ $0.distance(to: p) >= 0.3 }) ?? true {
            survey.trail.append(p)
            if survey.trail.count > 6000 {
                survey.trail.removeFirst(1000)
                trailStart = max(0, trailStart - 1000)
            }
        }

        let now = CACurrentMediaTime()
        history.append((now, p))
        history.removeAll { now - $0.t > 1.5 }

        guard autoMode, !busy else { autoHint = nil; return }
        let spacing = TestSettings.spacing
        let nearest = survey.points.map { $0.pos.distance(to: p) }.min() ?? .infinity
        if nearest >= spacing {
            let recent = history.filter { now - $0.t <= 0.8 }
            let still = recent.count >= 6 && recent.allSatisfy { $0.p.distance(to: p) < 0.2 }
            if still { measure() } else { autoHint = "New spot — stop for a moment to measure" }
        } else {
            autoHint = String(format: "Keep walking — next spot in %.1f m", spacing - nearest)
        }
    }

    // MARK: Actions

    func measure(at manual: Vec2? = nil) {
        guard !busy, let pos = manual ?? livePos else { return }
        busy = true
        autoHint = nil
        lastResult = nil
        progressText = "Starting…"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let secs = TestSettings.seconds
        Task {
            var m = await tester.run(seconds: secs) { [weak self] text in
                Task { @MainActor in self?.progressText = text }
            }
            m.pos = pos
            survey.points.append(m)
            lastResult = m
            busy = false
            progressText = nil
            save()
            rebuildHeat()
            UINotificationFeedbackGenerator().notificationOccurred(m.failed ? .error : .success)
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if lastResult?.id == m.id { lastResult = nil }
        }
    }

    /// "I'm here": shift this session's coordinates so the live position matches the tapped spot.
    func align(to target: Vec2) {
        guard let cur = livePos else { return }
        let d = target - cur
        survey.offset = survey.offset + d
        for i in survey.points.indices where survey.points[i].date >= sessionStart {
            survey.points[i].pos = survey.points[i].pos + d
        }
        if trailStart < survey.trail.count {
            for i in trailStart..<survey.trail.count { survey.trail[i] = survey.trail[i] + d }
        }
        if startSetThisSession, let s = survey.start { survey.start = s + d }
        history.removeAll()
        livePos = target
        save()
        rebuildHeat()
    }

    /// 2-point alignment for floor plan images: tap where you stand, walk, tap again.
    /// Works out rotation, position and the image's scale.
    func alignTap(_ p: Vec2) {
        guard trackingOK, let w = lastWorld else {
            alignMessage = "Wait until tracking is ready, then tap again."
            return
        }
        guard let first = alignFirst else {
            alignFirst = AlignPoint(world: w, plan: p)
            alignMessage = nil
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        let dw = w - first.world, dp = p - first.plan
        guard dw.length >= 1.5 else {
            alignMessage = String(format: "You've only moved %.1f m. Walk at least 3 m from the first spot, then tap.", dw.length)
            return
        }
        guard dp.length > 1e-6 else { alignMessage = "Tap a different spot from the first one."; return }

        // Rescale the plan so the tapped distance matches the distance actually walked.
        let k = dw.length / dp.length
        survey.metersPerPixel = (survey.metersPerPixel ?? 0.01) * k
        for i in survey.points.indices { survey.points[i].pos = survey.points[i].pos * k }
        for i in survey.trail.indices { survey.trail[i] = survey.trail[i] * k }
        if let s = survey.start { survey.start = s * k }
        let p1 = first.plan * k, p2 = p * k

        let rot = atan2(p2.y - p1.y, p2.x - p1.x) - atan2(dw.y, dw.x)
        survey.rotation = rot
        survey.offset = p1 - first.world.rotated(by: rot)
        survey.needsAlignment = false
        alignFirst = nil
        alignMessage = nil
        history.removeAll()
        save()
        rebuildHeat()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func restartAlignment() {
        survey.needsAlignment = true
        alignFirst = nil
        alignMessage = nil
        livePos = nil
        save()
    }

    func delete(_ m: Sample) {
        survey.points.removeAll { $0.id == m.id }
        save()
        rebuildHeat()
    }

    func clearPoints() {
        survey.points.removeAll()
        save()
        rebuildHeat()
    }

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        survey.name = n
        save()
    }

    func rebuildHeat() {
        let pts = survey.points.map { ($0.pos, thresholds.norm(metric, metric.value($0))) }
        heat = HeatMap.make(points: pts, bounds: survey.bounds())
    }
}

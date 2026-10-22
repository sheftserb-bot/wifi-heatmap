import ARKit
import SceneKit
import SwiftUI

struct SurveyScreen: View {
    @ObservedObject var model: SurveyModel
    let close: () -> Void

    @AppStorage(K.showLabels) var showLabels = true
    @AppStorage(K.showHeat) var showHeat = true
    @AppStorage(K.downBad) var downBad = 10.0
    @AppStorage(K.downGood) var downGood = 300.0
    @AppStorage(K.upBad) var upBad = 5.0
    @AppStorage(K.upGood) var upGood = 100.0
    @AppStorage(K.pingBad) var pingBad = 60.0
    @AppStorage(K.pingGood) var pingGood = 5.0

    @State var selected: Sample?
    @State var aligning = false
    @State var manual = false
    @State var showSettings = false
    @State var share: ShareItem?
    @State var renaming = false
    @State var newName = ""
    @State var confirmClear = false
    @State var closing = false

    private var thresholds: Thresholds {
        Thresholds(downBad: downBad, downGood: downGood, upBad: upBad, upGood: upGood, pingBad: pingBad, pingGood: pingGood)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .topTrailing) {
                PlanCanvas(survey: model.survey, metric: model.metric, thresholds: thresholds,
                           heat: showHeat ? model.heat : nil, live: model.livePos, heading: model.heading,
                           selected: selected?.id, showLabels: showLabels, interactive: true,
                           planImage: model.planImage, alignMark: model.alignFirst?.plan) { p, scale in
                    handleTap(p, scale)
                }
                ARPreview(session: model.session)
                    .frame(width: 90, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.8), lineWidth: 1))
                    .shadow(radius: 3)
                    .padding(10)
                    .allowsHitTesting(false)
                if !model.survey.points.isEmpty {
                    LegendView(metric: model.metric, thresholds: thresholds)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                }
            }
            bottomPanel
        }
        .onAppear {
            model.thresholds = thresholds
            model.start()
        }
        .onChange(of: thresholds) { model.thresholds = thresholds }
        .sheet(item: $selected) { m in
            PointDetail(m: m, distanceFromStart: model.survey.start.map { m.pos.distance(to: $0) }) {
                model.delete(m)
                selected = nil
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $share) { item in ShareSheet(items: [item.url]) }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .alert("Rename survey", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Save") { model.rename(newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete all points?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all points", role: .destructive) { model.clearPoints() }
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                guard !closing else { return }
                closing = true
                Task { await model.finish(); close() }
            } label: {
                Image(systemName: "chevron.left").font(.title3.bold())
            }
            Text(model.survey.name).font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            Picker("Metric", selection: $model.metric) {
                ForEach(Metric.allCases) { Text($0.short).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            Menu {
                Button { exportImage() } label: { Label("Share heat map image", systemImage: "photo") }
                Button { exportJSON() } label: { Label("Export survey (JSON)", systemImage: "doc") }
                Button { exportCSV() } label: { Label("Export points (CSV)", systemImage: "tablecells") }
                Divider()
                Toggle(isOn: $manual) { Label("Measure by tapping the plan", systemImage: "hand.tap") }
                Toggle(isOn: $showHeat) { Label("Show heat map", systemImage: "square.3.layers.3d") }
                Toggle(isOn: $showLabels) { Label("Show values", systemImage: "textformat.123") }
                Divider()
                Button { newName = model.survey.name; renaming = true } label: { Label("Rename", systemImage: "pencil") }
                if model.survey.planImageFile != nil {
                    Button { model.restartAlignment() } label: { Label("Re-align plan", systemImage: "arrow.triangle.2.circlepath") }
                }
                Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                Button(role: .destructive) { confirmClear = true } label: { Label("Delete all points", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: Bottom panel

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusView
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            HStack(spacing: 10) {
                Button { model.autoMode.toggle() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: model.autoMode ? "figure.walk.circle.fill" : "figure.walk.circle").font(.title3)
                        Text("Auto").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(model.autoMode ? .green : .gray)

                Button { model.measure() } label: {
                    Text(model.busy ? "Testing…" : "Measure here")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || !model.trackingOK || model.needsAlignment)
                .layoutPriority(1)

                Button { aligning.toggle() } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "scope").font(.title3)
                        Text("I'm here").font(.caption2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(aligning ? .orange : .gray)
                .disabled(!model.trackingOK || model.needsAlignment)
            }
        }
        .padding(12)
        .background(.bar)
    }

    @ViewBuilder private var statusView: some View {
        if model.needsAlignment {
            VStack(alignment: .leading, spacing: 3) {
                if model.alignFirst == nil {
                    Text("Align step 1 of 2").font(.headline)
                    Text("Stand in a spot you can find on the plan (a doorway or room corner) and tap it.")
                } else {
                    Text("Align step 2 of 2").font(.headline)
                    Text("Walk to another spot at least 3–4 m away, as far as possible, and tap it.")
                }
                if let m = model.alignMessage { Text(m).font(.caption).foregroundColor(.orange) }
                if !model.trackingOK { Text(model.trackingText).font(.caption).foregroundColor(.secondary) }
            }
        } else if let p = model.progressText {
            VStack(alignment: .leading, spacing: 2) {
                Text(p).font(.title3.bold())
                Text("Hold still").font(.caption).foregroundColor(.secondary)
            }
        } else if aligning {
            Text("Tap the spot on the plan where you are standing now.").foregroundColor(.orange)
        } else if !model.trackingOK {
            VStack(alignment: .leading, spacing: 2) {
                Label(model.trackingText, systemImage: "location.slash").foregroundColor(.orange)
                if manual { Text("Tap the plan to measure at that spot.").font(.caption).foregroundColor(.secondary) }
            }
        } else if let r = model.lastResult {
            if r.failed {
                Text("✕ No connection here — saved as a dead spot").font(.headline).foregroundColor(.red)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("↓ \(fmt(r.down))  ↑ \(fmt(r.up)) Mbps · \(fmt(r.ping)) ms").font(.title3.bold())
                    Text(r.server == "local" ? "Local server" : "Cloudflare").font(.caption).foregroundColor(.secondary)
                }
            }
        } else if model.autoMode, let h = model.autoHint {
            Text(h)
        } else {
            summary
        }
    }

    @ViewBuilder private var summary: some View {
        let ok = model.survey.points.filter { !$0.failed }
        if model.survey.points.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stand still and tap Measure here, or turn on Auto and walk.")
                Text("Aim for a point every 3–5 m and in every room.").font(.caption).foregroundColor(.secondary)
            }
        } else {
            let dead = model.survey.points.count - ok.count
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.survey.points.count) points · median ↓ \(fmt(median(ok.compactMap { $0.down }))) ↑ \(fmt(median(ok.compactMap { $0.up }))) Mbps · \(fmt(median(ok.compactMap { $0.ping }))) ms")
                    .font(.subheadline)
                if dead > 0 {
                    Text("\(dead) dead spot\(dead == 1 ? "" : "s")").font(.caption).foregroundColor(.red)
                }
            }
        }
    }

    // MARK: Actions

    private func handleTap(_ p: Vec2, _ scale: CGFloat) {
        if model.needsAlignment {
            model.alignTap(p)
            return
        }
        if aligning {
            model.align(to: p)
            aligning = false
            return
        }
        if let hit = model.survey.points.min(by: { $0.pos.distance(to: p) < $1.pos.distance(to: p) }),
           hit.pos.distance(to: p) * Double(scale) < 22 {
            selected = hit
            return
        }
        if manual { model.measure(at: p) }
    }

    private var fileBase: String {
        let s = model.survey.name.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        return s.isEmpty ? "survey" : s
    }

    private func exportImage() {
        let b = model.survey.bounds()
        let width: CGFloat = 1200
        let planH = min(2000, max(600, width * b.height / b.width))
        let view = ExportView(survey: model.survey, metric: model.metric, thresholds: thresholds,
                              heat: model.heat, showLabels: showLabels, planImage: model.planImage)
            .frame(width: width, height: planH + 110)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileBase)-\(model.metric.rawValue).png")
        try? data.write(to: url)
        share = ShareItem(url: url)
    }

    private func exportJSON() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(model.survey) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileBase).json")
        try? data.write(to: url)
        share = ShareItem(url: url)
    }

    private func exportCSV() {
        var lines = ["n,x_m,y_m,download_mbps,upload_mbps,ping_ms,jitter_ms,dead_spot,time,server"]
        let iso = ISO8601DateFormatter()
        func f(_ v: Double?, _ d: Int = 2) -> String { v.map { String(format: "%.\(d)f", $0) } ?? "" }
        for (i, p) in model.survey.points.enumerated() {
            lines.append([String(i + 1), f(p.pos.x), f(p.pos.y), f(p.down), f(p.up), f(p.ping, 1), f(p.jitter, 1),
                          p.failed ? "1" : "0", iso.string(from: p.date), p.server].joined(separator: ","))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(fileBase).csv")
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        share = ShareItem(url: url)
    }
}

func median(_ a: [Double]) -> Double? {
    guard !a.isEmpty else { return nil }
    let s = a.sorted(), m = s.count / 2
    return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
}

// MARK: - Supporting views

struct PointDetail: View {
    let m: Sample
    let distanceFromStart: Double?
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if m.failed { LabeledContent("Status", value: "No connection (dead spot)") }
                LabeledContent("Download", value: "\(fmt(m.down)) Mbps")
                LabeledContent("Upload", value: "\(fmt(m.up)) Mbps")
                LabeledContent("Ping", value: "\(fmt(m.ping)) ms")
                LabeledContent("Jitter", value: "\(fmt(m.jitter)) ms")
                if let d = distanceFromStart { LabeledContent("From start", value: String(format: "%.1f m", d)) }
                LabeledContent("Tested", value: m.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Server", value: m.server == "local" ? "Local server" : "Cloudflare")
                if let e = m.error { LabeledContent("Note", value: e) }
                Button("Delete point", role: .destructive, action: onDelete)
            }
            .navigationTitle("Measurement")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct ExportView: View {
    let survey: Survey
    let metric: Metric
    let thresholds: Thresholds
    let heat: HeatLayer?
    let showLabels: Bool
    var planImage: UIImage?

    var body: some View {
        let ok = survey.points.filter { !$0.failed }
        VStack(spacing: 0) {
            PlanCanvas(survey: survey, metric: metric, thresholds: thresholds, heat: heat,
                       showLabels: showLabels, interactive: false, planImage: planImage)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(survey.name) — \(metric.title)").font(.system(size: 26, weight: .bold))
                    Text("\(survey.points.count) points · median ↓ \(fmt(median(ok.compactMap { $0.down }))) / ↑ \(fmt(median(ok.compactMap { $0.up }))) Mbps · ping \(fmt(median(ok.compactMap { $0.ping }))) ms · \(Date().formatted(date: .abbreviated, time: .omitted))")
                        .font(.system(size: 17)).foregroundColor(.secondary)
                }
                Spacer()
                LegendView(metric: metric, thresholds: thresholds).scaleEffect(1.5).frame(width: 230)
            }
            .padding(.horizontal, 24)
            .frame(height: 110)
            .background(Color.white)
        }
        .background(Color.white)
    }
}

struct ShareItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

/// Small live camera preview so you can see what ARKit sees.
struct ARPreview: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView(frame: .zero)
        v.session = session
        v.scene = SCNScene()
        v.automaticallyUpdatesLighting = false
        v.rendersCameraGrain = false
        return v
    }
    func updateUIView(_ v: ARSCNView, context: Context) {}
}

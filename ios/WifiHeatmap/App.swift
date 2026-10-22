import RoomPlan
import SwiftUI

@main
struct WifiHeatmapApp: App {
    @StateObject var store = SurveyStore()

    var body: some Scene {
        WindowGroup {
            HomeView().environmentObject(store)
        }
    }
}

enum Flow: Identifiable {
    case scan
    case blank
    case open(Survey)

    var id: String {
        switch self {
        case .scan: return "scan"
        case .blank: return "blank"
        case .open(let s): return s.id.uuidString
        }
    }
}

struct HomeView: View {
    @EnvironmentObject var store: SurveyStore
    @State var flow: Flow?
    @State var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if RoomCaptureSession.isSupported {
                        Button { flow = .scan } label: {
                            Label("Scan a space with LiDAR", systemImage: "camera.metering.matrix")
                        }
                    } else {
                        Text("This iPhone has no LiDAR scanner. You can still survey without a floor plan.")
                            .font(.footnote).foregroundColor(.secondary)
                    }
                    Button { flow = .blank } label: {
                        Label("Survey without a scan", systemImage: "figure.walk")
                    }
                } footer: {
                    Text("Scan first, then walk around: your position is tracked on the plan and each spot gets a speed test.")
                }

                Section("Surveys") {
                    if store.surveys.isEmpty {
                        Text("No surveys yet").foregroundColor(.secondary)
                    }
                    ForEach(store.surveys) { s in
                        Button { flow = .open(s) } label: { SurveyRow(survey: s) }
                            .foregroundColor(.primary)
                    }
                    .onDelete { idx in
                        idx.map { store.surveys[$0] }.forEach(store.delete)
                    }
                }
            }
            .navigationTitle("WiFi Heatmap")
            .toolbar {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $flow) { f in
                FlowView(flow: f) { flow = nil }
                    .environmentObject(store)
            }
        }
    }
}

struct SurveyRow: View {
    let survey: Survey
    var body: some View {
        let ok = survey.points.filter { !$0.failed }
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(survey.name).font(.headline)
                if survey.plan != nil { Image(systemName: "square.split.bottomrightquarter").foregroundColor(.secondary) }
            }
            Text("\(survey.points.count) points · median ↓ \(fmt(median(ok.compactMap { $0.down }))) Mbps · \(survey.created.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundColor(.secondary)
        }
    }
}

/// Scan → survey, or straight into a survey.
struct FlowView: View {
    let flow: Flow
    let close: () -> Void
    @EnvironmentObject var store: SurveyStore
    @State var model: SurveyModel?

    var body: some View {
        Group {
            if let model {
                SurveyScreen(model: model, close: close)
            } else {
                switch flow {
                case .scan:
                    ScanScreen(onCancel: close) { room, session, keepAlive in
                        let built = PlanBuilder.build(from: room)
                        var s = Survey(name: defaultName())
                        s.plan = built.plan
                        s.rotation = built.rotation
                        store.save(s)
                        model = SurveyModel(survey: s, store: store, session: session, keepAlive: keepAlive, configuration: nil)
                    }
                case .blank:
                    Color(.systemBackground).onAppear {
                        let s = Survey(name: defaultName())
                        store.save(s)
                        model = SurveyModel.open(s, store: store)
                    }
                case .open(let s):
                    Color(.systemBackground).onAppear {
                        model = SurveyModel.open(s, store: store)
                    }
                }
            }
        }
    }

    private func defaultName() -> String {
        "Survey " + Date().formatted(date: .abbreviated, time: .shortened)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    @AppStorage(K.server) var server = "auto"
    @AppStorage(K.localURL) var localURL = ""
    @AppStorage(K.secs) var secs = 3.0
    @AppStorage(K.spacing) var spacing = 3.0
    @AppStorage(K.downBad) var downBad = 10.0
    @AppStorage(K.downGood) var downGood = 300.0
    @AppStorage(K.upBad) var upBad = 5.0
    @AppStorage(K.upGood) var upGood = 100.0
    @AppStorage(K.pingBad) var pingBad = 60.0
    @AppStorage(K.pingGood) var pingGood = 5.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Test server", selection: $server) {
                        Text("Auto").tag("auto")
                        Text("Local server").tag("local")
                        Text("Internet (Cloudflare)").tag("cloudflare")
                    }
                    TextField("Local server, e.g. 192.168.1.20:8080", text: $localURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Speed test")
                } footer: {
                    Text("Local measures pure Wi-Fi speed to a computer running server.py, wired to the router. Auto uses it when it answers, otherwise Cloudflare (then results also depend on your internet plan).")
                }

                Section("Measuring") {
                    Picker("Seconds per test", selection: $secs) {
                        Text("2 s").tag(2.0)
                        Text("3 s").tag(3.0)
                        Text("5 s").tag(5.0)
                    }
                    Stepper(value: $spacing, in: 1...10, step: 0.5) {
                        Text("Auto spacing: \(spacing, specifier: "%.1f") m")
                    }
                }

                Section {
                    row("Download Mbps", $downBad, $downGood)
                    row("Upload Mbps", $upBad, $upGood)
                    row("Ping ms", $pingBad, $pingGood)
                } header: {
                    Text("Colour scale")
                } footer: {
                    Text("Left = red (bad), right = green (good).")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func row(_ title: String, _ bad: Binding<Double>, _ good: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField("bad", value: bad, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 64)
                .foregroundColor(.red)
            Text("→").foregroundColor(.secondary)
            TextField("good", value: good, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 64)
                .foregroundColor(.green)
        }
    }
}

import ARKit
import RoomPlan
import SwiftUI
import UIKit

/// Hosts Apple's RoomCaptureView (LiDAR room scanning).
final class RoomScanController: UIViewController, RoomCaptureViewDelegate {
    private(set) var captureView: RoomCaptureView!
    var onResult: ((CapturedRoom) -> Void)?
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        view.addSubview(captureView)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Stop scanning but keep the AR session running, so the survey continues
    /// in exactly the same coordinate system as the scanned floor plan.
    func finishScan() { captureView.captureSession.stop(pauseARSession: false) }
    func cancelScan() { captureView.captureSession.stop() }

    var arSession: ARSession { captureView.captureSession.arSession }

    // RoomCaptureViewDelegate
    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool { true }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        onResult?(processedResult)
    }
}

struct RoomScanRepresentable: UIViewControllerRepresentable {
    let controller: RoomScanController
    func makeUIViewController(context: Context) -> RoomScanController { controller }
    func updateUIViewController(_ vc: RoomScanController, context: Context) {}
}

struct ScanScreen: View {
    let onCancel: () -> Void
    let onDone: (CapturedRoom, ARSession, AnyObject) -> Void

    @State var controller = RoomScanController()
    @State var processing = false

    var body: some View {
        ZStack {
            RoomScanRepresentable(controller: controller).ignoresSafeArea()
            VStack {
                HStack {
                    Button("Cancel") {
                        controller.cancelScan()
                        onCancel()
                    }
                    .buttonStyle(.borderedProminent).tint(.black.opacity(0.6))
                    Spacer()
                }
                .padding()
                Spacer()
                Text("Walk slowly through every room. Point the camera at walls, doors and windows.")
                    .font(.footnote).multilineTextAlignment(.center)
                    .padding(10).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal)
                Button {
                    processing = true
                    controller.finishScan()
                } label: {
                    Text(processing ? "Building floor plan…" : "Done scanning — start survey")
                        .bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(processing)
                .padding()
            }
        }
        .onAppear {
            let c = controller
            c.onResult = { room in
                onDone(room, c.arSession, c)
            }
        }
    }
}

/// Converts RoomPlan walls/doors/windows into a 2D plan (top view, metres).
enum PlanBuilder {
    static func build(from room: CapturedRoom) -> (plan: FloorPlan, rotation: Double) {
        func segment(_ s: CapturedRoom.Surface) -> (Vec2, Vec2) {
            let t = s.transform
            let c = Vec2(x: Double(t.columns.3.x), y: Double(t.columns.3.z))
            var d = Vec2(x: Double(t.columns.0.x), y: Double(t.columns.0.z))
            let len = d.length
            d = len > 1e-6 ? d * (1 / len) : Vec2(x: 1, y: 0)
            let half = Double(s.dimensions.x) / 2
            return (c - d * half, c + d * half)
        }

        let walls = room.walls.map(segment)

        // Rotate so the main walls are horizontal/vertical on screen.
        var sx = 0.0, sy = 0.0
        for (a, b) in walls {
            let v = b - a
            let ang = atan2(v.y, v.x), w = v.length
            sx += w * cos(4 * ang); sy += w * sin(4 * ang)
        }
        let rotation = (sx == 0 && sy == 0) ? 0 : -atan2(sy, sx) / 4
        func r(_ p: Vec2) -> Vec2 { p.rotated(by: rotation) }

        var plan = FloorPlan()
        plan.walls = walls.map { PlanSegment(a: r($0.0), b: r($0.1)) }
        func add(_ list: [CapturedRoom.Surface], _ kind: OpeningKind) {
            for s in list {
                let (a, b) = segment(s)
                plan.openings.append(PlanOpening(a: r(a), b: r(b), kind: kind))
            }
        }
        add(room.doors, .door)
        add(room.openings, .opening)
        add(room.windows, .window)
        return (plan, rotation)
    }
}

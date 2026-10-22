import Foundation

/// Saves each survey as JSON (plus its AR world map) in the app's Documents folder.
@MainActor
final class SurveyStore: ObservableObject {
    @Published private(set) var surveys: [Survey] = []
    let dir: URL

    init() {
        dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Surveys", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder()
        surveys = files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(Survey.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    func jsonURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).json") }
    func worldMapURL(_ id: UUID) -> URL { dir.appendingPathComponent("\(id.uuidString).worldmap") }

    func imageURL(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func saveImage(_ data: Data, for id: UUID) -> String? {
        let name = "\(id.uuidString).jpg"
        do { try data.write(to: imageURL(name), options: .atomic); return name } catch { return nil }
    }

    func save(_ s: Survey) {
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: jsonURL(s.id), options: .atomic)
        }
        if let i = surveys.firstIndex(where: { $0.id == s.id }) { surveys[i] = s }
        else { surveys.insert(s, at: 0) }
    }

    func delete(_ s: Survey) {
        try? FileManager.default.removeItem(at: jsonURL(s.id))
        try? FileManager.default.removeItem(at: worldMapURL(s.id))
        if let f = s.planImageFile { try? FileManager.default.removeItem(at: imageURL(f)) }
        surveys.removeAll { $0.id == s.id }
    }
}

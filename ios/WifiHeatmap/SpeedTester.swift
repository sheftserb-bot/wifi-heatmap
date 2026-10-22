import Foundation

struct TestEndpoints {
    let mode: String          // "local" or "cloudflare"
    let pingURL: String
    let downPrefix: String    // byte count is appended
    let upURL: String

    func ping() -> URL { bust(pingURL) }
    func down(_ bytes: Int) -> URL { bust(downPrefix + String(bytes)) }
    func up() -> URL { bust(upURL) }

    private func bust(_ s: String) -> URL {
        let r = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        return URL(string: s + (s.contains("?") ? "&" : "?") + "r=" + r)!
    }

    static let cloudflare = TestEndpoints(
        mode: "cloudflare",
        pingURL: "https://speed.cloudflare.com/__down?bytes=0",
        downPrefix: "https://speed.cloudflare.com/__down?bytes=",
        upURL: "https://speed.cloudflare.com/__up")

    /// Accepts "192.168.1.20:8080", "http://192.168.1.20:8080/" etc.
    static func local(_ raw: String) -> TestEndpoints? {
        var b = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if b.isEmpty { return nil }
        if !b.lowercased().hasPrefix("http") { b = "http://" + b }
        while b.hasSuffix("/") { b.removeLast() }
        guard URL(string: b) != nil else { return nil }
        return TestEndpoints(mode: "local", pingURL: b + "/ping", downPrefix: b + "/down?bytes=", upURL: b + "/up")
    }
}

enum SpeedTestError: LocalizedError {
    case noData
    case badStatus(Int)
    var errorDescription: String? {
        switch self {
        case .noData: return "No data received"
        case .badStatus(let c): return "Server answered \(c)"
        }
    }
}

/// Ping, download and upload test against the local server (server.py) or Cloudflare.
final class SpeedTester {

    static func config(timeout: TimeInterval = 6) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.urlCache = nil
        c.timeoutIntervalForRequest = timeout
        c.httpMaximumConnectionsPerHost = 8
        c.waitsForConnectivity = false
        return c
    }

    static let payload: Data = Data((0..<(1 << 20)).map { _ in UInt8.random(in: .min ... .max) })

    static func check(_ r: URLResponse) throws {
        if let h = r as? HTTPURLResponse, h.statusCode >= 400 { throw SpeedTestError.badStatus(h.statusCode) }
    }

    func endpoints() async -> TestEndpoints {
        let mode = TestSettings.serverMode
        if mode != "cloudflare", let local = TestEndpoints.local(TestSettings.localURL) {
            if mode == "local" { return local }
            if await reachable(local) { return local }
        }
        return .cloudflare
    }

    private func reachable(_ ep: TestEndpoints) async -> Bool {
        let s = URLSession(configuration: Self.config(timeout: 1.5))
        defer { s.finishTasksAndInvalidate() }
        do {
            let (_, r) = try await s.data(from: ep.ping())
            return (r as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    func run(seconds: Double, progress: @escaping (String) -> Void) async -> Sample {
        var m = Sample(pos: .zero)
        let ep = await endpoints()
        m.server = ep.mode
        do {
            progress("Ping…")
            let (p, j) = try await latency(ep)
            m.ping = p; m.jitter = j
            m.down = try await download(ep, seconds: seconds) { v in progress(String(format: "↓ %.0f Mbps…", v)) }
            m.up = try await upload(ep, seconds: seconds) { v in progress(String(format: "↑ %.0f Mbps…", v)) }
        } catch {
            if m.ping == nil { m.failed = true }     // could not reach the server at all: dead spot
            m.error = error.localizedDescription
        }
        return m
    }

    // MARK: Ping

    private func latency(_ ep: TestEndpoints) async throws -> (Double, Double) {
        let s = URLSession(configuration: Self.config(timeout: 3))
        defer { s.finishTasksAndInvalidate() }
        var times: [Double] = []
        for _ in 0..<9 {
            let t0 = CFAbsoluteTimeGetCurrent()
            let (_, r) = try await s.data(from: ep.ping())
            try Self.check(r)
            times.append((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        }
        times.removeFirst()                            // first request also opens the connection
        let sorted = times.sorted()
        var jitter = 0.0
        for i in 1..<times.count { jitter += abs(times[i] - times[i - 1]) }
        return (sorted[sorted.count / 2], jitter / Double(times.count - 1))
    }

    // MARK: Download

    private final class ByteCounter: NSObject, URLSessionDataDelegate {
        private let lock = NSLock()
        private var count = 0
        private var errors = 0
        let deadline: CFAbsoluteTime
        var restart: (() -> Void)?

        init(deadline: CFAbsoluteTime) { self.deadline = deadline }

        var bytes: Int { lock.lock(); defer { lock.unlock() }; return count }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock(); count += data.count; lock.unlock()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard CFAbsoluteTimeGetCurrent() < deadline else { return }
            if error != nil {
                lock.lock(); errors += 1; let e = errors; lock.unlock()
                if e > 6 { return }
            }
            restart?()
        }
    }

    private func download(_ ep: TestEndpoints, seconds: Double, progress: @escaping (Double) -> Void) async throws -> Double {
        let start = CFAbsoluteTimeGetCurrent(), end = start + seconds
        let counter = ByteCounter(deadline: end)
        let s = URLSession(configuration: Self.config(), delegate: counter, delegateQueue: nil)
        counter.restart = { [weak s] in s?.dataTask(with: ep.down(25_000_000)).resume() }
        for _ in 0..<3 { s.dataTask(with: ep.down(25_000_000)).resume() }
        while CFAbsoluteTimeGetCurrent() < end {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let el = CFAbsoluteTimeGetCurrent() - start
            progress(Double(counter.bytes) * 8 / el / 1e6)
        }
        let el = CFAbsoluteTimeGetCurrent() - start
        let bytes = counter.bytes
        counter.restart = nil
        s.invalidateAndCancel()
        guard bytes > 0 else { throw SpeedTestError.noData }
        return Double(bytes) * 8 / el / 1e6
    }

    // MARK: Upload

    private final class UpBox: @unchecked Sendable {
        private let lock = NSLock()
        private var bytes = 0
        private var last: CFAbsoluteTime
        init(_ t: CFAbsoluteTime) { last = t }
        func add(_ n: Int) -> (Int, CFAbsoluteTime) {
            lock.lock(); defer { lock.unlock() }
            bytes += n; last = CFAbsoluteTimeGetCurrent()
            return (bytes, last)
        }
        var snapshot: (Int, CFAbsoluteTime) { lock.lock(); defer { lock.unlock() }; return (bytes, last) }
    }

    private func upload(_ ep: TestEndpoints, seconds: Double, progress: @escaping (Double) -> Void) async throws -> Double {
        let start = CFAbsoluteTimeGetCurrent(), end = start + seconds
        let s = URLSession(configuration: Self.config(timeout: 10))
        defer { s.invalidateAndCancel() }
        let payload = Self.payload
        let box = UpBox(start)

        let errors = await withTaskGroup(of: Error?.self, returning: [Error].self) { group in
            for _ in 0..<3 {
                group.addTask {
                    do {
                        while CFAbsoluteTimeGetCurrent() < end {
                            var req = URLRequest(url: ep.up())
                            req.httpMethod = "POST"
                            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                            let (_, r) = try await s.upload(for: req, from: payload)
                            try SpeedTester.check(r)
                            let (b, t) = box.add(payload.count)
                            progress(Double(b) * 8 / max(t - start, 0.001) / 1e6)
                        }
                        return nil
                    } catch {
                        return error
                    }
                }
            }
            var out: [Error] = []
            for await e in group { if let e { out.append(e) } }
            return out
        }

        let (bytes, last) = box.snapshot
        guard bytes > 0 else { throw errors.first ?? SpeedTestError.noData }
        return Double(bytes) * 8 / max(last - start, 0.001) / 1e6
    }
}

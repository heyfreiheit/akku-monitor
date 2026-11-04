import Foundation
import Network

// MARK: - Datenmodell

struct ChromeTab: Codable, Identifiable, Hashable {
    let id: Int
    let windowId: Int
    let title: String
    let url: String
    let active: Bool
    let audible: Bool
    let discarded: Bool
    let pinned: Bool

    var host: String {
        guard let h = URL(string: url)?.host else { return url.hasPrefix("chrome") ? "Chrome-Seiten" : "Sonstige" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }
    var measurable: Bool { !discarded && (url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("file://")) }
}

struct TabPower: Identifiable {
    var id: Int { tab.id }
    let tab: ChromeTab
    let watts: Double
    let sharedWith: Int   // Anzahl Tabs im selben Prozess
}

/// Chromes Prozessor-Energie, aufgeteilt nach Herkunft.
struct ChromeBreakdown {
    var tabs: Double = 0
    var unassigned: Double = 0   // Erweiterungen, eingebettete Inhalte, noch nicht zugeordnete Tabs
    var gpu: Double = 0
    var browser: Double = 0      // Hauptprozess und Dienste (Netzwerk, Audio, Speicher)
    var total: Double { tabs + unassigned + gpu + browser }
}

// MARK: - Zuordnung Tab → Prozess

/// Hält die Tabs, die die Chrome-Erweiterung meldet, und findet per kurzer Rechenlast heraus,
/// welcher Renderer-Prozess zu welchem Tab gehört.
@MainActor
final class ChromeTabs {
    private(set) var tabs: [Int: ChromeTab] = [:]
    private(set) var pidOf: [Int: pid_t] = [:]
    private(set) var lastContact: Date?
    private var hostAtCalibration: [Int: String] = [:]
    private var failedAt: [Int: Date] = [:]
    private var snapshot: (tabId: Int, energy: [pid_t: UInt64])?
    private let processes: ProcessEnergySampler

    init(processes: ProcessEnergySampler) { self.processes = processes }

    var connected: Bool { lastContact.map { Date().timeIntervalSince($0) < 90 } ?? false }
    var mappedCount: Int { tabs.keys.filter { pidOf[$0] != nil }.count }

    /// Neue Tab-Liste. Gibt die Tabs zurück, die (neu) zugeordnet werden müssen.
    func update(_ list: [ChromeTab]) -> [Int] {
        lastContact = Date()
        tabs = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        for id in pidOf.keys where tabs[id] == nil { pidOf[id] = nil; hostAtCalibration[id] = nil }
        for id in failedAt.keys where tabs[id] == nil { failedAt[id] = nil }

        var need: [Int] = []
        for t in list where t.measurable {
            if let f = failedAt[t.id], Date().timeIntervalSince(f) < 300, hostAtCalibration[t.id] == t.host { continue }
            if let p = pidOf[t.id], ProcessEnergySampler.energy(p) != nil, hostAtCalibration[t.id] == t.host { continue }
            need.append(t.id)
        }
        // Aktive Tabs zuletzt, damit die kurze Rechenlast möglichst nicht dort spürbar ist.
        need.sort { (tabs[$0]?.active == true ? 1 : 0) < (tabs[$1]?.active == true ? 1 : 0) }
        return Array(need.prefix(8))
    }

    private func rendererEnergies() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        for p in ProcessEnergySampler.allPids() where processes.chromeKind(of: p) == .renderer {
            if let e = ProcessEnergySampler.energy(p) { out[p] = e }
        }
        return out
    }

    func calibrationStart(tabId: Int) {
        snapshot = (tabId, rendererEnergies())
    }

    /// Wertet die Rechenlast aus: Der Prozess mit dem klar größten Energiesprung gehört zum Tab.
    func calibrationEnd(tabId: Int, failed: Bool) -> pid_t? {
        defer { snapshot = nil }
        guard !failed, let snap = snapshot, snap.tabId == tabId else { failedAt[tabId] = Date(); return nil }
        let after = rendererEnergies()
        var deltas: [(pid_t, Double)] = []
        for (p, e) in after {
            guard let b = snap.energy[p], e >= b else { continue }
            deltas.append((p, Double(e - b) / 1e9))
        }
        deltas.sort { $0.1 > $1.1 }
        guard let top = deltas.first, top.1 >= 0.015 else { failedAt[tabId] = Date(); return nil }
        let second = deltas.count > 1 ? deltas[1].1 : 0
        guard top.1 >= second * 2.5 else { failedAt[tabId] = Date(); return nil }
        pidOf[tabId] = top.0
        hostAtCalibration[tabId] = tabs[tabId]?.host
        failedAt[tabId] = nil
        return top.0
    }

    /// Verteilt die gemessene Energie der Chrome-Prozesse auf Tabs und Restposten.
    func attribute(_ chrome: [pid_t: (kind: ChromeKind, joules: Double)], dt: Double) -> ([Int: (watts: Double, shared: Int)], ChromeBreakdown) {
        var tabsOfPid: [pid_t: [Int]] = [:]
        for (id, p) in pidOf where tabs[id]?.measurable == true { tabsOfPid[p, default: []].append(id) }
        var perTab: [Int: (Double, Int)] = [:]
        var b = ChromeBreakdown()
        for (p, v) in chrome {
            let w = v.joules / dt
            switch v.kind {
            case .gpu: b.gpu += w
            case .browser, .helper: b.browser += w
            case .renderer:
                if let ids = tabsOfPid[p], !ids.isEmpty {
                    b.tabs += w
                    for id in ids { perTab[id] = (w / Double(ids.count), ids.count) }
                } else {
                    b.unassigned += w
                }
            }
        }
        return (perTab.mapValues { (watts: $0.0, shared: $0.1) }, b)
    }
}

// MARK: - Lokale Schnittstelle für die Erweiterung (nur 127.0.0.1)

final class ChromeServer {
    static let port: UInt16 = 47830
    private var listener: NWListener?
    private let handler: @MainActor (String, Data) -> Data?

    init(handler: @escaping @MainActor (String, Data) -> Data?) { self.handler = handler }

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in
            c.start(queue: .main)
            self?.receive(c, Data())
        }
        l.start(queue: .main)
        listener = l
    }

    private func receive(_ c: NWConnection, _ buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                let resp = MainActor.assumeIsolated { self.respond(req) }
                c.send(content: resp, completion: .contentProcessed { _ in c.cancel() })
            } else if complete || error != nil || buf.count > 4 << 20 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }

    private static func parse(_ d: Data) -> Request? {
        guard let sep = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<sep.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = d[sep.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body.prefix(length)))
    }

    @MainActor private func respond(_ r: Request) -> Data {
        // Nur die Erweiterung darf rein: Webseiten können den Zusatz-Header ohne CORS-Freigabe nicht senden.
        let origin = r.headers["origin"] ?? ""
        guard r.method == "POST", r.headers["x-akku-monitor"] == "1",
              origin.isEmpty || origin.hasPrefix("chrome-extension://") else {
            return Self.http(403, Data("{}".utf8))
        }
        guard let out = handler(r.path, r.body) else { return Self.http(404, Data("{}".utf8)) }
        return Self.http(200, out)
    }

    private static func http(_ code: Int, _ body: Data) -> Data {
        var d = Data("HTTP/1.1 \(code) \(code == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        d.append(body)
        return d
    }
}

// MARK: - Erweiterung bereitstellen

enum ChromeExtension {
    /// Fester Ort außerhalb von iCloud, von dem Chrome die Erweiterung lädt.
    static var installDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AkkuMonitor/Chrome-Erweiterung", isDirectory: true)
    }

    /// Kopiert die mitgelieferte Erweiterung aus dem App-Bundle an den festen Ort.
    @discardableResult
    static func install() -> Bool {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("chrome-extension") else { return false }
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return false }
        try? fm.createDirectory(at: installDir, withIntermediateDirectories: true)
        for f in (try? fm.contentsOfDirectory(atPath: src.path)) ?? [] {
            let target = installDir.appendingPathComponent(f)
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: src.appendingPathComponent(f), to: target)
        }
        return true
    }
}

import AppKit
import Darwin
import Foundation
import IOKit

// MARK: - Akku (IOKit, AppleSmartBattery)

struct BatteryReading {
    var pct: Int
    var rawMAh: Int
    var rawMaxMAh: Int
    var designMAh: Int
    var cycles: Int
    var voltage: Double      // V
    var amperage: Double     // A, negativ = Entladen
    var tempC: Double
    var ac: Bool
    var charging: Bool
    var fullyCharged: Bool
    var systemLoadW: Double? // Gesamtleistung des Systems laut Power-Telemetrie
    var adapterW: Int?
    var adapterName: String?

    /// Nennspannung der 3-Zellen-Packs in MacBook Pros.
    static let nominalVoltage = 11.6

    var batteryW: Double { voltage * amperage }
    var healthPct: Double { designMAh > 0 ? Double(rawMaxMAh) / Double(designMAh) * 100 : 0 }
    var fullWh: Double { Double(rawMaxMAh) * Self.nominalVoltage / 1000 }
    var designWh: Double { Double(designMAh) * Self.nominalVoltage / 1000 }
    var remainingWh: Double { Double(rawMAh) * Self.nominalVoltage / 1000 }

    /// Was das System gerade zieht. Fällt auf den Entladestrom zurück, falls die Telemetrie fehlt.
    var systemW: Double {
        if let s = systemLoadW, s > 0 { return s }
        return ac ? 0 : max(0, -batteryW)
    }
}

enum Battery {
    static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

        func i(_ k: String, in dict: [String: Any] = d) -> Int64 { (dict[k] as? NSNumber)?.int64Value ?? 0 }
        func b(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }

        let telemetry = d["PowerTelemetryData"] as? [String: Any]
        let adapter = d["AdapterDetails"] as? [String: Any]
        let ac = b("ExternalConnected")
        var sysLoad: Double?
        if let t = telemetry {
            let v = Double(i("SystemLoad", in: t)) / 1000
            if v > 0 && v < 400 { sysLoad = v }
        }
        return BatteryReading(
            pct: Int(i("CurrentCapacity")),
            rawMAh: Int(i("AppleRawCurrentCapacity")),
            rawMaxMAh: Int(i("AppleRawMaxCapacity")),
            designMAh: Int(i("DesignCapacity")),
            cycles: Int(i("CycleCount")),
            voltage: Double(i("Voltage")) / 1000,
            amperage: Double(i("Amperage")) / 1000,
            tempC: Double(i("Temperature")) / 100,
            ac: ac,
            charging: b("IsCharging"),
            fullyCharged: b("FullyCharged"),
            systemLoadW: sysLoad,
            adapterW: ac ? (adapter?["Watts"] as? NSNumber)?.intValue : nil,
            adapterName: ac ? adapter?["Name"] as? String : nil
        )
    }
}

// MARK: - Aufteilung nach Chip-Bereichen (IOReport „Energy Model“, ohne Admin-Rechte)

struct ComponentPower {
    var cpu: Double = 0
    var gpu: Double = 0
    var memory: Double = 0
    var otherChip: Double = 0
    var total: Double { cpu + gpu + memory + otherChip }
}

final class EnergyModelSampler {
    private typealias CopyGroup = @convention(c) (CFString, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFDictionary>?
    private typealias CreateSub = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CreateSamples = @convention(c) (OpaquePointer?, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias GetStr = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias GetInt = @convention(c) (CFDictionary, Int32) -> Int64

    private var createSamples: CreateSamples?
    private var delta: Delta?
    private var chName: GetStr?
    private var unitLabel: GetStr?
    private var intValue: GetInt?
    private var subscription: OpaquePointer?
    private var subscribed: CFMutableDictionary?
    private var previous: (CFDictionary, Date)?

    init() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return }
        func sym<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let copyGroup: CopyGroup = sym("IOReportCopyChannelsInGroup"),
              let createSub: CreateSub = sym("IOReportCreateSubscription") else { return }
        createSamples = sym("IOReportCreateSamples")
        delta = sym("IOReportCreateSamplesDelta")
        chName = sym("IOReportChannelGetChannelName")
        unitLabel = sym("IOReportChannelGetUnitLabel")
        intValue = sym("IOReportSimpleGetIntegerValue")
        guard let channels = copyGroup("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, channels) else { return }
        var sub: Unmanaged<CFMutableDictionary>?
        subscription = createSub(nil, mutable, &sub, 0, nil)
        subscribed = sub?.takeRetainedValue()
    }

    func reset() { previous = nil }

    /// Liefert die mittlere Leistung seit dem letzten Aufruf in Watt.
    func sample() -> ComponentPower? {
        guard let createSamples, let delta, let chName, let unitLabel, let intValue,
              let subscription, let subscribed,
              let now = createSamples(subscription, subscribed, nil)?.takeRetainedValue() else { return nil }
        let t = Date()
        defer { previous = (now, t) }
        guard let (prev, prevT) = previous else { return nil }
        let dt = t.timeIntervalSince(prevT)
        guard dt > 0.5, dt < 120,
              let d = delta(prev, now, nil)?.takeRetainedValue() as NSDictionary?,
              let items = d["IOReportChannels"] as? [NSDictionary] else { return nil }

        var p = ComponentPower()
        var gpuFallback = 0.0
        var sawGpuEnergy = false
        for item in items {
            let cf = item as CFDictionary
            guard let name = chName(cf)?.takeUnretainedValue() as String? else { continue }
            let unit = (unitLabel(cf)?.takeUnretainedValue() as String?) ?? "mJ"
            let raw = Double(intValue(cf, 0))
            let joules: Double
            switch unit {
            case "nJ": joules = raw / 1e9
            case "uJ", "µJ": joules = raw / 1e6
            default: joules = raw / 1e3
            }
            let w = joules / dt
            switch name {
            case "CPU Energy": p.cpu += w
            case "GPU Energy": p.gpu += w; sawGpuEnergy = true
            case "GPU": gpuFallback += w
            case "DRAM", "AMCC", "DCS": p.memory += w
            case "ANE", "AFR", "ISP", "AVE", "MSR", "DISP", "DISPEXT": p.otherChip += w
            default:
                if name.contains("PCIe") || name.hasPrefix("apciec") { p.otherChip += w }
            }
        }
        if !sawGpuEnergy { p.gpu = gpuFallback }
        return p
    }
}

// MARK: - Prozessor-Energie pro App (proc_pid_rusage, ri_energy_nj)

struct AppIdentity {
    let name: String
    let bundlePath: String?
}

final class ProcessEnergySampler {
    private var last: [pid_t: UInt64] = [:]
    private var identity: [pid_t: AppIdentity] = [:]
    private var lastTime: Date?
    private(set) var bundlePaths: [String: String] = [:]

    func reset() { lastTime = nil; last = [:] }

    /// Joule pro App seit dem letzten Aufruf plus Zeitabstand. nil beim ersten Lauf oder nach Ruhezustand.
    func sample() -> (dt: Double, joules: [String: Double])? {
        let now = Date()
        let pids = Self.allPids()
        var current: [pid_t: UInt64] = [:]
        current.reserveCapacity(pids.count)
        var result: [String: Double] = [:]
        let valid: Bool = {
            guard let lt = lastTime else { return false }
            let dt = now.timeIntervalSince(lt)
            return dt > 0.5 && dt < 120
        }()

        for p in pids {
            guard let e = Self.energy(p) else { continue }
            current[p] = e
            var delta: UInt64 = 0
            if let prev = last[p] {
                if e >= prev { delta = e - prev } else { identity[p] = nil; delta = e }
            } else {
                identity[p] = nil
                delta = valid ? e : 0
            }
            if valid && delta > 0 {
                let id = identity[p] ?? resolve(p)
                result[id.name, default: 0] += Double(delta) / 1e9
            }
        }
        for p in identity.keys where current[p] == nil { identity[p] = nil }
        let dt = lastTime.map { now.timeIntervalSince($0) } ?? 0
        last = current
        lastTime = now
        return valid ? (dt, result) : nil
    }

    private func resolve(_ p: pid_t) -> AppIdentity {
        var buf = [CChar](repeating: 0, count: 4096)
        proc_pidpath(p, &buf, UInt32(buf.count))
        let path = String(cString: buf)
        let id = Self.identify(path: path, pid: p)
        identity[p] = id
        if let bp = id.bundlePath { bundlePaths[id.name] = bp }
        return id
    }

    static func identify(path: String, pid: pid_t) -> AppIdentity {
        if path.isEmpty { return AppIdentity(name: "pid \(pid)", bundlePath: nil) }
        let comps = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var prefix = ""
        for c in comps {
            prefix += "/" + c
            if let r = c.range(of: ".app"), c.hasSuffix(".app") || c.hasSuffix(".app.bundle") {
                return AppIdentity(name: String(c[..<r.lowerBound]), bundlePath: prefix)
            }
        }
        let exe = comps.last ?? path
        return AppIdentity(name: friendlyDaemons[exe] ?? exe, bundlePath: nil)
    }

    static let friendlyDaemons: [String: String] = [
        "mds_stores": "Spotlight-Indexierung", "mdworker_shared": "Spotlight-Indexierung", "mdworker": "Spotlight-Indexierung",
        "mds": "Spotlight-Indexierung", "photoanalysisd": "Fotos-Analyse", "mediaanalysisd": "Fotos-Analyse",
        "photolibraryd": "Fotos-Mediathek", "bird": "iCloud Drive", "cloudd": "iCloud Drive", "fileproviderd": "iCloud Drive",
        "backupd": "Time Machine", "softwareupdated": "Softwareupdate", "corespotlightd": "Spotlight-Indexierung",
        "node": "Node.js", "python3": "Python", "Python": "Python",
    ]

    static func allPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var buf = [pid_t](repeating: 0, count: Int(n) + 128)
        let c = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
        return Array(buf.prefix(Int(max(0, c))))
    }

    static func energy(_ p: pid_t) -> UInt64? {
        var info = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(p, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? info.ri_energy_nj : nil
    }
}

// MARK: - Bildschirmhelligkeit (DisplayServices, privat, optional)

enum Brightness {
    private typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private static let getter: Get? = {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW),
              let s = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        return unsafeBitCast(s, to: Get.self)
    }()

    /// Helligkeit des eingebauten Displays von 0 bis 1, nil wenn zugeklappt oder unbekannt.
    static func builtIn() -> Double? {
        guard let getter else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return nil }
        for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
            var v: Float = 0
            if getter(id, &v) == 0 { return Double(v) }
        }
        return nil
    }

    static func externalDisplayCount() -> Int {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return 0 }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }.count
    }
}

// MARK: - Shell

enum Shell {
    static func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

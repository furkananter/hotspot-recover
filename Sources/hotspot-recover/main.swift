import Foundation
import CoreWLAN
import ObjectiveC

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Helpers

func log(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(f.string(from: Date())) \(message)")
}

/// IPv4 addresses (host byte order) per interface, ignoring link-local 169.254.x.x.
func ipv4Addresses() -> [(name: String, addr: UInt32)] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0 else { return [] }
    defer { freeifaddrs(head) }
    var result: [(String, UInt32)] = []
    var cur = head
    while let ifa = cur {
        defer { cur = ifa.pointee.ifa_next }
        guard let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
        if addr >> 16 != 0xA9FE { result.append((String(cString: ifa.pointee.ifa_name), addr)) }
    }
    return result
}

func ipv4(of ifname: String) -> UInt32? { ipv4Addresses().first { $0.name == ifname }?.addr }

/// True when the iPhone is also tethered over a cable: some interface other than Wi-Fi holds a hotspot address.
func cableTethered(wifi: String) -> Bool {
    ipv4Addresses().contains { $0.name != wifi && isHotspotAddress($0.addr) }
}

/// iPhone Personal Hotspot hands out 172.20.10.0/28.
func isHotspotAddress(_ ip: UInt32) -> Bool { ip & 0xFFFF_FFF0 == 0xAC14_0A00 }

/// Joins via networksetup. The password goes over stdin ("-"), never argv, so it can't be seen in `ps`.
func joinNetwork(interface: String, ssid: String, password: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
    p.arguments = ["-setairportnetwork", interface, ssid, "-"]
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    p.standardError = output
    do { try p.run() } catch { return "failed to launch networksetup: \(error)" }
    input.fileHandleForWriting.write(Data((password + "\n").utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8) ?? ""
    return out.replacingOccurrences(of: password, with: "***")
        .replacingOccurrences(of: "Password:", with: "")
        .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
}

// Private API reply block. Arity is not guaranteed, so only the first two raw pointers are read.
typealias EnableReply = @convention(block) (UnsafeRawPointer?, UnsafeRawPointer?, UnsafeRawPointer?) -> Void
typealias EnableFn = @convention(c) (AnyObject, Selector, AnyObject, EnableReply) -> Void

// MARK: - One recovery attempt (main thread only)

final class Recovery: NSObject {
    private enum Phase { case browsing, enabling, joining, finished }
    private var phase = Phase.browsing
    private var session: NSObject?
    private var timer: Timer?
    private var started = Date()
    private let interface: String
    private let deviceName: String?
    private let completion: (Bool) -> Void

    init(interface: String, deviceName: String?, completion: @escaping (Bool) -> Void) {
        self.interface = interface
        self.deviceName = deviceName
        self.completion = completion
    }

    func start() {
        guard dlopen("/System/Library/PrivateFrameworks/Sharing.framework/Sharing", RTLD_NOW) != nil,
              let cls = NSClassFromString("SFRemoteHotspotSession") as? NSObject.Type else {
            return finish("SFRemoteHotspotSession is unavailable on this macOS version")
        }
        started = Date()
        let s = cls.init()
        session = s
        s.perform(NSSelectorFromString("setDelegate:"), with: self)
        s.perform(NSSelectorFromString("startBrowsing"))
        arm(15, "no hotspot device found within 15 s")
    }

    private func arm(_ seconds: TimeInterval, _ reason: String) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.finish(reason)
        }
    }

    @objc(session:updatedFoundDevices:)
    func session(_ s: NSObject, updatedFoundDevices devices: NSArray) {
        guard phase == .browsing else { return }
        let found = devices.compactMap { $0 as? NSObject }
        let name = { (d: NSObject) in d.value(forKey: "deviceName") as? String ?? "?" }
        guard let device = found.first(where: { deviceName == nil || name($0) == deviceName }) else {
            log("devices found: \(found.map(name)), none matches --device")
            return
        }
        log("device found: \(name(device))")
        phase = .enabling
        arm(20, "hotspot enable timed out after 20 s")

        let reply: EnableReply = { first, second, _ in
            let ssid = first.flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? String }
            let pw = second.flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as? String }
            DispatchQueue.main.async { self.enabled(ssid: ssid, password: pw) }
        }
        let sel = NSSelectorFromString("enableHotspotForDevice:withCompletionHandler:")
        unsafeBitCast(s.method(for: sel), to: EnableFn.self)(s, sel, device, reply)
    }

    private func enabled(ssid: String?, password: String?) {
        guard phase == .enabling else { return }
        guard let ssid, !ssid.isEmpty, let password, !password.isEmpty else {
            return finish("hotspot enable returned no credentials (iPhone unreachable?)")
        }
        log("hotspot enabled (\"\(ssid)\")")
        phase = .joining
        timer?.invalidate()
        let iface = interface
        DispatchQueue.global().async {
            var out = ""
            for attempt in 1...3 {
                out = joinNetwork(interface: iface, ssid: ssid, password: password)
                if out.isEmpty { break }
                if attempt < 3 { sleep(3) }
            }
            DispatchQueue.main.async { self.joined(output: out) }
        }
    }

    private func joined(output: String) {
        guard phase == .joining else { return }
        guard output.isEmpty else { return finish("networksetup: \(output)") }
        // Wait for DHCP to hand out a hotspot address.
        arm(10, "joined but no hotspot IPv4 within 10 s")
        poll()
    }

    private func poll() {
        guard phase == .joining else { return }
        if let ip = ipv4(of: interface), isHotspotAddress(ip) {
            log(String(format: "joined hotspot in %.1f s", Date().timeIntervalSince(started)))
            return finish(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.poll() }
    }

    /// nil failure = success.
    private func finish(_ failure: String?) {
        guard phase != .finished else { return }
        phase = .finished
        timer?.invalidate()
        session?.perform(NSSelectorFromString("setDelegate:"), with: nil)
        session?.perform(NSSelectorFromString("stopBrowsing"))
        session = nil
        if let failure { log("recovery failed: \(failure)") }
        completion(failure == nil)
    }
}

// MARK: - Watcher

final class Watcher {
    private let deviceName: String?
    private let always: Bool
    private enum Link { case unknown, hotspot, other }  // last network the Mac was on
    private var lastWifi = Link.unknown
    private var onCable = false
    private var noIPPolls = 0
    private var noIPSince: Date?
    private var recovering = false
    private var failures = 0
    private var nextAttempt = Date.distantPast
    private var current: Recovery?
    private var lastTick = Date()
    private var graceUntil = Date.distantPast
    private let grace: TimeInterval = 10
    private let backoff: [TimeInterval] = [5, 10, 20, 40, 60]

    init(deviceName: String?, always: Bool) {
        self.deviceName = deviceName
        self.always = always
    }

    func tick() {
        // After a wake from sleep (timers don't fire while asleep) or a Wi-Fi off->on toggle,
        // give macOS time to auto-join whatever network is nearby before grabbing the hotspot.
        let now = Date()
        if now.timeIntervalSince(lastTick) > 5 { graceUntil = now.addingTimeInterval(grace) }
        lastTick = now
        guard !recovering else { return }
        guard let wifi = CWWiFiClient.shared().interface(), let name = wifi.interfaceName, wifi.powerOn() else {
            noIPPolls = 0; noIPSince = nil; graceUntil = now.addingTimeInterval(grace); return
        }
        let wifiIP = ipv4(of: name)
        let cable = cableTethered(wifi: name)
        if cable != onCable {
            onCable = cable
            log(cable ? "iPhone cable link is up" : "iPhone cable link is down")
        }
        if let ip = wifiIP {
            lastWifi = isHotspotAddress(ip) ? .hotspot : .other
            noIPPolls = 0
            noIPSince = nil
            return
        }
        if cable {
            // Tethered over USB: macOS is already routing through the phone, nothing to recover.
            // Remember the phone so Wi-Fi is recovered if the cable link goes away.
            lastWifi = .hotspot
            noIPPolls = 0
            noIPSince = nil
            return
        }
        let wasOnHotspot = lastWifi == .hotspot
        noIPPolls += 1
        let since = noIPSince ?? Date()
        noIPSince = since
        let eligible = wasOnHotspot || (always && Date().timeIntervalSince(since) >= 10)
        guard noIPPolls >= 2, eligible, now >= nextAttempt, now >= graceUntil else { return }
        log("connection drop detected on \(name), recovering")
        recovering = true
        let r = Recovery(interface: name, deviceName: deviceName) { [self] ok in
            recovering = false
            current = nil
            if ok {
                failures = 0
                lastWifi = .hotspot
            } else {
                nextAttempt = Date().addingTimeInterval(backoff[min(failures, backoff.count - 1)])
                failures += 1
                log("retrying in \(Int(nextAttempt.timeIntervalSinceNow.rounded())) s")
            }
            noIPPolls = 0
            noIPSince = nil
        }
        current = r
        r.start()
    }
}

// MARK: - CLI

let usage = """
Usage: hotspot-recover [--once] [--device <name>] [--always] [--help]

Re-joins an iPhone Personal Hotspot when the Mac's Wi-Fi drops off it.

  (no args)        watch forever
  --once           run one recovery now and exit (0 = joined)
  --device <name>  only use the hotspot device with this name (default: first found)
  --always         recover whenever Wi-Fi is on and has had no IPv4 for 10 s,
                   even if this process never saw the hotspot
  --help           show this help
"""

var once = false, always = false
var deviceName: String?
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--once": once = true
    case "--always": always = true
    case "--device":
        guard let v = args.popFirst() else { print("--device needs a name\n\(usage)"); exit(64) }
        deviceName = v
    case "--help", "-h": print(usage); exit(0)
    default: print("unknown argument: \(a)\n\(usage)"); exit(64)
    }
}

if once {
    guard let wifi = CWWiFiClient.shared().interface(), let name = wifi.interfaceName, wifi.powerOn() else {
        log("Wi-Fi interface not found or powered off")
        exit(1)
    }
    let r = Recovery(interface: name, deviceName: deviceName) { ok in exit(ok ? 0 : 1) }
    r.start()
} else {
    let watcher = Watcher(deviceName: deviceName, always: always)
    Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in watcher.tick() }
    log("watching (device: \(deviceName ?? "first found"), always: \(always))")
}
RunLoop.main.run()

import Foundation
import CoreWLAN
import AppKit
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
    private(set) var failure: String?
    var elapsed: TimeInterval { Date().timeIntervalSince(started) }
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
        // .common so the timeout still fires while a menu is open (event-tracking run loop mode).
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.finish(reason)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
        self.failure = failure
        if let failure { log("recovery failed: \(failure)") }
        completion(failure == nil)
    }
}

// MARK: - Watcher

final class Watcher {
    private let deviceName: String?
    var always: Bool
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

    enum Status { case wifi, usb, reconnecting, notOnHotspot, wifiOff, paused }
    var onChange: (() -> Void)?
    var paused = false { didSet { notify() } }
    private(set) var lastRecovery: (date: Date, seconds: TimeInterval, failure: String?)?
    private var wifiOn = true
    private var onHotspotWifi = false
    private var lastNotified: Status?

    var status: Status {
        if recovering { return .reconnecting }
        if paused { return .paused }
        if !wifiOn { return .wifiOff }
        if onHotspotWifi { return .wifi }
        if onCable { return .usb }
        return .notOnHotspot
    }

    var canReconnect: Bool { !recovering && wifiOn }

    private func notify(force: Bool = false) {
        let s = status
        guard force || s != lastNotified else { return }
        lastNotified = s
        onChange?()
    }

    init(deviceName: String?, always: Bool) {
        self.deviceName = deviceName
        self.always = always
    }

    func tick() {
        defer { notify() }
        // After a wake from sleep (timers don't fire while asleep) or a Wi-Fi off->on toggle,
        // give macOS time to auto-join whatever network is nearby before grabbing the hotspot.
        let now = Date()
        if now.timeIntervalSince(lastTick) > 5 { graceUntil = now.addingTimeInterval(grace) }
        lastTick = now
        guard !recovering else { return }
        guard let wifi = CWWiFiClient.shared().interface(), let name = wifi.interfaceName, wifi.powerOn() else {
            wifiOn = false; onHotspotWifi = false
            noIPPolls = 0; noIPSince = nil; graceUntil = now.addingTimeInterval(grace); return
        }
        wifiOn = true
        let wifiIP = ipv4(of: name)
        onHotspotWifi = wifiIP.map(isHotspotAddress) ?? false
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
        guard noIPPolls >= 2, eligible, !paused, now >= nextAttempt, now >= graceUntil else { return }
        log("connection drop detected on \(name), recovering")
        startRecovery(on: name)
    }

    /// Menu "Reconnect Now": one recovery right away, same bookkeeping as an automatic one.
    func reconnectNow() {
        guard !recovering, let wifi = CWWiFiClient.shared().interface(), let name = wifi.interfaceName, wifi.powerOn() else { return }
        log("manual reconnect on \(name)")
        startRecovery(on: name)
    }

    private func startRecovery(on name: String) {
        recovering = true
        let r = Recovery(interface: name, deviceName: deviceName) { [self] ok in
            let rec = current
            recovering = false
            current = nil
            lastRecovery = (Date(), rec?.elapsed ?? 0, ok ? nil : rec?.failure ?? "unknown")
            if ok {
                failures = 0
                lastWifi = .hotspot
                onHotspotWifi = true
            } else {
                nextAttempt = Date().addingTimeInterval(backoff[min(failures, backoff.count - 1)])
                failures += 1
                log("retrying in \(Int(nextAttempt.timeIntervalSinceNow.rounded())) s")
            }
            noIPPolls = 0
            noIPSince = nil
            notify(force: true)
        }
        current = r
        notify()
        r.start()
    }
}

// MARK: - Menu bar icon

/// The app's own menu bar glyph: a phone with signal waves, plus one variant per state.
/// Drawn in code so it stays a crisp template image at any scale without an app bundle.
enum Glyph: CaseIterable { case wifi, usb, reconnect0, reconnect1, reconnect2, paused, off }

// 18x18 pt canvas, top-left origin (flipped). Phone on the left, signal on the right.
func drawGlyph(_ g: Glyph, color: NSColor) {
    let lw: CGFloat = 1.5
    color.setStroke(); color.setFill()
    // Phone body
    let phone = NSBezierPath(roundedRect: NSRect(x: 2.5, y: 2.25, width: 6.5, height: 13.5), xRadius: 2, yRadius: 2)
    phone.lineWidth = lw; phone.stroke()
    // Home indicator
    let bar = NSBezierPath(); bar.move(to: NSPoint(x: 4.9, y: 13.1)); bar.line(to: NSPoint(x: 6.6, y: 13.1))
    bar.lineWidth = 1.1; bar.lineCapStyle = .round; bar.stroke()

    func arc(_ r: CGFloat, alpha: CGFloat) {
        let p = NSBezierPath()
        // flipped coords: angles measured clockwise visually; -40..40 points right
        p.appendArc(withCenter: NSPoint(x: 8.6, y: 9), radius: r, startAngle: -42, endAngle: 42)
        p.lineWidth = lw; p.lineCapStyle = .round
        color.withAlphaComponent(alpha).setStroke(); p.stroke()
        color.setStroke()
    }
    switch g {
    case .wifi: arc(3.6, alpha: 1); arc(6.9, alpha: 1)
    case .reconnect0: arc(3.6, alpha: 0.3); arc(6.9, alpha: 0.3)
    case .reconnect1: arc(3.6, alpha: 1); arc(6.9, alpha: 0.3)
    case .reconnect2: arc(3.6, alpha: 1); arc(6.9, alpha: 1)
    case .off:
        arc(3.6, alpha: 0.3); arc(6.9, alpha: 0.3)
        let s = NSBezierPath(); s.move(to: NSPoint(x: 11.6, y: 4.6)); s.line(to: NSPoint(x: 16.4, y: 13.4))
        s.lineWidth = lw; s.lineCapStyle = .round; s.stroke()
    case .paused:
        for x in [12.6, 15.6] as [CGFloat] {
            let b = NSBezierPath(); b.move(to: NSPoint(x: x, y: 6)); b.line(to: NSPoint(x: x, y: 12))
            b.lineWidth = 1.7; b.lineCapStyle = .round; b.stroke()
        }
    case .usb:
        // cable leaves the phone's right edge and ends in a plug
        let c = NSBezierPath()
        c.move(to: NSPoint(x: 9.75, y: 11.6))
        c.curve(to: NSPoint(x: 14, y: 7.5), controlPoint1: NSPoint(x: 12.5, y: 11.5), controlPoint2: NSPoint(x: 14, y: 10.5))
        c.lineWidth = 1.3; c.lineCapStyle = .round; c.stroke()
        NSBezierPath(roundedRect: NSRect(x: 12.3, y: 3.6, width: 3.4, height: 4.2), xRadius: 0.8, yRadius: 0.8).fill()
        for x in [13.2, 14.8] as [CGFloat] {
            let pr = NSBezierPath(); pr.move(to: NSPoint(x: x, y: 3.6)); pr.line(to: NSPoint(x: x, y: 2))
            pr.lineWidth = 0.9; pr.stroke()
        }
    }
}

func glyphImage(_ g: Glyph, description: String) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        drawGlyph(g, color: .black)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = description
    return image
}

// MARK: - Menu

final class MenuController: NSObject, NSMenuDelegate {
    private let watcher: Watcher
    private let defaults: UserDefaults
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lastLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let reconnectItem = NSMenuItem(title: "Reconnect Now", action: #selector(reconnect), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Auto-Reconnect", action: #selector(togglePause), keyEquivalent: "")
    private let alwaysItem = NSMenuItem(title: "Reconnect After Restart", action: #selector(toggleAlways), keyEquivalent: "")
    private var shownGlyph: Glyph?
    private var animation: Timer?

    init(watcher: Watcher, defaults: UserDefaults) {
        self.watcher = watcher
        self.defaults = defaults
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        statusLine.isEnabled = false
        lastLine.isEnabled = false
        let show = NSMenuItem(title: "Show Log", action: #selector(showLog), keyEquivalent: "")
        let quit = NSMenuItem(title: "Quit hotspot-recover", action: #selector(quitApp), keyEquivalent: "q")
        for item in [reconnectItem, pauseItem, alwaysItem, show, quit] { item.target = self }
        for item in [statusLine, lastLine, .separator(), reconnectItem, pauseItem, .separator(), alwaysItem, show, .separator(), quit] {
            menu.addItem(item)
        }
        statusItem.menu = menu
        watcher.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let text: String, glyph: Glyph
        switch watcher.status {
        case .wifi: (text, glyph) = ("Connected over Wi-Fi", .wifi)
        case .usb: (text, glyph) = ("Connected over USB", .usb)
        case .reconnecting: (text, glyph) = ("Reconnecting…", .reconnect0)
        case .paused: (text, glyph) = ("Paused", .paused)
        case .notOnHotspot: (text, glyph) = ("Not on hotspot", .off)
        case .wifiOff: (text, glyph) = ("Wi-Fi is off", .off)
        }
        statusLine.title = text
        if let r = watcher.lastRecovery {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            lastLine.title = r.failure.map { "Last reconnect failed: \($0.prefix(60))" }
                ?? String(format: "Last reconnect: %@ (%.1f s)", f.string(from: r.date), r.seconds)
            lastLine.isHidden = false
        } else {
            lastLine.isHidden = true
        }
        reconnectItem.isEnabled = watcher.canReconnect
        pauseItem.state = watcher.paused ? .on : .off
        alwaysItem.state = watcher.always ? .on : .off
        if glyph == .reconnect0 { startAnimation(text) } else { stopAnimation(); show(glyph, text) }
    }

    private func show(_ glyph: Glyph, _ text: String) {
        guard glyph != shownGlyph else { return }
        shownGlyph = glyph
        statusItem.button?.image = glyphImage(glyph, description: text)
    }

    /// Light the waves one after another while reconnecting, like the Wi-Fi menu does.
    private func startAnimation(_ text: String) {
        guard animation == nil else { return }
        var frame = 0
        let frames: [Glyph] = [.reconnect0, .reconnect1, .reconnect2]
        show(frames[0], text)
        let t = Timer(timeInterval: 0.35, repeats: true) { [weak self] _ in
            frame = (frame + 1) % frames.count
            self?.show(frames[frame], text)
        }
        RunLoop.main.add(t, forMode: .common)
        animation = t
    }

    private func stopAnimation() {
        animation?.invalidate()
        animation = nil
    }

    @objc private func reconnect() { watcher.reconnectNow() }
    @objc private func togglePause() { watcher.paused.toggle(); refresh() }
    @objc private func toggleAlways() {
        watcher.always.toggle()
        defaults.set(watcher.always, forKey: "always")
        refresh()
    }
    @objc private func showLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/hotspot-recover.log"))
    }
    @objc private func quitApp() { exit(0) }
}

// MARK: - CLI

let usage = """
Usage: hotspot-recover [--once] [--no-menu] [--device <name>] [--always] [--help]

Re-joins an iPhone Personal Hotspot when the Mac's Wi-Fi drops off it.

  (no args)        menu bar icon + watch forever
  --no-menu        watch forever without the menu bar icon
  --once           run one recovery now and exit (0 = joined)
  --device <name>  only use the hotspot device with this name (default: first found)
  --always         recover whenever Wi-Fi is on and has had no IPv4 for 10 s,
                   even if this process never saw the hotspot
  --help           show this help
"""

var once = false, always = false, noMenu = false
var deviceName: String?
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    switch a {
    case "--once": once = true
    case "--always": always = true
    case "--no-menu": noMenu = true
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
    RunLoop.main.run()
} else {
    let defaults = UserDefaults(suiteName: "com.github.hotspot-recover") ?? .standard
    if always && !noMenu { defaults.set(true, forKey: "always") }
    let watcher = Watcher(deviceName: deviceName, always: noMenu ? always : defaults.bool(forKey: "always"))
    // .common so the watcher keeps ticking while a menu is open (event-tracking run loop mode).
    let ticker = Timer(timeInterval: 1, repeats: true) { _ in watcher.tick() }
    RunLoop.main.add(ticker, forMode: .common)
    log("watching (device: \(deviceName ?? "first found"), always: \(watcher.always), menu: \(!noMenu))")
    if noMenu {
        RunLoop.main.run()
    } else {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = MenuController(watcher: watcher, defaults: defaults)
        withExtendedLifetime(controller) { app.run() }
    }
}

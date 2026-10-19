// TV Remote: drives an Android TV box over a persistent root `adb shell`,
// injecting raw Linux input events (one write per key edge) for low latency.
import AppKit
import SwiftUI

// MARK: - Linux key codes (see the TV's Vendor_0001_Product_0001.kl)

enum Key: UInt16 {
    case up = 103, down = 108, left = 105, right = 106, ok = 28
    case back = 158, home = 172, menu = 139
    case volUp = 115, volDown = 114, mute = 113, power = 116
    case playPause = 164, rewind = 168, fastForward = 208, next = 163, previous = 165, stop = 128
    case source = 250, pictureMode = 248, info = 358
    case d0 = 11, d1 = 2, d2 = 3, d3 = 4, d4 = 5, d5 = 6, d6 = 7, d7 = 8, d8 = 9, d9 = 10
    case del = 14
}

// MARK: - adb link

@MainActor
final class AdbLink: ObservableObject {
    enum State: Equatable { case disconnected, connecting, connected(String), failed(String) }

    @Published var state: State = .disconnected
    @Published var serial: String {
        didSet { UserDefaults.standard.set(serial, forKey: "serial") }
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var lastPong = Date.distantPast
    private var heartbeat: Timer?
    private var retry: Timer?
    private var generation = 0
    private let writer = DispatchQueue(label: "adb-writer")

    nonisolated static let adbPath: String = {
        let candidates = [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "adb"
    }()

    init() {
        serial = UserDefaults.standard.string(forKey: "serial") ?? ""
    }

    var isConnected: Bool { if case .connected = state { return true } else { return false } }

    /// "192.168.1.50" -> "192.168.1.50:5555"; USB serials and host:port pass through.
    static func normalize(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: ".")
        if !t.contains(":"), parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) { return t + ":5555" }
        return t
    }

    func connect() {
        teardown()
        generation += 1
        let gen = generation
        let target = Self.normalize(serial)
        guard !target.isEmpty else {
            state = .failed("No TV selected · use Find TV")
            return
        }
        if target != serial { serial = target }
        state = .connecting

        DispatchQueue.global().async {
            // `adb connect` only applies to network targets (host:port).
            var reachable = true
            if target.contains(":") {
                let out = Self.run([Self.adbPath, "connect", target], timeout: 8)
                reachable = !(out.contains("failed") || out.contains("unable") || out.contains("refused") || out.isEmpty)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                if reachable {
                    self.startShell(target: target, gen: gen)
                } else {
                    self.state = .failed("Can't reach \(target) · try Find TV")
                    self.scheduleRetry()
                }
            }
        }
    }

    private func startShell(target: String, gen: Int) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.adbPath)
        p.arguments = ["-s", target, "shell"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe

        var buffer = ""
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                buffer += s
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
                    buffer.removeSubrange(...nl)
                    self.handle(line: line)
                }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.state = .failed("Connection lost")
                self.scheduleRetry()
            }
        }

        do { try p.run() } catch {
            state = .failed("Can't start adb")
            return
        }
        process = p
        stdin = inPipe.fileHandleForWriting

        // Find the TV's virtual "Hi keyboard" ($E) and "Hi mouse" ($M) input devices.
        send("""
        E=/dev/input/event0; M=/dev/input/event1; for f in /sys/class/input/event*/device/name; do \
        n=${f#/sys/class/input/}; case "$(cat $f)" in "Hi keyboard") E=/dev/input/${n%%/*};; \
        "Hi mouse") M=/dev/input/${n%%/*};; esac; done; \
        if [ -w "$E" ]; then echo "READY $E"; else echo "NOACCESS $E"; fi
        """)

        lastPong = Date()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(self.lastPong) > 12 {
                    self.state = .failed("TV not responding")
                    self.teardown()
                    self.scheduleRetry()
                } else {
                    self.send("echo PONG")
                }
            }
        }
    }

    private func handle(line: String) {
        if line.hasPrefix("READY ") {
            lastPong = Date()
            state = .connected(String(line.dropFirst(6)))
        } else if line == "PONG" {
            lastPong = Date()
        } else if line.hasPrefix("NOACCESS") {
            state = .failed("No root access to input device")
        } else if line.contains("not found") || line.contains("offline") || line.contains("unauthorized") {
            state = .failed(line)
        }
    }

    private func scheduleRetry() {
        retry?.invalidate()
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect() }
        }
    }

    private func teardown() {
        heartbeat?.invalidate(); heartbeat = nil
        retry?.invalidate(); retry = nil
        if let p = process {
            p.terminationHandler = nil
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
        stdin = nil
    }

    private func send(_ command: String) {
        guard let handle = stdin, let data = (command + "\n").data(using: .utf8) else { return }
        writer.async {
            do { try handle.write(contentsOf: data) } catch { /* termination handler reconnects */ }
        }
    }

    // MARK: Input

    /// One key edge: EV_KEY then SYN_REPORT on the keyboard device.
    func key(_ k: Key, down: Bool) {
        guard isConnected else { if case .failed = state { connect() }; return }
        emit("$E", [(1, k.rawValue, down ? 1 : 0)])
    }

    // MARK: Mouse

    private var pendingDX = 0.0, pendingDY = 0.0, pendingWheel = 0.0
    private var mouseFlush: Timer?
    static let pointerSpeed = 1.3
    private static let wheelStep = 14.0 // trackpad scroll points per wheel notch

    /// Accumulates pointer motion; flushed at ~60 Hz so a 120 Hz trackpad doesn't flood the TV.
    func moveBy(dx: Double, dy: Double) {
        pendingDX += dx * Self.pointerSpeed
        pendingDY += dy * Self.pointerSpeed
        scheduleMouseFlush()
    }

    /// Positive scrolls content up (REL_WHEEL convention). `precise` = trackpad points, else lines.
    func scroll(by delta: Double, precise: Bool) {
        pendingWheel += precise ? delta / Self.wheelStep : delta
        scheduleMouseFlush()
    }

    func mouseButton(right: Bool, down: Bool) {
        guard isConnected else { return }
        flushMouse()
        emit("$M", [(1, right ? 0x111 : 0x110, down ? 1 : 0)]) // BTN_RIGHT is Back on Android
    }

    private func scheduleMouseFlush() {
        guard mouseFlush == nil else { return }
        mouseFlush = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushMouse() }
        }
    }

    private func flushMouse() {
        mouseFlush?.invalidate(); mouseFlush = nil
        let dx = Int32(pendingDX.rounded(.towardZero)), dy = Int32(pendingDY.rounded(.towardZero))
        let wheel = Int32(pendingWheel.rounded(.towardZero))
        pendingDX -= Double(dx); pendingDY -= Double(dy); pendingWheel -= Double(wheel)
        guard isConnected else { pendingDX = 0; pendingDY = 0; pendingWheel = 0; return }
        var events: [(UInt16, UInt16, Int32)] = []
        if dx != 0 { events.append((2, 0, dx)) }     // REL_X
        if dy != 0 { events.append((2, 1, dy)) }     // REL_Y
        if wheel != 0 { events.append((2, 8, wheel)) } // REL_WHEEL
        if !events.isEmpty { emit("$M", events) }
    }

    /// Writes events plus SYN_REPORT as 32-bit `struct input_event`s in one write, using mksh's
    /// builtin `print` (no process spawn on the TV, ~0.2 ms vs ~30 ms for /system/bin/printf).
    private func emit(_ device: String, _ events: [(UInt16, UInt16, Int32)]) {
        var bytes = [UInt8]()
        for e in events { bytes += Self.event(type: e.0, code: e.1, value: e.2) }
        bytes += Self.event(type: 0, code: 0, value: 0)
        let escaped = bytes.map { String(format: "\\0%03o", $0) }.joined()
        send("print -n '\(escaped)' > \(device)")
    }

    func tap(_ k: Key) {
        key(k, down: true)
        key(k, down: false)
    }

    /// Types text on the TV via `input text` (slow, ~1s, but fine for search boxes).
    func type(_ text: String) {
        guard isConnected, !text.isEmpty else { return }
        let escaped = text
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: " ", with: "%s")
            .replacingOccurrences(of: "'", with: "'\\''")
        send("input text '\(escaped)'")
    }

    func openSettings() {
        guard isConnected else { return }
        send("am start -n com.android.tv.settings/.MainSettings >/dev/null 2>&1")
    }

    private static func event(type: UInt16, code: UInt16, value: Int32) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 8) // struct timeval (kernel stamps it)
        b += [UInt8(type & 0xff), UInt8(type >> 8), UInt8(code & 0xff), UInt8(code >> 8)]
        let v = UInt32(bitPattern: value)
        b += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)]
        return b
    }

    /// Runs a command, killing it after `timeout` seconds (adb can hang on non-adb hosts).
    nonisolated static func run(_ args: [String], timeout: TimeInterval = 10) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: args[0])
        p.arguments = Array(args.dropFirst())
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        // Collect output as it arrives: never read to EOF, because `adb` may fork its server
        // daemon, which inherits the pipe and keeps it open indefinitely.
        let buffer = OutputBuffer()
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { buffer.append(d) }
        }
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return "" }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate() }
        Thread.sleep(forTimeInterval: 0.05) // let the last chunk land
        out.fileHandleForReading.readabilityHandler = nil
        return buffer.string
    }
}

final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(data: data, encoding: .utf8) ?? "" }
}

// MARK: - TV discovery

struct FoundTV: Identifiable, Hashable {
    let serial: String
    let name: String
    var id: String { serial }
}

/// Finds TVs by probing every host on the Mac's local /24 networks for the adb port (5555),
/// then asking each responder for its model name. Also lists devices adb already knows.
@MainActor
final class TVFinder: ObservableObject {
    @Published private(set) var scanning = false
    @Published private(set) var message = ""
    @Published private(set) var found: [FoundTV] = []

    func scan(completion: @escaping ([FoundTV]) -> Void = { _ in }) {
        guard !scanning else { return }
        let subnets = Self.localSubnets()
        guard !subnets.isEmpty else {
            message = "Mac isn't on a Wi-Fi or Ethernet network"
            return
        }
        scanning = true
        found = []
        message = "Scanning " + subnets.map { "\($0).x" }.joined(separator: ", ") + "…"

        DispatchQueue.global(qos: .userInitiated).async {
            let results = Self.discover(subnets: subnets)
            DispatchQueue.main.async {
                self.scanning = false
                self.found = results
                self.message = results.isEmpty
                    ? "No TV found. Is network debugging on and the TV on this network?"
                    : "Found \(results.count). Pick your TV:"
                completion(results)
            }
        }
    }

    nonisolated private static func discover(subnets: [String]) -> [FoundTV] {
        let adb = AdbLink.adbPath
        var candidates = Set<String>()

        // Devices adb is already attached to (USB or network).
        for line in AdbLink.run([adb, "devices"], timeout: 5).split(separator: "\n") {
            let cols = line.split(separator: "\t")
            if cols.count == 2, cols[1] == "device" { candidates.insert(String(cols[0])) }
        }

        // Every host with the adb port open. TV Wi-Fi chips doze, so the first contact (ARP +
        // wake-up) can take over a second; a quick pass wakes them, a slower pass catches them.
        let lock = NSLock()
        let hosts = subnets.flatMap { subnet in (1...254).map { "\(subnet).\($0)" } }
        for timeoutMs: Int32 in [900, 2000] {
            let group = DispatchGroup()
            let gate = DispatchSemaphore(value: 96)
            for ip in hosts {
                gate.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { gate.signal(); group.leave() }
                    if portOpen(ip, 5555, timeoutMs: timeoutMs) {
                        lock.lock(); candidates.insert("\(ip):5555"); lock.unlock()
                    }
                }
            }
            group.wait()
            if candidates.contains(where: { $0.hasSuffix(":5555") }) { break }
        }

        // Identify each candidate.
        var results: [FoundTV] = []
        for serial in candidates.sorted() {
            if serial.contains(":") { _ = AdbLink.run([adb, "connect", serial], timeout: 5) }
            let out = AdbLink.run([adb, "-s", serial, "shell", "getprop", "ro.product.model"], timeout: 5)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let name: String
            if out.contains("unauthorized") {
                name = "Allow USB debugging on the TV, then scan again"
            } else if out.isEmpty || out.contains("error") || out.contains("failed") || out.contains("offline") {
                continue // port 5555 open, but not a usable adb device
            } else {
                name = out
            }
            results.append(FoundTV(serial: serial, name: name))
        }
        return results
    }

    /// First three octets of each active IPv4 Wi-Fi/Ethernet interface, e.g. "192.168.1".
    nonisolated private static func localSubnets() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var subnets: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let flags = Int32(ifa.ifa_flags)
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  String(cString: ifa.ifa_name).hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { continue } // no DHCP lease
            let subnet = ip.split(separator: ".").prefix(3).joined(separator: ".")
            if !subnets.contains(subnet) { subnets.append(subnet) }
        }
        return subnets
    }

    nonisolated private static func portOpen(_ ip: String, _ port: UInt16, timeoutMs: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) == 1 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}

// MARK: - Pointer capture (trackpad)

/// While active, the Mac pointer is hidden and frozen and all mouse input goes to the TV:
/// motion -> pointer, click -> click, right click -> Back, scroll -> wheel. Esc releases.
@MainActor
final class PointerCapture: ObservableObject {
    @Published private(set) var active = false
    private var monitor: Any?
    private var observers: [Any] = []
    private var buttonsDown = Set<Bool>() // right?

    func begin(link: AdbLink) {
        guard !active, link.isConnected else { return }
        active = true
        buttonsDown.removeAll()
        NSApp.keyWindow?.acceptsMouseMovedEvents = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self, weak link] e in
            guard let self, self.active, let link else { return e }
            switch e.type {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
                link.moveBy(dx: e.deltaX, dy: e.deltaY)
            case .leftMouseDown, .rightMouseDown:
                let right = e.type == .rightMouseDown
                self.buttonsDown.insert(right)
                link.mouseButton(right: right, down: true)
            case .leftMouseUp, .rightMouseUp:
                let right = e.type == .rightMouseUp
                if self.buttonsDown.remove(right) != nil { link.mouseButton(right: right, down: false) }
            case .scrollWheel:
                link.scroll(by: e.scrollingDeltaY, precise: e.hasPreciseScrollingDeltas)
            default:
                return e
            }
            return nil
        }

        let center = NotificationCenter.default
        for name in [NSApplication.didResignActiveNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.end(link: link) }
            })
        }
    }

    func end(link: AdbLink?) {
        guard active else { return }
        active = false
        for right in buttonsDown { link?.mouseButton(right: right, down: false) }
        buttonsDown.removeAll()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }
}

struct TrackpadView: View {
    @ObservedObject var link: AdbLink
    @ObservedObject var capture: PointerCapture

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(white: capture.active ? 0.2 : 0.14))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(capture.active ? Color(red: 0.31, green: 0.76, blue: 0.97) : Color(white: 0.25),
                            lineWidth: capture.active ? 2 : 1)
            )
            .overlay(
                VStack(spacing: 4) {
                    Image(systemName: capture.active ? "cursorarrow.motionlines" : "rectangle.and.hand.point.up.left")
                        .font(.system(size: 20))
                    Text(capture.active ? "Controlling TV pointer" : "Click to use as trackpad")
                        .font(.caption)
                    Text(capture.active ? "Esc to release · right-click = Back · scroll = scroll"
                                        : "Moves the TV's mouse pointer")
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
                .foregroundColor(capture.active ? .white : Color(white: 0.6))
            )
            .frame(width: 260, height: 130)
            .contentShape(Rectangle())
            .onTapGesture { capture.begin(link: link) }
            .opacity(link.isConnected ? 1 : 0.5)
    }
}

// MARK: - Keyboard shortcuts

@MainActor
final class KeyboardBridge {
    private var monitor: Any?
    private var held = Set<UInt16>()
    weak var capture: PointerCapture?

    // macOS virtual key codes -> TV keys.
    private static let map: [UInt16: Key] = [
        126: .up, 125: .down, 123: .left, 124: .right,
        36: .ok, 76: .ok,                 // Return, keypad Enter
        53: .back, 51: .back,             // Esc, Delete
        4: .home,                         // H
        46: .menu,                        // M
        49: .playPause,                   // Space
        24: .volUp, 27: .volDown,         // = -
        41: .mute,                        // ;
        1: .source,                       // S
        34: .info,                        // I
    ]

    func install(link: AdbLink) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            guard let self else { return event }
            // Let text fields keep their keys.
            if let responder = event.window?.firstResponder, responder is NSText { return event }
            if event.modifierFlags.contains(.command) { return event }
            // Esc first releases a captured pointer rather than pressing Back.
            if event.keyCode == 53, let capture = self.capture, capture.active {
                if event.type == .keyDown { capture.end(link: link) }
                return nil
            }
            guard let key = Self.map[event.keyCode] else { return event }
            if event.type == .keyDown {
                if event.isARepeat { return nil } // the TV generates its own repeats while held
                self.held.insert(event.keyCode)
                link.key(key, down: true)
            } else {
                if self.held.remove(event.keyCode) != nil { link.key(key, down: false) }
            }
            return nil
        }
    }
}

// MARK: - UI

struct HoldButton<Label: View>: View {
    let key: Key
    @ObservedObject var link: AdbLink
    var diameter: CGFloat = 52
    var tint: Color = Color(white: 0.22)
    @ViewBuilder var label: () -> Label
    @State private var pressed = false

    var body: some View {
        label()
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: diameter, height: diameter)
            .background(Circle().fill(pressed ? tint.opacity(0.55) : tint))
            .scaleEffect(pressed ? 0.92 : 1)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressed { pressed = true; link.key(key, down: true) }
                    }
                    .onEnded { _ in
                        pressed = false
                        link.key(key, down: false)
                    }
            )
            .animation(.easeOut(duration: 0.08), value: pressed)
    }
}

struct RemoteView: View {
    @ObservedObject var link: AdbLink
    @ObservedObject var capture: PointerCapture
    @ObservedObject var finder: TVFinder
    @State private var text = ""
    @State private var showNumbers = false
    @AppStorage("onTop") private var onTop = true

    var body: some View {
        VStack(spacing: 16) {
            header

            HStack(spacing: 18) {
                HoldButton(key: .power, link: link, tint: Color(red: 0.6, green: 0.15, blue: 0.15)) {
                    Image(systemName: "power")
                }
                HoldButton(key: .source, link: link) { Image(systemName: "rectangle.on.rectangle") }
                HoldButton(key: .pictureMode, link: link) { Image(systemName: "photo") }
                HoldButton(key: .mute, link: link) { Image(systemName: "speaker.slash.fill") }
            }

            dpad

            HStack(spacing: 18) {
                HoldButton(key: .back, link: link) { Image(systemName: "arrow.uturn.backward") }
                HoldButton(key: .home, link: link) { Image(systemName: "house.fill") }
                HoldButton(key: .menu, link: link) { Image(systemName: "line.3.horizontal") }
                Button { link.openSettings() } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color(white: 0.22)))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 18) {
                VStack(spacing: 10) {
                    HoldButton(key: .volUp, link: link) { Image(systemName: "plus") }
                    Text("VOL").font(.caption2).foregroundColor(.gray)
                    HoldButton(key: .volDown, link: link) { Image(systemName: "minus") }
                }
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        HoldButton(key: .rewind, link: link, diameter: 44) { Image(systemName: "backward.fill") }
                        HoldButton(key: .playPause, link: link, diameter: 44) { Image(systemName: "playpause.fill") }
                        HoldButton(key: .fastForward, link: link, diameter: 44) { Image(systemName: "forward.fill") }
                    }
                    HStack(spacing: 12) {
                        HoldButton(key: .previous, link: link, diameter: 44) { Image(systemName: "backward.end.fill") }
                        HoldButton(key: .stop, link: link, diameter: 44) { Image(systemName: "stop.fill") }
                        HoldButton(key: .next, link: link, diameter: 44) { Image(systemName: "forward.end.fill") }
                    }
                }
            }

            TrackpadView(link: link, capture: capture)

            DisclosureGroup(isExpanded: $showNumbers) { numberPad } label: {
                Text("Numbers").font(.caption).foregroundColor(.gray)
            }
            .frame(width: 250)

            HStack {
                TextField("Type on TV…", text: $text, onCommit: sendText)
                    .textFieldStyle(.roundedBorder)
                Button("Send", action: sendText).disabled(text.isEmpty || !link.isConnected)
            }
            .frame(width: 260)

            Text("Arrows · Return OK · Esc Back · H Home · M Menu · Space Play · = / − Vol · ; Mute · S Source")
                .font(.system(size: 9))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
                .frame(width: 260)
        }
        .padding(20)
        .frame(width: 300)
        .background(Color(white: 0.09))
        .onAppear { applyOnTop() }
        .onChange(of: onTop) { _ in applyOnTop() }
    }

    private var header: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).font(.caption).foregroundColor(.gray).lineLimit(1)
                Spacer()
                Toggle("On top", isOn: $onTop).toggleStyle(.checkbox).font(.caption)
            }
            HStack {
                TextField("TV IP, e.g. 192.168.1.50", text: $link.serial, onCommit: link.connect)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Button(link.isConnected ? "Reconnect" : "Connect", action: link.connect)
                    .disabled(link.serial.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack(spacing: 8) {
                Button(finder.scanning ? "Scanning…" : "Find TV") { finder.scan() }
                    .disabled(finder.scanning)
                if finder.scanning { ProgressView().controlSize(.small) }
                Text(finder.message)
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            ForEach(finder.found) { tv in
                Button {
                    link.serial = tv.serial
                    link.connect()
                } label: {
                    HStack {
                        Image(systemName: link.serial == tv.serial ? "checkmark.circle.fill" : "tv")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(tv.name).font(.caption).lineLimit(1)
                            Text(tv.serial).font(.system(size: 10, design: .monospaced)).foregroundColor(.gray)
                        }
                        Spacer()
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(white: 0.16)))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 260)
    }

    private var dpad: some View {
        ZStack {
            Circle().fill(Color(white: 0.16)).frame(width: 190, height: 190)
            VStack(spacing: 4) {
                HoldButton(key: .up, link: link, tint: .clear) { Image(systemName: "chevron.up") }
                HStack(spacing: 4) {
                    HoldButton(key: .left, link: link, tint: .clear) { Image(systemName: "chevron.left") }
                    HoldButton(key: .ok, link: link, diameter: 66, tint: Color(white: 0.3)) { Text("OK") }
                    HoldButton(key: .right, link: link, tint: .clear) { Image(systemName: "chevron.right") }
                }
                HoldButton(key: .down, link: link, tint: .clear) { Image(systemName: "chevron.down") }
            }
        }
    }

    private var numberPad: some View {
        let rows: [[Key]] = [[.d1, .d2, .d3], [.d4, .d5, .d6], [.d7, .d8, .d9], [.info, .d0, .del]]
        return VStack(spacing: 8) {
            ForEach(0..<rows.count, id: \.self) { r in
                HStack(spacing: 14) {
                    ForEach(rows[r], id: \.self) { k in
                        HoldButton(key: k, link: link, diameter: 40) { Text(label(for: k)).font(.system(size: 15)) }
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    private func label(for k: Key) -> String {
        switch k {
        case .info: return "i"
        case .del: return "⌫"
        default: return String(describing: k).replacingOccurrences(of: "d", with: "")
        }
    }

    private var statusColor: Color {
        switch link.state {
        case .connected: return .green
        case .connecting: return .yellow
        case .failed: return .red
        case .disconnected: return .gray
        }
    }

    private var statusText: String {
        switch link.state {
        case .connected(let dev): return "Connected · \(dev.replacingOccurrences(of: "/dev/input/", with: ""))"
        case .connecting: return "Connecting…"
        case .failed(let why): return why
        case .disconnected: return "Not connected"
        }
    }

    private func sendText() {
        link.type(text)
        text = ""
    }

    private func applyOnTop() {
        DispatchQueue.main.async {
            NSApp.windows.first?.level = onTop ? .floating : .normal
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) {
        CGAssociateMouseAndMouseCursorPosition(1) // never leave the Mac pointer frozen
    }
}

@main
struct TVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var link = AdbLink()
    @StateObject private var capture = PointerCapture()
    @StateObject private var finder = TVFinder()
    private let keyboard = KeyboardBridge()

    init() {
        signal(SIGPIPE, SIG_IGN) // a dropped adb pipe must not kill the app
    }

    var body: some Scene {
        WindowGroup("TV Remote") {
            RemoteView(link: link, capture: capture, finder: finder)
                .preferredColorScheme(.dark)
                .onAppear {
                    keyboard.capture = capture
                    keyboard.install(link: link)
                    if link.serial.isEmpty {
                        // First run: look for the TV and pick it if it's the only one.
                        finder.scan { found in
                            if found.count == 1 { link.serial = found[0].serial; link.connect() }
                        }
                    } else {
                        link.connect()
                    }
                }
        }
        .windowResizability(.contentSize)
    }
}

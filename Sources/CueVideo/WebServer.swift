import Foundation
import Network
import ImageIO
import CoreGraphics
import Combine
import CueATEM

/// A web page for an iPad (or any browser on the same network) that runs the booth while the
/// Mac is used for other things. Off until turned on in Setup. It listens on port 9912, and
/// everything except the page itself needs a login: a 6 digit PIN, shown in Setup, which
/// trades for a session key.
///
///     GET  /                the page
///     POST /api/login       {"pin": "123456"}   returns {"token": ...}
///     GET  /api/state       what's Live and Next, the sources, cameras, shots, keys
///     POST /api/do          {"action": "cut" | "fade" | "black" | "next" | "drive" ...}
///     GET  /api/picture     ?input=N&w=640   a JPEG of that input's picture
///
/// Requests carry the session key in an x-token header. Actions go through the same tools
/// Claude uses (ControlTools), so they keep the same safeguards, such as refusing to move the
/// camera that's on Live. Only a small set of actions is allowed: nothing here can change the
/// setup. HTTP only, so use it on a network you trust.
final class WebServer: ObservableObject {
    static let shared = WebServer()
    static let port: UInt16 = 9912

    @Published private(set) var running = false
    @Published private(set) var problem: String?
    @Published private(set) var pin = ""

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "cuevideo.web")
    // Only touched on `queue`.
    private var tokens: [String] = []
    private var failures = 0
    private var lockedUntil = Date.distantPast
    // Only touched on the main thread.
    private var held: [Int: (picture: CameraPicture, last: Date)] = [:]
    private var holdTimer: Timer?
    private var watchdog: DispatchWorkItem?
    private var driven: UUID?
    /// Held while serving, so macOS doesn't slow the app down (App Nap) or sleep the Mac while it's
    /// covered by other windows and an iPad is running the booth.
    private var activity: NSObjectProtocol?

    static var pinURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CueVideo", isDirectory: true).appendingPathComponent("web-pin")
    }

    // MARK: On and off

    /// Called when the setting changes. Main thread.
    func setEnabled(_ on: Bool) {
        if on, listener == nil { start() }
        if !on, listener != nil { stop() }
    }

    private func start() {
        let code = Self.loadOrMakePIN()
        pin = code
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            l.newConnectionHandler = { [weak self] c in self?.serve(c) }
            l.stateUpdateHandler = { [weak self] s in
                DispatchQueue.main.async {
                    switch s {
                    case .ready: self?.running = true; self?.problem = nil
                    case .failed(let e): self?.running = false; self?.problem = "Couldn't start: \(e.localizedDescription)"
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Churchfront Video is running the booth for another device")
        } catch {
            problem = "Couldn't start: \(error.localizedDescription)"
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        running = false
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
        queue.async { self.tokens.removeAll() }
        stopAll()
        for (_, h) in held { h.picture.release() }
        held.removeAll()
        holdTimer?.invalidate(); holdTimer = nil
    }

    /// A new PIN. Everyone logged in has to log in again.
    func newPIN() {
        let code = Self.makePIN()
        try? Data(code.utf8).write(to: Self.pinURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.pinURL.path)
        pin = code
        queue.async { self.tokens.removeAll() }
    }

    private static func loadOrMakePIN() -> String {
        if let t = try? String(contentsOf: pinURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           t.count == 6, t.allSatisfy(\.isNumber) { return t }
        let code = makePIN()
        try? FileManager.default.createDirectory(at: pinURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: pinURL.path, contents: Data(code.utf8), attributes: [.posixPermissions: 0o600])
        return code
    }

    private static func makePIN() -> String {
        var n: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &n)
        return String(format: "%06d", Int(n % 1_000_000))
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// This Mac's addresses on the network, for showing where to point the iPad.
    static func addresses() -> [String] {
        var out: [String] = []
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return [] }
        defer { freeifaddrs(first) }
        for p in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let i = p.pointee
            guard let sa = i.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (i.ifa_flags & UInt32(IFF_UP)) != 0, (i.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                out.append(String(cString: host))
            }
        }
        return out
    }

    // MARK: HTTP

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ got: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = got
            if let data { buf.append(data) }
            if let req = ControlServer.parse(buf) {
                // HTTP/1.1 keeps the connection for the next request unless told otherwise, so a button
                // press doesn't pay for a new connection each time.
                let keep = req.headers["connection"]?.lowercased() != "close"
                self.handle(req, c) { status, type, body in self.reply(c, status, type, body, keepAlive: keep) }
            } else if done || err != nil || buf.count > 1 << 20 {
                c.cancel()
            } else {
                self.receive(c, buf)
            }
        }
    }

    private func reply(_ c: NWConnection, _ status: Int, _ type: String, _ body: Data, keepAlive: Bool) {
        let text = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 429: "Too Many Requests"][status] ?? "OK"
        let head = "HTTP/1.1 \(status) \(text)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] error in
            if keepAlive, error == nil { self?.receive(c, Data()) } else { c.cancel() }
        })
    }

    private func json(_ done: @escaping (Int, String, Data) -> Void, _ status: Int, _ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        done(status, "application/json; charset=utf-8", data)
    }

    private func handle(_ r: ControlServer.Request, _ c: NWConnection, _ done: @escaping (Int, String, Data) -> Void) {
        let comps = URLComponents(string: "http://x" + r.path)
        let path = comps?.path ?? r.path
        let query = Dictionary((comps?.queryItems ?? []).compactMap { q in q.value.map { (q.name, $0) } }, uniquingKeysWith: { first, _ in first })

        switch (r.method, path) {
        case ("GET", "/"), ("GET", "/index.html"):
            done(200, "text/html; charset=utf-8", Data(WebUI.page.utf8)); return
        case ("GET", "/favicon.ico"):
            done(204, "text/plain", Data()); return
        case ("POST", "/api/login"):
            login(r, done); return
        default: break
        }

        guard path.hasPrefix("/api/") else { json(done, 404, ["error": "Not found."]); return }
        // A picture in an <img> can't send headers, so those two endpoints also take the key in the address.
        let fromAddress = path == "/api/stream" || path == "/api/picture"
        guard let t = r.headers["x-token"] ?? (fromAddress ? query["t"] : nil), tokens.contains(t) else {
            json(done, 401, ["error": "Log in with the PIN."]); return
        }

        switch (r.method, path) {
        case ("GET", "/api/state"):
            DispatchQueue.main.async { self.json(done, 200, self.stateObject()) }
        case ("POST", "/api/do"):
            guard let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else {
                json(done, 400, ["error": "Send a JSON action."]); return
            }
            DispatchQueue.main.async { self.perform(obj) { result in self.json(done, 200, result) } }
        case ("GET", "/api/picture"):
            let input = Int(query["input"] ?? "") ?? -1
            let width = min(1280, max(80, Int(query["w"] ?? "") ?? 640))
            DispatchQueue.main.async {
                let image = self.pictureImage(input)
                // Encoding is off this server's queue, so a picture never makes a button wait.
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let image, let jpeg = Self.jpeg(image, maxWidth: width, quality: 0.6) else { done(204, "text/plain", Data()); return }
                    done(200, "image/jpeg", jpeg)
                }
            }
        case ("GET", "/api/stream"):
            let input = Int(query["input"] ?? "") ?? -1
            let width = min(1280, max(80, Int(query["w"] ?? "") ?? 640))
            let fps = min(30, max(2, Double(query["fps"] ?? "") ?? 12))
            DispatchQueue.main.async { self.serveStream(c, input: input, width: width, fps: fps) }
        default:
            json(done, 404, ["error": "Not found."])
        }
    }

    private func login(_ r: ControlServer.Request, _ done: @escaping (Int, String, Data) -> Void) {
        if Date() < lockedUntil { json(done, 429, ["error": "Too many wrong tries. Wait 30 seconds."]); return }
        let given = ((try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any])?["pin"] as? String ?? ""
        let right = DispatchQueue.main.sync { self.pin }
        if !right.isEmpty, given.trimmingCharacters(in: .whitespaces) == right {
            failures = 0
            let token = Self.makeToken()
            tokens.append(token)
            if tokens.count > 40 { tokens.removeFirst(tokens.count - 40) }
            json(done, 200, ["token": token])
        } else {
            failures += 1
            if failures >= 5 { failures = 0; lockedUntil = Date().addingTimeInterval(30) }
            json(done, 401, ["error": "That PIN isn't right."])
        }
    }

    // MARK: State (main thread)

    private func stateObject() -> [String: Any] {
        let b = Booth.shared
        let s = b.atem.state, store = b.store
        let me = b.me
        func src(_ i: Int?) -> Any { i.map { ["input": $0, "name": store.label($0, s)] as [String: Any] } ?? NSNull() }
        let link: String
        switch b.atem.link {
        case .online: link = "online"
        case .connecting: link = "connecting"
        case .offline(let why): link = "offline: \(why)"
        case .idle: link = "not set up"
        }
        let live = s.program[me], next = s.preview[me]
        let sources = store.volunteerSources(s).map { v -> [String: Any] in
            ["input": v.input, "label": store.label(v.input, s), "live": v.input == live, "next": v.input == next,
             "picture": picture(for: v.input) != nil]
        }
        let cameras = b.ptz.cameras.map { c -> [String: Any] in
            let t = AutoTracker.shared.sessions[c.id]
            return ["id": c.id.uuidString, "name": c.name, "input": c.atemInput.map { $0 as Any } ?? NSNull(),
                    "onNext": c.atemInput != nil && c.atemInput == next, "onLive": c.atemInput != nil && c.atemInput == live,
                    "answering": b.ptz.online.contains(c.id), "shots": c.shots.map(\.name),
                    "tracking": t != nil, "trackState": t?.phase.rawValue ?? "", "trackShot": t?.size.rawValue ?? ""]
        }
        return [
            "link": link, "model": s.product, "live": src(live), "next": src(next),
            "transition": s.inTransition[me] ?? false, "black": s.ftbBlack[me] ?? false,
            "streaming": s.hasStreaming ? s.streaming as Any : NSNull(), "streamConnecting": s.streamConnecting,
            "recording": s.hasRecording ? s.recording as Any : NSNull(),
            "sources": sources, "cameras": cameras,
            "keys": store.config.keys.map { ["label": $0.label, "on": $0.isOn(s)] as [String: Any] },
            "shotSizes": ShotSize.allCases.map(\.rawValue),
        ]
    }

    // MARK: Picture streams (main thread)

    /// State of one open picture stream. Only touched on the main thread.
    private final class PictureStream {
        var inFlight = false
        var closed = false
        var lastID: ObjectIdentifier?
        var timer: DispatchSourceTimer?
    }

    /// A picture that keeps coming: multipart/x-mixed-replace, which a browser shows in a plain <img>.
    /// A new frame goes out only when the picture has changed and the last one has been sent, so a slow
    /// network skips frames instead of building up a delay.
    private func serveStream(_ c: NWConnection, input: Int, width: Int, fps: Double) {
        guard picture(for: input) != nil else {
            reply(c, 204, "text/plain", Data(), keepAlive: false); return
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nPragma: no-cache\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let st = PictureStream()
        func close() {
            st.closed = true
            st.timer?.cancel(); st.timer = nil
            c.cancel()
        }
        // The browser leaving shows up as a read finishing or failing.
        c.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, done, err in
            if done || err != nil { DispatchQueue.main.async { close() } }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / fps)
        timer.setEventHandler { [weak self] in
            guard let self, !st.closed, !st.inFlight, let img = self.pictureImage(input) else { return }
            let id = ObjectIdentifier(img)
            if id == st.lastID { return }
            st.lastID = id
            st.inFlight = true
            DispatchQueue.global(qos: .userInitiated).async {
                guard let jpeg = Self.jpeg(img, maxWidth: width, quality: 0.6) else {
                    DispatchQueue.main.async { st.inFlight = false }; return
                }
                var part = Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
                part.append(jpeg)
                part.append(Data("\r\n".utf8))
                c.send(content: part, completion: .contentProcessed { error in
                    DispatchQueue.main.async {
                        st.inFlight = false
                        if error != nil { close() }
                    }
                })
            }
        }
        st.timer = timer
        timer.resume()
    }

    // MARK: Pictures (main thread)

    /// The picture for a switcher input: its camera's, or the NDI picture set for it.
    private func picture(for input: Int) -> CameraPicture? {
        let b = Booth.shared
        if let cam = b.ptz.cameras.first(where: { $0.atemInput == input }), let p = CameraPicture.of(cam, b.store) { return p }
        return b.store.ndi(input).map { CameraPicture.ndi($0) }
    }

    /// The latest frame. Keeps that input's feed running while the web page is looking, and lets go
    /// of it a few seconds after it stops, so the Mac doesn't decode pictures nobody is watching.
    private func pictureImage(_ input: Int) -> CGImage? {
        guard let p = picture(for: input) else { return nil }
        if held[input] == nil { p.retain() }
        held[input] = (p, Date())
        if holdTimer == nil {
            holdTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.releaseIdle() }
        }
        return p.liveImage
    }

    private func releaseIdle() {
        let cutoff = Date().addingTimeInterval(-8)
        for (input, h) in held where h.last < cutoff {
            h.picture.release()
            held[input] = nil
        }
        if held.isEmpty { holdTimer?.invalidate(); holdTimer = nil }
    }

    /// Always redraws into an opaque RGB picture: JPEG has no alpha, and NDI pictures can.
    private static func jpeg(_ img: CGImage, maxWidth: Int, quality: Double) -> Data? {
        let w = min(maxWidth, img.width)
        let h = max(1, img.height * w / max(1, img.width))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    // MARK: Actions (main thread)

    private func camera(_ id: Any?) -> PTZCamera? {
        guard let s = id as? String else { return nil }
        return Booth.shared.ptz.cameras.first { $0.id.uuidString == s }
    }

    /// How the tools name a camera: by address when it has one, else by name.
    private func toolName(_ c: PTZCamera) -> String { c.host.isEmpty ? c.name : c.host }

    private func number(_ v: Any?) -> Double { (v as? Double) ?? (v as? Int).map(Double.init) ?? 0 }

    private func perform(_ a: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        func tool(_ name: String, _ args: [String: Any] = [:]) { ControlTools.call(name, args) { done($0) } }
        let b = Booth.shared
        switch a["action"] as? String ?? "" {
        case "next":
            guard let i = a["input"] else { done(["error": "Which source?"]); return }
            tool("set_next", ["source": i])
        case "cut": tool("cut")
        case "fade": tool("fade")
        case "black": tool("fade_to_black")
        case "stream":
            guard let on = a["on"] as? Bool else { done(["error": "Say on or off."]); return }
            tool("set_streaming", ["on": on])
        case "record":
            guard let on = a["on"] as? Bool else { done(["error": "Say on or off."]); return }
            tool("set_recording", ["on": on])
        case "key":
            guard let name = a["button"] as? String else { done(["error": "Which button?"]); return }
            var args: [String: Any] = ["button": name]
            if let on = a["on"] as? Bool { args["on"] = on }
            tool("set_key_button", args)

        case "shot", "home", "focus", "track", "untrack":
            guard let c = camera(a["camera"]) else { done(["error": "No such camera."]); return }
            switch a["action"] as? String {
            case "shot": tool("recall_shot", ["camera": toolName(c), "shot": a["shot"] ?? ""])
            case "home": tool("camera_home", ["camera": toolName(c)])
            case "focus": tool("camera_focus", ["camera": toolName(c), "mode": "once"])
            case "track":
                var args: [String: Any] = ["camera": toolName(c)]
                if let shot = a["shot"] as? String { args["shot"] = shot }
                tool("start_tracking", args)
            default: tool("stop_tracking", ["camera": toolName(c)])
            }

        case "drive", "zoom":
            // Like the joystick on the Mac: only the camera on Next moves. Held movement is kept
            // alive by repeated messages; if they stop (the iPad lost its connection, the page
            // closed) the camera is stopped within a moment.
            guard let c = camera(a["camera"]), c.atemInput != nil, c.atemInput == b.atem.state.preview[b.me] else {
                stopAll(); done(["error": "Only the camera on Next can be moved."]); return
            }
            if a["action"] as? String == "drive" {
                let x = max(-1, min(1, number(a["x"]))), y = max(-1, min(1, number(a["y"])))
                if x == 0 && y == 0 { b.ptz.stopDrive(camera: c.id) } else { b.ptz.drive(x: x, y: y, camera: c.id) }
            } else {
                b.ptz.zoom(max(-1, min(1, number(a["speed"]))), camera: c.id)
            }
            arm(c.id)
            done(["ok": true])
        case "stopcam":
            stopAll()
            done(["ok": true])
        default:
            done(["error": "That isn't something the web page can do."])
        }
    }

    private func arm(_ id: UUID) {
        driven = id
        watchdog?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.stopAll() }
        watchdog = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }

    private func stopAll() {
        watchdog?.cancel()
        watchdog = nil
        if let id = driven {
            Booth.shared.ptz.stopDrive(camera: id)
            Booth.shared.ptz.zoom(0, camera: id)
        }
        driven = nil
    }
}

// matte-fill: while an app is full screen on a target display (the built-in one by default), paints
// every pure-black area outside the app's content (the camera-housing band and letterbox/pillarbox
// bars) with a muted color derived from the content itself.
import Cocoa
import ScreenCaptureKit
import CoreImage

// MARK: - Config

struct Config: Codable {
    var fallbackColor = "#3A3733"      // used when adaptive sampling is unavailable
    var adaptive = true
    var coverBars = true               // letterbox / pillarbox detection
    var minLightness = 0.34            // OKLCH L range of the fill
    var maxLightness = 0.56
    var maxChroma = 0.05               // keeps the tint muted
    var smoothingSeconds = 1.2
    var sampleFPS = 10.0
    var displays = "builtin"           // "builtin": only the MacBook's own display; "all": every display

    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/matte-fill")
    static let stateFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/matte-fill/state.json")

    static let file = dir.appendingPathComponent("config.json")
    static let iinaData = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.colliderli.iina/plugins/.data/io.github.matte-fill")

    static func load() -> Config {
        let url = file
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do { return try JSONDecoder().decode(Config.self, from: data) }
        catch { NSLog("matte-fill: bad config.json (\(error)), using defaults"); return Config() }
    }
}

extension Config {
    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fallbackColor = try c.decodeIfPresent(String.self, forKey: .fallbackColor) ?? fallbackColor
        adaptive = try c.decodeIfPresent(Bool.self, forKey: .adaptive) ?? adaptive
        coverBars = try c.decodeIfPresent(Bool.self, forKey: .coverBars) ?? coverBars
        minLightness = try c.decodeIfPresent(Double.self, forKey: .minLightness) ?? minLightness
        maxLightness = try c.decodeIfPresent(Double.self, forKey: .maxLightness) ?? maxLightness
        maxChroma = try c.decodeIfPresent(Double.self, forKey: .maxChroma) ?? maxChroma
        smoothingSeconds = try c.decodeIfPresent(Double.self, forKey: .smoothingSeconds) ?? smoothingSeconds
        sampleFPS = try c.decodeIfPresent(Double.self, forKey: .sampleFPS) ?? sampleFPS
        displays = try c.decodeIfPresent(String.self, forKey: .displays) ?? displays
    }
}

// MARK: - OKLab color math

struct OKLab { var L: Double, a: Double, b: Double }

enum ColorMath {
    static func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    static func gam(_ c: Double) -> Double { c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055 }

    static func toOKLab(r: Double, g: Double, b: Double) -> OKLab {
        let (r, g, b) = (lin(r), lin(g), lin(b))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return OKLab(L: 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     a: 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     b: 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func toSRGB(_ c: OKLab) -> (Double, Double, Double) {
        let l = pow(c.L + 0.3963377774 * c.a + 0.2158037573 * c.b, 3)
        let m = pow(c.L - 0.1055613458 * c.a - 0.0638541728 * c.b, 3)
        let s = pow(c.L - 0.0894841775 * c.a - 1.2914855480 * c.b, 3)
        let f = { (x: Double) in min(1, max(0, gam(x))) }
        return (f(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                f(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                f(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    static func hex(_ c: OKLab) -> String {
        let (r, g, b) = toSRGB(c)
        return String(format: "#%02X%02X%02X", Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
    }

    static func fromHex(_ s: String) -> OKLab {
        let v = UInt32(s.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x3A3733
        return toOKLab(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    static func cgColor(_ c: OKLab) -> CGColor {
        let (r, g, b) = toSRGB(c)
        return CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    static func distance(_ x: OKLab, _ y: OKLab) -> Double {
        sqrt(pow(x.L - y.L, 2) + pow(x.a - y.a, 2) + pow(x.b - y.b, 2))
    }
}

// Weighted OKLab mean of the content pixels; rows near the top edge count 3x, hue from the
// chroma-weighted mean so vivid regions set the mood without dominating.
enum Palette {
    static func color(_ p: UnsafePointer<UInt8>, stride: Int, x: Range<Int>, y: Range<Int>, step: Int, cfg: Config,
                      skip: (Int, Int) -> Bool) -> OKLab? {
        guard !x.isEmpty, !y.isEmpty else { return nil }
        let nearEdge = y.lowerBound + max(1, y.count / 4)
        var sw = 0.0, sL = 0.0, sC = 0.0, ha = 0.0, hb = 0.0, n = 0
        for yy in Swift.stride(from: y.lowerBound, to: y.upperBound, by: step) {
            let rowW = yy < nearEdge ? 3.0 : 1.0
            for xx in Swift.stride(from: x.lowerBound, to: x.upperBound, by: step) where !skip(xx, yy) {
                let o = yy * stride + xx * 4
                let c = ColorMath.toOKLab(r: Double(p[o + 2]) / 255, g: Double(p[o + 1]) / 255, b: Double(p[o]) / 255)
                let C = hypot(c.a, c.b)
                sw += rowW; sL += c.L * rowW; sC += C * rowW
                ha += c.a * C * rowW; hb += c.b * C * rowW; n += 1
            }
        }
        guard n > 50 else { return nil }
        let meanL = sL / sw, meanC = sC / sw
        let L = min(cfg.maxLightness, max(cfg.minLightness, 0.26 + 0.45 * meanL))
        let C = min(cfg.maxChroma, 0.55 * meanC + 0.006)
        let hue = meanC < 0.012 ? 75.0 * .pi / 180 : atan2(hb, ha)   // near-neutral -> warm graphite
        return OKLab(L: L, a: C * cos(hue), b: C * sin(hue))
    }
}

// MARK: - Display & full-screen detection

@_silgen_name("CGSMainConnectionID") func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces") func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> CFArray?

enum Display {
    static func targetScreens(_ cfg: Config) -> [NSScreen] {
        cfg.displays == "all" ? NSScreen.screens : NSScreen.screens.filter { CGDisplayIsBuiltin(id(of: $0)) != 0 }
    }

    static func id(of screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // Owner pid + window number of a layer-0 window that fills the display below the camera housing
    // (the whole display where there is none), which is what a native full-screen window looks like.
    static func fullScreenWindowKey(_ screen: NSScreen) -> String? {
        let b = CGDisplayBounds(id(of: screen))
        let top = screen.safeAreaInsets.top
        let want = CGRect(x: b.minX, y: b.minY + top, width: b.width, height: b.height - top).integral
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd), r.integral == want else { continue }
            return "\(w[kCGWindowOwnerPID as String] ?? 0):\(w[kCGWindowNumber as String] ?? 0)"
        }
        return nil
    }

    // A native full-screen Space (type 4) is current on the display, or a window outside the
    // normal layer (e.g. IINA legacy full screen) covers the whole display.
    static func fullScreenSpaceCount(_ screen: NSScreen) -> Int {
        let did = id(of: screen)
        let uuid = CGDisplayCreateUUIDFromDisplayID(did).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        let spaces = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        for d in spaces {
            let ident = d["Display Identifier"] as? String ?? ""
            guard ident.caseInsensitiveCompare(uuid) == .orderedSame || (ident == "Main" && (spaces.count == 1 || CGMainDisplayID() == did)) else { continue }
            return (d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 4 }.count
        }
        return 0
    }

    static func fullScreenReason(_ screen: NSScreen) -> String? {
        let did = id(of: screen)
        let uuid = CGDisplayCreateUUIDFromDisplayID(did).map {
            CFUUIDCreateString(nil, $0.takeRetainedValue()) as String
        } ?? ""
        if let spaces = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] {
            for d in spaces {
                let ident = d["Display Identifier"] as? String ?? ""
                let matches = ident.caseInsensitiveCompare(uuid) == .orderedSame
                    || (ident == "Main" && (spaces.count == 1 || CGMainDisplayID() == did))
                if matches, let cur = d["Current Space"] as? [String: Any], (cur["type"] as? Int) == 4 {
                    return "native full-screen space"
                }
            }
        }
        if let k = fullScreenWindowKey(screen) { return "full-screen window \(k)" }
        let bounds = CGDisplayBounds(did)
        let me = ProcessInfo.processInfo.processIdentifier
        let skip: Set<String> = ["Dock", "Window Server", "WindowManager", "Control Center", "screencaptureui"]
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard (1...19).contains(layer),
                  (w[kCGWindowOwnerPID as String] as? Int32) != me,
                  !skip.contains(w[kCGWindowOwnerName as String] as? String ?? ""),
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if r.integral == bounds.integral { return "window of \(w[kCGWindowOwnerName as String] ?? "?") at layer \(layer)" }
        }
        return nil
    }
}

// MARK: - Overlay

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Without this AppKit pushes the window below the menu-bar area, i.e. off the notch band.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class OverlayView: NSView {
    private let shape = CAShapeLayer()
    private let band = CALayer()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer!.addSublayer(shape)
        shape.frame = bounds
        shape.actions = ["path": NSNull(), "fillColor": NSNull()]
        band.actions = ["backgroundColor": NSNull(), "frame": NSNull()]
        layer!.addSublayer(band)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setRects(_ rects: [CGRect]) {
        let p = CGMutablePath()
        p.addRects(rects)
        shape.path = p

    }

    func setColor(_ c: OKLab) { shape.fillColor = ColorMath.cgColor(c); band.backgroundColor = shape.fillColor }

    func setBand(_ r: CGRect) { band.frame = r }

    func setBandVisible(_ v: Bool) {
        guard (band.opacity > 0.5) != v else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
        band.opacity = v ? 1 : 0
        CATransaction.commit()
    }
}

// MARK: - Sampler: content color + black-bar geometry

struct Analysis {
    var color: OKLab?
    var rects: [CGRect]   // bar areas in screen points, top-left origin, subtitle holes already cut out
}

final class Sampler: NSObject, SCStreamOutput, SCStreamDelegate {
    var onAnalysis: ((Analysis) -> Void)?
    var onLost: (() -> Void)?
    private let queue = DispatchQueue(label: "matte-fill.sample")
    private let cfg: Config
    private let bandFraction: Double
    private let screenSize: CGSize

    // Bar state, only touched on `queue`.
    private var est = [0, 0, 0, 0]            // top, bottom, left, right (sample px)
    private var cand = [(0, 0.0), (0, 0.0)]   // (extent, since) for vertical and horizontal pairs
    private var lastSeen: [Double] = []
    private var frameNo = 0
    var tintBytes = (-100, -100, -100)
    var barsEnabled = true
    private var display: SCDisplay?
    private var startedAt = 0.0
    private var dbgStrict: [Int] = [], dbgLoose: [Int] = []

    init(cfg: Config, bandFraction: Double, screenSize: CGSize) {
        self.cfg = cfg
        self.bandFraction = bandFraction
        self.screenSize = screenSize
    }

    private var prepared: SCStream?
    private var running = false

    // Build the stream ahead of time so entering full screen only has to call startCapture.
    func prepare(displayID: CGDirectDisplayID, excludeWindowID: CGWindowID) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, err in
            guard let self, let content, let display = content.displays.first(where: { $0.displayID == displayID }) else {
                NSLog("matte-fill: capture unavailable (\(err?.localizedDescription ?? "no display")), using fallback color")
                return
            }
            let pid = ProcessInfo.processInfo.processIdentifier
            let mine = content.windows.filter { $0.windowID == excludeWindowID || $0.owningApplication?.processID == pid }
            if mine.isEmpty { NSLog("matte-fill: own overlay window not found in shareable content") }
            let filter = SCContentFilter(display: display, excludingWindows: mine)
            self.display = display
            let conf = SCStreamConfiguration()
            conf.width = display.width / 2
            conf.height = display.height / 2
            conf.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, self.cfg.sampleFPS)))
            conf.pixelFormat = kCVPixelFormatType_32BGRA
            conf.colorSpaceName = CGColorSpace.sRGB
            conf.showsCursor = false
            conf.queueDepth = 3
            let s = SCStream(filter: filter, configuration: conf, delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                DispatchQueue.main.async {
                    self.prepared = s
                    if self.running { s.startCapture { e in if let e { NSLog("matte-fill: startCapture failed: \(e)") } } }
                }
            } catch { NSLog("matte-fill: addStreamOutput failed: \(error)") }
        }
    }

    // Restrict sampling to the full-screen app so system HUDs and other apps never enter the analysis.
    func focus(pid: pid_t) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let self, let content, let display = self.display,
                  let app = content.applications.first(where: { $0.processID == pid }) else { return }
            let f = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            DispatchQueue.main.async { self.prepared?.updateContentFilter(f) { e in if let e { NSLog("matte-fill: focus failed: \(e)") } } }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        prepared?.startCapture { e in if let e { NSLog("matte-fill: startCapture failed: \(e)") } }
    }

    func stop() {
        if running { prepared?.stopCapture { _ in } }
        running = false
        queue.async { self.est = [0, 0, 0, 0]; self.cand = [(0, 0), (0, 0)]; self.frameNo = 0; self.startedAt = 0 }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("matte-fill: stream stopped: \(error)")
        DispatchQueue.main.async { self.running = false; self.prepared = nil; self.onLost?() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb) else { return }
        if startedAt == 0 { startedAt = CACurrentMediaTime() }
        let a = analyze(px, now: CACurrentMediaTime())
        frameNo += 1
        if frameNo < 30, FileManager.default.fileExists(atPath: Config.dir.appendingPathComponent("debug").path) {
            NSLog("matte-fill: f\(frameNo) t=\(String(format: "%.2f", CACurrentMediaTime() - startedAt)) strict=\(dbgStrict) est=\(est) rects=\(a.rects.count)")
        }
        if frameNo == 25, FileManager.default.fileExists(atPath: Config.dir.appendingPathComponent("debug").path) {
            NSLog("matte-fill: debug w=\(CVPixelBufferGetWidth(px)) h=\(CVPixelBufferGetHeight(px)) strict=\(dbgStrict) loose=\(dbgLoose) est=\(est) cand=\(cand)")
            let ci = CIImage(cvPixelBuffer: px)
            if let cg = CIContext().createCGImage(ci, from: ci.extent) {
                let url = Config.dir.appendingPathComponent("debug-frame.png")
                if let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
                }
            }
        }
        DispatchQueue.main.async { self.onAnalysis?(a) }
    }

    func analyze(_ px: CVPixelBuffer, now: Double) -> Analysis {
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return Analysis(color: nil, rects: []) }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
        let stride = CVPixelBufferGetBytesPerRow(px)
        let p = base.assumingMemoryBound(to: UInt8.self)
        let y0 = min(h - 1, Int(ceil(Double(h) * bandFraction - 1e-6)))
        let (tr, tg, tb) = tintBytes
        @inline(__always) func dark(_ x: Int, _ y: Int) -> Bool {
            let o = y * stride + x * 4
            let b = Int(p[o]), g = Int(p[o + 1]), r = Int(p[o + 2])
            return (b <= 10 && g <= 10 && r <= 10) || (abs(r - tr) <= 6 && abs(g - tg) <= 6 && abs(b - tb) <= 6)
        }

        if cfg.coverBars && barsEnabled { updateBars(w: w, h: h, y0: y0, now: now, dark: dark) }
        else { est = [0, 0, 0, 0] }
        let (t, b, l, r) = (est[0], est[1], est[2], est[3])

        let color = cfg.adaptive
            ? Palette.color(p, stride: stride, x: l..<(w - r), y: (y0 + t)..<(h - b), step: 4, cfg: cfg, skip: dark) : nil

        return Analysis(color: color, rects: barRects(w: w, h: h, y0: y0, now: now))
    }

    // Bars are adopted only when strictly black, symmetric and stable for 1.5 s; once adopted they
    // persist while their rows stay mostly black (so subtitles inside a bar don't drop it) and
    // shrink immediately when real content reaches into them.
    private func updateBars(w: Int, h: Int, y0: Int, now: Double, dark: (Int, Int) -> Bool) {
        if lastSeen.count != w * h { lastSeen = [Double](repeating: 0, count: w * h); est = [0, 0, 0, 0] }
        let ch = h - y0
        var rowFrac = [Double](repeating: 0, count: h)
        for y in y0..<h {
            var k = 0
            var x = 0
            while x < w { if dark(x, y) { k += 1 }; x += 2 }
            rowFrac[y] = Double(k) / Double((w + 1) / 2)
        }
        var colFrac = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var k = 0, m = 0
            var y = y0
            while y < h { if dark(x, y) { k += 1 }; m += 1; y += 2 }
            colFrac[x] = Double(k) / Double(max(1, m))
        }
        func run(_ f: [Double], _ idx: StrideTo<Int>, _ th: Double) -> Int {
            var n = 0
            for i in idx { if f[i] >= th { n += 1 } else { break } }
            return n
        }
        // Extent through mostly-black rows whose innermost row is pure black and at least half of
        // which are pure black, so a subtitle line inside the bar doesn't break detection.
        func barRun(_ f: [Double], _ idx: StrideTo<Int>) -> Int {
            var n = 0, strictN = 0, lastStrict = 0
            for i in idx {
                guard f[i] >= 0.6 else { break }
                n += 1
                if f[i] >= 0.995 { strictN += 1; lastStrict = n }
            }
            return lastStrict > 0 && strictN * 2 >= lastStrict ? lastStrict : 0
        }
        let strict = [barRun(rowFrac, Swift.stride(from: y0, to: h, by: 1)),
                      barRun(rowFrac, Swift.stride(from: h - 1, to: y0 - 1, by: -1)),
                      barRun(colFrac, Swift.stride(from: 0, to: w, by: 1)),
                      barRun(colFrac, Swift.stride(from: w - 1, to: -1, by: -1))]
        let loose = [run(rowFrac, Swift.stride(from: y0, to: h, by: 1), 0.6),
                     run(rowFrac, Swift.stride(from: h - 1, to: y0 - 1, by: -1), 0.6),
                     run(colFrac, Swift.stride(from: 0, to: w, by: 1), 0.6),
                     run(colFrac, Swift.stride(from: w - 1, to: -1, by: -1), 0.6)]
        dbgStrict = strict; dbgLoose = loose
        // Fraction of dark pixels in the row/column at depth k (1-based) from each edge.
        func frac(_ edge: Int, _ k: Int) -> Double {
            switch edge {
            case 0: let y = y0 + k - 1; return y < h ? rowFrac[y] : 0
            case 1: let y = h - k; return y >= y0 ? rowFrac[y] : 0
            case 2: return k - 1 < w ? colFrac[k - 1] : 0
            default: return w - k >= 0 ? colFrac[w - k] : 0
            }
        }
        // A bar edge is where a pure-black row meets non-black content; overlays inside the bar
        // (title bars, OSD, subtitles) don't matter, only the boundary does.
        func boundaryAt(_ edge: Int, _ m: Int) -> Int? {
            (max(1, m - 1)...(m + 1)).first { k in frac(edge, k) >= 0.85 && frac(edge, k) - frac(edge, k + 1) >= 0.25 }
        }
        for i in 0..<4 where est[i] > 0 && frac(i, est[i]) < 0.6 { est[i] = 0 }
        for (pair, dim) in [(0, ch), (1, w)] {
            let e0 = pair * 2, e1 = pair * 2 + 1
            let m = max(strict[e0], strict[e1])
            var d0 = 0, d1 = 0
            if m >= dim / 50, m <= dim * 35 / 100, let k0 = boundaryAt(e0, m), let k1 = boundaryAt(e1, m) { d0 = k0; d1 = k1 }
            let c = d0 + d1
            if abs(c - cand[pair].0) > 2 { cand[pair] = (c, now) }
            if c > 0, now - cand[pair].1 >= (now - startedAt < 2 ? 0 : 0.25),
               abs(d0 - est[e0]) > 1 || abs(d1 - est[e1]) > 1 {
                est[e0] = d0; est[e1] = d1
                for i in lastSeen.indices { lastSeen[i] = 0 }   // forget transition-era holes
            }
        }
        // Remember where non-black pixels (subtitles, controls) appear inside the bars.
        let (t, b, l, r) = (est[0], est[1], est[2], est[3])
        func mark(_ xs: Range<Int>, _ ys: Range<Int>) {
            guard !xs.isEmpty, !ys.isEmpty else { return }
            for y in ys { for x in xs where !dark(x, y) {
                for yy in max(0, y - 4)...min(h - 1, y + 4) { for xx in max(0, x - 4)...min(w - 1, x + 4) {
                    lastSeen[yy * w + xx] = now
                } }
            } }
        }
        mark(0..<w, y0..<(y0 + t))
        mark(0..<w, (h - b)..<h)
        mark(0..<l, (y0 + t)..<(h - b))
        mark((w - r)..<w, (y0 + t)..<(h - b))
    }

    // Row-major runs of covered cells, merged across identical consecutive rows, in screen points.
    // Each bar reaches 1 px into the content to hide the anti-aliased boundary row.
    private func barRects(w: Int, h: Int, y0: Int, now: Double) -> [CGRect] {
        let (t, b, l, r) = (est[0], est[1], est[2], est[3])
        guard t + b + l + r > 0, lastSeen.count == w * h else { return [] }
        let sx = screenSize.width / Double(w), sy = screenSize.height / Double(h)
        var out: [CGRect] = []
        func region(_ xs: Range<Int>, _ ys: Range<Int>) {
            guard !xs.isEmpty, !ys.isEmpty else { return }
            // Group recent non-black cells into horizontal clusters and cut one clean box per cluster.
            var boxes: [(Range<Int>, Range<Int>)] = []
            var colHit = [Bool](repeating: false, count: xs.count)
            for y in ys where y < h { for x in xs where now - lastSeen[y * w + x] <= 0.4 { colHit[x - xs.lowerBound] = true } }
            var i = 0
            while i < colHit.count {
                guard colHit[i] else { i += 1; continue }
                var j = i, gap = 0
                while j + 1 < colHit.count, gap < 24 { j += 1; gap = colHit[j] ? 0 : gap + 1 }
                let cx = (xs.lowerBound + i)..<(xs.lowerBound + j - gap + 1)
                var y0b = Int.max, y1b = Int.min
                for y in ys where y < h { for x in cx where now - lastSeen[y * w + x] <= 0.4 { y0b = min(y0b, y); y1b = max(y1b, y) } }
                if y0b <= y1b { boxes.append((max(xs.lowerBound, cx.lowerBound - 4)..<min(xs.upperBound, cx.upperBound + 4),
                                              max(ys.lowerBound, y0b - 2)..<min(ys.upperBound, y1b + 3))) }
                i = j + 1
            }
            var prevRuns: [Range<Int>] = [], startY = ys.lowerBound
            func flush(_ endY: Int) {
                for run in prevRuns {
                    out.append(CGRect(x: Double(run.lowerBound) * sx, y: Double(startY) * sy,
                                      width: Double(run.count) * sx, height: Double(endY - startY) * sy))
                }
            }
            for y in ys {
                var runs: [Range<Int>] = [], s = -1
                for x in xs {
                    let covered = !boxes.contains { $0.0.contains(x) && $0.1.contains(y) }
                    if covered, s < 0 { s = x }
                    if !covered, s >= 0 { runs.append(s..<x); s = -1 }
                }
                if s >= 0 { runs.append(s..<xs.upperBound) }
                if runs != prevRuns { flush(y); prevRuns = runs; startY = y }
            }
            flush(ys.upperBound)
        }
        if t > 0 { region(0..<w, y0..<min(h, y0 + t + 1)) }
        if b > 0 { region(0..<w, max(y0, h - b - 1)..<h) }
        if l > 0 { region(0..<min(w, l + 1), (y0 + t)..<(h - b)) }
        if r > 0 { region(max(0, w - r - 1)..<w, (y0 + t)..<(h - b)) }
        return out
    }
}

// MARK: - Shot analysis (bars baked into the video, for the IINA plugin)

// The plugin drops mpv screenshots (video only, no subtitles) into its data folder; each becomes a
// JSON verdict next to it: bar fractions per side, whether the frame is informative, its fill color.
enum ShotAnalyzer {
    static var lastColor: OKLab?

    static func poll(cfg: Config) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Config.iinaData.path) else { return }
        for name in names where name.hasPrefix("shot-") && name.hasSuffix(".jpg") {
            let url = Config.iinaData.appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let mtime = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mtime) > 0.3 else { continue }
            if let json = analyze(url, cfg: cfg) {
                NSLog("matte-fill: shot \(name) -> \(json)")
                try? json.write(to: url.deletingPathExtension().appendingPathExtension("json"), atomically: true, encoding: .utf8)
                try? fm.removeItem(at: url)
            } else if Date().timeIntervalSince(mtime) > 5 {
                try? fm.removeItem(at: url)   // unreadable (e.g. truncated) and not going to change
            }
        }
    }

    static func analyze(_ url: URL, cfg: Config) -> String? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1920] as CFDictionary) else { return nil }
        let w = img.width, h = img.height, stride = w * 4
        var buf = [UInt8](repeating: 0, count: stride * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        return buf.withUnsafeBufferPointer { b -> String in
            let p = b.baseAddress!
            @inline(__always) func dark(_ x: Int, _ y: Int) -> Bool {
                let o = y * stride + x * 4
                return max(p[o], p[o + 1], p[o + 2]) <= 24   // headroom for JPEG noise and lifted blacks
            }
            var rowDark = [Double](repeating: 0, count: h), colDark = [Double](repeating: 0, count: w)
            var bright = 0
            for y in 0..<h { for x in 0..<w where dark(x, y) { rowDark[y] += 1; colDark[x] += 1 } }
            for y in 0..<h { bright += w - Int(rowDark[y]); rowDark[y] /= Double(w) }
            for x in 0..<w { colDark[x] /= Double(h) }
            // Bars run from the edge through rows that are (almost) entirely black, plus the
            // anti-aliased boundary row.
            func run(_ f: [Double], _ idx: StrideTo<Int>) -> Int {
                var n = 0
                for i in idx { if f[i] >= 0.98 { n += 1 } else { break } }
                return n > 0 && n < f.count / 2 ? n + 1 : (n >= f.count / 2 ? f.count : 0)
            }
            let t = run(rowDark, Swift.stride(from: 0, to: h, by: 1)), bo = run(rowDark, Swift.stride(from: h - 1, to: -1, by: -1))
            let l = run(colDark, Swift.stride(from: 0, to: w, by: 1)), r = run(colDark, Swift.stride(from: w - 1, to: -1, by: -1))
            let (ft, fb, fl, fr) = (Double(t) / Double(h), Double(bo) / Double(h), Double(l) / Double(w), Double(r) / Double(w))
            // Informative: enough visible content, and it spans one axis edge to edge (a letterbox or
            // pillarbox shape); logos or a lone lit object on black say nothing about the bars.
            let info = t < h / 2 && l < w / 2 && Double(bright) / Double(w * h) >= 0.05 && (fl + fr <= 0.01 || ft + fb <= 0.01)
            let color = (t < h / 2 && l < w / 2)
                ? Palette.color(p, stride: stride, x: l..<(w - r), y: t..<(h - bo), step: 4, cfg: cfg, skip: dark) : nil
            if let color { lastColor = color }
            return String(format: "{\"top\":%.5f,\"bottom\":%.5f,\"left\":%.5f,\"right\":%.5f,\"info\":%@,\"color\":%@}",
                          ft, fb, fl, fr, info ? "true" : "false", color.map { "\"\(ColorMath.hex($0))\"" } ?? "null")
        }
    }
}

// MARK: - Per-display session

final class Session {
    let cfg: Config
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    var panel: OverlayPanel?
    var view: OverlayView?
    var sampler: Sampler?
    var shown = false
    var current: OKLab
    var target: OKLab
    var bandRect = CGRect.zero
    var barRects: [CGRect] = []
    var snapNext = true
    var framesSinceShow = 0
    var menuHoverUntil = 0.0
    var barCache: [String: [CGRect]] = [:]
    var fsSpaces = 0
    var pendingUntil = 0.0
    var shownKey: String?

    init(cfg: Config, screen: NSScreen, color: OKLab) {
        self.cfg = cfg
        self.screen = screen
        displayID = Display.id(of: screen)
        current = color
        target = color
        makePanel()
    }

    func tearDown() {
        hide()
        sampler?.stop(); sampler = nil
        panel?.orderOut(nil); panel = nil; view = nil
    }

    // A new full-screen Space appears as the zoom animation starts; show the band right then.
    func refresh() {
        let now = CACurrentMediaTime()
        let n = Display.fullScreenSpaceCount(screen)
        if n > fsSpaces { pendingUntil = now + 1.5 }
        if n < fsSpaces { pendingUntil = 0 }
        fsSpaces = n
        if let why = Display.fullScreenReason(screen) ?? (Session.pluginFullScreen(on: screen) ? "IINA plugin: full screen" : nil) {
            pendingUntil = 0; show(why: why)
        }
        else if now < pendingUntil { show(why: "full-screen transition") }
        else { hide() }
    }

    // The IINA plugin reports full screen as its transition starts, before a Space appears (and legacy
    // full screen never makes one).
    static func pluginFullScreen(on screen: NSScreen) -> Bool {
        let url = Config.iinaData.appendingPathComponent("status.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mtime) < 3,
              let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              o["fullscreen"] as? Bool == true, let f = o["screen"] as? [String: Double] else { return false }
        return abs((f["x"] ?? -1) - screen.frame.minX) < 1 && abs((f["y"] ?? -1) - screen.frame.minY) < 1
    }

    // IINA with a live plugin fills its own letterbox inside mpv; only the notch band is ours then.
    static func nativelyHandled(_ app: NSRunningApplication?) -> Bool {
        guard app?.bundleIdentifier == "com.colliderli.iina",
              let attrs = try? FileManager.default.attributesOfItem(atPath: Config.iinaData.appendingPathComponent("status.json").path),
              let mtime = attrs[.modificationDate] as? Date else { return false }
        return Date().timeIntervalSince(mtime) < 3
    }

    private func makePanel() {
        let f = screen.frame
        let p = OverlayPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)  // the menu bar itself paints the notch band black
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.setFrame(f, display: false)
        let v = OverlayView(frame: NSRect(origin: .zero, size: f.size))
        p.contentView = v
        v.setColor(current)
        bandRect = CGRect(x: 0, y: 0, width: f.width, height: screen.safeAreaInsets.top)
        v.setBand(bandRect)
        v.setRects([])
        p.alphaValue = 0
        panel = p; view = v
        if cfg.adaptive || cfg.coverBars {
            let s = Sampler(cfg: cfg, bandFraction: Double(screen.safeAreaInsets.top / f.height), screenSize: f.size)
            s.onAnalysis = { [weak self] a in
                guard let self, self.shown else { return }
                if self.framesSinceShow == 0 || (self.framesSinceShow == 25) {
                    NSLog("matte-fill: [\(self.screen.localizedName)] frame \(self.framesSinceShow) color=\(a.color.map(ColorMath.hex) ?? "-") bars=\(a.rects.count) rects \(a.rects.first.map { "first=\($0)" } ?? "")")
                }
                self.framesSinceShow += 1
                if let c = a.color {
                    self.target = c
                    if self.snapNext { self.current = c; self.snapNext = false; self.view?.setColor(c) }   // first sample: no fade
                }
                if a.rects != self.barRects { self.barRects = a.rects; self.view?.setRects(a.rects) }
                if let k = self.shownKey, self.framesSinceShow > 3 { self.barCache[k] = a.rects }
            }
            sampler = s
            let did = displayID, wid = CGWindowID(p.windowNumber)
            s.onLost = { [weak s] in s?.prepare(displayID: did, excludeWindowID: wid) }
            s.prepare(displayID: did, excludeWindowID: wid)
        }
    }

    private func show(why: String) {
        guard !shown, let panel else { return }
        shown = true
        snapNext = true
        framesSinceShow = 0
        let front = NSWorkspace.shared.frontmostApplication
        let native = Session.nativelyHandled(front)
        NSLog("matte-fill: [\(screen.localizedName)] show [\(why)]\(native ? " (IINA plugin)" : "") (capture access: \(CGPreflightScreenCaptureAccess()))")
        panel.setFrame(screen.frame, display: false)
        shownKey = Display.fullScreenWindowKey(screen)
        if native, let c = ShotAnalyzer.lastColor {
            // mpv's background already shows the color of the latest analyzed frame; start from it
            // and ease toward live samples instead of snapping.
            current = c; target = c; snapNext = false; view?.setColor(c)
        }
        if let k = shownKey, let cached = barCache[k], !native { barRects = cached; view?.setRects(cached) }
        sampler?.barsEnabled = !native
        if native { barRects = []; view?.setRects([]) }
        panel.orderFrontRegardless()
        panel.alphaValue = 1
        sampler?.start()
        if let pid = front?.processIdentifier { sampler?.focus(pid: pid) }
    }

    func hide() {
        guard shown else { return }
        shown = false
        NSLog("matte-fill: [\(screen.localizedName)] hide (last color \(ColorMath.hex(current)))")
        sampler?.stop()
        barRects = []
        panel?.orderOut(nil)
        view?.setRects([])
    }

    // Exponential smoothing toward the sampled target; the first sample after entering full screen snaps.
    func tick(dt: Double, now: Double) {
        guard shown else { return }
        let k = snapNext ? 0 : 1 - exp(-dt / max(0.05, cfg.smoothingSeconds))
        current = OKLab(L: current.L + (target.L - current.L) * k,
                        a: current.a + (target.a - current.a) * k,
                        b: current.b + (target.b - current.b) * k)
        view?.setColor(current)
        let (r, g, b) = ColorMath.toSRGB(current)
        sampler?.tintBytes = (Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
        if let f = panel?.frame {
            let m = NSEvent.mouseLocation
            let atTop = f.contains(m) && m.y >= f.maxY - bandRect.height - 8
            if atTop { menuHoverUntil = now + 0.6 }
            view?.setBandVisible(now > menuHoverUntil)
        }
    }

    var stateJSON: String {
        let f = screen.frame
        return "{\"id\":\(displayID),\"x\":\(f.minX),\"y\":\(f.minY),\"w\":\(f.width),\"h\":\(f.height),\"top\":\(screen.safeAreaInsets.top),\"active\":\(shown),\"color\":\"\(ColorMath.hex(current))\"}"
    }
}

// MARK: - Controller

final class Controller: NSObject {
    var cfg = Config.load()
    var sessions: [Session] = []
    var lastTick = CACurrentMediaTime()
    var lastWritten = ""
    var configStamp = Controller.stamp()

    static func stamp() -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: Config.file.path)
        return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)/\(a?[.size] ?? 0)"
    }

    func run() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(refresh), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        ws.addObserver(self, selector: #selector(refresh), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(rebuild),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.slowTick() }
        rebuild()
    }

    // One session per target display; rebuilt when displays change or the config switch flips.
    @objc func rebuild() {
        let seed = sessions.first?.current ?? ColorMath.fromHex(cfg.fallbackColor)
        sessions.forEach { $0.tearDown() }
        sessions = Display.targetScreens(cfg).map { Session(cfg: cfg, screen: $0, color: seed) }
        NSLog("matte-fill: displays=\(cfg.displays) -> \(sessions.map { $0.screen.localizedName })")
        lastWritten = ""
        refresh()
    }

    @objc func refresh() { sessions.forEach { $0.refresh() } }

    private func tick() {
        let now = CACurrentMediaTime(), dt = now - lastTick
        lastTick = now
        sessions.forEach { $0.tick(dt: dt, now: now) }
        writeState()
    }

    private func slowTick() {
        let st = Controller.stamp()
        if st != configStamp {
            configStamp = st
            let old = cfg.displays
            cfg = Config.load()
            NSLog("matte-fill: config reloaded (displays \(old) -> \(cfg.displays))")
            rebuild()
        }
        ShotAnalyzer.poll(cfg: cfg)
    }

    // The IINA plugin reads this: per target display, its frame, whether we are active there and the color.
    private func writeState() {
        let body = sessions.map(\.stateJSON).joined(separator: ",")
        guard body != lastWritten else { return }
        lastWritten = body
        let json = "{\"displays\":\"\(cfg.displays)\",\"screens\":[\(body)],\"t\":\(Date().timeIntervalSince1970)}"
        try? FileManager.default.createDirectory(at: Config.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? json.write(to: Config.stateFile, atomically: true, encoding: .utf8)
    }
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--status") {
    let cfg = Config.load()
    print("displays:", cfg.displays)
    let targets = Display.targetScreens(cfg)
    if targets.isEmpty { print("target: none") }
    for s in targets {
        print("target:", "\(s.localizedName) \(s.frame) safeTop=\(s.safeAreaInsets.top) builtin=\(CGDisplayIsBuiltin(Display.id(of: s)) != 0)",
              "fullscreen:", Display.fullScreenReason(s) ?? "no")
    }
    print("iinaPlugin:", Session.nativelyHandled(NSRunningApplication.runningApplications(withBundleIdentifier: "com.colliderli.iina").first) ? "live" : "not running")
    print("screenCaptureAccess:", CGPreflightScreenCaptureAccess())
    exit(0)
}
// Switch which displays Matte works on; the running agent picks it up within a second.
if let i = args.firstIndex(of: "--displays") {
    guard i + 1 < args.count, ["all", "builtin"].contains(args[i + 1]) else {
        print("usage: matte-fill --displays all|builtin"); exit(2)
    }
    var obj = (try? Data(contentsOf: Config.file)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    obj["displays"] = args[i + 1]
    try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
    let data = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: Config.file, options: .atomic)
    print("displays:", args[i + 1])
    exit(0)
}
if args.contains("--request-capture") {
    print("granted:", CGRequestScreenCaptureAccess())
    exit(0)
}
// Offline self-test of the IINA shot analysis: prints the JSON verdict the plugin would receive.
if let i = args.firstIndex(of: "--analyze-shot"), i + 1 < args.count {
    print(ShotAnalyzer.analyze(URL(fileURLWithPath: args[i + 1]), cfg: Config.load()) ?? "unreadable")
    exit(0)
}

// Offline self-test: feed a screenshot for 2 simulated seconds and print what would be painted.
if let i = args.firstIndex(of: "--analyze"), i + 1 < args.count,
   let src = NSImage(contentsOfFile: args[i + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil),
   let screen = Display.targetScreens(Config.load()).first ?? NSScreen.main {
    let w = Int(screen.frame.width) / 2, h = Int(screen.frame.height) / 2
    let (pw, ph) = (w, h)
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, pw, ph, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: pw, height: ph, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.draw(src, in: CGRect(x: 0, y: 0, width: pw, height: ph))
    CVPixelBufferUnlockBaseAddress(pb!, [])
    let s = Sampler(cfg: Config.load(), bandFraction: Double(screen.safeAreaInsets.top / screen.frame.height), screenSize: screen.frame.size)
    var a = Analysis(color: nil, rects: [])
    for k in 0...20 { a = s.analyze(pb!, now: Double(k) * 0.1) }
    print("color:", a.color.map(ColorMath.hex) ?? "none")
    for r in a.rects { print("rect:", r) }
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Debug: paint the band plus a 100pt test bar for 2 s to verify on-screen geometry.
if args.contains("--preview"), let screen = Display.targetScreens(Config.load()).first {
    let p = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
    p.isOpaque = false; p.backgroundColor = .clear; p.ignoresMouseEvents = true
    p.setFrame(screen.frame, display: false)
    let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
    p.contentView = v
    v.setColor(ColorMath.fromHex("#C04040"))
    v.setRects([CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.safeAreaInsets.top),
                CGRect(x: 0, y: screen.safeAreaInsets.top, width: 300, height: 100)])
    p.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    app.run()
}   // no Dock icon, never takes focus
NSLog("matte-fill: started (capture access: \(CGPreflightScreenCaptureAccess()))")
let controller = Controller()
controller.run()
app.run()

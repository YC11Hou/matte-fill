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
    var fadeSeconds = 2.5              // fade-in of the large color area (0 = instant, more = smoother)
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
        fadeSeconds = try c.decodeIfPresent(Double.self, forKey: .fadeSeconds) ?? fadeSeconds
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
@_silgen_name("SLSAddWindowsToSpaces") func SLSAddWindowsToSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)
@_silgen_name("SLSRemoveWindowsFromSpaces") func SLSRemoveWindowsFromSpaces(_ cid: Int32, _ windows: CFArray, _ spaces: CFArray)

enum Display {
    static func targetScreens(_ cfg: Config) -> [NSScreen] {
        NSScreen.screens.filter { isTarget(builtin: CGDisplayIsBuiltin(id(of: $0)) != 0, displays: cfg.displays) }
    }

    // Matte runs only on the built-in display unless the user turned on "all" (tests/1-external).
    static func isTarget(builtin: Bool, displays: String) -> Bool { builtin || displays == "all" }

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

    // Owner of the frontmost normal window over this display's center (the window list runs front to back).
    static func frontApp(on screen: NSScreen) -> pid_t? {
        let b = CGDisplayBounds(id(of: screen))
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  r.contains(CGPoint(x: b.midX, y: b.midY)) else { continue }
            return pid
        }
        return nil
    }

    // Owner of the frontmost normal window that covers most of this display (a full-screen window).
    static func fullScreenOwner(_ screen: NSScreen) -> pid_t? {
        let d = CGDisplayBounds(id(of: screen))
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  r.intersection(d).width * r.intersection(d).height >= 0.8 * d.width * d.height else { continue }
            return pid
        }
        return nil
    }

    // Height of the area the system menu bar paints on this display: the camera housing plus the menu
    // bar's own 1 pt bottom line (its window is 33 pt where safeAreaInsets.top is 32). Zero without a notch.
    static func menuBarHeight(_ screen: NSScreen) -> CGFloat {
        let top = screen.safeAreaInsets.top
        guard top > 0 else { return 0 }
        let b = CGDisplayBounds(id(of: screen))
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let heights = list.compactMap { w -> CGFloat? in
            guard w[kCGWindowOwnerName as String] as? String == "Window Server", w[kCGWindowName as String] as? String == "Menubar",
                  let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  abs(r.minX - b.minX) < 1, abs(r.minY - b.minY) < 1, abs(r.width - b.width) < 1 else { return nil }
            return r.height
        }
        return max(top, heights.filter { $0 < top + 8 }.max() ?? top)
    }

    static func spaceID(_ s: [String: Any]) -> UInt64? {
        (s["id64"] as? NSNumber)?.uint64Value ?? (s["ManagedSpaceID"] as? NSNumber)?.uint64Value
    }

    // IDs of the native full-screen Spaces (type 4) on the display.
    static func allSpaceIDs() -> Set<UInt64> {
        let spaces = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        return Set(spaces.flatMap { ($0["Spaces"] as? [[String: Any]] ?? []).compactMap(spaceID) })
    }

    static func fullScreenSpaceIDs(_ screen: NSScreen) -> Set<UInt64> {
        let did = id(of: screen)
        let uuid = CGDisplayCreateUUIDFromDisplayID(did).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? ""
        let spaces = CGSCopyManagedDisplaySpaces(CGSMainConnectionID()) as? [[String: Any]] ?? []
        for d in spaces {
            let ident = d["Display Identifier"] as? String ?? ""
            guard ident.caseInsensitiveCompare(uuid) == .orderedSame || (ident == "Main" && (spaces.count == 1 || CGMainDisplayID() == did)) else { continue }
            return Set((d["Spaces"] as? [[String: Any]] ?? []).filter { ($0["type"] as? Int) == 4 }.compactMap(spaceID))
        }
        return []
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

// Wherever the system paints black under something that has to stay visible (menu titles over the notch
// band, player UI over the bars), the black is replaced the same way: a live copy of the screen is
// screen-blended over the fill (out = src + (1 - src) * fill), so black becomes exactly the fill while
// text, icons and their anti-aliased edges stay intact. The band and the bars share this one component.
final class MirrorFill {
    private var fills: [CALayer] = [], mirrors: [CALayer] = []
    private var held: [CVPixelBuffer] = []
    var enabled = false { didSet { if enabled != oldValue { show() } } }

    // A fill and its mirror inside `parent`, both covering `frame` (the mirror shows the whole capture).
    func add(to parent: CALayer, frame: CGRect) {
        let fill = CALayer(), mirror = CALayer()
        for l in [fill, mirror] { l.frame = frame; l.actions = ["backgroundColor": NSNull(), "frame": NSNull(), "contents": NSNull()] }
        mirror.contentsGravity = .resize
        mirror.filters = [MirrorFill.blackLevel(), MirrorFill.clampToRange()]
        mirror.compositingFilter = CIFilter(name: "CIScreenBlendMode")
        parent.addSublayer(fill); parent.addSublayer(mirror)
        fills.append(fill); mirrors.append(mirror)
    }

    func setFrame(_ r: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for l in fills + mirrors { l.frame = r }
        CATransaction.commit()
    }

    func setColor(_ c: CGColor) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for f in fills { f.backgroundColor = c }
        CATransaction.commit()
    }

    // Keeps the latest captured frame even while hidden (a static screen sends no new frames), and
    // retains the last few buffers so capture never reuses a surface that is still on screen.
    func setMirror(_ px: CVPixelBuffer?) {
        if let px { held.append(px); if held.count > 3 { held.removeFirst() } } else { held = [] }
        show()
    }

    private func show() {
        let surface = enabled ? held.last.flatMap { CVPixelBufferGetIOSurface($0)?.takeUnretainedValue() } : nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for m in mirrors { m.contents = surface }
        CATransaction.commit()
    }

    // Compressed video black is rarely 0 (it sits around 10-20), so the mirror's black level is pulled
    // down before the screen blend; otherwise encoded bars would end up a shade lighter than the band.
    static let videoBlack: CGFloat = 28.0 / 255
    static func blackLevel() -> CIFilter {
        let f = CIFilter(name: "CIColorMatrix")!
        let g = 1 / (1 - videoBlack)
        f.setValue(CIVector(x: g, y: 0, z: 0, w: 0), forKey: "inputRVector")
        f.setValue(CIVector(x: 0, y: g, z: 0, w: 0), forKey: "inputGVector")
        f.setValue(CIVector(x: 0, y: 0, z: g, w: 0), forKey: "inputBVector")
        f.setValue(CIVector(x: -videoBlack * g, y: -videoBlack * g, z: -videoBlack * g, w: 0), forKey: "inputBiasVector")
        return f
    }

    // The black-level shift leaves values below zero; the window server composites them unclamped,
    // which made screen-blended bars darker than the fill (measured live, 2026-10-11).
    static func clampToRange() -> CIFilter {
        let f = CIFilter(name: "CIColorClamp")!
        f.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
        f.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
        return f
    }
}

// The notch band: exactly the camera-housing area, where the menu bar itself paints black, never
// reaching into the app's content. A dropped-down menu bar keeps its titles and icons over the fill.
final class BandView: NSView {
    private let band = CALayer()
    let matte = MirrorFill()
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer = CALayer()
        band.masksToBounds = true
        band.actions = ["frame": NSNull()]
        matte.add(to: band, frame: .zero)
        layer!.addSublayer(band)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setBand(_ r: CGRect) {
        band.frame = r
        matte.setFrame(CGRect(origin: .zero, size: r.size))
    }

    // Yields to a menu bar that brings a background of its own, at the menu bar's own pace.
    func setBandVisible(_ v: Bool) {
        guard (band.opacity > 0.5) != v else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.18)
        band.opacity = v ? 1 : 0
        CATransaction.commit()
    }
}

// The bars: one persistent tile per edge, each a clip over the shared MirrorFill, so every change
// (appearing, leaving, resizing) is an eased transition rather than a jump.
final class BarsView: NSView {
    enum Edge: CaseIterable { case top, bottom, left, right }
    private struct Tile { let clip: CALayer; var rect: CGRect? }
    private var tiles: [Edge: Tile] = [:]
    let matte = MirrorFill()
    var fadeSeconds = 2.5
    private var span = 2.5
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer = CALayer()
        for e in Edge.allCases {
            // The clip's bounds origin always equals its frame origin, so its sublayers stay in screen
            // coordinates while the clip itself moves or resizes.
            let clip = CALayer()
            clip.masksToBounds = true
            clip.opacity = 0
            matte.add(to: clip, frame: bounds)
            layer!.addSublayer(clip)
            tiles[e] = Tile(clip: clip, rect: nil)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func edge(of r: CGRect) -> Edge {
        if r.width >= bounds.width - 1 { return r.midY < bounds.midY ? .top : .bottom }
        return r.midX < bounds.midX ? .left : .right
    }

    // Moves each edge's tile toward its new rect: new bars fade in, gone bars fade out, changed bars
    // slide, all over `fadeSeconds`. `animated: false` resets at once (used when leaving full screen).
    func setRects(_ rects: [CGRect], animated: Bool, duration: Double? = nil) {
        span = duration ?? fadeSeconds
        var want: [Edge: CGRect] = [:]
        for r in rects { want[edge(of: r)] = r }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for e in Edge.allCases {
            guard var t = tiles[e] else { continue }
            let to = want[e]
            if !animated {
                t.clip.removeAllAnimations()
                if let to { place(t.clip, to) }
                t.clip.opacity = to == nil ? 0 : 1
            } else if let to, let from = t.rect, t.clip.opacity > 0 {
                if from != to { ease(t.clip, "position") { ease(t.clip, "bounds") { place(t.clip, to) } } }
            } else if let to {
                if t.clip.presentation().map({ $0.opacity <= 0.001 }) ?? true { place(t.clip, to) }
                else { ease(t.clip, "position") { ease(t.clip, "bounds") { place(t.clip, to) } } }
                ease(t.clip, "opacity") { t.clip.opacity = 1 }
            } else if t.rect != nil {
                ease(t.clip, "opacity") { t.clip.opacity = 0 }
            }
            t.rect = to
            tiles[e] = t
        }
        CATransaction.commit()
    }

    private func place(_ l: CALayer, _ r: CGRect) {
        l.frame = r
        l.bounds = r
    }

    // Animates `key` from what is on screen now to the value `change` sets, so an interrupted
    // transition continues smoothly from where it is.
    private func ease(_ l: CALayer, _ key: String, _ change: () -> Void) {
        let from = (l.presentation() ?? l).value(forKey: key)
        change()
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = l.value(forKey: key)
        a.duration = span
        a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        l.add(a, forKey: key)
    }
}

// MARK: - Sampler: content color + black-bar geometry

struct Analysis {
    var color: OKLab?
    var rects: [CGRect]   // bar areas in screen points, top-left origin
}

final class Sampler: NSObject, SCStreamOutput, SCStreamDelegate {
    var onAnalysis: ((Analysis) -> Void)?
    var onLost: (() -> Void)?
    var onMirror: ((CVPixelBuffer) -> Void)?
    private let queue = DispatchQueue(label: "matte-fill.sample")
    private let mirrorQueue = DispatchQueue(label: "matte-fill.mirror")
    private let cfg: Config
    private let bandFraction: Double
    private let screenSize: CGSize

    // Bar state, only touched on `queue`.
    private var est = [0, 0, 0, 0]            // top, bottom, left, right (sample px)
    private var cand = [(0, 0.0), (0, 0.0)]   // (extent, since) for vertical and horizontal pairs
    private var pend = [(-1, 0.0), (-1, 0.0), (-1, 0.0), (-1, 0.0)]   // per edge: (proposed depth, since)
    private var size = (0, 0)
    private var frameNo = 0
    var tintBytes = (-100, -100, -100)
    var barsEnabled = true
    private var display: SCDisplay?
    private var startedAt = 0.0
    private var dbgStrict: [Int] = []
    private var sig: [Int] = []
    private var motion: [(t: Double, moved: Bool)] = []
    var assumeMotion = false   // offline stills stand in for playing video

    init(cfg: Config, bandFraction: Double, screenSize: CGSize) {
        self.cfg = cfg
        self.bandFraction = bandFraction
        self.screenSize = screenSize
    }

    private var prepared: SCStream?
    private var running = false
    private var mirrorStream: SCStream?
    private var mirrorRunning = false

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
            // Second stream at native pixels and frame rate, only GPU-composited (never read on the CPU).
            let mc = SCStreamConfiguration()
            let mode = CGDisplayCopyDisplayMode(displayID)
            mc.width = mode?.pixelWidth ?? display.width * 2
            mc.height = mode?.pixelHeight ?? display.height * 2
            mc.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            mc.pixelFormat = kCVPixelFormatType_32BGRA
            mc.colorSpaceName = CGColorSpace.sRGB
            mc.showsCursor = false
            mc.queueDepth = 6
            let m = SCStream(filter: filter, configuration: mc, delegate: self)
            do {
                try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue)
                try m.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.mirrorQueue)
                DispatchQueue.main.async {
                    self.prepared = s
                    self.mirrorStream = m
                    if self.running { s.startCapture { e in if let e { NSLog("matte-fill: startCapture failed: \(e)") } } }
                    if self.mirrorRunning { self.mirrorRunning = false; self.setMirror(true) }
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
            DispatchQueue.main.async {
                for st in [self.prepared, self.mirrorStream] { st?.updateContentFilter(f) { e in if let e { NSLog("matte-fill: focus failed: \(e)") } } }
            }
        }
    }

    func start() {
        guard !running else { return }
        running = true
        prepared?.startCapture { e in if let e { NSLog("matte-fill: startCapture failed: \(e)") } }
    }

    // The mirror runs only while bars are painted, so plain full-screen apps cost nothing extra.
    func setMirror(_ on: Bool) {
        guard on != mirrorRunning else { return }
        mirrorRunning = on
        NSLog("matte-fill: mirror \(on ? "on" : "off")")
        guard let m = mirrorStream else { return }
        if on { m.startCapture { e in if let e { NSLog("matte-fill: mirror start failed: \(e)") } } }
        else { m.stopCapture { _ in } }
    }

    func stop() {
        if running { prepared?.stopCapture { _ in } }
        running = false
        setMirror(false)
        queue.async { self.est = [0, 0, 0, 0]; self.cand = [(0, 0), (0, 0)]; self.pend = [(-1, 0), (-1, 0), (-1, 0), (-1, 0)]; self.frameNo = 0; self.startedAt = 0; self.sig = []; self.motion = [] }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("matte-fill: stream stopped: \(error)")
        DispatchQueue.main.async {
            if self.mirrorRunning { self.mirrorStream?.stopCapture { _ in } }
            self.running = false; self.mirrorRunning = false; self.prepared = nil; self.mirrorStream = nil; self.onLost?()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let px = CMSampleBufferGetImageBuffer(sb) else { return }
        if stream === mirrorStream { DispatchQueue.main.async { self.onMirror?(px) }; return }
        if startedAt == 0 { startedAt = CACurrentMediaTime() }
        let a = analyze(px, now: CACurrentMediaTime())
        frameNo += 1
        if frameNo < 30, FileManager.default.fileExists(atPath: Config.dir.appendingPathComponent("debug").path) {
            NSLog("matte-fill: f\(frameNo) t=\(String(format: "%.2f", CACurrentMediaTime() - startedAt)) reading=\(dbgStrict) est=\(est) rects=\(a.rects.count)")
        }
        if frameNo == 25, FileManager.default.fileExists(atPath: Config.dir.appendingPathComponent("debug").path) {
            NSLog("matte-fill: debug w=\(CVPixelBufferGetWidth(px)) h=\(CVPixelBufferGetHeight(px)) reading=\(dbgStrict) est=\(est) cand=\(cand)")
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
            return (b <= 36 && g <= 36 && r <= 36) || (abs(r - tr) <= 6 && abs(g - tg) <= 6 && abs(b - tb) <= 6)
        }
        @inline(__always) func level(_ x: Int, _ y: Int) -> Int {
            let o = y * stride + x * 4
            return max(Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
        }

        // Bars only exist around playing video: an app's own dark UI (an editor, a terminal) can look just
        // like one, but holds still. So a first bar needs the picture to have been moving for the last second:
        // most of a coarse 16x9 grid of cell means changing from frame to frame, not a cursor or a spinner.
        var cells: [Int] = []
        for gy in 0..<9 {
            for gx in 0..<16 {
                var sum = 0
                for sy in 0..<4 { for sx in 0..<4 { sum += level((gx * 4 + sx) * w / 64, y0 + (gy * 4 + sy) * (h - y0) / 36) } }
                cells.append(sum)
            }
        }
        let moved = sig.count == cells.count && zip(sig, cells).filter { abs($0 - $1) >= 48 }.count >= 4
        sig = cells
        motion.append((now, moved))
        motion.removeAll { now - $0.t > 1 }
        let moving = assumeMotion || (motion.count >= 5 && Double(motion.filter(\.moved).count) >= 0.5 * Double(motion.count))
        if cfg.coverBars && barsEnabled { updateBars(w: w, h: h, y0: y0, now: now, moving: moving, dark: dark, level: level) }
        else { est = [0, 0, 0, 0] }
        let (t, b, l, r) = (est[0], est[1], est[2], est[3])

        let color = cfg.adaptive
            ? Palette.color(p, stride: stride, x: l..<(w - r), y: (y0 + t)..<(h - b), step: 4, cfg: cfg, skip: dark) : nil

        return Analysis(color: color, rects: barRects(w: w, h: h, y0: y0))
    }

    private enum Reading { case edge(Int, textured: Bool, share: Double), none, unknown }

    // Even in the first 2 s a bar edge has to hold one depth this long: a video's frame holds still, while the
    // system's full-screen zoom (in or out) moves the picture's edges over a dark desktop every frame.
    static let settle = 0.25

    // Bars belong to the video's layout, which changes rarely; player UI (controls, titles, subtitles,
    // danmaku, hints) comes and goes on top of them. So a bar only moves or goes on positive evidence:
    //   - an edge: a line's black run from the screen edge ends in a sharp step up into a solid stretch of
    //     picture (thin lines and text strokes don't qualify), at least 20% of lines agree on the depth,
    //     and they include one unbroken stretch (text is strokes with gaps, a picture edge is a line);
    //     the deepest such depth wins, since UI inside a bar always sits shallower than its edge, unless
    //     picture shows through shallower than it: a bar is black right up to its edge, so an unbroken,
    //     textured stretch of lines meeting picture earlier proves that depth is a dark scene, not a bar;
    //   - no bar: at least 70% of lines show picture right at the screen edge.
    // Moving or removing a bar also needs that picture to be textured across lines: player UI (control
    // strips, panels, gradients) is flat, picture is not. Adopting a new bar doesn't, as frames often
    // start with flat sky or walls; the pair rule keeps dark scenes out instead.
    // Anything else (UI covering the edge, a dark scene) is "unknown" and leaves the bars exactly as they
    // are. New bars need a pair (both edges, or one edge and the other side black just as deep), so a
    // dark scene can't fake one. The layout is found in the first 2 s; after that it is damped, since a
    // video's frame rarely changes while its scenes do: a refinement of a sample or two needs 1 s of
    // agreement, anything larger 5 s, and a first bar found after 8 s (UI hid it until then) 5 s too.
    // Only the color follows the scenes.
    private func updateBars(w: Int, h: Int, y0: Int, now: Double, moving: Bool, dark: (Int, Int) -> Bool, level: (Int, Int) -> Int) {
        if size != (w, h) { size = (w, h); est = [0, 0, 0, 0] }
        let ch = h - y0
        let caps = [ch * 35 / 100 + 2, ch * 35 / 100 + 2, w * 35 / 100 + 2, w * 35 / 100 + 2]
        let lens = [ch, ch, w, w]
        let lines = [Array(Swift.stride(from: 0, to: w, by: 2)), Array(Swift.stride(from: 0, to: w, by: 2)),
                     Array(Swift.stride(from: y0, to: h, by: 2)), Array(Swift.stride(from: y0, to: h, by: 2))]
        // Pixel at depth d (0 = outermost) along line i from edge e.
        func at(_ e: Int, _ i: Int, _ d: Int) -> (Int, Int) {
            switch e {
            case 0: return (i, y0 + d)
            case 1: return (i, h - 1 - d)
            case 2: return (d, i)
            default: return (w - 1 - d, i)
            }
        }
        var runs = [[Int]](repeating: [], count: 4), votes = [[(d: Int, i: Int)]](repeating: [], count: 4), open = [[Int]](repeating: [], count: 4)
        var pics = [[(d: Int, i: Int)]](repeating: [], count: 4)
        for e in 0..<4 {
            for i in lines[e] {
                var d = 0
                while d < caps[e], dark(at(e, i, d).0, at(e, i, d).1) { d += 1 }
                runs[e].append(d)
                guard d < caps[e] else { continue }
                let k = min(8, lens[e] - d)
                var solid = 0
                for j in 0..<k where !dark(at(e, i, d + j).0, at(e, i, d + j).1) { solid += 1 }
                let step = max(level(at(e, i, d).0, at(e, i, d).1), d + 1 < lens[e] ? level(at(e, i, d + 1).0, at(e, i, d + 1).1) : 0)
                guard step >= 48, solid >= k * 3 / 4 else { continue }
                pics[e].append((d, i))
                if d < max(1, lens[e] / 50) { open[e].append(i) } else { votes[e].append((d, i)) }
            }
        }
        func support(_ e: Int, _ d: Int) -> Double { Double(runs[e].filter { $0 >= d }.count) / Double(max(1, runs[e].count)) }
        // Picture is textured across lines; player UI (control strips, gradients, panels) is flat. Only
        // a textured stretch counts as picture.
        func textured(_ e: Int, _ ls: [Int], _ d: Int) -> Bool {
            guard d < lens[e], ls.count >= 4 else { return false }
            var sum = 0.0, sq = 0.0
            for i in ls {
                let p = at(e, i, d)
                let v = Double(level(p.0, p.1))
                sum += v; sq += v * v
            }
            let n = Double(ls.count), m = sum / n
            return (sq / n - m * m).squareRoot() >= 6
        }
        // A picture edge is one long straight line; text and icons are short strokes with gaps between
        // them. So the agreeing lines must include an unbroken stretch of at least 10% of all lines.
        func continuous(_ e: Int, _ ls: [Int], _ share: Double = 0.1) -> Bool {
            let base = e < 2 ? 0 : y0
            let ord = ls.map { ($0 - base) / 2 }.sorted()
            var best = ord.isEmpty ? 0 : 1, cur = 1
            for k in 1..<max(1, ord.count) where ord.count > 1 {
                cur = ord[k] - ord[k - 1] <= 2 ? cur + 1 : 1
                best = max(best, cur)
            }
            return Double(best) >= share * Double(max(1, runs[e].count))
        }
        // Where picture shows through shallower than depth d: lines meeting textured picture right at the
        // screen edge (within 2 samples, 4% unbroken; UI floats inside a bar a few points below the edge, like
        // Chrome's Esc bubble), or a straight picture edge at one depth held to the same 10% as any edge (icons
        // in a bar are shorter).
        func through(_ e: Int, _ d: Int) -> Int? {
            func picture(_ ls: [(d: Int, i: Int)], _ share: Double) -> Bool {
                guard ls.count >= 4, continuous(e, ls.map(\.i), share) else { return false }
                var sum = 0.0, sq = 0.0
                for v in ls {
                    let p = at(e, v.i, min(lens[e] - 1, v.d + 2))
                    let l = Double(level(p.0, p.1))
                    sum += l; sq += l * l
                }
                let n = Double(ls.count), m = sum / n
                return (sq / n - m * m).squareRoot() >= 6
            }
            let edge = max(1, lens[e] / 50)
            if picture(pics[e].filter { $0.d < 2 }, 0.04) { return 0 }
            for k in Swift.stride(from: edge, to: d - 2, by: 1) where picture(votes[e].filter { abs($0.d - k) <= 1 }, 0.1) { return k }
            return nil
        }
        func read(_ e: Int) -> Reading {
            let n = Double(max(1, runs[e].count))
            var hist = [Int](repeating: 0, count: caps[e] + 2)
            for v in votes[e] { hist[v.d] += 1 }
            for d in Swift.stride(from: caps[e] - 1, through: max(1, lens[e] / 50), by: -1) {
                guard Double(hist[d - 1] + hist[d] + hist[d + 1]) >= 0.2 * n else { continue }
                let k = (d - 1...d + 1).max { hist[$0] < hist[$1] }!
                let near = votes[e].filter { abs($0.d - k) <= 1 }
                guard continuous(e, near.map(\.i)), through(e, k) == nil else { continue }
                return .edge(k, textured: textured(e, near.map(\.i), k + 2), share: Double(near.count) / n)
            }
            return Double(open[e].count) >= 0.7 * n && textured(e, open[e], 1) ? .none : .unknown
        }
        let r = (0..<4).map(read)
        dbgStrict = r.map { if case .edge(let k, _, _) = $0 { return k }; if case .none = $0 { return 0 }; return -1 }
        let locked = now - startedAt >= 2
        for (pair, _) in [(0, ch), (1, w)] {
            let e0 = pair * 2, e1 = pair * 2 + 1
            if est[e0] == 0 && est[e1] == 0 {
                var d0 = 0, d1 = 0
                switch (r[e0], r[e1]) {
                case let (.edge(k0, _, _), .edge(k1, _, _)): d0 = k0; d1 = k1
                case let (.edge(k, _, _), _) where support(e1, k) >= 0.3: d0 = k; d1 = k
                case let (_, .edge(k, _, _)) where support(e0, k) >= 0.3: d0 = k; d1 = k
                // One strong, textured edge while the other side is only covered (player UI right after
                // entering), not contradicted: assume symmetry; the real depth slides in once UI hides.
                case let (.edge(k, true, sh), .unknown) where sh >= 0.3: d0 = k; d1 = k
                case let (.unknown, .edge(k, true, sh)) where sh >= 0.3: d0 = k; d1 = k
                default: break
                }
                let c = d0 + d1
                if abs(c - cand[pair].0) > 2 { cand[pair] = (c, now) }
                if c > 0, moving, now - cand[pair].1 >= (!locked ? Sampler.settle : now - startedAt < 8 ? 0.25 : 5) { est[e0] = d0; est[e1] = d1 }
                continue
            }
            for e in [e0, e1] {
                var want: Int?
                switch r[e] {
                // Deeper by even one sample is taken (never leave a black line); shallower needs two (no jitter).
                case .edge(let k, true, _) where k > est[e] || est[e] - k > 1: want = k
                case .none where est[e] > 0: want = 0
                default: want = nil
                }
                // Picture showing inside the current bar: it can be no deeper than where that picture starts.
                if want == nil, est[e] > 0, let b = through(e, est[e]) { want = b }
                guard let want else { pend[e] = (-1, 0); continue }
                let shrinking = want < est[e] - 2 && pend[e].0 >= 0 && pend[e].0 < est[e] - 2
                if shrinking { pend[e].0 = max(pend[e].0, want) }
                else if pend[e].0 < 0 || abs(pend[e].0 - want) > 1 { pend[e] = (want, now) }
                if now - pend[e].1 >= (!locked ? Sampler.settle : abs(want - est[e]) <= 2 ? 1 : 5) { est[e] = shrinking ? pend[e].0 : want; pend[e] = (-1, 0) }
            }
        }
    }

    // Whole bar regions in screen points. Each bar reaches 2 px into the content: the scaled video's
    // soft edge fades to black there, and the screen-blended mirror turns that fade into the fill.
    private func barRects(w: Int, h: Int, y0: Int) -> [CGRect] {
        let (t, b, l, r) = (est[0], est[1], est[2], est[3])
        let e = 2
        let sx = screenSize.width / Double(w), sy = screenSize.height / Double(h)
        func rect(_ xs: Range<Int>, _ ys: Range<Int>) -> CGRect {
            CGRect(x: Double(xs.lowerBound) * sx, y: Double(ys.lowerBound) * sy, width: Double(xs.count) * sx, height: Double(ys.count) * sy)
        }
        var out: [CGRect] = []
        if t > 0 { out.append(rect(0..<w, y0..<min(h, y0 + t + e))) }
        if b > 0 { out.append(rect(0..<w, max(y0, h - b - e)..<h)) }
        if l > 0 { out.append(rect(0..<min(w, l + e), (y0 + t)..<(h - b))) }
        if r > 0 { out.append(rect(max(0, w - r - e)..<w, (y0 + t)..<(h - b))) }
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

// MARK: - Protected (DRM) playback

// Browsers black out DRM video (HBO Max, Netflix...) while any screen capture is running on the system,
// so Matte must capture nothing while such video plays. Detected without capturing: Chromium browsers
// decrypt in their own CDM utility processes, whose CPU time only grows while protected video plays.
final class ProtectedPlayback {
    private var cdms: [pid_t] = []                       // CDM processes of every browser
    private var listedAt = -100.0

    // True while any browser, on any display, has a CDM process alive (a page with protected video is open,
    // playing, paused or buffering): a browser blacks out its protected video whenever any capture runs
    // anywhere, so a movie on the external display is protected just as much as one on ours. Decryption
    // CPU is not a usable signal: it measured flat for seconds while a movie was on (2026-10-19).
    func playing(now: Double) -> Bool {
        if now - listedAt >= 1 { cdms = ProtectedPlayback.cdmProcesses(); listedAt = now }
        return ProtectedPlayback.protects(cdms)
    }

    static func protects(_ cdmProcesses: [pid_t]) -> Bool { !cdmProcesses.isEmpty }

    // Browser helper processes running the CDM service (Chromium-based browsers alike). Other apps carry a
    // CDM too (Spotify, for audio) and never black anything out, so only browsers count.
    static let browsers = ["Google Chrome", "Microsoft Edge", "Brave Browser", "Chromium", "Arc", "Vivaldi", "Opera"]
    static func isBrowserCDM(_ args: String) -> Bool {
        args.contains("CdmServiceBroker") && browsers.contains { args.contains("/\($0).app/") }
    }

    static func cdmProcesses() -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let n = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        return pids.prefix(max(0, n)).filter { pid in
            var name = [CChar](repeating: 0, count: 256)
            guard proc_name(pid, &name, UInt32(name.count)) > 0, String(cString: name).contains("Helper") else { return false }
            return isBrowserCDM(arguments(pid))
        }
    }

    private static func arguments(_ pid: pid_t) -> String {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid], size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return "" }
        return String(decoding: buf.prefix(size).map { $0 == 0 ? 32 : $0 }, as: UTF8.self)
    }

}

// MARK: - Menu bar watcher

// Watches what lies under the notch band (our own windows excluded): while the full-screen menu bar is
// hidden that strip is the system's plain black. A menu bar on black only adds titles and icons, which
// the band shows through its mirror; the band yields only to a menu bar with a background of its own,
// never on a guess from the pointer position.
final class MenuBarWatcher: NSObject, SCStreamOutput, SCStreamDelegate {
    var onChange: ((Bool) -> Void)?
    var onFrame: ((CVPixelBuffer) -> Void)?
    private var resetAt: UInt64 = 0
    private(set) var visible = false
    var isRunning: Bool { running }
    private(set) var titlesAt = 0.0   // last time anything at all (titles, icons) lit the strip
    private var lastLit = false
    private var stream: SCStream?
    private var running = false
    private var blackFrames = 0
    private var litFrames = 0
    private var lastSeen: Bool?
    private let queue = DispatchQueue(label: "matte-fill.menubar")
    private let sides: [Range<Double>]   // horizontal fractions of the menu bar area beside the camera housing

    init(screen: NSScreen) {
        let w = screen.frame.width
        let l = screen.auxiliaryTopLeftArea.map { $0.maxX / w } ?? 0.5
        let r = screen.auxiliaryTopRightArea.map { $0.minX / w } ?? 0.5
        sides = [0.0..<max(0.01, l), min(0.99, r)..<1.0]
    }

    func prepare(displayID: CGDirectDisplayID, height: CGFloat) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
            guard let self, let content, let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
            let pid = ProcessInfo.processInfo.processIdentifier
            let mine = content.windows.filter { $0.owningApplication?.processID == pid }
            let conf = SCStreamConfiguration()
            let scale = Double(CGDisplayCopyDisplayMode(displayID)?.pixelWidth ?? display.width * 2) / Double(display.width)
            conf.sourceRect = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: height)
            conf.width = Int((Double(display.width) * scale).rounded())
            conf.height = Int((Double(height) * scale).rounded())
            conf.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            conf.pixelFormat = kCVPixelFormatType_32BGRA
            conf.colorSpaceName = CGColorSpace.sRGB
            conf.showsCursor = false
            conf.queueDepth = 6
            let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: mine), configuration: conf, delegate: self)
            do { try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: self.queue) } catch { return }
            DispatchQueue.main.async {
                self.stream = s
                if self.running { s.startCapture { _ in } }
            }
        }
    }

    // Forget what was seen so far (it may have been the desktop's menu bar during a Space switch);
    // showing then needs two lit frames in a row.
    func reset() {
        let t = mach_absolute_time()
        queue.async { self.blackFrames = 0; self.litFrames = 0; self.lastSeen = nil; self.resetAt = t }
        if visible { visible = false; onChange?(false) }
    }

    func start() {
        guard !running else { return }
        running = true; queue.async { self.blackFrames = 0; self.lastSeen = nil }
        stream?.startCapture { _ in }
    }

    func stop() {
        guard running else { return }
        running = false
        titlesAt = 0
        stream?.stopCapture { _ in }
        if visible { visible = false; onChange?(false) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { DispatchQueue.main.async { self.stream = nil } }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        // A static strip arrives as image-less idle frames: they repeat the last observation, otherwise the
        // black count stalls after the menu bar hides and the band never comes back.
        guard let px = CMSampleBufferGetImageBuffer(sb) else {
            if Self.status(sb) == .idle, lastSeen != nil { tally(lastSeen!); note(lastLit) }
            return
        }
        // Frames shown before the last reset may still be the desktop's menu bar.
        let shownAt = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?
            .first?[.displayTime] as? UInt64 ?? 0
        if shownAt >= resetAt { DispatchQueue.main.async { if self.running { self.onFrame?(px) } } }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), st = CVPixelBufferGetBytesPerRow(px)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var lit = 0, n = 0
        for side in sides {
            for x in stride(from: Int(side.lowerBound * Double(w)), to: Int(side.upperBound * Double(w)), by: 4) {
                for y in stride(from: 0, to: h, by: 4) {
                    let o = y * st + x * 4
                    if max(p[o], p[o + 1], p[o + 2]) > 24 { lit += 1 }
                    n += 1
                }
            }
        }
        // Titles on black light a few percent of the strip; a menu bar background lights most of it.
        let share = n > 0 ? Double(lit) / Double(n) : 0
        tally(share >= 0.6)
        // Titles and icons light about 1% or more; a privacy dot (camera, microphone) a few hundredths.
        lastLit = share >= 0.003
        note(lastLit)
        if FileManager.default.fileExists(atPath: Config.dir.appendingPathComponent("debug").path) {
            NSLog("matte-fill: menu bar strip lit \(String(format: "%.4f", share))")
        }
    }

    private static func status(_ sb: CMSampleBuffer) -> SCFrameStatus? {
        guard let a = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = a.first?[.status] as? Int else { return nil }
        return SCFrameStatus(rawValue: raw)
    }

    // Shows after 0.1 s of lit frames; hides after 0.15 s of plain black (60 fps), so it never flickers.
    private func note(_ lit: Bool) {
        guard lit else { return }
        DispatchQueue.main.async { if self.running { self.titlesAt = CACurrentMediaTime() } }
    }

    private func tally(_ seen: Bool) {
        lastSeen = seen
        blackFrames = seen ? 0 : blackFrames + 1
        litFrames = seen ? litFrames + 1 : 0
        let v = litFrames >= 6 || (visible && blackFrames < 9)
        DispatchQueue.main.async {
            guard self.running, v != self.visible else { return }
            self.visible = v
            self.onChange?(v)
        }
    }
}

// MARK: - Per-display session

final class Session {
    let cfg: Config
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    var bandPanel: OverlayPanel?
    var barsPanel: OverlayPanel?
    var bandView: BandView?
    var barsView: BarsView?
    var sampler: Sampler?
    var shown = false
    var current: OKLab
    var target: OKLab
    var bandRect = CGRect.zero
    var barRects: [CGRect] = []
    var snapNext = true
    var framesSinceShow = 0
    var sampling = false
    var native = false
    var probeAt = 0.0
    var wantLook = false
    var appTitle: String?
    var titleSeen: (title: String, since: Double)?
    var menuBar: MenuBarWatcher?
    var barCache: [String: [CGRect]] = [:]
    var fsSpaces = 0
    var pendingUntil = 0.0
    var holdUntil = 0.0
    var steady: (bounds: CGRect, since: Double)?
    var exiting = false
    var exitAt = 0.0
    var appPID: pid_t?
    var settledSpace = false
    var bandYielded = false
    var protectedMode = false
    let drm = ProtectedPlayback()
    var lastDRMCheck = 0.0
    var menuSeenAt = 0.0
    var pointerTopAt = 0.0
    var pointerAwayAt = 0.0
    var knownFS = Set<UInt64>()
    var pinned = false
    var memberSpaces = Set<UInt64>()
    var lastSweep = 0.0
    var shownAt = 0.0
    var shownKey: String?

    init(cfg: Config, screen: NSScreen, color: OKLab) {
        self.cfg = cfg
        self.screen = screen
        displayID = Display.id(of: screen)
        current = color
        target = color
        makePanels()
    }

    func tearDown() {
        hide()
        sampler?.stop(); sampler = nil
        menuBar?.stop(); menuBar = nil
        bandPanel?.orderOut(nil); barsPanel?.orderOut(nil)
        bandPanel = nil; barsPanel = nil; bandView = nil; barsView = nil
    }

    // Drive show/hide from full-screen state. Our two windows are members of full-screen Spaces only:
    // they join a new one the moment the system creates it, so the system draws them as part of that
    // Space from the first frame of its slide (in and out), and they never belong to a desktop Space.
    func refresh() {
        let now = CACurrentMediaTime()
        // Requirement 1 at run time: our windows never sit on another display (the system moves windows
        // when displays are rearranged); one that drifted is put straight back.
        for p in [bandPanel, barsPanel].compactMap({ $0 }) where p.frame != screen.frame {
            NSLog("matte-fill: [\(screen.localizedName)] window \(p.windowNumber) was at \(p.frame), put back on \(screen.frame)")
            p.setFrame(screen.frame, display: false)
        }
        let ids = Display.fullScreenSpaceIDs(screen)
        let fresh = ids.subtracting(knownFS)
        knownFS = ids
        memberSpaces.formIntersection(ids)
        if !fresh.isEmpty { adopt(fresh) }
        if now - lastSweep >= 0.5 { lastSweep = now; sweep() }
        let n = ids.count
        if n > fsSpaces { pendingUntil = now + 1.5 }
        if n < fsSpaces { pendingUntil = 0 }
        fsSpaces = n
        let reason = Display.fullScreenReason(screen)
        let settled = reason == "native full-screen space"
        if settled && !settledSpace {
            menuBar?.reset()   // only frames from the full-screen Space count
            bandView?.matte.setMirror(nil)
            if shown { pin() }
        }
        settledSpace = settled
        if shown { applyMenuBar() }
        if let why = reason ?? (Session.pluginFullScreen(on: screen) ? "IINA plugin: full screen" : nil) {
            pendingUntil = 0; holdUntil = 0; show(why: why)
        }
        else if now < pendingUntil { holdUntil = 0; show(why: "full-screen transition") }
        else if shown, holdUntil == 0 { holdUntil = now + Session.exitHold }
        else if now >= holdUntil { holdUntil = 0; hide() }
        if shown { watchForExit(now); paceSampling(now); paceMenuBar(now) }
        if now - lastDRMCheck >= 0.5 {
            lastDRMCheck = now
            if drm.playing(now: now), shown, !protectedMode { enterProtectedMode() }
        }
    }

    // Protected (DRM) video is playing: no capture of any kind runs from here until full screen ends,
    // so the video never blacks out. The notch band needs no capture and stays, easing to the default
    // color (config `fallbackColor`); in a browser's video full screen the menu bar never drops over it.
    // The bars inside the picture can't be located without capture, so they fade out (a browser
    // extension recolors them at the source instead).
    private func enterProtectedMode() {
        protectedMode = true
        NSLog("matte-fill: [\(screen.localizedName)] protected (DRM) video playing on some display: no capture, notch band in the default color")
        stopSampling()
        menuBar?.stop()
        bandYielded = false
        bandView?.setBandVisible(true)
        bandView?.matte.enabled = false
        target = ColorMath.fromHex(cfg.fallbackColor)
        snapNext = false
        if !barRects.isEmpty { applyBars([]) }
        barsView?.matte.enabled = false
    }

    // Space handling, measured frame by frame (2026-10-11): the system's slide into a new full-screen
    // Space never includes third-party windows, so entering keeps the windows on every Space
    // (`roaming`, which leaves the shortest black after the slide). Once the system has settled in
    // the full-screen Space they are pinned to it: leaving then slides them out with the Space with no
    // black frame, and swiping back to the desktop never carries them along.
    static let roaming: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    static let pinnedBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

    private func adopt(_ ids: Set<UInt64>) {
        memberSpaces.formUnion(ids)
        NSLog("matte-fill: [\(screen.localizedName)] full-screen Space \(ids.sorted()) appeared")
        if let bandPanel, let barsPanel {   // members from its creation, in case the slide snapshot honours it
            for p in [barsPanel, bandPanel] where !p.isVisible { p.alphaValue = 0; p.orderFrontRegardless() }
            SLSAddWindowsToSpaces(CGSMainConnectionID(), [bandPanel.windowNumber, barsPanel.windowNumber] as CFArray, Array(ids) as CFArray)
        }
        if pinned { pin() }
    }

    private func pin() {
        guard let bandPanel, let barsPanel, !memberSpaces.isEmpty else { return }
        pinned = true
        for p in [barsPanel, bandPanel] { p.collectionBehavior = Session.pinnedBehavior }
        SLSAddWindowsToSpaces(CGSMainConnectionID(), [bandPanel.windowNumber, barsPanel.windowNumber] as CFArray, Array(memberSpaces) as CFArray)
        lastSweep = 0; sweep()
    }

    private func unpin() {
        pinned = false
        for p in [barsPanel, bandPanel] { p?.collectionBehavior = Session.roaming }
    }

    // Safety net, every 0.5 s while pinned: our windows must never sit on a desktop (non-full-screen) Space.
    private func sweep() {
        guard pinned, !memberSpaces.isEmpty, let bandPanel, let barsPanel else { return }
        let others = Display.allSpaceIDs().subtracting(memberSpaces)
        guard !others.isEmpty else { return }
        SLSRemoveWindowsFromSpaces(CGSMainConnectionID(), [bandPanel.windowNumber, barsPanel.windowNumber] as CFArray, Array(others) as CFArray)
    }

    // Exit mirrors entry: entering, the band appears as the system transition starts and the bars ease
    // in once it is over; leaving, the bars ease back out as soon as the system starts its exit, and the
    // band goes when the system's slide takes over. The system gives ~0.6 s between the app's
    // full-screen window starting to change and the Space switch, so the same curve runs over that.
    static let exitFadeSeconds = 0.6

    // The app's full-screen window, once its bounds have held still for 0.5 s, is the steady state; any
    // later change in it (the system's exit animation replaces or resizes it) starts the exit.
    private func watchForExit(_ now: Double) {
        // The full-screen app is the owner of the window filling this display once the Space has switched;
        // at the start of the transition the window under the display's center may still be another app's.
        if settledSpace, steady == nil, let owner = Display.fullScreenOwner(screen), owner != appPID {
            NSLog("matte-fill: [\(screen.localizedName)] full-screen app is pid \(owner)")
            appPID = owner
        }
        let b = appPID.flatMap { Session.mainWindowBounds(screen, pid: $0) }
        // Learning: only once the system has switched to the full-screen Space, and only a window that
        // fills the screen and then holds still for 0.5 s; while entering, the window still changes.
        guard let st = steady, st.since == 0 else {
            if settledSpace, let b, fillsScreen(b) {
                if let st = steady, st.bounds == b { if now - st.since >= 0.5 { steady = (b, 0) } }   // 0 marks it settled
                else { steady = (b, now) }
            } else { steady = nil }
            return
        }
        if exiting, b == st.bounds || now - exitAt > 1.5 {
            // Not an exit after all (still in full screen): relearn the window; the sampler brings the
            // bars back with the normal ease-in.
            exiting = false; steady = nil
            NSLog("matte-fill: [\(screen.localizedName)] exit cancelled")
            wantLook = true
            return
        }
        if st.since == 0, b != st.bounds, !exiting {
            exiting = true; exitAt = now
            applyMenuBar()
            NSLog("matte-fill: [\(screen.localizedName)] exit started, bars ease out over \(Session.exitFadeSeconds)s")
            barRects = []
            barsView?.matte.enabled = false   // capture stops now; a frozen frame must not ride the fade
            barsView?.setRects([], animated: true, duration: Session.exitFadeSeconds)
        }
    }

    // A full-screen window covers the whole display below the menu bar area.
    private func fillsScreen(_ r: CGRect) -> Bool {
        let d = CGDisplayBounds(displayID)
        return r.minX <= d.minX + 1 && r.maxX >= d.maxX - 1 && r.maxY >= d.maxY - 1 && r.minY <= d.minY + bandRect.height + 1
    }

    // The full-screen app's largest on-screen window that covers most of this display.
    static func mainWindow(_ screen: NSScreen, pid: pid_t) -> (bounds: CGRect, title: String)? {
        let d = CGDisplayBounds(Display.id(of: screen))
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w -> (bounds: CGRect, title: String)? in
            guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd),
                  r.intersection(d).width * r.intersection(d).height >= 0.8 * d.width * d.height else { return nil }
            return (r, w[kCGWindowName as String] as? String ?? "")
        }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }

    static func mainWindowBounds(_ screen: NSScreen, pid: pid_t) -> CGRect? { mainWindow(screen, pid: pid)?.bounds }

    // Leaving full screen, the Space switches ~0.2 s before the system's slide starts drawing (a
    // snapshot that still holds our colors); staying that long hands over to it without a black frame.
    static let exitHold = 0.3

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

    private func makePanel(level: Int) -> OverlayPanel {
        let f = screen.frame
        let p = OverlayPanel(contentRect: f, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = NSWindow.Level(rawValue: level)
        p.collectionBehavior = Session.roaming
        p.ignoresMouseEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.setFrame(f, display: false)
        p.alphaValue = 0
        return p
    }

    // Two windows, each at the lowest level its job allows, so nothing of the system is ever covered:
    // the band sits just above the menu bar and covers exactly what it paints black, the bars just above the
    // full-screen app, below notifications, HUDs, menus and every other system window.
    private func makePanels() {
        let f = screen.frame
        let bp = makePanel(level: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        let bv = BandView(frame: NSRect(origin: .zero, size: f.size))
        bp.contentView = bv
        bv.matte.setColor(ColorMath.cgColor(current))
        bandRect = CGRect(x: 0, y: 0, width: f.width, height: Display.menuBarHeight(screen))
        NSLog("matte-fill: [\(screen.localizedName)] notch band height \(bandRect.height) (safe area \(screen.safeAreaInsets.top))")
        bv.setBand(bandRect)
        let rp = makePanel(level: Int(CGWindowLevelForKey(.normalWindow)) + 1)
        let rv = BarsView(frame: NSRect(origin: .zero, size: f.size))
        rv.fadeSeconds = cfg.fadeSeconds
        rp.contentView = rv
        rv.matte.setColor(ColorMath.cgColor(current))
        bandPanel = bp; barsPanel = rp; bandView = bv; barsView = rv
        if bandRect.height > 0 {
            let m = MenuBarWatcher(screen: screen)
            m.onChange = { [weak self] _ in self?.applyMenuBar() }
            m.onFrame = { [weak bv] px in bv?.matte.setMirror(px) }
            m.prepare(displayID: displayID, height: bandRect.height)
            menuBar = m
        }
        if cfg.adaptive || cfg.coverBars {
            let s = Sampler(cfg: cfg, bandFraction: Double(screen.safeAreaInsets.top / f.height), screenSize: f.size)
            s.onAnalysis = { [weak self] a in
                guard let self, self.shown, self.sampling else { return }   // no stale frames once capture stopped
                if self.framesSinceShow == 0 || (self.framesSinceShow == 25) {
                    NSLog("matte-fill: [\(self.screen.localizedName)] frame \(self.framesSinceShow) color=\(a.color.map(ColorMath.hex) ?? "-") bars=\(a.rects.count) rects \(a.rects.first.map { "first=\($0)" } ?? "")")
                }
                self.framesSinceShow += 1
                if let c = a.color {
                    self.target = c
                    if self.snapNext { self.current = c; self.snapNext = false; self.setColor(c) }   // first sample: no fade
                }
                if !self.exiting, a.rects != self.barRects { self.applyBars(a.rects) }
                if let k = self.shownKey, self.framesSinceShow > 3 { self.barCache[k] = a.rects }
            }
            s.onMirror = { [weak self] px in self?.barsView?.matte.setMirror(px) }
            sampler = s
            let did = displayID, wid = CGWindowID(bp.windowNumber)
            s.onLost = { [weak s] in s?.prepare(displayID: did, excludeWindowID: wid) }
            s.prepare(displayID: did, excludeWindowID: wid)
        }
    }

    // The band yields only to the full-screen Space's own menu bar: while the system is still switching
    // Spaces (entering or leaving) the strip shows the desktop's menu bar, and the band stays put.
    private func applyMenuBar() {
        let now = CACurrentMediaTime()
        let own = settledSpace && !exiting
        bandView?.matte.enabled = own && !protectedMode
        let seen = (menuBar?.visible ?? false) && own
        if !seen { menuSeenAt = 0 } else if menuSeenAt == 0 { menuSeenAt = now }
        let p = NSEvent.mouseLocation, f = screen.frame
        let top = own && p.x >= f.minX && p.x <= f.maxX && p.y >= f.maxY - 2 && p.y <= f.maxY + 1
        let below = !(p.x >= f.minX && p.x <= f.maxX && p.y >= f.maxY - bandRect.height - 4)
        if !top { pointerTopAt = 0 } else if pointerTopAt == 0 { pointerTopAt = now }
        if !below { pointerAwayAt = 0 } else if pointerAwayAt == 0 { pointerAwayAt = now }
        let yield = Session.menuBarYield(watching: menuBar?.isRunning == true, background: seen && now - menuSeenAt >= 0.15,
                                         pointerTopFor: pointerTopAt == 0 ? 0 : now - pointerTopAt,
                                         pointerAwayFor: pointerAwayAt == 0 ? 0 : now - pointerAwayAt, yielded: bandYielded)
        guard yield != bandYielded else { return }
        bandYielded = yield
        NSLog("matte-fill: [\(screen.localizedName)] \(yield ? "menu bar shown, band yields" : "band back")")
        bandView?.setBandVisible(!yield)
    }

    // The band never keeps the menu bar covered. While the strip is watched, the band stays and mirrors
    // the menu bar's titles over the fill, yielding only to a menu bar with a background of its own (held
    // 0.15 s: leaving full screen flashes it for a frame or two). When it can't be watched (protected video
    // allows no capture), the pointer decides: resting 0.4 s at the very top, where the full-screen menu bar
    // drops from, the band yields; it comes back 1 s after the pointer has left the menu bar area.
    static func menuBarYield(watching: Bool, background: Bool, pointerTopFor: Double, pointerAwayFor: Double, yielded: Bool) -> Bool {
        if watching { return background }
        if yielded { return pointerAwayFor < 1 }
        return pointerTopFor >= 0.4
    }

    private func setColor(_ c: OKLab) {
        let cg = ColorMath.cgColor(c)
        bandView?.matte.setColor(cg)
        barsView?.matte.setColor(cg)
    }

    private func show(why: String) {
        guard !shown, let bandPanel, let barsPanel else { return }
        shown = true
        snapNext = false   // the band shows the last color through the transition and eases to the new one
        framesSinceShow = 0
        steady = nil
        exiting = false
        // The app going full screen on this display, not the frontmost app: with two displays the user
        // may be working in another app on the other one.
        let front = Display.frontApp(on: screen).flatMap { NSRunningApplication(processIdentifier: $0) } ?? NSWorkspace.shared.frontmostApplication
        appPID = front?.processIdentifier
        native = Session.nativelyHandled(front)
        let protected = drm.playing(now: CACurrentMediaTime())
        NSLog("matte-fill: [\(screen.localizedName)] show [\(why)]\(native ? " (IINA plugin)" : "") (capture access: \(CGPreflightScreenCaptureAccess()))")
        for p in [bandPanel, barsPanel] { p.setFrame(screen.frame, display: false) }
        shownKey = Display.fullScreenWindowKey(screen)
        if native, let c = ShotAnalyzer.lastColor {
            // mpv's background already shows the color of the latest analyzed frame; start from it
            // and ease toward live samples instead of snapping.
            current = c; target = c; snapNext = false; setColor(c)
        }
        sampler?.barsEnabled = !native
        if let k = shownKey, let cached = barCache[k], !native { applyBars(cached) }   // same window as before
        shownAt = CACurrentMediaTime()
        for p in [barsPanel, bandPanel] { p.orderFrontRegardless(); p.alphaValue = 1 }
        if settledSpace { pin() }
        if protected {
            // Already playing protected video: start in the default color and never start a capture.
            current = ColorMath.fromHex(cfg.fallbackColor); setColor(current)
            enterProtectedMode()
            return
        }
        appTitle = appPID.flatMap { Session.mainWindow(screen, pid: $0)?.title }
        wantLook = true
    }

    // The one gate every capture of ours passes (tests/2-animation checks that no other path starts one).
    // The system's own transitions (zooming into or out of full screen, sliding Spaces) run with no capture
    // at all, so nothing competes with their frames: capture starts only once the full-screen window has
    // held still for 0.5 s (legacy full screen: 1 s after showing) and stops the moment an exit begins.
    // Protected video playing on any display (tests/1-external) allows none either.
    static func captureAllowed(shown: Bool, protected: Bool, exiting: Bool, settledSpace: Bool, windowSettled: Bool,
                               legacyFullScreen: Bool, sinceShown: Double) -> Bool {
        guard shown, !protected, !exiting else { return false }
        if settledSpace { return windowSettled }
        return legacyFullScreen && sinceShown >= 1
    }

    // `strip`: the menu bar watcher's capture, which needs only the Space switch done (the menu bar must be
    // watched even while an app's full-screen window keeps changing); the sampler also waits for the window.
    private func calm(_ now: Double, strip: Bool = false) -> Bool {
        Session.captureAllowed(shown: shown, protected: protectedMode, exiting: exiting, settledSpace: settledSpace,
                               windowSettled: strip || steady?.since == 0, legacyFullScreen: !settledSpace && Session.pluginFullScreen(on: screen),
                               sinceShown: now - shownAt)
    }

    // Capture runs only while it is needed, since macOS shows its screen-recording indicator for as long as
    // any runs: video (bars painted, or IINA's plugin) keeps it live; any other full-screen app gets a short
    // look for its color and bars, then capture stops. A new window title (another page, another file)
    // takes a fresh look.
    static let probeSeconds = 3.0

    private func startSampling() {
        guard !sampling, calm(CACurrentMediaTime()), let sampler else { return }
        sampling = true
        probeAt = CACurrentMediaTime()
        NSLog("matte-fill: [\(screen.localizedName)] capture on")
        sampler.start()
        if let pid = appPID { sampler.focus(pid: pid) }
        if !barRects.isEmpty { sampler.setMirror(true) }
    }

    // On a notched display the full-screen menu bar window never moves (it paints the band black while
    // hidden), so only its pixels tell, and they also feed the band's mirror. The strip is watched only
    // while the pointer is at the top of the screen, the one place it drops from, or while it is still out.
    private func paceMenuBar(_ now: Double) {
        guard let menuBar, !protectedMode else { return }
        let p = NSEvent.mouseLocation, f = screen.frame
        let near = calm(now, strip: true) && p.x >= f.minX && p.x <= f.maxX && p.y >= f.maxY - bandRect.height - 8 && p.y <= f.maxY
        // Keep watching until the strip has been plain black for 0.3 s, so the mirror never freezes on titles.
        if near || (calm(now, strip: true) && (menuBar.visible || now - menuBar.titlesAt < 0.3)) {
            if !menuBar.isRunning { NSLog("matte-fill: [\(screen.localizedName)] menu bar watch on"); menuBar.start() }
        } else if menuBar.isRunning {
            NSLog("matte-fill: [\(screen.localizedName)] menu bar watch off")
            menuBar.stop(); bandView?.matte.setMirror(nil)
        }
    }

    private func stopSampling() {
        guard sampling else { return }
        sampling = false
        NSLog("matte-fill: [\(screen.localizedName)] capture off")
        sampler?.stop()
    }

    private func paceSampling(_ now: Double) {
        guard !protectedMode, let pid = appPID else { return }
        guard calm(now) else { stopSampling(); return }
        if sampling {
            if !native, barRects.isEmpty, barsView?.matte.enabled != true, now - probeAt >= Session.probeSeconds { stopSampling() }
        } else if wantLook {
            wantLook = false
            startSampling()
        } else if let st = steady, st.since == 0, let m = Session.mainWindow(screen, pid: pid), m.title != appTitle {
            // The title must hold for 1 s in the unchanged full-screen window: leaving full screen retitles
            // some apps, and the moving exit animation must never be read as a new video's bars.
            guard m.bounds == st.bounds else { titleSeen = nil; return }
            if titleSeen?.title != m.title { titleSeen = (m.title, now) }
            guard now - titleSeen!.since >= 1 else { return }
            appTitle = m.title; titleSeen = nil
            startSampling()
        } else { titleSeen = nil }
    }

    func hide() {
        guard shown else { return }
        shown = false
        protectedMode = false
        exiting = false
        steady = nil
        NSLog("matte-fill: [\(screen.localizedName)] hide (last color \(ColorMath.hex(current)))")
        stopSampling()
        menuBar?.stop()
        bandYielded = false
        bandView?.setBandVisible(true)
        bandView?.matte.enabled = false
        bandView?.matte.setMirror(nil)
        bandPanel?.orderOut(nil); barsPanel?.orderOut(nil)
        bandPanel?.alphaValue = 0; barsPanel?.alphaValue = 0
        unpin()
        barRects = []
        barsView?.setRects([], animated: false)
        barsView?.matte.enabled = false
        barsView?.matte.setMirror(nil)
    }

    // Bars ease in, out and between sizes (BarsView); the mirror runs only while some bar is painted.
    private func applyBars(_ rects: [CGRect]) {
        if barRects.isEmpty, !rects.isEmpty { NSLog("matte-fill: [\(screen.localizedName)] bars ease in over \(cfg.fadeSeconds)s") }
        barRects = rects
        barsView?.setRects(rects, animated: cfg.fadeSeconds > 0.01)
        if !rects.isEmpty {
            barsView?.matte.enabled = true
            if sampling, calm(CACurrentMediaTime()) { sampler?.setMirror(true) }
            return
        }
        // Keep passing the app's UI through until the leaving bars have fully faded out.
        DispatchQueue.main.asyncAfter(deadline: .now() + cfg.fadeSeconds) { [weak self] in
            guard let self, self.barRects.isEmpty else { return }
            self.barsView?.matte.enabled = false
            self.sampler?.setMirror(false)
        }
    }

    // Exponential smoothing toward the sampled target; the first sample after entering full screen snaps.
    func tick(dt: Double, now: Double) {
        guard shown else { return }
        let k = snapNext ? 0 : 1 - exp(-dt / max(0.05, cfg.smoothingSeconds))
        current = OKLab(L: current.L + (target.L - current.L) * k,
                        a: current.a + (target.a - current.a) * k,
                        b: current.b + (target.b - current.b) * k)
        setColor(current)
        let (r, g, b) = ColorMath.toSRGB(current)
        sampler?.tintBytes = (Int(r * 255 + 0.5), Int(g * 255 + 0.5), Int(b * 255 + 0.5))
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
    var lastWritten: String?
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
        lastWritten = nil
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
        let json = "{\"displays\":\"\(cfg.displays)\",\"fade\":\(cfg.fadeSeconds),\"screens\":[\(body)],\"t\":\(Date().timeIntervalSince1970)}"
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

// Offline self-test: feed screenshots in order, each as 2 simulated seconds of playback, and print what
// would be painted after each (several files simulate UI appearing, layout changes and so on).
// `--screen WxHxTOP` fixes the screen geometry and uses the default config, so results don't depend on the
// displays attached or the local config (tools/check.sh relies on this).
let fixedScreen: (size: CGSize, top: CGFloat)? = args.firstIndex(of: "--screen").flatMap { k in
    let v = k + 1 < args.count ? args[k + 1].split(separator: "x").compactMap { Double($0) } : []
    return v.count == 3 ? (CGSize(width: v[0], height: v[1]), CGFloat(v[2])) : nil
}
if let i = args.firstIndex(of: "--analyze"), i + 1 < args.count,
   let size = fixedScreen?.size ?? (Display.targetScreens(Config.load()).first ?? NSScreen.main)?.frame.size {
    let top = fixedScreen?.top ?? (Display.targetScreens(Config.load()).first ?? NSScreen.main)?.safeAreaInsets.top ?? 0
    let w = Int(size.width) / 2, h = Int(size.height) / 2
    let s = Sampler(cfg: fixedScreen == nil ? Config.load() : Config(), bandFraction: Double(top / size.height), screenSize: size)
    s.assumeMotion = !args.contains("--still")
    var t = 0.0
    // `--hold S`: each image stands for S seconds of frames (default 2 s at 10 fps); `--transition` and `--keep` only label a case.
    var skip: Set<String> = ["--still", "--screen", "--hold", "--transition", "--keep"]
    if let k = args.firstIndex(of: "--screen"), k + 1 < args.count { skip.insert(args[k + 1]) }
    let hold = args.firstIndex(of: "--hold").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
    if let k = args.firstIndex(of: "--hold"), k + 1 < args.count { skip.insert(args[k + 1]) }
    for path in args[(i + 1)...] where !skip.contains(path) {
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("unreadable:", path); continue }
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, nil, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb!), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        var a = Analysis(color: nil, rects: [])
        if let hold {
            let dt = min(0.1, hold)
            for _ in 0..<max(1, Int((hold / dt).rounded())) { a = s.analyze(pb!, now: t); t += dt }
        } else {
            for _ in 0...20 { a = s.analyze(pb!, now: t); t += 0.1 }
        }
        if args[(i + 1)...].filter({ !skip.contains($0) }).count > 1 { print("after", (path as NSString).lastPathComponent) }
        print("color:", a.color.map(ColorMath.hex) ?? "none")
        for r in a.rects { print("rect:", r) }
    }
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
    let v = BarsView(frame: NSRect(origin: .zero, size: screen.frame.size))
    p.contentView = v
    v.matte.setColor(ColorMath.cgColor(ColorMath.fromHex("#C04040")))
    v.setRects([CGRect(x: 0, y: screen.safeAreaInsets.top, width: screen.frame.width, height: 100)], animated: false)
    p.orderFrontRegardless()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
    app.run()
}   // no Dock icon, never takes focus
NSLog("matte-fill: started (capture access: \(CGPreflightScreenCaptureAccess()))")
let controller = Controller()
controller.run()
app.run()

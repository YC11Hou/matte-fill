import AppKit

// Live, read-only check of requirement 1 while the computer is in normal use: every 0.1 s it records whether
// any Matte window is on screen over a non-target display, and when the external display's front window
// changes. No capture, no input, no focus. Usage: watch <seconds> <logfile>
let secs = Double(CommandLine.arguments.dropFirst().first ?? "600") ?? 600
let out = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/dev/stdout"
FileManager.default.createFile(atPath: out, contents: nil)
let fh = FileHandle(forWritingAtPath: out)!
let fmt = DateFormatter(); fmt.dateFormat = "HH:mm:ss.SSS"
func log(_ s: String) { fh.write((fmt.string(from: Date()) + " " + s + "\n").data(using: .utf8)!) }
var last = ""
let t0 = Date()
while Date().timeIntervalSince(t0) < secs {
    let external = NSScreen.screens.filter { CGDisplayIsBuiltin(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value) == 0 }
        .map { CGDisplayBounds(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value) }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var lines: [String] = []
    for w in list {
        guard let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd) else { continue }
        let owner = w[kCGWindowOwnerName as String] as? String ?? ""
        let alpha = w[kCGWindowAlpha as String] as? Double ?? 0
        for e in external where r.intersects(e) {
            if owner == "Matte" && alpha > 0 { lines.append("VIOLATION Matte window \(w[kCGWindowNumber as String] ?? 0) on external \(r)") }
            if (w[kCGWindowLayer as String] as? Int) == 0, r.width >= e.width - 1, r.height >= e.height - 40 {
                lines.append("external full-size window: \(owner) \(Int(r.width))x\(Int(r.height))")
            }
        }
    }
    let now = lines.sorted().joined(separator: " | ")
    if now != last { log(now.isEmpty ? "external: no full-size window, no Matte window" : now); last = now }
    usleep(100_000)
}

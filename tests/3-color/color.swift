import Cocoa

// Requirement 3: on the built-in display every area the system paints black comes out as the fill, in
// every case, with whatever floats on the black (menu titles, player UI) intact. Rendered offline with the
// real BandView / BarsView through CARenderer (1x: texture size = layer points).
func runColor() {
    let fillColor = CGColor(red: 68 / 255, green: 85 / 255, blue: 74 / 255, alpha: 1)
    let W = 1470, BAND = 33

    // The fill as the renderer outputs it (color management included), from a band with no mirror.
    let band = BandView(frame: NSRect(x: 0, y: 0, width: W, height: BAND))
    band.setBand(CGRect(x: 0, y: 0, width: W, height: BAND))
    band.matte.setColor(fillColor)
    let bt = Target(band.layer!, w: W, h: BAND)
    var px = bt.render()
    let F = px(700, 16)

    print("notch band")
    check(max(F.0, F.1, F.2) > 20, "1. menu bar hidden: the band is the fill \(F), not black")
    check(uniform(px, 0..<W, 0..<BAND, F), "1. menu bar hidden: the whole band is one fill")

    // Menu bar dropped down: its own black background with white titles and a gray icon.
    let menu = frame(W, BAND) { x, y in
        if y >= 10 && y < 23 { if x >= 20 && x < 120 { return 255 }; if x >= 1300 && x < 1320 { return 128 } }
        return 0
    }
    band.matte.enabled = true
    band.matte.setMirror(menu)
    px = bt.render()
    check(uniform(px, 200..<1200, 0..<BAND, F), "2. menu bar shown: its black background becomes exactly the fill")
    check(px(50, 15) == (255, 255, 255), "2. menu bar shown: white titles stay white \(px(50, 15))")
    let icon = px(1310, 15)
    check(icon.0 > F.0 && icon.0 < 255, "2. menu bar shown: a gray icon blends over the fill \(icon)")

    band.matte.setMirror(nil)
    px = bt.render()
    check(uniform(px, 0..<W, 0..<BAND, F), "2. menu bar gone again: no titles left behind")

    // Protected video / system transition: capture is off and the mirror disabled; a frame still held
    // from before must not show.
    band.matte.setMirror(menu)
    band.matte.enabled = false
    px = bt.render()
    check(uniform(px, 0..<W, 0..<BAND, F), "3/6. no capture (transition, DRM): plain fill, a held frame never shows")

    print("bars")
    let BW = 400, BH = 300
    let bars = BarsView(frame: NSRect(x: 0, y: 0, width: BW, height: BH))
    bars.matte.setColor(fillColor)
    let rt = Target(bars.layer!, w: BW, h: BH)
    let video = frame(BW, BH) { x, y in
        if y >= 60 { return 120 }                                   // picture
        if y >= 20 && y < 30 && x >= 100 && x < 200 { return 255 }  // subtitle in the bar
        return x >= 300 && x < 320 ? 0 : 14                         // player black and encoded video black
    }
    bars.setRects([CGRect(x: 0, y: 0, width: BW, height: 60)], animated: false)
    bars.matte.enabled = true
    bars.matte.setMirror(video)
    px = rt.render()
    check(near(px(50, 40), F), "4. encoded video black (14) becomes the fill \(px(50, 40))")
    check(near(px(310, 40), F), "4. player black (0) becomes the fill \(px(310, 40))")
    check(px(150, 25) == (255, 255, 255), "4. a subtitle in the bar stays white")
    check(px(50, 150) == (0, 0, 0), "4. nothing is painted outside the bar")
    check(near(px(50, 40), F, 0), "4/1. bars and band share one fill, exactly")
}

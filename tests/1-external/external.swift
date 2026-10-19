import Foundation

// Requirement 1: the external display is never affected. Matte runs only on the built-in display (unless
// the user turns on "all"), and since a browser blacks out protected video when any capture runs anywhere,
// a DRM movie on the external display stops every capture of ours.
func runExternal() {
    check(!Display.isTarget(builtin: false, displays: "builtin"), "an external display is not a target by default")
    check(Display.isTarget(builtin: true, displays: "builtin"), "the built-in display is the target")
    check(Display.isTarget(builtin: false, displays: "all"), "\"all\" (user's switch) includes the external display")

    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper --type=utility --utility-sub-type=media.mojom.CdmServiceBroker"
    let edge = "/Applications/Microsoft Edge.app/Contents/Frameworks/Microsoft Edge Framework.framework/Helpers/Microsoft Edge Helper.app/Contents/MacOS/Microsoft Edge Helper --type=utility --utility-sub-type=media.mojom.CdmServiceBroker"
    let spotify = "/Applications/Spotify.app/Contents/Frameworks/Spotify Helper.app/Contents/MacOS/Spotify Helper --type=utility --utility-sub-type=media.mojom.CdmServiceBroker"
    let renderer = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer) --type=renderer"
    check(ProtectedPlayback.isBrowserCDM(chrome), "Chrome's CDM counts as protected playback (on any display)")
    check(ProtectedPlayback.isBrowserCDM(edge), "Edge's CDM counts as protected playback")
    check(!ProtectedPlayback.isBrowserCDM(spotify), "Spotify's CDM (audio) does not count")
    check(!ProtectedPlayback.isBrowserCDM(renderer), "a browser renderer without a CDM does not count")

    var any = false
    for settled in [false, true] { for win in [false, true] { for legacy in [false, true] { for t in [0.0, 5.0] {
        any = any || Session.captureAllowed(shown: true, protected: true, exiting: false, settledSpace: settled,
                                            windowSettled: win, legacyFullScreen: legacy, sinceShown: t)
    } } } }
    check(!any, "protected playback anywhere: no capture in any state")
}

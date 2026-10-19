import Foundation

// Requirement 2: the built-in display's system animations stay exactly as they are and never drop a frame:
// Matte never changes a system setting or animation (checked on the source by structure.py), and runs no
// capture of any kind while the system zooms into or out of full screen or slides Spaces.
func runAnimation() {
    func allowed(shown: Bool = true, exiting: Bool = false, settled: Bool, window: Bool, legacy: Bool = false, t: Double = 5) -> Bool {
        Session.captureAllowed(shown: shown, protected: false, exiting: exiting, settledSpace: settled,
                               windowSettled: window, legacyFullScreen: legacy, sinceShown: t)
    }
    check(!allowed(settled: false, window: false, t: 0.2), "entering: Space not settled yet (zoom running), no capture")
    check(!allowed(settled: true, window: false), "entering: window not held still for 0.5 s yet, no capture")
    check(allowed(settled: true, window: true), "settled full screen: capture allowed")
    check(!allowed(exiting: true, settled: true, window: true), "exiting (zoom out running): no capture")
    check(!allowed(shown: false, settled: true, window: true), "not in full screen: no capture")
    check(!allowed(settled: false, window: false, legacy: true, t: 0.5), "legacy full screen, first second: no capture")
    check(allowed(settled: false, window: false, legacy: true, t: 1.5), "legacy full screen after 1 s: capture allowed")
}

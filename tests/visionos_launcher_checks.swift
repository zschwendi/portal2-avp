// Host checks for visionos/Sources/PortalLauncherModel.swift. Built and run by
// tests/test_visionos_launcher.py; no GameController, engine or headset.
import Foundation

@main struct LauncherChecks {
static func main() {
var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { failures += 1; print("FAIL line \(line): \(message)") }
}

// A lone Sense controller (partner asleep) must not lock out a DualSense.
do {
    check(!PortalControllerRoute.senseOwnsInput(senseDevices: 1, gamepadConnected: true), "lone Sense yields to a gamepad")
    check(PortalControllerRoute.senseOwnsInput(senseDevices: 1, gamepadConnected: false), "lone Sense plays without a gamepad")
    check(PortalControllerRoute.senseOwnsInput(senseDevices: 2, gamepadConnected: true), "a pair beats a gamepad")
    check(!PortalControllerRoute.senseOwnsInput(senseDevices: 0, gamepadConnected: false), "nothing connected")
    check(PortalControllerRoute.resolve(senseDevices: 1, gamepads: ["DualSense"]) == .gamepad("DualSense"),
          "readiness names the pad that actually plays")
    check(PortalControllerRoute.resolve(senseDevices: 2, gamepads: ["DualSense"]) == .sensePair, "pair readiness")
    check(PortalControllerRoute.resolve(senseDevices: 1, gamepads: []) == .singleSense, "one-handed Sense is flagged")
    check(!PortalControllerRoute.singleSense.ready && !PortalControllerRoute.none.ready, "incomplete routes are not ready")
}

// Only losing the controller that plays pauses, and only during gameplay.
do {
    func pauses(_ owner: PortalRouteLoss.Owner, spatial: Bool = false, pad: Bool = false,
                running: Bool = true, menu: Bool = false) -> Bool {
        PortalRouteLoss.pauses(owner: owner, lostSpatial: spatial, lostSelectedGamepad: pad,
                               engineRunning: running, gameUIVisible: menu)
    }
    check(pauses(.gamepad, pad: true), "playing pad lost")
    check(pauses(.spatial, spatial: true), "a Sense controller of the playing pair lost")
    check(!pauses(.spatial, pad: true), "spare DualSense removed while Sense plays")
    check(!pauses(.gamepad, spatial: true), "idle Sense removed while a pad plays")
    check(!pauses(.gamepad, pad: false), "a second, unselected pad removed")
    check(!pauses(.gamepad, pad: true, menu: true), "already in a menu: a pause press would resume")
    check(!pauses(.gamepad, pad: true, running: false), "no engine yet")
    check(!pauses(.hands, spatial: true, pad: true) && !pauses(.none, pad: true), "hands/none never pause")
}

// The card never offers Play for incomplete files, and never Play twice.
do {
    func card(engine: Int32 = 0, content: Bool? = true, nothing: Bool = false, importing: Bool = false,
              fraction: Double? = nil, starting: Bool = false) -> PortalCardState {
        PortalCardState.resolve(engine: engine, content: content, nothingImported: nothing, importing: importing,
                                importFraction: fraction, starting: starting)
    }
    check(card().action == .play, "complete files: Play")
    check(card(engine: -1, content: false, nothing: true) == .needsFiles(incomplete: false), "nothing imported")
    check(card(engine: -1, content: false).action == .importFiles, "start refused by the gate: Import")
    check(card(content: nil).action == .wait, "before the first check finishes")
    check(card(importing: true, fraction: 0.5) == .importing(fraction: 0.5), "import progress")
    check(card(content: true, importing: true).action == .showProgress, "an import outranks Play")
    check(card(starting: true).action == .wait, "Play pressed: no second start")
    check(card(engine: 1).action == .resume, "Library over the running game: Resume")
    check(card(engine: 1, importing: true).action == .resume, "never import over a running engine")
    if case .explain = card(engine: 2).action {} else { check(false, "stopped engine explains instead of playing") }
}

if failures > 0 { print("\(failures) launcher check(s) failed"); exit(1) }
print("launcher checks passed")
}
}

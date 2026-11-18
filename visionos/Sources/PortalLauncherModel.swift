import Foundation

// Launcher rules without UI or engine types, so an iPad/iPhone launcher can
// share them and tests/visionos_launcher_checks.swift can run them on a Mac.

// What the Library card shows. The engine has one lifetime per process, so a
// stopped engine cannot be played again without relaunching the app.
enum PortalCardState: Equatable, Sendable {
    case checking
    case needsFiles(incomplete: Bool)   // nothing imported yet, or some files missing
    case importing(fraction: Double?)
    case ready
    case continueCampaign
    case starting
    case paused                          // the Library is shown over the running game
    case stopped

    // p2_vision_game_state: 0 idle, 1 starting/running, 2 returned, -1 content incomplete.
    // `content`: the last check's verdict (nil: none finished yet).
    static func resolve(engine: Int32, content: Bool?, nothingImported: Bool, importing: Bool,
                        importFraction: Double?, starting: Bool, campaignSaveAvailable: Bool = false) -> PortalCardState {
        switch engine {
        case 1: return .paused
        case 2: return .stopped
        default: break
        }
        if importing { return .importing(fraction: importFraction) }
        if starting { return .starting }
        switch content {
        case .some(true): return campaignSaveAvailable ? .continueCampaign : .ready
        case .some(false): return .needsFiles(incomplete: !nothingImported)
        case .none: return .checking
        }
    }

    var action: PortalCardAction {
        switch self {
        case .needsFiles: return .importFiles
        case .importing: return .showProgress
        case .ready: return .play
        case .continueCampaign: return .continueCampaign
        case .paused: return .resume
        case .stopped: return .explain(Self.stoppedReason)
        case .checking, .starting: return .wait
        }
    }

    static let stoppedReason = "Portal 2 has stopped. Close and reopen the app to play again."

    var statusLabel: String {
        switch self {
        case .checking: return "Checking game files"
        case .needsFiles(let incomplete): return incomplete ? "Game files incomplete" : "Game files needed"
        case .importing: return "Importing game files"
        case .ready, .continueCampaign: return "Ready to play"
        case .starting: return "Starting"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }

    var symbolName: String {
        switch self {
        case .checking, .starting, .importing: return "hourglass"
        case .needsFiles: return "tray.and.arrow.down"
        case .ready, .continueCampaign: return "checkmark.circle.fill"
        case .paused: return "pause.circle.fill"
        case .stopped: return "stop.circle"
        }
    }
}

enum PortalCardAction: Equatable, Sendable {
    case importFiles, play, continueCampaign, resume, showProgress, wait
    case explain(String)

    var title: String {
        switch self {
        case .importFiles: return "Import"
        case .play: return "Play"
        case .continueCampaign: return "Continue"
        case .resume: return "Resume"
        case .showProgress: return "Progress"
        case .wait: return "Please wait"
        case .explain: return "Details"
        }
    }

    var symbolName: String {
        switch self {
        case .importFiles: return "tray.and.arrow.down"
        case .play, .continueCampaign: return "play.fill"
        case .resume: return "playpause.fill"
        case .showProgress: return "list.bullet.rectangle"
        case .wait: return "hourglass"
        case .explain: return "info.circle"
        }
    }

    var prominent: Bool {
        switch self {
        case .importFiles, .play, .continueCampaign, .resume: return true
        case .showProgress, .wait, .explain: return false
        }
    }
}

// Which controller route plays. PortalController and the readiness strip use
// the same rule, so what the Library says is what the game receives.
enum PortalControllerRoute: Equatable, Sendable {
    case sensePair
    case gamepad(String)
    case singleSense      // one Sense controller and no gamepad: playable, one-handed
    case none

    // Both Sense controllers own input even while one is still resolving (a
    // gamepad must not fight a pair). A lone Sense controller — its partner
    // asleep or out of battery — yields to a connected gamepad.
    static func senseOwnsInput(senseDevices: Int, gamepadConnected: Bool) -> Bool {
        senseDevices >= 2 || (senseDevices == 1 && !gamepadConnected)
    }

    static func resolve(senseDevices: Int, gamepads: [String]) -> PortalControllerRoute {
        if senseOwnsInput(senseDevices: senseDevices, gamepadConnected: !gamepads.isEmpty) {
            return senseDevices >= 2 ? .sensePair : .singleSense
        }
        if let first = gamepads.first { return .gamepad(first) }
        return .none
    }

    var ready: Bool {
        switch self {
        case .sensePair, .gamepad: return true
        case .singleSense, .none: return false
        }
    }

    var summary: String {
        switch self {
        case .sensePair: return "PS VR2 Sense controllers ready"
        case .gamepad(let name): return "\(name) ready"
        case .singleSense: return "Connect your other Sense controller"
        case .none: return "Connect a controller to play"
        }
    }

    var detail: String {
        switch self {
        case .sensePair: return "In immersive view, aim portals with the right controller."
        case .gamepad: return "R2 fires blue, L2 fires orange."
        case .singleSense: return "Only one hand\u{2019}s controls work until both are connected."
        case .none: return "DualSense, PS VR2 Sense or another gamepad. Hand gestures also work in immersive view."
        }
    }
}

// Fixed-hand Sense bindings from resolved accessory identities
// (PortalSenseTracking). A controller can be listed before its identity
// resolves; the refresh retries on this bounded schedule while connections are
// unchanged, and a retry replaces the bindings only when it binds more hands.
enum PortalSenseBinding {
    enum Hand: Equatable, Sendable { case left, right, other }

    // Seconds before each retry of a refresh that left a controller unbound.
    static let retryDelays: [Double] = [0.5, 1, 2, 4, 8, 8]

    // Indices of the one identity per hand, left first. A hand reported twice
    // binds neither; .other never binds.
    static func assign(_ hands: [Hand]) -> [Int] {
        [Hand.left, .right].compactMap { hand in
            let matches = hands.indices.filter { hands[$0] == hand }
            return matches.count == 1 ? matches[0] : nil
        }
    }

    // Every connected controller, up to a pair, has a hand.
    static func complete(connected: Int, bound: Int) -> Bool { bound >= min(connected, 2) }

    // The first pass always applies; a retry only when it binds more.
    static func adopts(attempt: Int, bound: Int, current: Int) -> Bool { attempt == 0 || bound > current }
}

// Losing the controller that is playing pauses the game, once, during
// gameplay. A spare device leaving (a DualSense while a Sense pair plays, one
// of two gamepads) changes nothing.
enum PortalRouteLoss {
    enum Owner: Equatable, Sendable { case spatial, gamepad, hands, none }

    static func pauses(owner: Owner, lostSpatial: Bool, lostSelectedGamepad: Bool,
                       engineRunning: Bool, gameUIVisible: Bool) -> Bool {
        guard engineRunning, !gameUIVisible else { return false }
        switch owner {
        case .spatial: return lostSpatial
        case .gamepad: return lostSelectedGamepad
        case .hands, .none: return false
        }
    }
}

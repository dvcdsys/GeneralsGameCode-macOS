import Foundation
import AppKit

enum AspectRatio: String, CaseIterable, Identifiable {
    case fourThree  = "4:3"
    case sixteenNine = "16:9"
    case sixteenTen  = "16:10"
    var id: String { rawValue }
    var ratio: Double {
        switch self {
        case .fourThree:   return 4.0 / 3.0
        case .sixteenNine: return 16.0 / 9.0
        case .sixteenTen:  return 16.0 / 10.0
        }
    }
}

/// Resolutions for one aspect ratio (a Picker section).
struct ResolutionGroup: Identifiable {
    let aspect: AspectRatio
    var items: [GameResolution]
    var id: String { aspect.rawValue }
}

/// A selectable screen resolution. `Options.ini` stores it as `Resolution = W H`.
struct GameResolution: Identifiable, Hashable {
    let w: Int
    let h: Int
    let aspect: AspectRatio

    var id: String { "\(w)x\(h)" }
    var label: String { "\(w) × \(h)" }

    /// Common resolutions grouped by aspect ratio.
    static let catalogue: [GameResolution] = [
        .init(w: 1024, h: 768,  aspect: .fourThree),
        .init(w: 1280, h: 960,  aspect: .fourThree),
        .init(w: 1600, h: 1200, aspect: .fourThree),
        .init(w: 1280, h: 720,  aspect: .sixteenNine),
        .init(w: 1920, h: 1080, aspect: .sixteenNine),
        .init(w: 2560, h: 1440, aspect: .sixteenNine),
        .init(w: 1280, h: 800,  aspect: .sixteenTen),
        .init(w: 1680, h: 1050, aspect: .sixteenTen),
        .init(w: 1920, h: 1200, aspect: .sixteenTen),
    ]

    static func grouped() -> [ResolutionGroup] {
        AspectRatio.allCases.map { a in
            ResolutionGroup(aspect: a, items: catalogue.filter { $0.aspect == a })
        }
    }

    /// Closest standard aspect for an arbitrary w×h.
    static func closestAspect(w: Int, h: Int) -> AspectRatio {
        guard h > 0 else { return .sixteenNine }
        let r = Double(w) / Double(h)
        return AspectRatio.allCases.min(by: { abs($0.ratio - r) < abs($1.ratio - r) })!
    }

    /// A catalogue entry matching w×h, or a synthesised one (so a user-set odd
    /// resolution still shows up in the picker).
    static func match(w: Int, h: Int) -> GameResolution {
        catalogue.first(where: { $0.w == w && $0.h == h })
            ?? GameResolution(w: w, h: h, aspect: closestAspect(w: w, h: h))
    }

    /// The main display's native pixel resolution, as a suggested default.
    static func native() -> GameResolution? {
        guard let screen = NSScreen.main else { return nil }
        let scale = screen.backingScaleFactor
        let w = Int((screen.frame.width  * scale).rounded())
        let h = Int((screen.frame.height * scale).rounded())
        return GameResolution(w: w, h: h, aspect: closestAspect(w: w, h: h))
    }

    /// The main display's current *logical* resolution (points) — the size the
    /// game's fullscreen layer fills. Rendering at this exact aspect avoids the
    /// stretch you get from a mismatched ratio (e.g. 16:10 on a 16" MacBook Pro's
    /// ~1.547 panel). Lighter than native pixels; the aspect matches the panel.
    static func displayLogical() -> GameResolution? {
        guard let screen = NSScreen.main else { return nil }
        let w = Int(screen.frame.width.rounded())
        let h = Int(screen.frame.height.rounded())
        guard w > 0, h > 0 else { return nil }
        return GameResolution(w: w, h: h, aspect: closestAspect(w: w, h: h))
    }
}

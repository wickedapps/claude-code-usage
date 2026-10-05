import AppKit
import SwiftUI
import ClaudeUsageCore

enum DashboardSection: String, CaseIterable, Identifiable {
    case limits = "Limits", tokens = "Tokens"
    var id: String { rawValue }
}

/// Shared colors. Claude's terracotta is the only brand color; everything else is semantic.
enum UsageTheme {
    static let claude = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.886, green: 0.518, blue: 0.408, alpha: 1)
            : NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    })

    /// Model hues: blue, aqua, amber. Orange stays reserved for Claude itself.
    /// Three is the most that clears colorblind separation on both light and dark surfaces.
    static let modelHues: [Color] = [
        adaptive(light: (0.165, 0.471, 0.839), dark: (0.224, 0.529, 0.898)),
        adaptive(light: (0.106, 0.686, 0.478), dark: (0.098, 0.620, 0.439)),
        adaptive(light: (0.929, 0.631, 0.000), dark: (0.788, 0.522, 0.000)),
    ]
    /// Every model past the three largest, and the folded Other series.
    static let otherModel = Color(nsColor: .systemGray)

    private static func adaptive(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

/// Colors follow the model, not its rank in the selected range, so switching
/// ranges never repaints a model. The three largest models across the whole
/// ledger get a hue; the rest are grey.
struct ModelPalette {
    private let slots: [String: Int]

    init(samples: [UsageSample]) {
        var totals: [String: UInt64] = [:]
        for sample in samples { totals[sample.model, default: 0] += sample.tokens.total }
        let ranked = totals.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        slots = Dictionary(uniqueKeysWithValues: ranked.prefix(UsageTheme.modelHues.count).enumerated().map { ($1.key, $0) })
    }

    func hasHue(_ model: String) -> Bool { slots[model] != nil }

    func color(_ model: String) -> Color {
        slots[model].map { UsageTheme.modelHues[$0] } ?? UsageTheme.otherModel
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { self == .system ? "System" : self == .light ? "Light" : "Dark" }
    /// Nil follows the system setting.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

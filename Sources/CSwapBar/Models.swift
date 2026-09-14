import Foundation

enum UsageLevel {
    case low, medium, high

    init(pct: Double?) {
        guard let pct else { self = .low; return }
        if pct >= 80 { self = .high }
        else if pct >= 50 { self = .medium }
        else { self = .low }
    }
}

import SwiftUI

/// A vector icon built from one or more SVG path-data strings (in a 100x100
/// viewBox, scaled uniformly to fill whatever frame it's given). Used for
/// providers whose real logo isn't an SF Symbol -- the path data below is
/// copied verbatim from CodexBar's own bundled `ProviderIcon-*.svg` assets
/// (`/Applications/CodexBar.app/Contents/Resources/`), so these render as
/// the same marks CodexBar itself uses, not a generic stand-in.
///
/// Deliberately not loaded as bundled SVG resources: an SPM executable
/// target's resource bundle isn't copied into the .app by
/// `Scripts/build_app.sh` today, so a bundled asset would silently fail to
/// load once packaged. A hand-parsed vector shape has no such dependency,
/// and scales/tints exactly like an SF Symbol.
struct ProviderGlyph: Shape {
    let pathData: [String]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 100
        let offset = CGPoint(x: rect.minX + (rect.width - side) / 2, y: rect.minY + (rect.height - side) / 2)
        var combined = Path()
        for data in pathData {
            combined.addPath(Self.parse(data, scale: scale, offset: offset))
        }
        return combined
    }

    /// A minimal SVG path-data interpreter covering exactly the commands
    /// these two icons use: M/L/H/V/C and Z, all absolute (uppercase).
    private static func parse(_ data: String, scale: CGFloat, offset: CGPoint) -> Path {
        var path = Path()
        let scanner = Scanner(string: data)
        scanner.charactersToBeSkipped = CharacterSet(charactersIn: " ,")
        var current = CGPoint.zero // raw SVG units, not yet scaled
        var subpathStart = CGPoint.zero
        var command: Character?

        func toView(_ p: CGPoint) -> CGPoint {
            CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale)
        }

        while !scanner.isAtEnd {
            if let letters = scanner.scanCharacters(from: CharacterSet(charactersIn: "MLHVCZ")), let last = letters.last {
                command = last
            }
            switch command {
            case "M":
                guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return path }
                current = CGPoint(x: x, y: y)
                subpathStart = current
                path.move(to: toView(current))
                command = "L" // subsequent bare coordinate pairs are implicit lineto
            case "L":
                guard let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return path }
                current = CGPoint(x: x, y: y)
                path.addLine(to: toView(current))
            case "H":
                guard let x = scanner.scanDouble() else { return path }
                current = CGPoint(x: x, y: current.y)
                path.addLine(to: toView(current))
            case "V":
                guard let y = scanner.scanDouble() else { return path }
                current = CGPoint(x: current.x, y: y)
                path.addLine(to: toView(current))
            case "C":
                guard let x1 = scanner.scanDouble(), let y1 = scanner.scanDouble(),
                      let x2 = scanner.scanDouble(), let y2 = scanner.scanDouble(),
                      let x = scanner.scanDouble(), let y = scanner.scanDouble() else { return path }
                path.addCurve(to: toView(CGPoint(x: x, y: y)), control1: toView(CGPoint(x: x1, y: y1)), control2: toView(CGPoint(x: x2, y: y2)))
                current = CGPoint(x: x, y: y)
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                return path
            }
        }
        return path
    }
}

extension ProviderGlyph {
    static let antigravity = ProviderGlyph(pathData: [
        "M85.2843 88.0301C90.1329 91.6664 97.4057 89.2422 90.7389 82.5755C70.7389 63.1816 74.9813 9.84827 50.1329 9.84827C25.2843 9.84827 29.5267 63.1816 9.52673 82.5755C2.25402 89.8483 10.1328 91.6664 14.9813 88.0301C33.7692 75.3028 32.5571 52.8786 50.1329 52.8786C67.7086 52.8786 66.4965 75.3028 85.2843 88.0301Z",
    ])

    static let zai = ProviderGlyph(pathData: [
        "M52.3767 10.0721L45.8028 19.4273C44.7914 20.8938 43.072 21.804 41.2516 21.804H5.34765V10.0215C5.29708 10.0721 52.3767 10.0721 52.3767 10.0721Z",
        "M97.0291 10.0722L40.5942 90.0216H2.97095L59.4058 10.0722H97.0291Z",
        "M47.6233 90.0215L54.2478 80.6157C55.2592 79.1492 56.9785 78.2389 58.799 78.2389H94.6524V90.0215H47.6233Z",
    ])
}

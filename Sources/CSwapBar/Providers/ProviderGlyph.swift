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

    /// OpenCode's own `Mark` component (`packages/ui/src/components/logo.tsx`,
    /// viewBox `0 0 16 20`), rescaled into this type's 100x100 one: uniform
    /// scale 5, centered horizontally.
    ///
    /// Only the logo's outer path is used. Its second path fills the lower
    /// half of the frame's inner square in a darker shade, which in this
    /// single-color rendering would merge with the frame and leave a solid
    /// block with a notch -- so the frame alone is what still reads as the
    /// mark, at menu-bar size especially.
    static let opencodeGo = ProviderGlyph(pathData: [
        "M70 20H30V80H70V20ZM90 100H10V0H90V100Z",
    ])

    /// CodexBar's `ProviderIcon-deepseek.svg`, rescaled from its
    /// `3.5 5.5 24.8 20` viewBox into this type's 100x100 one (centered).
    static let deepseek = ProviderGlyph(pathData: [
        "M96.778 21.648C95.762 21.152 95.325 22.097 94.731 22.578C94.530 22.735 94.356 22.940 94.187 23.121C92.702 24.712 90.970 25.751 88.710 25.625C85.398 25.444 82.575 26.484 80.078 29.020C79.546 25.893 77.782 24.027 75.101 22.830C73.695 22.207 72.273 21.585 71.293 20.231C70.604 19.270 70.419 18.199 70.072 17.143C69.856 16.505 69.635 15.852 68.903 15.742C68.107 15.616 67.796 16.285 67.485 16.844C66.233 19.128 65.752 21.648 65.796 24.200C65.906 29.933 68.328 34.501 73.132 37.754C73.679 38.124 73.821 38.502 73.648 39.045C73.321 40.163 72.931 41.250 72.585 42.369C72.368 43.085 72.041 43.243 71.277 42.928C68.639 41.825 66.359 40.195 64.347 38.218C60.929 34.910 57.838 31.256 53.983 28.398C53.077 27.728 52.175 27.106 51.238 26.515C47.304 22.688 51.754 19.545 52.781 19.175C53.860 18.789 53.156 17.451 49.675 17.466C46.198 17.482 43.012 18.648 38.956 20.199C38.362 20.435 37.740 20.609 37.098 20.742C33.416 20.049 29.592 19.892 25.595 20.341C18.074 21.184 12.065 24.743 7.647 30.823C2.343 38.124 1.095 46.425 2.623 55.088C4.229 64.207 8.880 71.768 16.031 77.675C23.441 83.794 31.979 86.794 41.717 86.219C47.631 85.881 54.219 85.085 61.646 78.793C63.520 79.722 65.485 80.092 68.749 80.376C71.262 80.612 73.679 80.250 75.554 79.864C78.487 79.242 78.283 76.525 77.223 76.021C68.623 72.012 70.509 73.642 68.792 72.327C73.163 67.145 79.751 61.766 82.327 44.346C82.527 42.959 82.354 42.093 82.327 40.967C82.311 40.290 82.465 40.022 83.244 39.943C85.398 39.699 87.489 39.108 89.410 38.045C94.983 34.997 97.227 29.996 97.758 23.995C97.838 23.082 97.743 22.129 96.778 21.648ZM48.226 75.650C39.890 69.090 35.849 66.932 34.180 67.027C32.620 67.113 32.900 68.901 33.242 70.067C33.601 71.217 34.069 72.012 34.727 73.020C35.180 73.690 35.491 74.690 34.274 75.430C31.589 77.100 26.923 74.871 26.702 74.760C21.272 71.563 16.731 67.334 13.530 61.553C10.443 55.985 8.647 50.016 8.352 43.644C8.273 42.101 8.726 41.557 10.254 41.282C12.266 40.912 14.345 40.833 16.357 41.124C24.863 42.369 32.104 46.180 38.173 52.205C41.638 55.647 44.260 59.750 46.962 63.758C49.832 68.019 52.923 72.075 56.857 75.398C58.243 76.564 59.354 77.454 60.413 78.108C57.216 78.462 51.876 78.541 48.226 75.650ZM52.219 49.921C52.219 49.236 52.766 48.693 53.455 48.693C53.608 48.693 53.750 48.724 53.876 48.771C54.046 48.834 54.203 48.929 54.325 49.071C54.546 49.283 54.672 49.598 54.672 49.921C54.672 50.606 54.125 51.150 53.439 51.150C52.750 51.150 52.219 50.606 52.219 49.921ZM64.626 56.300C63.831 56.623 63.035 56.907 62.272 56.938C61.086 56.994 59.791 56.513 59.086 55.923C57.995 55.009 57.216 54.497 56.885 52.890C56.747 52.205 56.826 51.150 56.948 50.544C57.231 49.236 56.916 48.401 55.999 47.638C55.247 47.015 54.298 46.850 53.250 46.850C52.860 46.850 52.502 46.677 52.234 46.535C51.797 46.314 51.439 45.771 51.781 45.102C51.892 44.889 52.423 44.361 52.549 44.267C53.967 43.456 55.605 43.723 57.121 44.330C58.527 44.904 59.586 45.960 61.114 47.448C62.677 49.252 62.957 49.756 63.847 51.102C64.548 52.166 65.190 53.252 65.627 54.497C65.890 55.269 65.548 55.906 64.626 56.300Z",
    ])

    /// Kiro's mascot, the ghost from its own app icon (AWS's "Kiro CLI.app"),
    /// redrawn here as vector paths rather than copied from CodexBar, which
    /// doesn't ship a Kiro mark: a domed body whose bottom edge is three
    /// scallops, with two eyes cut out of it.
    ///
    /// The eyes are separate subpaths wound the opposite way to the body, so
    /// the default non-zero winding rule punches them out as holes -- the
    /// same reason they read as eyes rather than two filled dots at
    /// menu-bar size.
    static let kiro = ProviderGlyph(pathData: [
        "M17 50C17 31.8 31.8 17 50 17C68.2 17 83 31.8 83 50L83 80C83 95 61 95 61 80C61 95 39 95 39 80C39 95 17 95 17 80Z",
        "M38 47C35.24 47 33 49.24 33 52C33 54.76 35.24 57 38 57C40.76 57 43 54.76 43 52C43 49.24 40.76 47 38 47Z",
        "M62 47C59.24 47 57 49.24 57 52C57 54.76 59.24 57 62 57C64.76 57 67 54.76 67 52C67 49.24 64.76 47 62 47Z",
    ])
}

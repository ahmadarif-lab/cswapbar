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

    /// Codex's own app mark (the scalloped cloud with a `>_` prompt cut out of
    /// it, from the logo's single-color variant on zonalogo.com), rescaled
    /// from its 250x250 viewBox into this type's 100x100 one, with every
    /// quadratic and relative segment converted to the absolute M/L/C/Z this
    /// type's parser reads.
    ///
    /// The prompt's `>` and `_` are separate subpaths wound the opposite way
    /// to the cloud, so the default non-zero winding rule punches them out as
    /// holes -- the same trick as Kiro's eyes.
    static let codex = ProviderGlyph(pathData: [
        "M33.35 2.38C34.33 1.98 35.35 1.64 36.41 1.34C37.44 1.08 38.49 0.87 39.55 0.71C40.61 0.58 41.68 0.50 42.76 0.47C43.82 0.47 44.88 0.54 45.94 0.67C51.42 1.30 56.34 3.65 60.68 7.70C60.70 7.73 60.76 7.77 60.84 7.82C60.86 7.82 60.89 7.82 60.92 7.82C60.92 7.82 60.94 7.82 61.00 7.82C61.00 7.82 61.01 7.82 61.04 7.82C61.04 7.82 61.05 7.82 61.08 7.82C62.45 7.45 63.87 7.20 65.33 7.06C66.75 6.96 68.17 6.97 69.58 7.10C71.03 7.21 72.45 7.46 73.82 7.86C75.20 8.20 76.54 8.68 77.84 9.29L78.07 9.45L78.71 9.76C80.09 10.43 81.37 11.23 82.56 12.19C83.81 13.09 84.95 14.11 85.98 15.25C86.99 16.38 87.90 17.60 88.72 18.90C89.51 20.17 90.20 21.52 90.79 22.95C91.92 25.73 92.49 28.66 92.49 31.73C92.55 32.29 92.55 32.84 92.49 33.40C92.47 33.98 92.44 34.55 92.41 35.11C92.33 35.66 92.24 36.23 92.14 36.81C92.03 37.37 91.91 37.91 91.78 38.44C91.78 38.49 91.78 38.55 91.78 38.60C91.78 38.65 91.78 38.72 91.78 38.80C91.78 38.83 91.79 38.88 91.82 38.96C91.84 38.98 91.88 39.02 91.94 39.08C95.19 42.41 97.35 46.39 98.41 50.99C100.00 58.86 98.38 65.94 93.57 72.24L92.81 73.12C92.02 74.04 91.16 74.89 90.23 75.66C89.33 76.48 88.36 77.21 87.33 77.84C86.32 78.48 85.25 79.03 84.11 79.51C83.03 80.01 81.90 80.44 80.74 80.78C80.66 80.78 80.60 80.81 80.58 80.86C80.50 80.86 80.44 80.88 80.42 80.90C80.39 80.93 80.35 80.98 80.30 81.06C80.30 81.09 80.29 81.13 80.26 81.18C79.19 84.24 78.15 86.82 76.21 89.40C71.24 95.96 63.97 99.53 55.75 99.53C49.24 99.50 43.47 97.11 38.44 92.34C38.38 92.31 38.33 92.29 38.28 92.26C38.22 92.23 38.17 92.22 38.12 92.22C38.06 92.22 38.02 92.22 38.00 92.22C37.92 92.22 37.87 92.22 37.84 92.22C35.69 92.90 33.51 92.98 31.21 92.98C30.28 92.98 29.35 92.91 28.43 92.78C27.53 92.67 26.61 92.51 25.69 92.30C24.81 92.09 23.94 91.82 23.06 91.51C22.19 91.19 21.34 90.82 20.52 90.39C19.65 89.97 18.80 89.49 17.98 88.96C17.19 88.44 16.42 87.87 15.68 87.26C14.88 86.65 14.15 85.99 13.49 85.27C12.83 84.58 12.22 83.84 11.66 83.05C10.79 81.97 9.96 80.90 9.36 79.67C9.15 79.25 8.94 78.82 8.73 78.40C8.57 77.95 8.39 77.51 8.21 77.09C8.02 76.64 7.86 76.19 7.73 75.74C7.60 75.31 7.47 74.86 7.33 74.39C7.04 73.33 6.83 72.28 6.70 71.25C6.54 70.19 6.46 69.13 6.46 68.07C6.46 67.01 6.54 65.95 6.70 64.89C6.81 63.84 6.99 62.78 7.26 61.72C7.26 61.72 7.26 61.70 7.26 61.68C7.26 61.65 7.26 61.64 7.26 61.64C7.31 61.58 7.33 61.55 7.33 61.52C7.33 61.49 7.31 61.48 7.26 61.48C7.26 61.43 7.26 61.39 7.26 61.36C7.26 61.33 7.24 61.32 7.22 61.32C7.22 61.27 7.22 61.24 7.22 61.24C7.19 61.21 7.18 61.20 7.18 61.20C6.54 60.54 5.93 59.85 5.35 59.14C4.79 58.42 4.26 57.71 3.76 56.99C3.31 56.20 2.89 55.40 2.49 54.61C2.09 53.79 1.75 52.95 1.46 52.11C1.24 51.58 1.07 51.03 0.94 50.48C0.75 49.95 0.61 49.42 0.50 48.89C0.40 48.33 0.30 47.78 0.23 47.22C0.17 46.64 0.12 46.07 0.07 45.51C0.01 44.77 0.00 44.03 0.03 43.29C0.03 42.55 0.07 41.83 0.15 41.14C0.17 40.40 0.25 39.66 0.38 38.92C0.49 38.18 0.64 37.45 0.82 36.73C2.67 30.62 6.24 25.81 11.51 22.32C12.64 21.55 13.73 20.95 14.76 20.53C15.95 20.03 17.15 19.60 18.34 19.26C18.39 19.26 18.43 19.24 18.46 19.22C18.48 19.16 18.52 19.12 18.58 19.10C18.60 19.10 18.62 19.06 18.62 18.98C18.64 18.95 18.65 18.93 18.65 18.90C18.92 18.08 19.21 17.28 19.53 16.52C19.79 15.75 20.12 14.99 20.52 14.25C20.92 13.46 21.34 12.72 21.79 12.03C22.24 11.31 22.73 10.64 23.26 10.00C23.92 9.16 24.63 8.37 25.37 7.66C26.16 6.92 26.97 6.20 27.79 5.51C28.64 4.88 29.54 4.30 30.49 3.77C31.42 3.24 32.37 2.77 33.35 2.38Z",
        "M52.54 60.53C51.62 60.57 50.79 60.92 50.15 61.64C49.56 62.27 49.20 63.11 49.20 63.98C49.20 64.89 49.56 65.73 50.15 66.44C50.79 67.08 51.62 67.44 52.54 67.48L72.55 67.48C73.51 67.52 74.46 67.24 75.14 66.52C75.81 65.89 76.25 64.93 76.25 63.98C76.25 63.03 75.81 62.11 75.14 61.48C74.46 60.76 73.51 60.45 72.55 60.53Z",
        "M30.01 34.75C29.54 33.99 28.82 33.40 27.91 33.20C27.04 33.00 26.12 33.08 25.33 33.56C24.53 33.99 23.94 34.75 23.70 35.62C23.42 36.50 23.54 37.45 23.94 38.20L30.97 50.48L24.02 62.19C23.54 62.99 23.38 63.98 23.58 64.89C23.86 65.81 24.41 66.52 25.21 67.00C26.00 67.48 26.96 67.64 27.87 67.36C28.74 67.16 29.54 66.60 30.01 65.81L38.00 52.26C38.18 52.03 38.30 51.75 38.36 51.43C38.44 51.14 38.47 50.83 38.47 50.52C38.47 50.20 38.44 49.91 38.36 49.64C38.30 49.32 38.20 49.03 38.04 48.77Z",
    ])
}

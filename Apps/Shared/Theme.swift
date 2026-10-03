import SwiftUI
import ImageIO

enum PayTheme {
    static let ink = Color(red: 0.13, green: 0.12, blue: 0.11)
    static let muted = Color(red: 0.47, green: 0.42, blue: 0.38)
    static let cinnabar = Color(red: 0.72, green: 0.20, blue: 0.17)
    static let line = Color(red: 0.80, green: 0.75, blue: 0.70)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

}

/// Keep the approved painting untouched; display only its illustration region.
struct JiangnanArtwork: View {
    let height: CGFloat
    private static let illustration: CGImage? = {
        guard let url = Bundle.main.url(forResource: "jiangnan-reference", withExtension: "jpg"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    var body: some View {
        GeometryReader { geometry in
            #if os(watchOS)
            let source = CGRect(x: 902, y: 543, width: 263, height: 39)
            #else
            let source = CGRect(x: 222, y: 54, width: 505, height: 414)
            #endif
            let scale = geometry.size.width / source.width
            if let illustration = Self.illustration {
                Image(decorative: illustration, scale: 1, orientation: .up)
                    .resizable()
                    .frame(width: 1536 * scale, height: 1024 * scale)
                    .offset(x: -source.minX * scale, y: -source.minY * scale)
                    .frame(width: geometry.size.width, height: height, alignment: .topLeading)
                    .clipped()
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct CinnabarButtonStyle: ButtonStyle {
    var filled = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PayTheme.font(17, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 45)
            .foregroundStyle(filled ? Color.white : PayTheme.ink)
            .background(filled ? PayTheme.cinnabar : Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(filled ? PayTheme.cinnabar : PayTheme.line, lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 3).inset(by: 3).stroke(filled ? Color.white.opacity(0.8) : PayTheme.line.opacity(0.55), lineWidth: 0.6))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

enum PayDisplay {
    static func money(_ cents: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "zh_CN")
        return "¥" + (formatter.string(from: NSDecimalNumber(value: cents).dividing(by: 100)) ?? "0.00")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return "\(minutes / 60)时\(minutes % 60)分"
    }
}

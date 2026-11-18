import SwiftUI

enum AcousticTheme {
    static let oledBlack = Color.black
    static let carbonSurface = Color(red: 0.067, green: 0.067, blue: 0.082)
    static let elevatedSurface = Color(red: 0.105, green: 0.105, blue: 0.125)
    static let hairline = Color.white.opacity(0.09)
    static let textPrimary = Color(red: 0.96, green: 0.96, blue: 0.97)
    static let textSecondary = Color.white.opacity(0.58)
    static let textMuted = Color.white.opacity(0.32)

    static func accentColor(from rgb: (red: Double, green: Double, blue: Double)) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

struct SignalBarsView: View {
    let isActive: Bool
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.28, paused: !isActive)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = isActive ? abs(sin(phase * 4.2 + Double(index) * 1.15)) : 0.2
                    let height = 4.0 + wave * 9.0
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: 2.2, height: height)
                }
            }
            .frame(height: 14)
        }
    }
}

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Live workout location puck: avatar disc with a forward triangle for course.
struct LiveUserMarker: View {
    var name: String
    #if canImport(UIKit)
    var image: UIImage?
    #endif
    /// Degrees clockwise from true north. `nil` keeps the tip pointing up.
    var courseDegrees: Double?
    var diameter: CGFloat = 28

    var body: some View {
        let tip = diameter * 0.38
        ZStack {
            Circle()
                .fill(Color.omniCobalt)
                .frame(width: diameter + 4, height: diameter + 4)
                .shadow(color: Color.black.opacity(0.28), radius: 3, y: 1)
            face
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(Color.white, lineWidth: 2)
                }
            // Tip sits on the leading edge of travel (top before rotation).
            LiveUserMarkerTip()
                .fill(Color.white)
                .overlay {
                    LiveUserMarkerTip()
                        .stroke(Color.omniCobalt, lineWidth: 1)
                }
                .frame(width: tip, height: tip * 0.9)
                .offset(y: -(diameter / 2 + tip * 0.28))
        }
        .frame(width: diameter + tip, height: diameter + tip)
        .rotationEffect(.degrees(courseDegrees ?? 0))
        .accessibilityLabel("当前位置")
    }

    @ViewBuilder
    private var face: some View {
        #if canImport(UIKit)
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            initialFace
        }
        #else
        initialFace
        #endif
    }

    private var initialFace: some View {
        Text(mark)
            .font(.system(size: diameter * 0.42, weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.omniCobalt)
    }

    private var mark: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return "我" }
        return String(first)
    }
}

/// Isosceles tip used as the heading arrow on the live user puck.
struct LiveUserMarkerTip: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

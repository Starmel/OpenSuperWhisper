import SwiftUI

/// The macOS notch silhouette: concave "wings" at the top (where it meets the screen edge)
/// and rounded bottom corners. Ported from the approach used by MewNotch / boring.notch so the
/// recording pill reads as a real notch rather than a plain rounded rectangle.
struct NotchShape: Shape {
    var topRadius: CGFloat = 8
    var bottomRadius: CGFloat = 13

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // Top-left concave wing.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius, y: rect.minY + topRadius),
            control: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        // Left side down.
        path.addLine(to: CGPoint(x: rect.minX + topRadius, y: rect.maxY - bottomRadius))
        // Bottom-left rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topRadius + bottomRadius, y: rect.maxY),
            control: CGPoint(x: rect.minX + topRadius, y: rect.maxY))
        // Across the bottom.
        path.addLine(to: CGPoint(x: rect.maxX - topRadius - bottomRadius, y: rect.maxY))
        // Bottom-right rounded corner.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topRadius, y: rect.maxY - bottomRadius),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.maxY))
        // Right side up.
        path.addLine(to: CGPoint(x: rect.maxX - topRadius, y: rect.minY + topRadius))
        // Top-right concave wing.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topRadius, y: rect.minY))
        path.closeSubpath()

        return path
    }
}

import SwiftUI

/// Lightweight, generic vector illustrations; these do not depict measured lighting or device state.
struct DeviceArtwork: View {
    let keyboard: Bool
    var color: Color = RazerTheme.green
    var brightness: Double = 0.75

    var body: some View {
        ZStack {
            Ellipse().fill(color.opacity(0.10 * brightness))
                .frame(width: 220, height: 70).blur(radius: 24).offset(y: 42)
            if keyboard {
                KeyboardDrawing(color: color, brightness: brightness)
                    .frame(width: 262, height: 102).rotationEffect(.degrees(-9))
            } else {
                mouse.frame(width: 105, height: 162).rotationEffect(.degrees(-17))
            }
        }
        .frame(width: 286, height: 184)
        .accessibilityLabel(keyboard ? "键盘示意图" : "鼠标示意图")
    }

    private var mouse: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                MouseShape()
                    .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .shadow(color: .black.opacity(0.22), radius: 12, x: 0, y: 14)
                MouseShape().strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                Path { path in
                    path.move(to: CGPoint(x: geometry.size.width / 2, y: 4))
                    path.addLine(to: CGPoint(x: geometry.size.width / 2, y: 57))
                    path.move(to: CGPoint(x: 6, y: 61))
                    path.addQuadCurve(to: CGPoint(x: 99, y: 61), control: CGPoint(x: 53, y: 75))
                }.stroke(.black.opacity(0.42), lineWidth: 1)
                RoundedRectangle(cornerRadius: 4).fill(color.opacity(brightness))
                    .frame(width: 9, height: 23).offset(y: 19)
                    .overlay(alignment: .top) {
                        VStack(spacing: 3) {
                            ForEach(0..<4, id: \.self) { _ in Rectangle().fill(.black.opacity(0.3)).frame(width: 6, height: 1) }
                        }.offset(y: 23)
                    }
                Image(systemName: "bolt.fill").font(.system(size: 19, weight: .light))
                    .foregroundStyle(color.opacity(brightness * 0.7)).offset(y: 100)
            }
        }
    }
}

private struct MouseShape: InsettableShape {
    var insetAmount = 0.0
    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        return Path { path in
            path.move(to: point(0.5, 0))
            path.addCurve(to: point(0.97, 0.45), control1: point(0.86, -0.01), control2: point(0.97, 0.20))
            path.addCurve(to: point(0.87, 0.90), control1: point(1.02, 0.65), control2: point(1.01, 0.79))
            path.addCurve(to: point(0.13, 0.90), control1: point(0.71, 1.04), control2: point(0.29, 1.04))
            path.addCurve(to: point(0.03, 0.45), control1: point(-0.01, 0.79), control2: point(-0.02, 0.65))
            path.addCurve(to: point(0.5, 0), control1: point(0.03, 0.20), control2: point(0.14, -0.01))
            path.closeSubpath()
        }
    }
    func inset(by amount: CGFloat) -> some InsettableShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

private struct KeyboardDrawing: View {
    let color: Color
    let brightness: Double

    var body: some View {
        Canvas { context, size in
            let chassis = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let outline = Path(roundedRect: chassis, cornerRadius: 9)
            var chassisContext = context
            chassisContext.addFilter(.shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 9))
            chassisContext.fill(outline, with: .linearGradient(Gradient(colors: [Color(white: 0.25), Color(white: 0.12)]), startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
            context.stroke(outline, with: .color(.white.opacity(0.16)), lineWidth: 1)
            let width = (size.width - 25) / 16
            let height = (size.height - 22) / 6
            for row in 0..<6 {
                for column in 0..<16 {
                    if row == 5 && (4...9).contains(column) { continue }
                    let key = CGRect(x: 8 + CGFloat(column) * width, y: 8 + CGFloat(row) * height,
                                     width: row == 5 && column == 3 ? width * 7 - 3 : width - 3, height: height - 3)
                    let path = Path(roundedRect: key, cornerRadius: 2)
                    context.fill(path, with: .color(Color(white: 0.10)))
                    let opacity = brightness * (0.18 + Double((row + column) % 4) * 0.11)
                    context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: 0.8)
                    if row < 5 {
                        let legend = Path(CGRect(x: key.minX + 3, y: key.minY + 3, width: 3, height: 1))
                        context.fill(legend, with: .color(color.opacity(brightness * 0.65)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

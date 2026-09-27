//
//  JobVehicleDiagram.swift
//  DetailCRM
//
//  Line drawings of a generic vehicle for each inspection view (front,
//  rear, both sides, top, interior), drawn with SwiftUI paths so they scale
//  crisply and follow the theme. Damage marks are stored as normalized
//  x/y (0…1) over the diagram's frame, so they land in the same place on
//  every screen size.
//

import SwiftUI

/// Width / height of each view's drawing.
enum JobVehicleDiagramLayout {
    static func aspectRatio(for view: JobVehicleView) -> CGFloat {
        switch view {
        case .front, .rear: return 1.35
        case .left, .right: return 2.3
        case .top: return 0.55
        case .interior: return 0.8
        }
    }
}

/// The outline for one view. `rect` is the diagram frame.
struct JobVehicleDiagramShape: Shape {
    let view: JobVehicleView

    func path(in rect: CGRect) -> Path {
        switch view {
        case .front: return Self.frontOrRear(in: rect, isFront: true)
        case .rear: return Self.frontOrRear(in: rect, isFront: false)
        case .left: return Self.side(in: rect, facingLeft: true)
        case .right: return Self.side(in: rect, facingLeft: false)
        case .top: return Self.top(in: rect)
        case .interior: return Self.interior(in: rect)
        }
    }

    // MARK: - Helpers

    private static func point(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
    }

    private static func box(_ rect: CGRect, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y, width: rect.width * w, height: rect.height * h)
    }

    // MARK: - Front / rear

    private static func frontOrRear(in rect: CGRect, isFront: Bool) -> Path {
        var path = Path()
        // Body
        path.addRoundedRect(in: box(rect, 0.06, 0.42, 0.88, 0.36), cornerSize: CGSize(width: rect.width * 0.06, height: rect.width * 0.06))
        // Cabin / glass
        path.move(to: point(rect, 0.18, 0.42))
        path.addLine(to: point(rect, 0.28, 0.12))
        path.addLine(to: point(rect, 0.72, 0.12))
        path.addLine(to: point(rect, 0.82, 0.42))
        path.move(to: point(rect, 0.23, 0.40))
        path.addLine(to: point(rect, 0.31, 0.17))
        path.addLine(to: point(rect, 0.69, 0.17))
        path.addLine(to: point(rect, 0.77, 0.40))
        path.closeSubpath()
        // Mirrors
        path.addEllipse(in: box(rect, 0.02, 0.34, 0.08, 0.06))
        path.addEllipse(in: box(rect, 0.90, 0.34, 0.08, 0.06))
        // Lights
        if isFront {
            path.addRoundedRect(in: box(rect, 0.10, 0.48, 0.18, 0.08), cornerSize: CGSize(width: 4, height: 4))
            path.addRoundedRect(in: box(rect, 0.72, 0.48, 0.18, 0.08), cornerSize: CGSize(width: 4, height: 4))
            // Grille
            path.addRoundedRect(in: box(rect, 0.34, 0.50, 0.32, 0.12), cornerSize: CGSize(width: 6, height: 6))
        } else {
            path.addRoundedRect(in: box(rect, 0.10, 0.47, 0.16, 0.10), cornerSize: CGSize(width: 4, height: 4))
            path.addRoundedRect(in: box(rect, 0.74, 0.47, 0.16, 0.10), cornerSize: CGSize(width: 4, height: 4))
            // Plate
            path.addRect(box(rect, 0.40, 0.56, 0.20, 0.08))
        }
        // Bumper line
        path.move(to: point(rect, 0.08, 0.68))
        path.addLine(to: point(rect, 0.92, 0.68))
        // Wheels
        path.addRoundedRect(in: box(rect, 0.12, 0.78, 0.14, 0.14), cornerSize: CGSize(width: 4, height: 4))
        path.addRoundedRect(in: box(rect, 0.74, 0.78, 0.14, 0.14), cornerSize: CGSize(width: 4, height: 4))
        return path
    }

    // MARK: - Side

    private static func side(in rect: CGRect, facingLeft: Bool) -> Path {
        // Drawn facing left, mirrored for the passenger side.
        var path = Path()
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            point(rect, facingLeft ? x : 1 - x, y)
        }
        func b(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            box(rect, facingLeft ? x : 1 - x - w, y, w, h)
        }
        // Body outline
        path.move(to: p(0.03, 0.62))
        path.addLine(to: p(0.05, 0.46))
        path.addLine(to: p(0.22, 0.40))
        path.addLine(to: p(0.34, 0.16))
        path.addLine(to: p(0.70, 0.16))
        path.addLine(to: p(0.84, 0.40))
        path.addLine(to: p(0.96, 0.44))
        path.addLine(to: p(0.97, 0.62))
        path.addLine(to: p(0.88, 0.70))
        path.move(to: p(0.72, 0.70))
        path.addLine(to: p(0.30, 0.70))
        path.move(to: p(0.14, 0.70))
        path.addLine(to: p(0.03, 0.62))
        // Windows
        path.move(to: p(0.25, 0.40))
        path.addLine(to: p(0.36, 0.21))
        path.addLine(to: p(0.51, 0.21))
        path.addLine(to: p(0.51, 0.40))
        path.closeSubpath()
        path.move(to: p(0.54, 0.40))
        path.addLine(to: p(0.54, 0.21))
        path.addLine(to: p(0.68, 0.21))
        path.addLine(to: p(0.80, 0.40))
        path.closeSubpath()
        // Door line
        path.move(to: p(0.525, 0.40))
        path.addLine(to: p(0.525, 0.68))
        // Wheels
        path.addEllipse(in: b(0.14, 0.56, 0.16, 0.16 * 2.3))
        path.addEllipse(in: b(0.72, 0.56, 0.16, 0.16 * 2.3))
        return path
    }

    // MARK: - Top

    private static func top(in rect: CGRect) -> Path {
        var path = Path()
        // Body
        path.addRoundedRect(in: box(rect, 0.10, 0.03, 0.80, 0.94), cornerSize: CGSize(width: rect.width * 0.22, height: rect.width * 0.22))
        // Windshield
        path.move(to: point(rect, 0.20, 0.34))
        path.addLine(to: point(rect, 0.26, 0.24))
        path.addLine(to: point(rect, 0.74, 0.24))
        path.addLine(to: point(rect, 0.80, 0.34))
        path.closeSubpath()
        // Roof
        path.addRoundedRect(in: box(rect, 0.22, 0.36, 0.56, 0.34), cornerSize: CGSize(width: 8, height: 8))
        // Rear window
        path.move(to: point(rect, 0.22, 0.72))
        path.addLine(to: point(rect, 0.78, 0.72))
        path.addLine(to: point(rect, 0.72, 0.80))
        path.addLine(to: point(rect, 0.28, 0.80))
        path.closeSubpath()
        // Mirrors
        path.addEllipse(in: box(rect, 0.02, 0.30, 0.09, 0.04))
        path.addEllipse(in: box(rect, 0.89, 0.30, 0.09, 0.04))
        return path
    }

    // MARK: - Interior

    private static func interior(in rect: CGRect) -> Path {
        var path = Path()
        // Cabin outline
        path.addRoundedRect(in: box(rect, 0.05, 0.03, 0.90, 0.94), cornerSize: CGSize(width: rect.width * 0.12, height: rect.width * 0.12))
        // Dashboard
        path.addRoundedRect(in: box(rect, 0.10, 0.07, 0.80, 0.10), cornerSize: CGSize(width: 8, height: 8))
        // Steering wheel
        path.addEllipse(in: box(rect, 0.18, 0.16, 0.20, 0.07))
        // Front seats
        path.addRoundedRect(in: box(rect, 0.14, 0.27, 0.28, 0.22), cornerSize: CGSize(width: 10, height: 10))
        path.addRoundedRect(in: box(rect, 0.58, 0.27, 0.28, 0.22), cornerSize: CGSize(width: 10, height: 10))
        // Console
        path.addRoundedRect(in: box(rect, 0.45, 0.25, 0.10, 0.24), cornerSize: CGSize(width: 6, height: 6))
        // Rear bench
        path.addRoundedRect(in: box(rect, 0.12, 0.58, 0.76, 0.20), cornerSize: CGSize(width: 12, height: 12))
        path.move(to: point(rect, 0.37, 0.58))
        path.addLine(to: point(rect, 0.37, 0.78))
        path.move(to: point(rect, 0.63, 0.58))
        path.addLine(to: point(rect, 0.63, 0.78))
        // Cargo
        path.addRoundedRect(in: box(rect, 0.14, 0.82, 0.72, 0.11), cornerSize: CGSize(width: 8, height: 8))
        return path
    }
}

/// The drawing plus its marks; taps on empty space report a normalized
/// point (when `onTap` is set), taps on a pin select it.
struct JobVehicleDiagramView: View {
    let view: JobVehicleView
    let marks: [InspectionMark]
    var selectedMarkID: UUID? = nil
    var onTap: ((CGPoint) -> Void)? = nil
    var onSelectMark: ((InspectionMark) -> Void)? = nil

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Theme.surfaceMuted)
                JobVehicleDiagramShape(view: view)
                    .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .padding(Theme.Spacing.sm)
                ForEach(Array(marks.enumerated()), id: \.element.id) { index, mark in
                    JobMarkPin(mark: mark, number: index + 1, isSelected: mark.id == selectedMarkID)
                        .position(x: CGFloat(mark.x) * size.width, y: CGFloat(mark.y) * size.height)
                        .onTapGesture {
                            onSelectMark?(mark)
                        }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        guard let onTap, size.width > 0, size.height > 0 else { return }
                        let x = min(max(value.location.x / size.width, 0), 1)
                        let y = min(max(value.location.y / size.height, 0), 1)
                        onTap(CGPoint(x: x, y: y))
                    }
            )
        }
        .aspectRatio(JobVehicleDiagramLayout.aspectRatio(for: view), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(view.displayName) diagram, \(marks.count) damage marks")
    }
}

/// A numbered damage pin.
struct JobMarkPin: View {
    let mark: InspectionMark
    let number: Int
    let isSelected: Bool

    /// Grows with Dynamic Type, capped so pins never hide the diagram.
    @ScaledMetric(relativeTo: .caption) private var scaledSide: CGFloat = 26

    private var side: CGFloat { min(scaledSide, 40) }

    var body: some View {
        Text("\(number)")
            .font(Theme.Typography.captionEmphasis.monospacedDigit())
            .foregroundStyle(Theme.onAccent)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: side, height: side)
            .background(Circle().fill(Theme.danger))
            .overlay(
                Circle().strokeBorder(Theme.surface, lineWidth: isSelected ? 3 : 2)
            )
            .scaleEffect(isSelected ? 1.2 : 1)
            .frame(width: max(44, side + 8), height: max(44, side + 8))
            .contentShape(Circle())
            .accessibilityElement()
            .accessibilityLabel("Mark \(number): \(mark.damage.displayName)")
            .accessibilityAddTraits(.isButton)
    }
}

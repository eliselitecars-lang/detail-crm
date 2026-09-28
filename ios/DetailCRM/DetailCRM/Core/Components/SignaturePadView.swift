//
//  SignaturePadView.swift
//  DetailCRM
//
//  Finger signature capture (inspections, forms signed on device). The pad
//  is always "paper" (white with black ink) in both light and dark mode so
//  the exported PNG looks like a real signature.
//

import SwiftUI
import UIKit

/// Strokes in normalized coordinates (0…1 in both axes) so the drawing can
/// be exported at any size.
struct SignatureDrawing: Equatable {
    var strokes: [[CGPoint]] = []
    /// Width / height of the pad the strokes were drawn on.
    var aspectRatio: CGFloat = 3

    var isEmpty: Bool { strokes.allSatisfy { $0.isEmpty } }

    mutating func clear() {
        strokes = []
    }

    /// PNG of the signature (black ink on white) at `width` points wide.
    func pngData(width: CGFloat = 900, lineWidth: CGFloat = 6) -> Data? {
        guard !isEmpty, width > 0, aspectRatio > 0 else { return nil }
        let size = CGSize(width: width, height: (width / aspectRatio).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setStroke()
            UIColor.black.setFill()
            for stroke in strokes {
                let points = stroke.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
                guard let first = points.first else { continue }
                if points.count == 1 {
                    let half: CGFloat = lineWidth / 2
                    let dot = CGRect(x: first.x - half, y: first.y - half, width: lineWidth, height: lineWidth)
                    UIBezierPath(ovalIn: dot).fill()
                    continue
                }
                let path = UIBezierPath()
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                path.stroke()
            }
        }
        return image.pngData()
    }
}

struct SignaturePadView: View {
    @Binding var drawing: SignatureDrawing
    var height: CGFloat = 180
    var prompt: String = "Sign above"

    @State private var activeStroke: [CGPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            GeometryReader { proxy in
                let size = proxy.size
                Canvas { context, canvasSize in
                    let style = StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                    for stroke in drawing.strokes {
                        context.stroke(Self.path(for: stroke, in: canvasSize), with: .color(.black), style: style)
                    }
                    context.stroke(Self.path(for: activeStroke, in: canvasSize), with: .color(.black), style: style)
                }
                .background(Color.white)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { value in
                            activeStroke.append(Self.normalized(value.location, in: size))
                        }
                        .onEnded { _ in
                            let finished = activeStroke
                            activeStroke = []
                            guard !finished.isEmpty, size.height > 0 else { return }
                            drawing.aspectRatio = size.width / size.height
                            drawing.strokes.append(finished)
                        }
                )
            }
            .frame(height: height)
            .overlay(alignment: .bottom) {
                baseline
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: Theme.Size.hairline)
            )
            .accessibilityElement()
            .accessibilityLabel("Signature pad")
            .accessibilityValue(drawing.isEmpty ? "Empty" : "Signed")

            HStack {
                Text(prompt)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Clear") {
                    drawing.clear()
                    activeStroke = []
                }
                .font(Theme.Typography.footnote.weight(.semibold))
                .foregroundStyle(Theme.glacier)
                .disabled(drawing.isEmpty)
            }
        }
    }

    private var baseline: some View {
        Rectangle()
            .fill(Color.black.opacity(0.18))
            .frame(height: 1)
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.bottom, Theme.Spacing.xl)
            .allowsHitTesting(false)
    }

    private static func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(
            x: min(max(point.x / size.width, 0), 1),
            y: min(max(point.y / size.height, 0), 1)
        )
    }

    private static func path(for stroke: [CGPoint], in size: CGSize) -> Path {
        var path = Path()
        guard let first = stroke.first else { return path }
        let start = CGPoint(x: first.x * size.width, y: first.y * size.height)
        if stroke.count == 1 {
            path.addEllipse(in: CGRect(x: start.x - 1.25, y: start.y - 1.25, width: 2.5, height: 2.5))
            return path
        }
        path.move(to: start)
        for point in stroke.dropFirst() {
            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
        }
        return path
    }
}

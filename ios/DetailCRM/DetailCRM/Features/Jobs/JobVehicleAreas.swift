//
//  JobVehicleAreas.swift
//  DetailCRM
//
//  Named parts of each vehicle diagram, so a damage mark can be added by
//  choosing "Front door" from a list instead of pointing at the drawing.
//  That is the path for VoiceOver, Switch Control, Voice Control and Full
//  Keyboard Access users (the drawing itself only takes a finger tap).
//
//  Each area stores the same normalized x/y (0…1 over the diagram frame)
//  a tap on the middle of that part of the drawing would, so the pin lands
//  on the part in every client (iPhone, web, job report).
//

import Foundation

/// One named spot on a diagram.
struct JobVehicleArea: Identifiable, Hashable, Sendable {
    let name: String
    let x: Double
    let y: Double

    var id: String { name }
}

extension JobVehicleView {

    /// Named areas of this view, in reading order (front to back, top to
    /// bottom). Positions follow `JobVehicleDiagramShape`: the front and rear
    /// views face the viewer (so the driver side is on the drawing's right
    /// in the front view and on its left in the rear view); the driver-side
    /// view has the front of the car on the left, the passenger-side view on
    /// the right; the top and interior views have the front at the top and
    /// the driver side on the left.
    var areas: [JobVehicleArea] {
        switch self {
        case .front:
            return [
                JobVehicleArea(name: "Windshield", x: 0.50, y: 0.27),
                JobVehicleArea(name: "Hood", x: 0.50, y: 0.46),
                JobVehicleArea(name: "Grille", x: 0.50, y: 0.56),
                JobVehicleArea(name: "Front bumper", x: 0.50, y: 0.72),
                JobVehicleArea(name: "Driver-side headlight", x: 0.81, y: 0.52),
                JobVehicleArea(name: "Passenger-side headlight", x: 0.19, y: 0.52),
                JobVehicleArea(name: "Driver-side mirror", x: 0.94, y: 0.37),
                JobVehicleArea(name: "Passenger-side mirror", x: 0.06, y: 0.37),
                JobVehicleArea(name: "Driver-side front wheel", x: 0.81, y: 0.85),
                JobVehicleArea(name: "Passenger-side front wheel", x: 0.19, y: 0.85),
            ]
        case .rear:
            return [
                JobVehicleArea(name: "Rear window", x: 0.50, y: 0.27),
                JobVehicleArea(name: "Trunk or tailgate", x: 0.50, y: 0.46),
                JobVehicleArea(name: "License plate area", x: 0.50, y: 0.60),
                JobVehicleArea(name: "Rear bumper", x: 0.50, y: 0.72),
                JobVehicleArea(name: "Driver-side taillight", x: 0.18, y: 0.52),
                JobVehicleArea(name: "Passenger-side taillight", x: 0.82, y: 0.52),
                JobVehicleArea(name: "Driver-side rear wheel", x: 0.19, y: 0.85),
                JobVehicleArea(name: "Passenger-side rear wheel", x: 0.81, y: 0.85),
            ]
        case .left, .right:
            // Distances from the front of the car; mirrored for the
            // passenger side exactly like the drawing.
            let facesLeft = self == .left
            func area(_ name: String, _ fromFront: Double, _ y: Double) -> JobVehicleArea {
                JobVehicleArea(name: name, x: facesLeft ? fromFront : 1 - fromFront, y: y)
            }
            return [
                area("Front bumper", 0.05, 0.54),
                area("Front fender", 0.22, 0.48),
                area("Front wheel", 0.22, 0.74),
                area("Front door", 0.40, 0.55),
                area("Front door window", 0.43, 0.31),
                area("Roof line", 0.52, 0.18),
                area("Rocker panel", 0.51, 0.68),
                area("Rear door", 0.63, 0.55),
                area("Rear door window", 0.63, 0.31),
                area("Rear quarter panel", 0.84, 0.50),
                area("Rear wheel", 0.80, 0.74),
                area("Rear bumper", 0.96, 0.54),
            ]
        case .top:
            return [
                JobVehicleArea(name: "Hood", x: 0.50, y: 0.13),
                JobVehicleArea(name: "Windshield", x: 0.50, y: 0.29),
                JobVehicleArea(name: "Roof", x: 0.50, y: 0.53),
                JobVehicleArea(name: "Rear window", x: 0.50, y: 0.76),
                JobVehicleArea(name: "Trunk or rear deck", x: 0.50, y: 0.89),
                JobVehicleArea(name: "Driver-side mirror", x: 0.065, y: 0.32),
                JobVehicleArea(name: "Passenger-side mirror", x: 0.935, y: 0.32),
            ]
        case .interior:
            return [
                JobVehicleArea(name: "Dashboard", x: 0.50, y: 0.12),
                JobVehicleArea(name: "Steering wheel", x: 0.28, y: 0.195),
                JobVehicleArea(name: "Driver seat", x: 0.28, y: 0.38),
                JobVehicleArea(name: "Center console", x: 0.50, y: 0.37),
                JobVehicleArea(name: "Passenger seat", x: 0.72, y: 0.38),
                JobVehicleArea(name: "Rear seat, driver side", x: 0.245, y: 0.68),
                JobVehicleArea(name: "Rear seat, middle", x: 0.50, y: 0.68),
                JobVehicleArea(name: "Rear seat, passenger side", x: 0.755, y: 0.68),
                JobVehicleArea(name: "Cargo area", x: 0.50, y: 0.875),
            ]
        }
    }
}

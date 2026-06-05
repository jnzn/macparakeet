import SwiftUI
import XCTest
@testable import MacParakeet

/// Guards the PDX-016 optimization: the base rose curve is precomputed once in
/// unit space and scaled per frame, instead of re-evaluating sin/cos for every
/// sample on every frame. These tests lock that the precomputed curve is
/// identical to the original per-point formula, so the visual is unchanged.
final class RhodoneaScribeLoaderTests: XCTestCase {
    func testPrecomputedBaseCurveMatchesScaledPointFormula() {
        let size = CGSize(width: 120, height: 96)
        let radius = min(size.width, size.height) * 0.44
        let centerX = size.width / 2
        let centerY = size.height / 2

        XCTAssertEqual(RhodoneaScribeLoader.baseUnitPoints.count, RhodoneaScribeLoader.baseSamples + 1)

        for (index, unit) in RhodoneaScribeLoader.baseUnitPoints.enumerated() {
            let phase = Double(index) / Double(RhodoneaScribeLoader.baseSamples)
            let scaled = CGPoint(x: centerX + radius * unit.x, y: centerY + radius * unit.y)
            let expected = RhodoneaScribeLoader.point(phase: phase, size: size)
            XCTAssertEqual(scaled.x, expected.x, accuracy: 1e-9)
            XCTAssertEqual(scaled.y, expected.y, accuracy: 1e-9)
        }
    }

    func testUnitPointMatchesRoseCurveFormula() {
        // Independent re-derivation of r = sin^2(2.5θ) on the unit curve.
        for index in 0...20 {
            let phase = Double(index) / 20.0
            let theta = phase * 2 * .pi
            let s = sin(2.5 * theta)
            let r = s * s
            let expected = CGPoint(x: r * cos(theta), y: r * sin(theta))
            let actual = RhodoneaScribeLoader.unitPoint(phase: phase)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-12)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-12)
        }
    }
}

import XCTest
import SwiftUI

/// The bar-length side of the "used / remaining" setting. The number beside
/// every bar already followed the setting; the bar did not, so "20% left"
/// used to sit next to a bar drawn four-fifths full.
final class UsagePaletteTests: XCTestCase {

    /// The one wrong answer: no reading inverted into a full bar, which reads
    /// as "plenty left" right next to the "—" the label shows.
    func testNoReadingGivesNoFillInEitherMode() {
        XCTAssertNil(UsagePalette.barFill(nil, showsRemaining: false))
        XCTAssertNil(UsagePalette.barFill(nil, showsRemaining: true))
    }

    func testUsedAndRemainingAreComplements() {
        for (used, remaining) in [(0.0, 1.0), (25.0, 0.75), (50.0, 0.5), (100.0, 0.0)] {
            XCTAssertEqual(UsagePalette.barFill(used, showsRemaining: false)!, used / 100, accuracy: 1e-9,
                           "used \(used)")
            XCTAssertEqual(UsagePalette.barFill(used, showsRemaining: true)!, remaining, accuracy: 1e-9,
                           "used \(used)")
        }
    }

    /// 50% is the one value where a flipped bar looks identical either way,
    /// so the asymmetric case is the one that proves the flip happened.
    func testSeventyPercentUsedIsThirtyPercentOfBarWhenShowingRemaining() {
        XCTAssertEqual(UsagePalette.barFill(70, showsRemaining: true)!, 0.3, accuracy: 1e-9)
        XCTAssertEqual(UsagePalette.barFill(70, showsRemaining: false)!, 0.7, accuracy: 1e-9)
    }

    /// Overage is reported as more than 100%; the bar stops at full (and at
    /// empty in the other mode) rather than overflowing its track.
    func testOutOfRangeReadingsClampToTheTrack() {
        XCTAssertEqual(UsagePalette.barFill(140, showsRemaining: false)!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(UsagePalette.barFill(140, showsRemaining: true)!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(UsagePalette.barFill(-5, showsRemaining: false)!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(UsagePalette.barFill(-5, showsRemaining: true)!, 1.0, accuracy: 1e-9)
    }

    /// The pace tick on the menu bar bar runs through the same conversion, so
    /// "fill past the tick = burning fast" survives the flip with its
    /// direction reversed: 70 used against 40 elapsed is 0.7 > 0.4 one way and
    /// 0.3 < 0.6 the other. Both say the same thing.
    func testPaceComparisonSurvivesTheFlip() {
        let usedFill = UsagePalette.barFill(70, showsRemaining: false)!
        let usedTick = UsagePalette.barFill(40, showsRemaining: false)!
        XCTAssertGreaterThan(usedFill, usedTick)

        let leftFill = UsagePalette.barFill(70, showsRemaining: true)!
        let leftTick = UsagePalette.barFill(40, showsRemaining: true)!
        XCTAssertLessThan(leftFill, leftTick)
    }

    /// A spent quota draws no fill at all in "remaining" mode — the right
    /// length, and the reason the menu bar can no longer hang its warning on
    /// the fill. Pinned here because it is the fact the view has to cope with;
    /// that it now colours the always-present outline instead is a view
    /// change, checked on the real menu bar rather than faked in a unit test
    /// (`MenuBarConfig` would drag real UserDefaults into a logic bundle).
    func testASpentQuotaDrawsNoFillInRemainingMode() {
        XCTAssertEqual(UsagePalette.barFill(100, showsRemaining: true)!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(UsagePalette.barFill(140, showsRemaining: true)!, 0.0, accuracy: 1e-9)
        XCTAssertEqual(UsagePalette.barFill(99, showsRemaining: true)!, 0.01, accuracy: 1e-9)
    }
}

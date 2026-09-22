import XCTest
@testable import CursorMeter

/// The dimensionless chart metric `percent` (share of the cycle allowance),
/// driven by "Popover shows → Percent".
final class WeeklyChartScaleMetricTests: XCTestCase {

    private func day(units: Double, cents: Double) -> DayUsage {
        DayUsage(
            date: Date(), requests: Int(units.rounded()), isToday: false,
            isOnDemand: false, onDemandCents: 0, totalChargedCents: Int(cents.rounded()),
            usageUnits: units, amountCents: cents)
    }

    // MARK: - Denominator

    func testScaleBasisPicksTheMatchingDayField() {
        let day = self.day(units: 12, cents: 3400)
        XCTAssertEqual(
            WeeklyChartScale(total: 1, basisIsCents: false).basisValue(for: day), 12)
        XCTAssertEqual(
            WeeklyChartScale(total: 1, basisIsCents: true).basisValue(for: day), 3400)
    }

    func testScaleGuardsAgainstZeroAllowance() {
        let scale = WeeklyChartScale(total: 0, basisIsCents: false)
        XCTAssertNil(WeeklyChartMetric.percent.value(for: day(units: 10, cents: 0), scale: scale))
    }

    // MARK: - Percent values

    func testPercentIsShareOfCycleAllowance() {
        let scale = WeeklyChartScale(total: 3000, basisIsCents: false)
        let value = WeeklyChartMetric.percent.value(for: day(units: 300, cents: 0), scale: scale) ?? -1
        XCTAssertEqual(value, 10, accuracy: 0.001, "300 of 3000 = 10%")
    }

    func testCreditPlansScaleInCents() {
        let scale = WeeklyChartScale(total: 120_000, basisIsCents: true)
        let value = WeeklyChartMetric.percent.value(for: day(units: 0, cents: 12_000), scale: scale) ?? -1
        XCTAssertEqual(value, 10, accuracy: 0.001, "$120.00 of $1200.00")
    }

    func testPercentNeedsAScale() {
        let day = self.day(units: 10, cents: 100)
        XCTAssertNil(WeeklyChartMetric.percent.value(for: day, scale: nil))
        XCTAssertTrue(WeeklyChartMetric.percent.needsScale)
        XCTAssertFalse(WeeklyChartMetric.amount.needsScale)
    }

    // MARK: - Fallback

    func testPercentDegradesWithoutAllowance() {
        let days = [day(units: 5, cents: 500), day(units: 8, cents: 800)]
        XCTAssertEqual(days.effectiveMetric(preferred: .percent, hasScale: false), .usageUnits)
        XCTAssertEqual(days.effectiveMetric(preferred: .percent, hasScale: true), .percent)
    }

    func testAmountStillDegradesWhenMoneyIsMissing() {
        let days = [
            DayUsage(date: Date(), requests: 3, isToday: false, isOnDemand: false,
                     onDemandCents: 0, totalChargedCents: 0, usageUnits: 3, amountCents: nil),
        ]
        XCTAssertEqual(days.effectiveMetric(preferred: .amount), .usageUnits)
    }

    // MARK: - Labels

    func testPeakLabelsFollowTheMetric() {
        XCTAssertEqual(WeeklyUsageChartView.peakLabel(value: 1234, metric: .amount), "$12.34")
        XCTAssertEqual(WeeklyUsageChartView.peakLabel(value: 12.34, metric: .usageUnits), "12.3")
        XCTAssertEqual(WeeklyUsageChartView.peakLabel(value: 96.82, metric: .percent), "96.8%")
    }

    func testSortIndexIsStableForPopupTags() {
        XCTAssertEqual(WeeklyChartMetric.allCases.map(\.sortIndex), [0, 1, 2])
        XCTAssertEqual(WeeklyChartMetric(sortIndex: 2), .percent)
        XCTAssertNil(WeeklyChartMetric(sortIndex: 9))
    }
}

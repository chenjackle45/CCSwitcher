import Foundation

/// Anthropic's limited-time "double usage" promo logic, centralized so the
/// popover banner and the app lifecycle agree.
enum DoubleUsagePromo {
    /// Inclusive start / exclusive end of the promo campaign window.
    private static func campaignBounds() -> (start: Date, end: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        // The campaign window is defined in Anthropic's ET schedule; computing
        // the boundary Dates in the user's local zone would shift them by the
        // UTC offset for non-ET users.
        if let et = TimeZone(identifier: "America/New_York") {
            calendar.timeZone = et
        }
        var startC = DateComponents()
        startC.year = 2026; startC.month = 3; startC.day = 13
        var endC = DateComponents()
        endC.year = 2026; endC.month = 3; endC.day = 29 // up to March 28 inclusive
        guard let start = calendar.date(from: startC),
              let end = calendar.date(from: endC) else { return nil }
        return (start, end)
    }

    /// True if the promo campaign is running at `date` (drives the banner).
    static func isCampaignActive(at date: Date = Date()) -> Bool {
        guard let bounds = campaignBounds() else { return false }
        return date >= bounds.start && date < bounds.end
    }
}

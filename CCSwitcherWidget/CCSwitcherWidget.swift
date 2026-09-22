import WidgetKit
import SwiftUI

// MARK: - Brand Color

private let brandColor = Color(rgb: UsagePalette.terracotta)

// MARK: - Timeline Entry

struct CCSwitcherEntry: TimelineEntry {
    let date: Date
    let data: WidgetData?

    static let placeholder = CCSwitcherEntry(
        date: .now,
        data: WidgetData(
            accounts: [
                WidgetAccountData(
                    email: "us***@ex***.com",
                    displayName: "My Org",
                    subscriptionType: "Pro",
                    isActive: true,
                    sessionUtilization: 42,
                    sessionResetTime: "2 hr 15 min",
                    weeklyUtilization: 28,
                    weeklyResetTime: "in 3 days",
                    fableWeeklyUtilization: 35,
                    fableWeeklyResetTime: "in 3 days",
                    extraUsageEnabled: true,
                    hasError: false,
                    errorMessage: nil
                )
            ],
            todayCost: 3.45,
            conversationTurns: 18,
            activeCodingTime: "1h 30m",
            linesWritten: 326,
            modelUsage: ["Fable": 18, "Opus": 12, "Sonnet": 5, "Haiku": 1],
            lastUpdated: .now,
            showsRemaining: false
        )
    )
}

// MARK: - Timeline Provider

struct CCSwitcherProvider: TimelineProvider {
    func placeholder(in context: Context) -> CCSwitcherEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (CCSwitcherEntry) -> Void) {
        if context.isPreview {
            completion(.placeholder)
        } else {
            completion(currentEntry())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CCSwitcherEntry>) -> Void) {
        let entry = currentEntry()
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }

    private func currentEntry() -> CCSwitcherEntry {
        CCSwitcherEntry(date: .now, data: WidgetData.load())
    }
}

// MARK: - Widget Entry View

struct CCSwitcherWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: CCSwitcherEntry

    var body: some View {
        if let data = entry.data {
            switch family {
            case .systemSmall:
                SmallWidgetView(data: data)
            case .systemMedium:
                MediumWidgetView(data: data)
            case .systemLarge:
                LargeWidgetView(data: data)
            default:
                SmallWidgetView(data: data)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(brandColor)
                .widgetAccentable()
            Text("Open CCSwitcher")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("to load data")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Small Widget

private struct SmallWidgetView: View {
    let data: WidgetData
    @Environment(\.colorScheme) private var scheme

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header — account + badge
            HStack(spacing: 5) {
                if let account = activeAccount {
                    Text(account.displayName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if let sub = account.subscriptionType {
                        PlanBadge(text: sub)
                    }
                } else {
                    Text("CCSwitcher")
                        .font(.caption.weight(.semibold))
                    Spacer()
                }
            }

            if let account = activeAccount {
                Spacer(minLength: 2)

                // Usage bars
                if account.hasError {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(UsagePalette.warning.color(scheme))
                        if let msg = account.errorMessage {
                            Text(msg)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        } else {
                            Text("Error")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } else {
                    compactUsageBar(label: "Session", utilization: account.sessionUtilization)
                    compactUsageBar(label: "Weekly", utilization: account.weeklyUtilization)
                    if account.fableWeeklyUtilization != nil {
                        compactUsageBar(label: "Weekly · Fable", utilization: account.fableWeeklyUtilization)
                    }
                }

                Spacer(minLength: 2)

                // Today's cost
                HStack {
                    Text(formatCost(data.todayCost))
                        .font(.title3.weight(.semibold).monospacedDigit())
                    Text("today")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            } else {
                Spacer()
                Text("No accounts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private func compactUsageBar(label: LocalizedStringKey, utilization: Double?) -> some View {
        // `pct` is only ever a colour input. The filled length goes through
        // `barFill`, which keeps "no reading" as an empty track instead of
        // turning it into a full "100% remaining" bar.
        let pct = utilization ?? 0
        let fill = UsagePalette.barFill(utilization, showsRemaining: data.showsRemaining ?? false)
        return VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(utilization.map { UsagePalette.percentText($0, showsRemaining: data.showsRemaining ?? false) } ?? "—")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(pct, scheme))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.quaternary)
                        .frame(height: 5)
                    if let fill {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(colorForUtilization(pct, scheme))
                            .frame(width: geo.size.width * fill, height: 5)
                    }
                }
            }
            .frame(height: 5)
        }
    }
}

// MARK: - Medium Widget

private struct MediumWidgetView: View {
    let data: WidgetData
    @Environment(\.colorScheme) private var scheme

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 5) {
                if let account = activeAccount {
                    Text(account.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if let sub = account.subscriptionType {
                        PlanBadge(text: sub)
                    }
                }
                Spacer()
                Text(data.lastUpdated, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 4)

            // Main content: usage bars on left, activity on right
            HStack(spacing: 12) {
                // Left: Usage bars
                VStack(alignment: .leading, spacing: 0) {
                    if let account = activeAccount {
                        if account.hasError {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(UsagePalette.warning.color(scheme))
                                if let msg = account.errorMessage {
                                    Text(msg)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                } else {
                                    Text("Error")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer(minLength: 0)
                        } else {
                            Spacer(minLength: 0)
                            usageBar(label: "Session", utilization: account.sessionUtilization, resetTime: account.sessionResetTime)
                            Spacer(minLength: 4)
                            usageBar(label: "Weekly", utilization: account.weeklyUtilization, resetTime: account.weeklyResetTime)
                            if account.fableWeeklyUtilization != nil {
                                Spacer(minLength: 4)
                                usageBar(label: "Weekly · Fable", utilization: account.fableWeeklyUtilization, resetTime: account.fableWeeklyResetTime)
                            }

                            if let extra = account.extraUsageEnabled {
                                Spacer(minLength: 4)
                                HStack(spacing: 4) {
                                    Image(systemName: extra ? "bolt.fill" : "bolt.slash")
                                        .font(.caption2)
                                        .foregroundStyle(extra ? UsagePalette.warning.color(scheme) : .gray)
                                    Text("Extra usage")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(LocalizedStringKey(extra ? "On" : "Off"))
                                        .font(.caption2)
                                        .foregroundStyle(extra ? UsagePalette.warning.color(scheme) : .gray)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Divider
                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1)

                // Right: Activity stats
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    statRow(icon: "dollarsign.circle", label: "Cost", value: formatCost(data.todayCost))
                    Spacer(minLength: 4)
                    statRow(icon: "bubble.left.and.bubble.right", label: "Turns", value: "\(data.conversationTurns)")
                    Spacer(minLength: 4)
                    statRow(icon: "clock", label: "Active", value: data.activeCodingTime)
                    Spacer(minLength: 4)
                    statRow(icon: "doc.text", label: "Lines", value: "\(data.linesWritten)")
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func usageBar(label: LocalizedStringKey, utilization: Double?, resetTime: String?) -> some View {
        // `pct` is only a colour input; see `compactUsageBar`.
        let pct = utilization ?? 0
        let fill = UsagePalette.barFill(utilization, showsRemaining: data.showsRemaining ?? false)
        return VStack(spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                if let reset = resetTime {
                    Text(reset)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(utilization.map { UsagePalette.percentText($0, showsRemaining: data.showsRemaining ?? false) } ?? "—")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(colorForUtilization(pct, scheme))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2.5)
                        .fill(.quaternary)
                        .frame(height: 5)
                    if let fill {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(colorForUtilization(pct, scheme))
                            .frame(width: geo.size.width * fill, height: 5)
                    }
                }
            }
            .frame(height: 5)
        }
    }

    private func statRow(icon: String, label: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.caption.weight(.medium).monospacedDigit())
        }
    }
}

// MARK: - Large Widget

private struct LargeWidgetView: View {
    let data: WidgetData
    @Environment(\.colorScheme) private var scheme

    /// One compact row per account so eight accounts fit (issue #35).
    private static let maxAccounts = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header — app name + which bar is which
            HStack(spacing: 5) {
                Text("CCSwitcher+")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Top to bottom: Session / Weekly / Fable")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            // Today's activity
            HStack(spacing: 0) {
                activityStat(icon: "bubble.left.and.bubble.right", value: "\(data.conversationTurns)", label: "Turns")
                activityStat(icon: "clock", value: data.activeCodingTime, label: "Active")
                activityStat(icon: "doc.text", value: "\(data.linesWritten)", label: "Lines")
                activityStat(icon: "dollarsign.circle", value: formatCost(data.todayCost), label: "Cost")
            }

            // Per-account rows
            VStack(spacing: 0) {
                ForEach(Array(data.accounts.prefix(Self.maxAccounts).enumerated()), id: \.offset) { index, account in
                    if index > 0 {
                        Rectangle()
                            .fill(.quaternary)
                            .frame(height: 0.5)
                    }
                    accountRow(account)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func activityStat(icon: String, value: String, label: LocalizedStringKey) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func accountRow(_ account: WidgetAccountData) -> some View {
        HStack(spacing: 7) {
            Text(account.displayName)
                .font(.caption2.weight(account.isActive ? .bold : .regular))
                .foregroundStyle(account.isActive ? UsagePalette.brandText.color(scheme) : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            if account.hasError {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(UsagePalette.warning.color(scheme))
                    if let msg = account.errorMessage {
                        Text(msg)
                    } else {
                        Text("Error")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 115, alignment: .leading)
            } else {
                VStack(spacing: 2) {
                    thinBar(account.sessionUtilization)
                    thinBar(account.weeklyUtilization)
                    thinBar(account.fableWeeklyUtilization)
                }
                .frame(width: 72)

                // The tightest of the three windows.
                let peak = [account.sessionUtilization, account.weeklyUtilization, account.fableWeeklyUtilization]
                    .compactMap { $0 }
                    .max()
                Text(peak.map { UsagePalette.percentText($0, showsRemaining: data.showsRemaining ?? false) } ?? "—")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(colorForUtilization(peak ?? 0, scheme))
                    .fixedSize()
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
    }

    private func thinBar(_ utilization: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                if let pct = utilization,
                   let fill = UsagePalette.barFill(pct, showsRemaining: data.showsRemaining ?? false) {
                    Capsule()
                        .fill(colorForUtilization(pct, scheme))
                        .frame(width: geo.size.width * fill)
                }
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Circular (Rings) Widget

private struct CircleWidgetView: View {
    let data: WidgetData
    @Environment(\.colorScheme) private var scheme

    private var activeAccount: WidgetAccountData? {
        data.accounts.first(where: \.isActive) ?? data.accounts.first
    }

    var body: some View {
        VStack(spacing: 8) {
            // Header — show account name instead of app name
            HStack(spacing: 5) {
                Text(activeAccount?.displayName ?? "CCSwitcher")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if let sub = activeAccount?.subscriptionType {
                    PlanBadge(text: sub)
                }
            }

            Spacer(minLength: 0)

            if let account = activeAccount, !account.hasError {
                HStack(spacing: 12) {
                    ringStat(
                        label: "Session",
                        resetTime: account.sessionResetTime,
                        utilization: account.sessionUtilization,
                        accent: colorForUtilization(account.sessionUtilization ?? 0, scheme)
                    )
                    ringStat(
                        label: "Weekly",
                        resetTime: account.weeklyResetTime,
                        utilization: account.weeklyUtilization,
                        accent: colorForUtilization(account.weeklyUtilization ?? 0, scheme)
                    )
                }
                .frame(maxWidth: .infinity)
            } else if let account = activeAccount, account.hasError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title3)
                        .foregroundStyle(UsagePalette.warning.color(scheme))
                    if let msg = account.errorMessage {
                        Text(msg)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    } else {
                        Text("Error")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)
                    }
                }
            } else {
                Text("No accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    private func ringStat(label: LocalizedStringKey, resetTime: String?, utilization: Double?, accent: Color) -> some View {
        // The arc follows the same setting as the number inside it; with no
        // reading there is no arc, rather than a full ring around a "—".
        let arc = UsagePalette.barFill(utilization, showsRemaining: data.showsRemaining ?? false)
        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 6)
                if let arc {
                    Circle()
                        .trim(from: 0, to: arc)
                        .stroke(accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(utilization.map { UsagePalette.percentText($0, showsRemaining: data.showsRemaining ?? false) } ?? "—")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 6)
            }
            .aspectRatio(1, contentMode: .fit)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let reset = resetTime {
                Text(reset)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CircleWidgetEntryView: View {
    var entry: CCSwitcherEntry

    var body: some View {
        if let data = entry.data {
            CircleWidgetView(data: data)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 28))
                    .foregroundStyle(brandColor)
                Text("Open CCSwitcher")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("to load data")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Helpers

private func colorForUtilization(_ pct: Double, _ scheme: ColorScheme) -> Color {
    UsagePalette.level(pct).color(scheme)
}

/// Plan name ("Max") as a quiet outlined tag.
private struct PlanBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 1))
    }
}

private func formatCost(_ cost: Double) -> String {
    cost >= 1 ? String(format: "$%.2f", cost) : String(format: "$%.4f", cost)
}

// MARK: - Widget Definition

struct CCSwitcherWidget: Widget {
    let kind: String = "CCSwitcherWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CCSwitcherProvider()) { entry in
            CCSwitcherWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("CCSwitcher")
        .description("Monitor your Claude Code account usage, costs, and activity.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CCSwitcherCircleWidget: Widget {
    let kind: String = "CCSwitcherCircleWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CCSwitcherProvider()) { entry in
            CircleWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("CCSwitcher Rings")
        .description("Session and weekly usage shown as circular progress rings.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Widget Bundle

@main
struct CCSwitcherWidgetBundle: WidgetBundle {
    @WidgetBundleBuilder
    var body: some Widget {
        CCSwitcherWidget()
        CCSwitcherCircleWidget()
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}

#Preview("Medium", as: .systemMedium) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}

#Preview("Large", as: .systemLarge) {
    CCSwitcherWidget()
} timeline: {
    CCSwitcherEntry.placeholder
}

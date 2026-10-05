import Accessibility
import Charts
import SwiftUI
import ClaudeUsageCore

struct TokenChartPoint: Identifiable {
    let date: Date
    let tokens: UInt64
    var id: Date { date }
}

struct TokenModelSeries: Identifiable {
    let model: TokenOverviewModel
    let points: [TokenChartPoint]
    var id: String { model.id }
}

struct TokenUsageChart: View {
    let data: TokenPageData
    @State private var hoveredDate: Date?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var title: String { data.summary.range.hourly ? "Hourly processed tokens" : "Daily processed tokens" }
    private var axisDates: [Date] {
        let dates = data.summary.series.map(\.start)
        guard let first = dates.first, let last = dates.last else { return [] }
        return Array(Set([first, dates[dates.count / 2], last])).sorted()
    }
    private var domain: ClosedRange<Date> {
        let first = data.summary.series.first?.start ?? data.summary.start
        let last = data.summary.series.last?.start ?? data.summary.end
        return first...max(first.addingTimeInterval(1), last)
    }
    private var maximum: Double {
        max(1, Double(data.chartSeries.flatMap(\.points).map(\.tokens).max() ?? 0) * 1.08)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.headline)
            chart
                .frame(height: 260)
                .accessibilityLabel(title)
                .accessibilityValue("\(data.summary.totals.total) tokens across \(data.summary.sessions) sessions")
                .accessibilityChartDescriptor(TokenChartAccessibility(data: data, title: title, maximum: maximum))
                .accessibilityHint("Use left and right arrow keys to inspect each time period.")
                .focusable()
                .onMoveCommand(perform: moveSelection)
                .onExitCommand { hoveredDate = nil }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: data.summary) { _ in hoveredDate = nil }
        .transaction { transaction in
            if reduceMotion { transaction.animation = nil }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(data.chartSeries) { series in
                ForEach(series.points) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Tokens", Double(point.tokens)),
                             series: .value("Model", series.model.id), stacking: .unstacked)
                        .foregroundStyle(series.model.color.opacity(contrast == .increased ? 0.22 : 0.14))
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", point.date), y: .value("Tokens", Double(point.tokens)),
                             series: .value("Model", series.model.id))
                        .foregroundStyle(series.model.color)
                        .lineStyle(StrokeStyle(lineWidth: contrast == .increased ? 2 : 1.5))
                        .interpolationMethod(.catmullRom)
                }
            }
            if let hoveredDate {
                RuleMark(x: .value("Selected date", hoveredDate))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...maximum)
        .chartLegend(.hidden)
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisValueLabel(anchor: xLabelAnchor(value.as(Date.self)), collisionResolution: .disabled) {
                    if let date = value.as(Date.self) {
                        Text(TokenChartDate.axis(date, hourly: data.summary.range.hourly))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: contrast == .increased ? 1 : 0.5))
                    .foregroundStyle(Color(nsColor: .separatorColor))
                AxisValueLabel {
                    if let value = value.as(Double.self) {
                        Text(UsageFormat.compactTokens(UInt64(max(0, value))))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
        }
        .chartPlotStyle { plot in plot.clipped() }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                let plot = geometry[proxy.plotAreaFrame]
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard plot.contains(location), let date: Date = proxy.value(atX: location.x - plot.minX) else {
                                hoveredDate = nil
                                return
                            }
                            hoveredDate = data.summary.series.min {
                                abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
                            }?.start
                        case .ended:
                            hoveredDate = nil
                        }
                    }
                if let hoveredDate, let position = proxy.position(forX: hoveredDate) {
                    let width = min(240, geometry.size.width)
                    let x = position + plot.minX
                    let proposed = x > plot.midX ? x - width - 12 : x + 12
                    hoverCard(for: hoveredDate)
                        .frame(width: width)
                        .offset(x: max(0, min(geometry.size.width - width, proposed)), y: 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func xLabelAnchor(_ date: Date?) -> UnitPoint {
        if date == axisDates.first { return .topLeading }
        if date == axisDates.last { return .topTrailing }
        return .top
    }

    private func hoverCard(for date: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(TokenChartDate.bucket(date, hourly: data.summary.range.hourly))
                .font(.caption.weight(.medium))
            ForEach(data.chartSeries) { series in
                HStack(spacing: 7) {
                    Circle().fill(series.model.color).frame(width: 6, height: 6)
                    Text(series.model.title).lineLimit(1)
                    Spacer(minLength: 6)
                    Text(UsageFormat.compactTokens(series.points.first { $0.date == date }?.tokens ?? 0))
                }
                .font(.caption)
            }
        }
        .monospacedDigit()
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 0.5)
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let dates = data.summary.series.map(\.start)
        guard !dates.isEmpty else { return }
        let index = hoveredDate.flatMap { dates.firstIndex(of: $0) }
        switch direction {
        case .left: hoveredDate = dates[max(0, (index ?? dates.count) - 1)]
        case .right: hoveredDate = dates[min(dates.count - 1, (index ?? -1) + 1)]
        default: break
        }
    }
}

private enum TokenChartDate {
    static func axis(_ date: Date, hourly: Bool) -> String {
        if hourly { return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))).uppercased() }
        return date.formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }

    static func bucket(_ date: Date, hourly: Bool) -> String {
        if hourly { return date.formatted(.dateTime.month(.abbreviated).day().hour(.defaultDigits(amPM: .abbreviated))) }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

private struct TokenChartAccessibility: AXChartDescriptorRepresentable {
    let data: TokenPageData
    let title: String
    let maximum: Double

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = data.summary.series.map(\.start)
        let first = dates.first ?? data.summary.start
        let last = dates.last ?? data.summary.end
        let hourly = data.summary.range.hourly
        let xAxis = AXNumericDataAxisDescriptor(
            title: hourly ? "Hour" : "Day", range: first.timeIntervalSince1970...max(first.timeIntervalSince1970 + 1, last.timeIntervalSince1970),
            gridlinePositions: []
        ) { TokenChartDate.bucket(Date(timeIntervalSince1970: $0), hourly: hourly) }
        let yAxis = AXNumericDataAxisDescriptor(title: "Processed tokens", range: 0...maximum, gridlinePositions: []) {
            "\(UInt64(max(0, $0))) tokens"
        }
        let series = data.chartSeries.map { series in
            AXDataSeriesDescriptor(name: series.model.title, isContinuous: true, dataPoints: series.points.map {
                AXDataPoint(x: $0.date.timeIntervalSince1970, y: Double($0.tokens),
                            label: "\(TokenChartDate.bucket($0.date, hourly: hourly)), \($0.tokens) tokens")
            })
        }
        return AXChartDescriptor(title: title,
                                 summary: "\(data.summary.totals.total) processed tokens across \(data.summary.sessions) sessions.",
                                 xAxis: xAxis, yAxis: yAxis, series: series)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let updated = makeChartDescriptor()
        descriptor.title = updated.title
        descriptor.summary = updated.summary
        descriptor.xAxis = updated.xAxis
        descriptor.yAxis = updated.yAxis
        descriptor.series = updated.series
    }
}

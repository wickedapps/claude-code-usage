import AppKit
import ServiceManagement
import SwiftUI
import ClaudeUsageCore

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    var maximumHeight: CGFloat = .greatestFiniteMagnitude

    static let width: CGFloat = 560

    var body: some View {
        SettingsHeightLimit(maximumHeight: maximumHeight) {
            ViewThatFits(in: .vertical) {
                sections.fixedSize(horizontal: false, vertical: true)
                ScrollView { sections }
            }
        }
        .frame(width: Self.width)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("settings-view")
    }

    private var sections: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let error = store.settingsError, !error.isEmpty {
                StatusBanner(kind: .error, text: error)
            }
            SettingsCard(title: "General") {
                SettingsRow(title: "Appearance", description: appearanceDescription) {
                    Picker("Appearance", selection: $store.appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .accessibilityLabel("Appearance")
                    .accessibilityHint(appearanceDescription)
                }
                Divider()
                SettingsRow(title: "Open at login", description: loginDescription,
                            message: store.loginMessage) {
                    HStack(spacing: 12) {
                        if store.loginMessage?.localizedCaseInsensitiveContains("approval") == true {
                            Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                                .buttonStyle(.bordered)
                                .accessibilityHint("Approve Claude Code Usage to open at login.")
                        }
                        settingsToggle("Open at login", description: loginHint, isOn: Binding(
                            get: { store.loginEnabled }, set: { store.setLoginEnabled($0) }
                        ))
                    }
                }
                Divider()
                SettingsRow(title: "Start in the menu bar only", description: startDescription) {
                    settingsToggle("Start in the menu bar only", description: startDescription,
                                   isOn: setting(\.startHidden))
                }
            }
            SettingsCard(title: "Menu bar") {
                SettingsRow(title: "Show 5-hour usage", description: fiveHourDescription) {
                    settingsToggle("Show 5-hour usage", description: fiveHourDescription,
                                   isOn: setting(\.menuBar.showFiveHour))
                        .disabled(fiveHourLocked)
                }
                Divider()
                SettingsRow(title: "Show weekly usage", description: weeklyDescription) {
                    settingsToggle("Show weekly usage", description: weeklyDescription,
                                   isOn: setting(\.menuBar.showSevenDay))
                        .disabled(weeklyLocked)
                }
                Divider()
                SettingsRow(title: "Percentages", description: percentDescription) {
                    Picker("Percentages", selection: setting(\.menuBar.percent)) {
                        Text("Left").tag(PercentMode.left)
                        Text("Used").tag(PercentMode.used)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                    .accessibilityLabel("Percentages")
                    .accessibilityHint(percentDescription)
                }
                Divider()
                SettingsRow(title: "Show 5h and 7d labels", description: labelsDescription) {
                    settingsToggle("Show 5h and 7d labels", description: labelsDescription,
                                   isOn: setting(\.menuBar.showLabels))
                }
                Divider()
                SettingsRow(title: "Show reset countdown", description: resetDescription) {
                    settingsToggle("Show reset countdown", description: resetDescription,
                                   isOn: setting(\.menuBar.showReset))
                }
                Divider()
                SettingsRow(title: "Preview", description: previewDescription) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(UsageFormat.menuBarTitle(
                            state: store.state, limits: store.limits,
                            settings: store.settings.menuBar, loading: store.loading, now: context.date
                        ))
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.2),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Preview")
                        .accessibilityValue(UsageFormat.menuBarTitle(
                            state: store.state, limits: store.limits,
                            settings: store.settings.menuBar, loading: store.loading, now: context.date
                        ))
                        .accessibilityHint(previewDescription)
                    }
                }
            }
            SettingsCard(title: "Refresh") {
                SettingsRow(title: "Refresh interval", description: refreshDescription) {
                    Picker("Refresh interval", selection: setting(\.refresh)) {
                        ForEach(RefreshRate.allCases, id: \.self) { rate in
                            Text(rate.label).tag(rate)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .accessibilityLabel("Refresh interval")
                    .accessibilityHint(refreshDescription)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .font(.body)
    }

    private let appearanceDescription = "Use light or dark mode, or follow the system."
    private let loginDescription = "Open Claude Code Usage when you sign in."
    private let startDescription = "Launch without opening the usage window."
    private let percentDescription = "Show the percentage left or used."
    private let labelsDescription = "Label each usage window in the menu bar."
    private let resetDescription = "Show the time until each usage limit resets."
    private let previewDescription = "Your current menu bar title."
    private let refreshDescription = "How often limits update while the window is closed. The open window refreshes every minute."

    private var loginHint: String {
        guard let message = store.loginMessage, !message.isEmpty else { return loginDescription }
        return loginDescription + " " + message
    }

    private var fiveHourDescription: String {
        fiveHourLocked ? "At least one window stays in the menu bar." : "Show your 5-hour limit in the menu bar."
    }

    private var weeklyDescription: String {
        weeklyLocked ? "At least one window stays in the menu bar." : "Show your weekly limit in the menu bar."
    }

    private var fiveHourLocked: Bool { store.settings.menuBar.showFiveHour && shownCount == 1 }
    private var weeklyLocked: Bool { store.settings.menuBar.showSevenDay && shownCount == 1 }

    private var shownCount: Int {
        [store.settings.menuBar.showFiveHour, store.settings.menuBar.showSevenDay].filter { $0 }.count
    }

    private func settingsToggle(_ title: String, description: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(title)
            .accessibilityHint(description)
    }

    private func setting<Value>(_ path: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(get: { store.settings[keyPath: path] }, set: { value in
            store.updateSettings { $0[keyPath: path] = value }
        })
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.body)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: contrast == .increased ? 1.5 : 1)
                }
        }
    }
}

private struct SettingsRow<Control: View>: View {
    let title: String
    let description: String
    var message: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 320, alignment: .leading)
            // The native control supplies this title and description as its label and hint.
            .accessibilityHidden(true)
            Spacer(minLength: 0)
            control.fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
}

/// Propose the measured page height, capped to the screen, so ViewThatFits only
/// selects the scrolling variant when the full page cannot fit.
private struct SettingsHeightLimit: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: min(size.height, maximumHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(bounds.size))
    }
}

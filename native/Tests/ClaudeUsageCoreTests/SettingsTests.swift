import XCTest
@testable import ClaudeUsageCore

final class SettingsTests: XCTestCase {
    private var home: URL!
    private let bundleID = "com.example.claude-usage"

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private var environment: [String: String] { ["HOME": home.path] }

    func testRoundTripKeepsTheSavedNamesAndLayout() throws {
        var settings = AppSettings()
        settings.menuBar.showFiveHour = false
        settings.menuBar.showSevenDay = true
        settings.menuBar.percent = .used
        settings.menuBar.showLabels = false
        settings.menuBar.showReset = true
        settings.startHidden = true
        settings.refresh = .fifteenMinutes

        let expected = """
        {
          "menu_bar": {
            "show_five_hour": false,
            "show_seven_day": true,
            "percent": "used",
            "show_labels": false,
            "show_reset": true
          },
          "start_hidden": true,
          "refresh": "fifteen_minutes"
        }
        """
        XCTAssertEqual(SettingsPersistence.encode(settings), expected)

        try SettingsPersistence.save(settings, bundleID: bundleID, environment: environment)
        let file = try XCTUnwrap(SettingsPersistence.settingsFileURL(bundleID: bundleID, environment: environment))
        XCTAssertTrue(file.path.hasSuffix("/Library/Application Support/com.example.claude-usage/settings.json"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), expected)
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), settings)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("json.tmp").path))
    }

    func testDefaultsMatchThePreSettingsBehavior() throws {
        let settings = AppSettings()
        XCTAssertTrue(settings.menuBar.showFiveHour)
        XCTAssertTrue(settings.menuBar.showSevenDay)
        XCTAssertTrue(settings.menuBar.showLabels)
        XCTAssertFalse(settings.menuBar.showReset)
        XCTAssertEqual(settings.menuBar.percent, .left)
        XCTAssertFalse(settings.startHidden)
        XCTAssertEqual(settings.refresh, .fiveMinutes)
        XCTAssertEqual(settings.refresh.interval, 300)

        try SettingsPersistence.save(settings, bundleID: bundleID, environment: environment)
        let file = try XCTUnwrap(SettingsPersistence.settingsFileURL(bundleID: bundleID, environment: environment))
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text, """
        {
          "menu_bar": {
            "show_five_hour": true,
            "show_seven_day": true,
            "percent": "left",
            "show_labels": true,
            "show_reset": false
          },
          "start_hidden": false,
          "refresh": "five_minutes"
        }
        """)
    }

    func testPartialFileFillsDefaultsAndDropsUnknownFields() throws {
        try write("""
        {"start_hidden":true,"menu_bar":{"show_opus":true},"future":42}
        """)
        let loaded = SettingsPersistence.load(bundleID: bundleID, environment: environment)
        XCTAssertTrue(loaded.startHidden)
        XCTAssertTrue(loaded.menuBar.showFiveHour)
        XCTAssertTrue(loaded.menuBar.showSevenDay)
        XCTAssertEqual(loaded.menuBar.percent, .left)
        XCTAssertEqual(loaded.refresh, .fiveMinutes)

        try SettingsPersistence.save(loaded, bundleID: bundleID, environment: environment)
        let file = try XCTUnwrap(SettingsPersistence.settingsFileURL(bundleID: bundleID, environment: environment))
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(saved.contains("show_opus"))
        XCTAssertFalse(saved.contains("future"))
        XCTAssertTrue(saved.contains("\"start_hidden\": true"))
    }

    func testDocumentedNamesAndExplicitFalseStick() throws {
        try write("""
        {
            "menu_bar": {
                "show_five_hour": true,
                "show_seven_day": false,
                "percent": "used",
                "show_labels": false,
                "show_reset": true
            },
            "start_hidden": false,
            "refresh": "one_minute"
        }
        """)
        let loaded = SettingsPersistence.load(bundleID: bundleID, environment: environment)
        XCTAssertFalse(loaded.menuBar.showLabels)
        XCTAssertFalse(loaded.menuBar.showSevenDay)
        XCTAssertTrue(loaded.menuBar.showFiveHour)
        XCTAssertTrue(loaded.menuBar.showReset)
        XCTAssertEqual(loaded.menuBar.percent, .used)
        XCTAssertEqual(loaded.refresh, .oneMinute)
        XCTAssertEqual(loaded.refresh.interval, 60)
        XCTAssertFalse(loaded.startHidden)
    }

    func testSwiftStyleSpacingStillDecodes() throws {
        try write("""
        {
          "refresh" : "fifteen_minutes",
          "start_hidden" : true,
          "menu_bar" : {
            "percent" : "left",
            "show_labels" : false
          }
        }
        """)
        let loaded = SettingsPersistence.load(bundleID: bundleID, environment: environment)
        XCTAssertEqual(loaded.refresh, .fifteenMinutes)
        XCTAssertTrue(loaded.startHidden)
        XCTAssertFalse(loaded.menuBar.showLabels)
        XCTAssertTrue(loaded.menuBar.showFiveHour)
        XCTAssertEqual(loaded.menuBar.percent, .left)
    }

    func testInvalidOrNullValuesFallBackToTheWholeDefault() throws {
        try write(#"{"start_hidden":true,"refresh":"weekly"}"#)
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())

        try write(#"{"start_hidden":true,"menu_bar":{"percent":"both"}}"#)
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())

        try write(#"{"start_hidden":null,"refresh":"one_minute"}"#)
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())

        try write(#"{"menu_bar":{"show_labels":null},"start_hidden":true}"#)
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())

        try write("{")
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())

        try write(#"{"start_hidden":"yes"}"#)
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())
    }

    func testMissingFileAndTempFileStayOnDefaults() throws {
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())

        let file = try XCTUnwrap(SettingsPersistence.settingsFileURL(bundleID: bundleID, environment: environment))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"start_hidden":true}"#.utf8).write(to: file.deletingPathExtension().appendingPathExtension("json.tmp"))
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), AppSettings())
    }

    func testSaveReplacesThePreviousFileAtomically() throws {
        var first = AppSettings()
        first.refresh = .oneMinute
        try SettingsPersistence.save(first, bundleID: bundleID, environment: environment)

        let file = try XCTUnwrap(SettingsPersistence.settingsFileURL(bundleID: bundleID, environment: environment))
        let temporary = file.deletingPathExtension().appendingPathExtension("json.tmp")
        try Data("junk".utf8).write(to: temporary)

        var second = AppSettings()
        second.startHidden = true
        second.refresh = .fifteenMinutes
        try SettingsPersistence.save(second, bundleID: bundleID, environment: environment)

        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: environment), second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual(names, ["settings.json"])
    }

    func testMissingHomeCannotBeSaved() {
        XCTAssertEqual(SettingsPersistence.load(bundleID: bundleID, environment: [:]), AppSettings())
        XCTAssertThrowsError(try SettingsPersistence.save(AppSettings(), bundleID: bundleID, environment: [:])) { error in
            XCTAssertEqual(error.localizedDescription, "No home directory to save settings in")
        }
    }

    private func write(_ text: String) throws {
        let file = try XCTUnwrap(SettingsPersistence.settingsFileURL(bundleID: bundleID, environment: environment))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
}

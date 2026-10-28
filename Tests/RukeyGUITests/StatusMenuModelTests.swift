import XCTest
@testable import RukeyGUI

@MainActor
final class StatusMenuModelTests: XCTestCase {
    func testStatusTitleWhenRunning() {
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: false,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false)
        XCTAssertEqual(model.statusTitle, "Работает")
    }

    func testStatusTitleWithoutPermission() {
        let model = StatusMenuModel(
            permission: .denied, running: false, secureInputActive: false,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false)
        XCTAssertEqual(model.statusTitle, "Нет прав Accessibility")
    }

    func testStatusTitleWhenGrantedButNotRunning() {
        let model = StatusMenuModel(
            permission: .granted, running: false, secureInputActive: false,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false)
        XCTAssertEqual(model.statusTitle, "Не запущено")
    }

    func testStatusTitleUnderSecureInput() {
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: true,
            language: .russian, lastCorrection: nil, learningBanner: nil,
            launchAtLogin: false)
        XCTAssertEqual(model.statusTitle, "Приостановлено: защищённый ввод")
    }

    func testLastCorrectionIsTruncatedToTheLimit() {
        let long = String(repeating: "а", count: 200)
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: false,
            language: .russian,
            lastCorrection: .init(original: long, converted: long),
            learningBanner: nil, launchAtLogin: false)
        XCTAssertTrue(model.lastCorrectionTitle!.count <= StatusItemController.menuTitleLimit + 3)
        XCTAssertTrue(model.lastCorrectionTitle!.contains("…"))
    }

    func testLearningBannerWinsOverCorrectionForTheBannerSlot() {
        let model = StatusMenuModel(
            permission: .granted, running: true, secureInputActive: false,
            language: .russian,
            lastCorrection: .init(original: "ghb", converted: "при"),
            learningBanner: .init(prefix: "ghb", converted: "при"),
            launchAtLogin: false)
        XCTAssertNotNil(model.learningBannerTitle)
        XCTAssertEqual(model.learningBannerTitle, "Запомнено: ghb больше не станет при")
    }
}

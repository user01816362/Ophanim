import Foundation
import UIKit

let settings = AppConfig.shared

@objc public final class AppConfig: NSObject {
    @objc public static let shared = AppConfig()

    let bundleIdentifier = Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? ""
    let settingsUrl: URL
    var settingsData: AppSettingsData

    override init() {
        #if os(macOS)
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        #else
        let homeURL = URL(fileURLWithPath: "/Users/\(NSUserName())")
        #endif
        settingsUrl = homeURL
            .appendingPathComponent("Library/Containers/be.ophanim.Ophanim")
            .appendingPathComponent("App Settings")
            .appendingPathComponent("\(bundleIdentifier).plist")
        do {
            let data = try Data(contentsOf: settingsUrl)
            settingsData = try PropertyListDecoder().decode(AppSettingsData.self, from: data)
        } catch {
            settingsData = AppSettingsData()
            print("[Galgal] AppConfig decode failed: \(error)")
        }
    }


    lazy var keymapping = settingsData.keymapping

    lazy var notch = settingsData.notch

    lazy var sensitivity = settingsData.sensitivity / 100

    @objc lazy var bypass = settingsData.bypass

    /// Per-detector jailbreak-bypass allowlist (ObjC class names). GalgalShadow swizzles a detector
    /// only if its class name is in this set. Empty = no jailbreak bypass.
    @objc lazy var jailbreakBypasses: [String] = settingsData.jailbreakBypasses ?? []

    @objc lazy var windowSizeHeight = CGFloat(settingsData.windowHeight)

    @objc lazy var windowSizeWidth = CGFloat(settingsData.windowWidth)

    @objc lazy var inverseScreenValues = settingsData.inverseScreenValues

    @objc lazy var adaptiveDisplay = settingsData.resolution == 0 ? false : true

    @objc lazy var resizableWindow = settingsData.resolution == 6 ? true : false

    @objc lazy var deviceModel = settingsData.iosDeviceModel as NSString

    /// Device table (verified against Apple tech specs + theiphonewiki identifiers;
    /// see commit history for sources). iPad Pro only; iPhones 16 and newer.
    /// oemID feeds hw.target. iPad entries carry BoardConfig values (JxxxAP); iPhone
    /// entries carry A-model numbers (same slot, documented mixing - true iPhone
    /// BoardConfigs are not published per model).
    /// Dropped: iPad6,7 / iPad8,6 (A9X/A12X), iPhone14,3 / 15,3 / 16,2 (13-15 series),
    /// iPhone19,4 (foldable identifier unverified - never ship a guessed board).
    /// M5 13-inch board (J8xx) unverified: A-number A3360 used instead, marked below.
    /// iPhone19,2 board + both 19,x RAM figures unverified (leak-grade only).
    @objc lazy var oemID: NSString = {
        switch settingsData.iosDeviceModel {
        // iPad Pro (RAM = highest available per model: 12GB exists only on M5)
        case "iPad13,8":
            return "J522AP"     // Pro 12.9" 5th (M1)
        case "iPad14,5":
            return "J620AP"     // Pro 12.9" 6th (M2) - was A2436 (A-number, wrong slot)
        case "iPad16,5":
            return "J720AP"     // Pro 13" 7th (M4) Wi-Fi - was iPad16,6+A2925 cross-wired
        case "iPad17,3":
            return "A3360"      // Pro 13" M5 Wi-Fi - A-number: J8xx board UNVERIFIED
        // iPhone 16 series (all 8GB)
        case "iPhone17,1":
            return "A3083"      // 16 Pro
        case "iPhone17,2":
            return "A3084"      // 16 Pro Max
        case "iPhone17,3":
            return "A3081"      // 16
        case "iPhone17,4":
            return "A3082"      // 16 Plus
        case "iPhone17,5":
            return "A3212"      // 16e
        // iPhone 17 series
        case "iPhone18,1":
            return "A3256"      // 17 Pro (12GB)
        case "iPhone18,2":
            return "A3257"      // 17 Pro Max (12GB)
        case "iPhone18,3":
            return "A3258"      // 17 (8GB)
        case "iPhone18,4":
            return "A3260"      // Air (12GB)
        case "iPhone18,5":
            return "A3575"      // 17e (8GB)
        // iPhone 18 series (identifiers verified; RAM leak-grade, marked unverified)
        case "iPhone19,2":
            return "A3472"      // 18 Pro [board UNVERIFIED]
        case "iPhone19,3":
            return "A3473"      // 18 Pro Max
        case "iPhone19,4":
            return "A3447"      // foldable [identifier + board UNVERIFIED - user override]
        default:
            return "J320xAP"
        }
    }()

    /// Reported memory in bytes, per model (hw.memsize spoof). Highest available RAM
    /// per model: 12GB exists only on M5 iPads (M1/M2/M4 top out at 8/16 with no 12GB
    /// tier, so they report 16GB). iPhone 16 series: 8GB; 17 Pro/Air: 12GB.
    @objc lazy var memoryBytes: NSNumber = {
        switch settingsData.iosDeviceModel {
        case "iPad13,8", "iPad14,5", "iPad16,5":
            return NSNumber(value: Int64(16) * 1024 * 1024 * 1024)
        case "iPad17,3":
            return NSNumber(value: Int64(12) * 1024 * 1024 * 1024)
        case "iPhone18,1", "iPhone18,2", "iPhone18,4":
            return NSNumber(value: Int64(12) * 1024 * 1024 * 1024)
        case "iPhone19,2", "iPhone19,3", "iPhone19,4":
            return NSNumber(value: Int64(12) * 1024 * 1024 * 1024) // [unverified]
        default:
            return NSNumber(value: Int64(8) * 1024 * 1024 * 1024)
        }
    }()

    @objc lazy var chainGuard = settingsData.chainGuard

    @objc lazy var chainGuardDebugging = settingsData.chainGuardDebugging

    @objc lazy var windowFixMethod = settingsData.windowFixMethod

    @objc lazy var customScaler = settingsData.customScaler

    @objc lazy var rootWorkDir = settingsData.rootWorkDir

    @objc lazy var noKMOnInput = settingsData.noKMOnInput

    @objc lazy var enableScrollWheel = settingsData.enableScrollWheel

    @objc lazy var hideTitleBar = settingsData.hideTitleBar

    @objc lazy var floatingWindow = settingsData.floatingWindow

    @objc lazy var displayRotation = settingsData.displayRotation

    @objc lazy var checkMicPermissionSync = settingsData.checkMicPermissionSync

    @objc lazy var limitMotionUpdateFrequency = settingsData.limitMotionUpdateFrequency

    @objc lazy var disableBuiltinMouse = settingsData.disableBuiltinMouse

    @objc lazy var blockSleepSpamming = settingsData.blockSleepSpamming
}

struct AppSettingsData: Codable {
    var keymapping = true
    var sensitivity: Float = 50

    var disableTimeout = false
    var iosDeviceModel = "iPad13,8"
    var windowWidth = 1920
    var windowHeight = 1080
    var customScaler = 2.0
    var resolution = 2
    var aspectRatio = 1
    var displayRotation = 0
    var notch = false
    var bypass = false
    // Optional so older plists (without the key) still decode. nil/absent = no jailbreak bypass.
    var jailbreakBypasses: [String]?
    var version = "2.0.0"
    var chainGuard = false
    var chainGuardDebugging = false
    var inverseScreenValues = false
    var windowFixMethod = 0
    var rootWorkDir = true
    var noKMOnInput = false
    var enableScrollWheel = true
    var hideTitleBar = false
    var floatingWindow = false
    var checkMicPermissionSync = false
    var limitMotionUpdateFrequency = false
    var disableBuiltinMouse = false
    var resizableAspectRatioType = 0
    var resizableAspectRatioWidth = 0
    var resizableAspectRatioHeight = 0
    var blockSleepSpamming = false
}

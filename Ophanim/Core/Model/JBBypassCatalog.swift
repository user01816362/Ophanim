import Foundation

/// Catalog of per-SDK jailbreak/root detectors that Galgal's GalgalShadow can bypass. The `id` is
/// the ObjC class name GalgalShadow swizzles (the runtime gates each on whether its id is in the
/// per-app allowlist `settings.jailbreakBypasses`); `label` is a human hint shown in the editor.
/// Keep ids in sync with the `[GalgalShadowLoader jb:@"…"]` gates in GalgalShadow.m.
enum JBBypassCatalog {
    static let all: [(id: String, label: String)] = [
        ("UIDevice", "UIDevice (generic + device info)"),
        ("RNDeviceInfo", "React Native DeviceInfo"),
        ("JailbreakDetection", "JailbreakDetection"),
        ("JailbreakDetectionVC", "JailbreakDetectionVC"),
        ("DTTJailbreakDetection", "DTTJailbreakDetection"),
        ("jailBreak", "jailBreak"),
        ("jailBrokenJudge", "jailBrokenJudge (Cydia/path/file)"),
        ("ANSMetadata", "ANSMetadata (Akamai)"),
        ("AppsFlyerUtils", "AppsFlyer"),
        ("OneSignalJailbreakDetection", "OneSignal"),
        ("ADYSecurityChecks", "Adyen"),
        ("GemaltoConfiguration", "Gemalto / Thales"),
        ("DigiPassHandler", "OneSpan DigiPass"),
        ("v_VDMap", "Verimatrix VOS (debugger/tamper too)"),
        ("TNGDeviceTool", "TNG (Cydia/file/env)"),
        ("KSSystemInfo", "Kochava"),
        ("GBDeviceInfo", "GBDeviceInfo"),
        ("FBAdBotDetector", "Facebook Ad Bot Detector"),
        ("SDMUtils", "SDMUtils"),
        ("UtilitySystem", "UtilitySystem"),
        ("CMARAppRestrictionsDelegate", "CMARAppRestrictionsDelegate"),
        ("UBReportMetadataDevice", "Urban Airship"),
        ("CPWRDeviceInfo", "CPWRDeviceInfo"),
        ("CPWRSessionInfo", "CPWRSessionInfo"),
        ("EMDSKPPConfiguration", "Entrust EMDSKPP"),
        ("EnrollParameters", "EnrollParameters"),
        ("EMDskppConfigurationBuilder", "Entrust EMDskppConfigurationBuilder"),
        ("FCRSystemMetadata", "FCRSystemMetadata"),
        ("DTXSessionInfo", "DTXSessionInfo"),
        ("DTXDeviceInfo", "DTXDeviceInfo"),
        ("DTDeviceInfo", "DTDeviceInfo"),
        ("SecVIDeviceUtil", "SecVIDeviceUtil"),
        ("RVPBridgeExtension4Jailbroken", "RVPBridgeExtension4Jailbroken"),
        ("ZDetection", "Zimperium zDetection"),
        ("AWMyDeviceGeneralInfo", "AirWatch / Workspace ONE"),
    ]
    static var allIDs: [String] { all.map(\.id) }
}


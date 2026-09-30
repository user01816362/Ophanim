import Foundation

/// Pure aggregation over decoded OPEvents: NDJSON scan + behavior/privacy report.
enum ReportBuilder {
    /// Load captured events for an app, newest last, optionally filtered, capped to `limit`.
    static func events(_ bundleID: String, category: String?, search: String?, limit: Int) -> [OPEvent] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        var all: [OPEvent] = []
        for dir in logDirs(bundleID) {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { continue }
            for f in files where f.pathExtension == "ndjson" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard let d = line.data(using: .utf8),
                          let e = try? decoder.decode(OPEvent.self, from: d) else { continue }
                    if let category, e.category.rawValue != category { continue }
                    if let search, !search.isEmpty,
                       !(e.api.localizedCaseInsensitiveContains(search)
                         || e.summary.localizedCaseInsensitiveContains(search)
                         || e.fields.contains { $0.value.localizedCaseInsensitiveContains(search) }) {
                        continue
                    }
                    all.append(e)
                }
            }
        }
        all.sort { $0.timestamp < $1.timestamp }
        return limit > 0 && all.count > limit ? Array(all.suffix(limit)) : all
    }

    /// Where capture NDJSON lives. The current path is Ophanim's shared container keyed by bundle id
    /// (`OPPaths.logDirectory`); the legacy path is the app's own data container, kept so logs written
    /// before the shared-dir fix stay readable. Both are scanned by `events`.
    private static func logDirs(_ bundleID: String) -> [URL] {
        [OPPaths.logDirectory(forBundleID: bundleID),
         OPPaths.legacyLogDirectory(forBundleID: bundleID)]
    }

    /// Filesystem path probes matched against event paths (case-insensitive
    /// substring). iOS-absolute markers (no macOS-host FP); the few generic names
    /// at the end rely on the hosted-app context. See Research/10 for the 2026
    /// landscape (rootless default, ElleKit, RootHide, Sileo/Zebra, Frida).
    private static let jbMarkers = ["/var/jb", "/private/preboot", "/var/Liy", ".procursus_strapped",
        "/Applications/Sileo.app", "/Applications/Zebra.app", "/Applications/Filza.app",
        "/Applications/Dopamine.app", "/Applications/palera1nLoader.app", "/Applications/Cydia.app",
        "com.opa334.Dopamine.plist", "/usr/bin/palera1n-helper", "/var/binpack", ".installed_unc0ver",
        ".cydia_no_stash", "/jb/", "/private/var/stash", "/etc/apt", "/private/var/lib/apt",
        "/Library/MobileSubstrate/DynamicLibraries", "MobileSubstrate", ".jbroot",
        "libellekit.dylib", "libhooker.dylib", "libsubstitute.dylib", "TweakInject",
        "/usr/sbin/frida-server", "/usr/lib/frida", "FridaGadget", "frida-agent",
        "cycript", "libcycript", "CydiaSubstrate", "cydia.log",
        "ABDYLD.dylib", "ABSubLoader.dylib",
        "/etc/ssh/sshd_config", "/usr/libexec/ssh-keysign", "jailbreak"]

    /// Known tracker / analytics / ad / attribution / crash-reporting SDK host substrings.
    /// 2026 set: Firebase still core (+logging/installation hosts), CleverTap + PostHog +
    /// TelemetryDeck added, TikTok App Events, ironSource/LevelPlay (supersonicads),
    /// AppLovin MAX subdomains, Sentry ingest, Airship/Customer.io, Criteo.
    /// Removed: Flurry (sunset Mar 2024), MoPub (sunset Mar 2022). See Research/11.
    static let trackerCatalog: [String: String] = [
        "google-analytics.com": "Google Analytics (analytics)",
        "googletagmanager.com": "Google Tag Manager (analytics)",
        "app-measurement.com": "Firebase Analytics (analytics)",
        "firebaselogging.googleapis.com": "Firebase Logging (analytics)",
        "firebaseinstallations.googleapis.com": "Firebase Installations (analytics)",
        "firebase": "Firebase (analytics)", "crashlytics.com": "Crashlytics (crash)",
        "doubleclick.net": "Google Ads / DoubleClick (ads)", "googlesyndication.com": "Google AdSense (ads)",
        "googleadservices.com": "Google Ads (ads)", "admob": "Google AdMob (ads)",
        "graph.facebook.com": "Facebook SDK (analytics/ads)", "facebook.com/v": "Facebook Graph (analytics)",
        "appsflyer.com": "AppsFlyer (attribution)", "onelink.me": "AppsFlyer OneLink (attribution)",
        "adjust.com": "Adjust (attribution)", "adj.st": "Adjust (attribution)",
        "branch.io": "Branch (attribution)", "singular.net": "Singular (attribution)", "kochava.com": "Kochava (attribution)",
        "amplitude.com": "Amplitude (analytics)", "mixpanel.com": "Mixpanel (analytics)",
        "us.i.posthog.com": "PostHog (analytics)", "nom.telemetrydeck.com": "TelemetryDeck (analytics)",
        "segment.com": "Segment (analytics)", "segment.io": "Segment (analytics)",
        "sentry.io": "Sentry (crash)", "ingest.sentry.io": "Sentry ingest (crash)",
        "bugsnag.com": "Bugsnag (crash)", "nr-data.net": "New Relic (analytics)",
        "onesignal.com": "OneSignal (push/analytics)",
        "braze.com": "Braze (engagement)", "appboy.com": "Braze/Appboy (engagement)", "iterable.com": "Iterable (engagement)",
        "clevertap-prod.com": "CleverTap (engagement)", "wzrkt.com": "CleverTap legacy (engagement)",
        "airship.com": "Airship (push)", "customer.io": "Customer.io (engagement)",
        "moengage.com": "MoEngage (engagement)",
        "business-api.tiktok.com": "TikTok App Events (ads)", "criteo.com": "Criteo (ads)",
        "applovin.com": "AppLovin (ads)", "a.applovin.com": "AppLovin MAX (ads)",
        "ms.applovin.com": "AppLovin MAX (ads)", "rt.applovin.com": "AppLovin MAX RTB (ads)",
        "chartboost.com": "Chartboost (ads)", "vungle.com": "Vungle (ads)",
        "adcolony.com": "AdColony (ads)", "inmobi.com": "InMobi (ads)", "tapjoy.com": "TapJoy (ads)",
        "supersonicads.com": "ironSource/Unity LevelPlay (ads)", "ironsrc.com": "ironSource (ads)",
        "unity3d.com": "Unity Ads (ads)", "unityads": "Unity Ads (ads)",
        "scorecardresearch.com": "comScore (analytics)", "demdex.net": "Adobe Audience (analytics)",
        "omtrdc.net": "Adobe Analytics (analytics)"
    ]

    /// Summarize a run into a behavior/privacy picture: who it talked to, what it accessed, etc.
    static func report(_ bundleID: String) -> [String: Any] {
        let events = self.events(bundleID, category: nil, search: nil, limit: 0)
        var byCat: [String: Int] = [:]
        var hosts: [String: Int] = [:]
        var statuses: [String: Int] = [:]
        var identifiers = Set<String>()
        var privacy = Set<String>()
        var kcAccounts = Set<String>(); var kcOps: [String: Int] = [:]
        var cryptoOps = 0
        var jbProbes = Set<String>(); var jbBypassed = Set<String>()
        var pinChecks = 0; var pinBypassed = 0
        var launches = Set<String>(); var dlopens = Set<String>(); var spawns = Set<String>()
        var tlsPlaintext = false

        for e in events {
            byCat[e.category.rawValue, default: 0] += 1
            let f = e.fields
            switch e.category {
            case .network:
                if let h = f["host"], !h.isEmpty { hosts[h, default: 0] += 1 }
                else if let ip = f["ip"], !ip.isEmpty { hosts[ip, default: 0] += 1 }
                else if let u = f["url"], let host = URL(string: u)?.host { hosts[host, default: 0] += 1 }
                if let s = f["status"], s != "0", !s.isEmpty { statuses[s, default: 0] += 1 }
                if e.api.hasPrefix("SecTrust") { pinChecks += 1; if f["bypassed"] == "yes" { pinBypassed += 1 } }
                if e.layer == .tls { tlsPlaintext = true }
            case .device:
                identifiers.insert(f["value"].map { "\(e.api) = \($0)" } ?? e.api)
            case .privacy:
                privacy.insert(e.api)
            case .keychain:
                if let a = f["account"], !a.isEmpty { kcAccounts.insert(a) }
                kcOps[e.api, default: 0] += 1
            case .crypto:
                cryptoOps += 1
            case .filesystem:
                if let p = f["path"], jbMarkers.contains(where: { p.localizedCaseInsensitiveContains($0) }) {
                    jbProbes.insert(p)
                }
            case .jailbreak:
                jbBypassed.insert(e.summary.isEmpty ? e.api : e.api)
            case .process:
                if e.api.contains("openURL") || e.api.contains("canOpenURL"), let u = f["url"] { launches.insert(u) }
                else if e.api == "dlopen", let p = f["path"] { dlopens.insert(p) }
                else if (e.api == "posix_spawn" || e.api == "execve"), let p = f["path"] { spawns.insert(p) }
            }
        }

        func topHosts() -> [[String: Any]] {
            hosts.sorted { $0.value > $1.value }.prefix(40).map { ["host": $0.key, "connections": $0.value] }
        }
        var trackers: [[String: String]] = []
        for h in hosts.keys.sorted() {
            for (sub, sdk) in trackerCatalog where h.localizedCaseInsensitiveContains(sub) {
                trackers.append(["host": h, "sdk": sdk]); break
            }
        }
        return [
            "bundleID": bundleID,
            "eventsAnalyzed": events.count,
            "summaryByCategory": byCat,
            "network": [
                "distinctHosts": hosts.count,
                "hosts": topHosts(),
                "httpStatuses": statuses,
                "tlsPlaintextCaptured": tlsPlaintext,
                "trackersDetected": trackers
            ] as [String: Any],
            "identifiersAccessed": Array(identifiers).sorted(),
            "privacyAPIs": Array(privacy).sorted(),
            "keychain": ["accountsOrServices": Array(kcAccounts).sorted(), "operations": kcOps] as [String: Any],
            "cryptoOperations": cryptoOps,
            "jailbreak": ["pathProbes": Array(jbProbes).sorted(), "detectorsBypassed": Array(jbBypassed).sorted()] as [String: Any],
            "certificatePinning": ["checks": pinChecks, "forceAccepted": pinBypassed],
            "process": [
                "appsOrURLsLaunched": Array(launches).sorted(),
                "librariesLoaded": Array(dlopens).sorted(),
                "processesSpawned": Array(spawns).sorted()
            ] as [String: Any]
        ]
    }
}

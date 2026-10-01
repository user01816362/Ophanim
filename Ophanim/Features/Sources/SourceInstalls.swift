//
//  SourceInstalls.swift
//  Ophanim
//
//  Background-tolerant downloads + installs for App Sources, owned by this singleton
//  store - never by a view. Closing the Sources window destroys the view, not the
//  transfer: progress, pause/resume, and install handoff all live here.
//
//  Apple pattern (Downloading Files in the Background): a background URLSession with
//  a fixed identifier + delegate (completion-handler tasks do not survive), resume
//  data persisted per app (survives quit; restored as paused), AppDelegate draining
//  the background completion handler. Honest limits, stated not hidden: resume needs
//  a server that honors Range (falls back to a fresh download otherwise), and tmp
//  files belong to the URLSession temp dir until moved in didFinishDownloadingTo.
//

import Foundation

/// Transfer/install state per bundle id (one active transfer per app).
enum SourceInstallState: Equatable {
    case idle
    case downloading(progress: Double?)
    case paused(progress: Double?)
    case installing
    case failed(String)
}

@Observable
final class SourceInstalls: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static let shared = SourceInstalls()

    private(set) var states: [String: SourceInstallState] = [:]
    /// Human version string of the in-flight/paused transfer, for row display.
    private(set) var activeVersions: [String: String] = [:]

    private var session: URLSession!
    private var delegate: DownloadDelegate!

    private func makeSession() {
        let delegate = DownloadDelegate(owner: self)
        self.delegate = delegate
        let config = URLSessionConfiguration.background(
            withIdentifier: "be.ophanim.Ophanim.sources")
        config.sessionSendsLaunchEvents = true
        self.session = URLSession(configuration: config, delegate: delegate,
                                  delegateQueue: nil)
    }

    private var tasks: [String: URLSessionDownloadTask] = [:]
    /// Generation per bundle id: starting a new transfer retires the previous one's
    /// late callbacks (a cancelled twin's didCompleteWithError must never stomp the
    /// survivor's state). Embedded in taskDescription, checked on every callback.
    private var generations: [String: Int] = [:]
    /// The version object behind the in-flight/paused transfer (retry/resume need
    /// more than the version string). In-memory only; resume data persists separately.
    private var versionObjects: [String: SourceAppVersion] = [:]

    func versionObject(for bundleID: String) -> SourceAppVersion? {
        versionObjects[bundleID]
    }
    /// Staged downloads live under the product container (not system tmp) so the
    /// app's own cache-clear owns leftovers. Swept on init.
    /// Nonisolated: the URLSession delegate calls this synchronously inside its
    /// callback (file paths only, no published state).
    nonisolated private static var stagingDir: URL {
        Galgal.ophanimContainer.appendingPathComponent("AppSources/Downloads")
    }

    private var resumeDir: URL {
        Galgal.ophanimContainer.appendingPathComponent("AppSources/Resume")
    }

    override init() {
        super.init()
        makeSession()
        restoreInterrupted()
        sweepStaging()
    }

    func state(for bundleID: String) -> SourceInstallState {
        states[bundleID] ?? .idle
    }

    // MARK: - Control (called from rows / context menus / MCP)

    func start(app: SourceApp, version: SourceAppVersion) {
        let bid = app.bundleIdentifier
        cancelTask(for: bid, keepResume: false)
        // New generation retires the previous transfer's late callbacks (a cancelled
        // twin's didCompleteWithError must never stomp the survivor's state).
        let gen = (generations[bid] ?? 0) + 1
        generations[bid] = gen
        states[bid] = .downloading(progress: nil)
        activeVersions[bid] = version.version
        versionObjects[bid] = version
        let task = session.downloadTask(with: version.downloadURL)
        task.taskDescription = [bid, String(gen), version.version].joined(separator: "\n")
        tasks[bid] = task
        task.resume()
    }

    func pause(bundleID bid: String) {
        guard let task = tasks[bid] else { return }
        tasks[bid] = nil
        task.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let progress = self.progress(of: bid)
                if let resumeData { self.storeResume(resumeData, for: bid) }
                self.states[bid] = .paused(progress: progress)
            }
        }
    }

    func resume(bundleID bid: String, version: SourceAppVersion) {
        cancelTask(for: bid, keepResume: true)
        let gen = (generations[bid] ?? 0) + 1
        generations[bid] = gen
        states[bid] = .downloading(progress: progress(of: bid))
        activeVersions[bid] = version.version
        versionObjects[bid] = version
        let task: URLSessionDownloadTask
        if let resumeData = loadResume(for: bid) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: version.downloadURL)
        }
        task.taskDescription = [bid, String(gen), version.version].joined(separator: "\n")
        tasks[bid] = task
        task.resume()
    }

    func cancel(bundleID bid: String) {
        cancelTask(for: bid, keepResume: false)
        removeResume(for: bid)
        states[bid] = .idle
        activeVersions[bid] = nil
        versionObjects[bid] = nil
    }

    // MARK: - Delegate callbacks (via DownloadDelegate, always on MainActor here)

    func downloadProgress(bundleID bid: String, generation gen: Int,
                          written: Int64, expected: Int64) {
        guard isCurrent(bid, generation: gen),
              case .downloading = states[bid] else { return }
        states[bid] = .downloading(progress: expected > 0 ? Double(written) / Double(expected) : nil)
    }

    /// Generation check: stale callbacks from a superseded transfer are dropped.
    private func isCurrent(_ bid: String, generation gen: Int) -> Bool {
        generations[bid] == gen
    }

    func downloadFinished(bundleID bid: String, generation gen: Int, stagedAt dest: URL) {
        guard isCurrent(bid, generation: gen) else { return }
        tasks[bid] = nil
        removeResume(for: bid)
        // The file was moved into our staging dir synchronously inside the delegate
        // callback (Apple's contract: the session tmp is only valid for the callback's
        // duration). Validate before anything treats it as an IPA.
        do {
            try IPAValidate.downloadedFile(at: dest)
        } catch {
            states[bid] = .failed(error.localizedDescription)
            activeVersions[bid] = nil
            versionObjects[bid] = nil
            return
        }
        states[bid] = .installing
        // Background-safe: explicit Galgal decision from prefs, never a modal prompt.
        // The installer's own verdict reconciles the row (no timers, no guessing).
        // Postamble stays here (row state); the fetchApps+notify kernel is shared.
        AppInstalls.installIPA(at: dest,
                               injectGalgal: InstallPreferences.shared.alwaysInstallGalgal) { [weak self] installed in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if installed != nil, self.installedVersion(for: bid) != nil {
                    self.states[bid] = .idle
                    self.activeVersions[bid] = nil
                    self.versionObjects[bid] = nil
                } else {
                    self.states[bid] = .failed(
                        NSLocalizedString("sources.error.installFailed", comment: ""))
                    self.activeVersions[bid] = nil
                    self.versionObjects[bid] = nil
                }
            }
        }
    }

    func downloadFailed(bundleID bid: String, generation gen: Int,
                        error: Error, resumeData: Data?) {
        guard isCurrent(bid, generation: gen) else { return }
        tasks[bid] = nil
        if let resumeData {
            storeResume(resumeData, for: bid)
            states[bid] = .paused(progress: progress(of: bid))
        } else {
            removeResume(for: bid)
            states[bid] = .failed(error.localizedDescription)
            activeVersions[bid] = nil
            versionObjects[bid] = nil
        }
    }

    // MARK: - Installed inventory + version compare (single definitions)

    /// Installed (marketing version, build) from the local app's own Info.plist.
    func installedVersion(for bundleID: String) -> (version: String, build: String?)? {
        guard let appURL = AppQueryService.appURL(bundleID) else { return nil }
        let info = PlistReader.appInfoDict(at: appURL.appendingPathComponent("Info.plist"))
        guard let version = info["CFBundleShortVersionString"] as? String else { return nil }
        return (version, info["CFBundleVersion"] as? String)
    }

    /// Numeric-aware marketing-version compare (never lexicographic: "1.10" > "1.9").
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: .numeric)
    }

    /// Row state for a source app: reinstall when the feed's latest compatible build
    /// is what is installed, update when the feed is newer, install when absent.
    enum RowState: Equatable {
        case install
        case reinstall
        case update
    }

    func rowState(for app: SourceApp) -> RowState {
        guard let latest = latestCompatible(app),
              let installed = installedVersion(for: app.bundleIdentifier) else {
            return .install
        }
        let order = Self.compareVersions(latest.version, installed.version)
        if order == .orderedDescending { return .update }
        if order == .orderedSame,
           let latestBuild = latest.buildVersion, let installedBuild = installed.build,
           latestBuild != installedBuild,
           Self.compareVersions(latestBuild, installedBuild) == .orderedDescending {
            return .update
        }
        return .reinstall
    }

    /// First feed entry in feed order (versions[0] is latest per the source spec),
    /// falling back to the legacy flat-shape build for feeds without versions[].
    /// Downgrades never badge: only strictly-newer counts.
    /// Deliberately NO min/maxOSVersion filtering: feed bounds name iOS versions,
    /// but the host runs macOS - there is no honest mapping, and comparing macOS
    /// 15.x against an iOS 17.0 floor would false-exclude everything. The fields
    /// are still decoded (and shown) for transparency.
    func latestCompatible(_ app: SourceApp) -> SourceAppVersion? {
        if let first = app.versions.first { return first }
        return app.latestVersion
    }

    // MARK: - Resume persistence

    private func resumeURL(for bid: String) -> URL {
        try? FileManager.default.createDirectory(at: resumeDir,
                                                 withIntermediateDirectories: true)
        let safe = bid.replacingOccurrences(of: "/", with: "_")
        return resumeDir.appendingPathComponent("\(safe).resume")
    }

    private func storeResume(_ data: Data, for bid: String) {
        try? data.write(to: resumeURL(for: bid), options: .atomic)
    }

    private func loadResume(for bid: String) -> Data? {
        try? Data(contentsOf: resumeURL(for: bid))
    }

    private func removeResume(for bid: String) {
        try? FileManager.default.removeItem(at: resumeURL(for: bid))
    }

    private func progress(of bid: String) -> Double? {
        if case .downloading(let p) = states[bid] { return p }
        if case .paused(let p) = states[bid] { return p }
        return nil
    }

    private func cancelTask(for bid: String, keepResume: Bool) {
        if let task = tasks[bid] {
            tasks[bid] = nil
            if keepResume {
                task.cancel { [weak self] resumeData in
                    if let resumeData { self?.storeResume(resumeData, for: bid) }
                }
            } else {
                task.cancel()
            }
        }
        if !keepResume { removeResume(for: bid) }
    }

    /// Interrupted transfers (quit mid-download, failed with resume data) restore as
    /// paused: the user resumes explicitly, nothing restarts on its own.
    private func restoreInterrupted() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: resumeDir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "resume" {
            let bid = entry.deletingPathExtension().lastPathComponent
            states[bid] = .paused(progress: nil)
        }
    }

    /// Leftover staged IPAs (quit mid-install): our container, our responsibility.
    /// Resume data (above) is kept - only orphaned .ipa files go.
    private func sweepStaging() {
        let dir = Self.stagingDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.pathExtension == "ipa" {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    fileprivate nonisolated static func stageURL() -> URL {
        try? FileManager.default.createDirectory(at: stagingDir,
                                                 withIntermediateDirectories: true)
        return stagingDir.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ipa")
    }
}

/// URLSession delegate (nonisolated by necessity): forwards to the MainActor store.
/// Kept separate so session callbacks never touch published state off-main.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var owner: SourceInstalls?

    init(owner: SourceInstalls) { self.owner = owner }

    private func identity(of task: URLSessionTask) -> (bid: String, gen: Int)? {
        let parts = (task.taskDescription ?? "").split(separator: "\n").map(String.init)
        guard parts.count >= 2, let gen = Int(parts[1]) else { return nil }
        return (parts[0], gen)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let (bid, gen) = identity(of: downloadTask) else { return }
        let expected = totalBytesExpectedToWrite
        let written = totalBytesWritten
        Task { @MainActor [weak owner] in
            owner?.downloadProgress(bundleID: bid, generation: gen,
                                    written: written, expected: expected)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Synchronous move, INSIDE the callback: Apple's contract keeps the session
        // tmp valid only for this call's duration. Forwarding `location` across an
        // await was the 100%-repro "couldn't be moved" failure. A failed move here
        // surfaces through downloadFailed below (no tmp, no resume) - stated, not silent.
        guard let (bid, gen) = identity(of: downloadTask),
              let owner = owner else { return }
        let dest = SourceInstalls.stageURL()
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            Task { @MainActor [weak owner] in
                owner?.downloadFailed(bundleID: bid, generation: gen,
                                      error: error, resumeData: nil)
            }
            return
        }
        Task { @MainActor [weak owner] in
            owner?.downloadFinished(bundleID: bid, generation: gen, stagedAt: dest)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error,
              let (bid, gen) = identity(of: task) else { return }
        var resumeData: Data? = nil
        if let userInfo = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData]
            as? Data {
            resumeData = userInfo
        }
        Task { @MainActor [weak owner] in
            owner?.downloadFailed(bundleID: bid, generation: gen,
                                  error: error, resumeData: resumeData)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            (NSApp.delegate as? AppDelegate)?.backgroundSessionCompletion?()
            (NSApp.delegate as? AppDelegate)?.backgroundSessionCompletion = nil
        }
    }
}

import Foundation
import Combine

/// At most once a day, checks the project's GitHub releases for a newer tagged version and
/// shows a brief alert linking to it. No Sparkle, no code signing, no auto-install — just a
/// nudge; the user downloads the DMG (or opens the release page) and updates by hand.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    /// The newest version seen so far, normalized (no leading "v"). Nil until the first
    /// successful check completes.
    @Published private(set) var latestVersion: String? = nil
    /// True once `latestVersion` is newer than the running build.
    @Published private(set) var updateAvailable = false

    private static let releasesURL = URL(string: "https://api.github.com/repos/21AG21/MacNotchIsland/releases/latest")!
    private static let userAgent = "NotchIsland/1.0 (https://github.com/21AG21/MacNotchIsland)"
    /// How often a check is actually allowed to hit the network.
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    /// How often `start()`'s timer wakes up to see whether `checkInterval` has elapsed.
    private static let pollInterval: TimeInterval = 60 * 60
    private static let lastCheckKey = "lastUpdateCheck"
    private static let announcedTagKey = "announcedUpdateTag"

    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var started = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        if dueForCheck() { performCheck(forced: false) }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            guard let self, self.dueForCheck() else { return }
            self.performCheck(forced: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        started = false
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
    }

    /// User-initiated (a "Check for Updates…" menu item): always hits the network and always
    /// gives feedback, even when the running build is already current.
    func checkNow() {
        performCheck(forced: true)
    }

    // MARK: - Checking

    private func dueForCheck() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date else { return true }
        return Date().timeIntervalSince(last) >= Self.checkInterval
    }

    private func performCheck(forced: Bool) {
        // Never wake the network while the Mac is asleep.
        guard !EnergyPolicy.shared.isAsleep else { return }
        task?.cancel()
        var request = URLRequest(url: Self.releasesURL, timeoutInterval: 12)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let dataTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.handle(data: data, response: response, error: error, forced: forced)
            }
        }
        task = dataTask
        dataTask.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, forced: Bool) {
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard error == nil, (200..<300).contains(status), let data, let release = Self.parse(data) else {
            NSLog("Notch Island: update check failed\(error.map { " (\($0.localizedDescription))" } ?? "").")
            if forced { showUpToDateAlert() }
            return
        }
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        latestVersion = release.version
        let newer = Self.isNewer(release.version, than: current)
        updateAvailable = newer
        guard newer else {
            if forced { showUpToDateAlert() }
            return
        }
        // Avoid re-alerting on every automatic re-check once a tag has already been shown;
        // a manual "Check for Updates…" always confirms, even for an already-announced tag.
        let announced = UserDefaults.standard.string(forKey: Self.announcedTagKey)
        guard forced || announced != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: Self.announcedTagKey)
        showUpdateAlert(release)
    }

    private func showUpdateAlert(_ release: Release) {
        let custom = CustomActivity(title: "Update available", subtitle: "Notch Island \(release.version)",
                                     symbol: "arrow.down.circle.fill", tint: "blue",
                                     trailingText: release.version, url: release.releaseURL)
        let activity = IslandActivity(id: "update", kind: .custom, content: .custom(custom),
                                       priority: 85, presentation: .expanded, openAction: .url(release.releaseURL))
        ActivityCenter.shared.showAlert(activity, duration: 6)
    }

    private func showUpToDateAlert() {
        let custom = CustomActivity(title: "Up to date", symbol: "checkmark.circle.fill", tint: "green")
        let activity = IslandActivity(id: "update", kind: .custom, content: .custom(custom), priority: 85)
        ActivityCenter.shared.showAlert(activity, duration: 2)
    }

    // MARK: - Parsing & version comparison (pure, unit-tested)

    /// What we need from a GitHub "latest release" response.
    struct Release: Equatable {
        var version: String
        var releaseURL: URL
        var dmgURL: URL?
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [GitHubAsset]?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    /// Decodes a GitHub "latest release" payload. Nil on anything malformed or missing the
    /// fields we need.
    static func parse(_ data: Data) -> Release? {
        guard let decoded = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let url = URL(string: decoded.htmlURL) else { return nil }
        let version = normalize(tag: decoded.tagName)
        guard !version.isEmpty else { return nil }
        let dmgURL = decoded.assets?.first { $0.name.lowercased().hasSuffix(".dmg") }
            .flatMap { URL(string: $0.browserDownloadURL) }
        return Release(version: version, releaseURL: url, dmgURL: dmgURL)
    }

    /// Strips a single leading "v"/"V" from a release tag: "v1.2.3" -> "1.2.3".
    static func normalize(tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.first, first == "v" || first == "V" { t.removeFirst() }
        return t
    }

    /// Dotted-numeric version comparison ("v" prefixes are stripped first). Missing trailing
    /// components count as 0, so "1.2" equals "1.2.0"; a pre-release suffix ("2.0.0-beta")
    /// sorts lower than the plain release it precedes ("2.0.0").
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidate = normalize(tag: candidate)
        let current = normalize(tag: current)
        let (candidateBase, candidatePre) = splitPreRelease(candidate)
        let (currentBase, currentPre) = splitPreRelease(current)
        let candidateParts = numericComponents(candidateBase)
        let currentParts = numericComponents(currentBase)
        let count = max(candidateParts.count, currentParts.count)
        for i in 0..<count {
            let c = i < candidateParts.count ? candidateParts[i] : 0
            let d = i < currentParts.count ? currentParts[i] : 0
            if c != d { return c > d }
        }
        if candidatePre == nil && currentPre != nil { return true }
        if candidatePre != nil && currentPre == nil { return false }
        if let candidatePre, let currentPre, candidatePre != currentPre { return candidatePre > currentPre }
        return false
    }

    /// Splits "2.0.0-beta" into ("2.0.0", "beta"); a version with no "-" has no pre-release.
    private static func splitPreRelease(_ version: String) -> (base: String, pre: String?) {
        guard let dash = version.firstIndex(of: "-") else { return (version, nil) }
        let pre = String(version[version.index(after: dash)...])
        return (String(version[..<dash]), pre.isEmpty ? nil : pre)
    }

    private static func numericComponents(_ base: String) -> [Int] {
        base.split(separator: ".").map { Int($0) ?? 0 }
    }
}

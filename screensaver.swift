import AVFoundation
import Cocoa
import CryptoKit
import OSLog
import Quartz
import ScreenSaver

// MARK: - Logging

// A screensaver cannot be debugged interactively: it exits the moment you touch
// the machine, and it runs inside a system host process you did not launch.
// Logging is the only diagnostic channel, so it is worth doing properly.
// Users can collect these with Console.app, filtering on this subsystem.
private enum Log {
    private static let subsystem = "me.byjp.livescreensaver"

    static let player = Logger(subsystem: subsystem, category: "player")
    static let extraction = Logger(subsystem: subsystem, category: "extraction")
    static let config = Logger(subsystem: subsystem, category: "config")

    /// Stream URLs routinely carry signed tokens and expiry signatures in their
    /// query strings. Log enough to identify the stream, never enough to share
    /// someone's credentials in a bug report.
    static func redact(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return "<unparseable url>" }
        let hadQuery = components.query != nil
        components.query = nil
        components.fragment = nil
        let base = components.string ?? "<unparseable url>"
        return hadQuery ? base + "?<redacted>" : base
    }
}

// The preferences domain for ScreenSaverDefaults. This deliberately does NOT
// match CFBundleIdentifier (me.byjp.livescreensaver): changing it would orphan
// the settings of everyone who already has the screensaver installed, since
// their configured URL lives under this name. Migrate the stored values before
// ever changing this string.
private let ModuleName = "com.livescreensaver.app"
private let URLKey = "HLSStreamURL"
private let StreamStartTimeKey = "StreamStartTime"
private let DefaultURL =
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_adv_example_hevc/master.m3u8"

// MARK: - Shared URL Helper Functions

private let ytdlpPaths = [
    "/opt/homebrew/bin/yt-dlp",
    "/usr/local/bin/yt-dlp",
    "/opt/local/bin/yt-dlp",
    (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/yt-dlp"),
]

/// Whether a binary is safe for a screensaver to execute.
///
/// Two of the searched locations are writable without admin rights on a default
/// install (`/usr/local/bin`, `~/.local/bin`). Anything group- or world-writable
/// can be swapped by another account for something this process would then run,
/// so refuse it rather than execute it.
private func isSafeToExecute(_ path: String) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.uint16Value,
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
    else {
        return false
    }
    // Owned by root, or by whoever is running the screensaver.
    guard owner == 0 || owner == getuid() else { return false }
    // Not writable by group or other.
    return permissions & 0o022 == 0
}

/// Whether a yt-dlp exists at all, regardless of whether it is safe to run.
/// Lets the failure be reported as "unsafe" rather than "not installed".
private func ytDlpIsInstalled() -> Bool {
    return ytdlpPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
}

private func findYtDlpPath() -> String? {
    for path in ytdlpPaths where FileManager.default.isExecutableFile(atPath: path) {
        if isSafeToExecute(path) {
            return path
        }
        Log.extraction.error(
            "Refusing to run \(path, privacy: .public): writable by group or other")
    }
    return nil
}

/// Looked up once per process. yt-dlp breaks against YouTube often enough that
/// "which version" is the first question worth asking about a broken stream.
private let ytdlpVersion: String = {
    guard let path = findYtDlpPath() else { return "not installed" }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = ["--version"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let version = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (version?.isEmpty == false) ? version! : "unknown"
    } catch {
        return "unknown"
    }
}()

private func needsYtDlpExtraction(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString),
        let path = url.path.split(separator: "/").last
    else {
        return true
    }
    return !path.contains(".m3u8")
}

private func isStreamPlaceURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString),
        let host = url.host?.lowercased()
    else {
        return false
    }
    return host == "stream.place" || host.hasSuffix(".stream.place")
}

private func getStreamPlaceHLSURL(_ urlString: String) -> URL? {
    guard let url = URL(string: urlString),
        let host = url.host
    else {
        return nil
    }

    let path = url.path
    var username = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if username.hasPrefix("embed/") {
        username = String(username.dropFirst(6))
    }
    guard !username.isEmpty else {
        return nil
    }

    return URL(string: "https://\(host)/api/playback/\(username)/hls/index.m3u8")
}

// MARK: - Shared Player Manager (singleton for multi-monitor support)

private extension Notification.Name {
    static let sharedPlayerReady = Notification.Name("SharedPlayerReadyNotification")
    static let sharedPlayerFailed = Notification.Name("SharedPlayerFailedNotification")
}

/// Why playback could not start or continue, in terms a user can act on.
///
/// The configuration sheet already explains failures well while a URL is being
/// typed. These are the same class of problem discovered later -- a stream that
/// ends overnight, or a yt-dlp that gets uninstalled -- where the only place to
/// say anything is the screensaver itself.
enum StreamError {
    case ytDlpMissing
    case ytDlpUnsafe
    case extractionFailed
    case invalidConfiguredURL
    case streamUnavailable
    case noNetwork
    case retriesExhausted

    var reason: String {
        switch self {
        case .ytDlpMissing:
            return "YouTube streams need yt-dlp. Install it with: brew install yt-dlp"
        case .ytDlpUnsafe:
            return "Found yt-dlp, but other users can modify it, so it wasn't run."
        case .extractionFailed:
            return "Couldn't read the stream address for this URL."
        case .invalidConfiguredURL:
            return "That URL doesn't look like a stream. Check it in Options."
        case .streamUnavailable:
            return "The stream is offline or has ended."
        case .noNetwork:
            return "No internet connection."
        case .retriesExhausted:
            return "The stream kept dropping out. It may be having problems."
        }
    }
}

/// Manages a single AVPlayer instance shared across all screensaver views.
/// This ensures the video is streamed only once, regardless of how many monitors are connected.
private class SharedPlayerManager {
    static let shared = SharedPlayerManager()

    private(set) var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var statusObservation: NSKeyValueObservation?
    private var viewCount = 0
    private var isSettingUp = false
    private var currentSourceURL: String?
    private var retryCount = 0
    /// True between scheduling a retry and that retry resolving. Without it,
    /// `checkStall()` -- which runs on every animation frame of every view --
    /// re-enters the failure path before the previous retry has had a chance.
    private var isRetryScheduled = false
    /// Set once the retry budget is spent, so the manager stops churning.
    private(set) var hasFailedPermanently = false
    private var lastStallCheck = Date.distantPast
    /// What to report if the retries run out; set by whichever step failed.
    private var failureHint: StreamError?
    /// Non-nil once playback has given up. Views render this.
    private(set) var currentError: StreamError?

    private let defaults = ScreenSaverDefaults(forModuleWithName: ModuleName)!
    private let cacheExpirationSeconds: TimeInterval = 300
    private let extractionTimeoutSeconds: TimeInterval = 15
    private let maxRetries = 3
    private let stallTimeoutSeconds: TimeInterval = 10
    /// `checkStall()` is called at the animation frame rate by every view. The
    /// work it does only needs to happen about once a second.
    private let stallCheckInterval: TimeInterval = 1
    private var stallDetectionTime: Date?

    private static let expirationRegex = try? NSRegularExpression(
        pattern: "expire/([0-9]+)", options: [])

    /// ScreenSaverDefaults needs an explicit synchronize for writes to persist.
    /// The configuration sheet did this; the playback paths did not, so the
    /// stream start time could silently fail to be written -- taking
    /// multi-display sync and the retry reset with it.
    private func writeDefault(_ value: Any?, forKey key: String) {
        if let value = value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
    private static let preferredTimescale: CMTimeScale = 600

    private init() {}

    // MARK: - Threading contract
    //
    // Every property of this class is read and written on the main queue only.
    // The blocking work -- yt-dlp, and the cache and lock files it touches --
    // runs on background queues, but those blocks operate on locals and hop back
    // to main before touching any state here.
    //
    // registerView/unregisterView are the two entry points that can arrive from
    // elsewhere (a view's deinit is not guaranteed to be on the main thread), so
    // they bounce themselves onto it.

    func registerView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.registerView() }
            return
        }
        viewCount += 1
        Log.player.debug("View registered (\(self.viewCount) attached)")
        if viewCount == 1 && player == nil && !isSettingUp {
            setupPlayer()
        }
    }

    func unregisterView() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.unregisterView() }
            return
        }
        viewCount -= 1
        Log.player.debug("View unregistered (\(self.viewCount) attached)")
        if viewCount <= 0 {
            cleanup()
        }
    }

    private func notifyViewsPlayerReady() {
        NotificationCenter.default.post(name: .sharedPlayerReady, object: self)
    }

    /// Give up and tell the views why, so the user sees something other than a
    /// black screen.
    private func failPermanently(with error: StreamError) {
        Log.player.error("Giving up: \(error.reason, privacy: .public)")
        hasFailedPermanently = true
        isSettingUp = false
        isRetryScheduled = false
        stallDetectionTime = nil
        currentError = error
        player?.pause()
        NotificationCenter.default.post(name: .sharedPlayerFailed, object: self)
    }

    private func setupPlayer() {
        guard !isSettingUp else {
            return
        }
        isSettingUp = true
        failureHint = nil

        let originalURLString = defaults.string(forKey: URLKey) ?? DefaultURL
        Log.player.info("Setting up player for \(Log.redact(originalURLString), privacy: .public)")

        if isStreamPlaceURL(originalURLString) {
            guard let hlsURL = getStreamPlaceHLSURL(originalURLString) else {
                // Previously returned with isSettingUp still true, permanently
                // wedging the manager: no view could ever trigger setup again.
                failPermanently(with: .invalidConfiguredURL)
                return
            }
            loadVideo(url: hlsURL)
            return
        }

        var urlString = originalURLString

        if needsYtDlpExtraction(originalURLString) {
            // Retrying will not conjure up a missing binary, so say so straight
            // away rather than spending the retry budget first.
            guard let ytDlp = findYtDlpPath() else {
                if ytDlpIsInstalled() {
                    failPermanently(with: .ytDlpUnsafe)
                } else {
                    Log.extraction.error("yt-dlp not found in any known location")
                    failPermanently(with: .ytDlpMissing)
                }
                return
            }
            Log.extraction.info(
                "Using yt-dlp \(ytdlpVersion, privacy: .public) at \(ytDlp, privacy: .public)")
            currentSourceURL = originalURLString

            if let cachedURL = getCachedHLSURL(for: originalURLString) {
                Log.extraction.info("Cache hit; refreshing in the background")
                urlString = cachedURL

                DispatchQueue.global(qos: .background).async { [weak self] in
                    _ = self?.extractHLSURL(originalURLString, forceRefresh: true)
                }
            } else {
                Log.extraction.info("Cache miss; extracting synchronously")
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let extracted = self?.extractHLSURL(originalURLString)
                    DispatchQueue.main.async {
                        guard let self = self else { return }
                        // Extraction can fail because yt-dlp is missing, the
                        // lock is held, or the network is down. Previously this
                        // block simply did nothing, leaving isSettingUp true
                        // forever and the user on an endless spinner.
                        guard let extracted = extracted, let url = URL(string: extracted) else {
                            self.isSettingUp = false
                            self.failureHint = .extractionFailed
                            self.handlePlaybackFailure()
                            return
                        }
                        self.loadVideo(url: url)
                    }
                }
                return
            }
        }

        guard let url = URL(string: urlString) else {
            failPermanently(with: .invalidConfiguredURL)
            return
        }

        loadVideo(url: url)
    }

    private func loadVideo(url: URL) {
        NotificationCenter.default.removeObserver(self)
        statusObservation?.invalidate()

        playerItem = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: playerItem)

        player?.volume = 0.0
        player?.automaticallyWaitsToMinimizeStalling = false

        statusObservation = playerItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                if item.status == .readyToPlay {
                    self?.synchronizePlayback()
                    self?.stallDetectionTime = nil
                    self?.retryCount = 0
                    self?.isRetryScheduled = false
                    self?.hasFailedPermanently = false
                    self?.isSettingUp = false
                    self?.failureHint = nil
                    self?.currentError = nil
                    Log.player.info("Player ready")
                    self?.notifyViewsPlayerReady()
                } else if item.status == .failed {
                    if self?.failureHint == nil {
                        self?.failureHint =
                            (item.error as NSError?)?.code == NSURLErrorNotConnectedToInternet
                            ? .noNetwork : .streamUnavailable
                    }
                    self?.handlePlaybackFailure()
                }
            }
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemStalled),
            name: .AVPlayerItemPlaybackStalled,
            object: playerItem
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerItemFailedToPlay),
            name: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(playerDidFinishPlaying),
            name: .AVPlayerItemDidPlayToEndTime,
            object: playerItem
        )

        player?.play()
    }

    @objc private func playerItemStalled(_ notification: Notification) {
        if stallDetectionTime == nil {
            stallDetectionTime = Date()
        }
    }

    @objc private func playerItemFailedToPlay(_ notification: Notification) {
        handlePlaybackFailure()
    }

    @objc private func playerDidFinishPlaying(_ notification: Notification) {
        // Restart through the same synchronisation used on first load. A plain
        // seek to zero ignored StreamStartTime, so displays that were aligned
        // when playback started drifted apart after the first loop.
        synchronizePlayback()
    }

    private func synchronizePlayback() {
        guard let player = player, let playerItem = playerItem else { return }

        let streamStartTime: Date
        if let savedStartTime = defaults.object(forKey: StreamStartTimeKey) as? Date {
            streamStartTime = savedStartTime
        } else {
            let newStartTime = Date()
            writeDefault(newStartTime, forKey: StreamStartTimeKey)
            streamStartTime = newStartTime
        }

        let duration = playerItem.duration
        if duration.isIndefinite || duration.seconds.isNaN || duration.seconds == 0 {
            player.play()
            return
        }

        let elapsedTime = Date().timeIntervalSince(streamStartTime)
        let videoDuration = duration.seconds
        let syncedPosition = elapsedTime.truncatingRemainder(dividingBy: videoDuration)

        player.seek(
            to: CMTime(seconds: syncedPosition, preferredTimescale: Self.preferredTimescale)
        ) { [weak self] finished in
            if finished {
                self?.player?.play()
            }
        }
    }

    private func handlePlaybackFailure() {
        // Re-entry guard. This is reachable from checkStall(), which every view
        // calls on every animation frame; without it a single expired stall
        // spends the entire retry budget within a few frames and the
        // exponential backoff below never actually delays anything.
        guard !isRetryScheduled, !hasFailedPermanently else { return }

        // Clearing this is what stops the next frame seeing the same expired
        // stall and calling straight back in.
        stallDetectionTime = nil

        guard retryCount < maxRetries else {
            failPermanently(with: failureHint ?? .retriesExhausted)
            return
        }

        retryCount += 1
        isRetryScheduled = true
        Log.player.notice(
            "Playback failed; retry \(self.retryCount)/\(self.maxRetries) in \(pow(2.0, Double(self.retryCount - 1)))s"
        )

        if let sourceURL = currentSourceURL {
            let cacheFile = getCacheFilePath(for: sourceURL)
            try? FileManager.default.removeItem(atPath: cacheFile)
        }
        writeDefault(nil, forKey: StreamStartTimeKey)

        let delay = pow(2.0, Double(retryCount - 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.retryPlayback()
        }
    }

    private func retryPlayback() {
        player?.pause()
        stallDetectionTime = nil

        guard let sourceURL = currentSourceURL else {
            // A direct HLS URL needs no extraction; rebuild from defaults.
            isRetryScheduled = false
            isSettingUp = false
            setupPlayer()
            return
        }

        // extractHLSURL() runs yt-dlp with waitUntilExit(). On the main queue
        // that freezes the screensaver, and the process hosting it, for however
        // long yt-dlp takes -- typically seconds. The initial setup path already
        // dispatches this off the main queue; this one did not.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let extracted = self?.extractHLSURL(sourceURL)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isRetryScheduled = false
                guard let extracted = extracted, let url = URL(string: extracted) else {
                    self.handlePlaybackFailure()
                    return
                }
                self.loadVideo(url: url)
            }
        }
    }

    func checkStall() {
        // Called from animateOneFrame(), so this runs at the frame rate for
        // every connected display. Throttle to roughly once a second.
        let now = Date()
        guard now.timeIntervalSince(lastStallCheck) >= stallCheckInterval else { return }
        lastStallCheck = now

        // Nothing to police while setup or a retry is in flight, or once the
        // retry budget is spent.
        guard !hasFailedPermanently, !isRetryScheduled, !isSettingUp else { return }

        if let stallTime = stallDetectionTime,
            now.timeIntervalSince(stallTime) > stallTimeoutSeconds
        {
            handlePlaybackFailure()
            return
        }

        if player?.error != nil || playerItem?.error != nil {
            handlePlaybackFailure()
            return
        }

        if (player?.rate ?? 0) > 0 {
            stallDetectionTime = nil
        } else {
            if stallDetectionTime == nil {
                stallDetectionTime = now
            }
            player?.play()
        }
    }

    private func cleanup() {
        NotificationCenter.default.removeObserver(self)
        statusObservation?.invalidate()
        player?.pause()
        player = nil
        playerItem = nil
        isSettingUp = false
        retryCount = 0
        isRetryScheduled = false
        hasFailedPermanently = false
        stallDetectionTime = nil
        lastStallCheck = .distantPast
        failureHint = nil
        currentError = nil
        viewCount = 0
    }

    // MARK: - URL Extraction helpers

    private func md5Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }

    private func getCacheFilePath(for url: String) -> String {
        let hash = md5Hash(url)
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("screensaver_\(hash)")
    }

    private func extractExpirationTimestamp(from url: String) -> TimeInterval? {
        guard let regex = Self.expirationRegex,
            let match = regex.firstMatch(
                in: url, options: [], range: NSRange(url.startIndex..., in: url)),
            match.numberOfRanges > 1
        else {
            return nil
        }

        let timestampRange = match.range(at: 1)
        guard let range = Range(timestampRange, in: url) else {
            return nil
        }

        let timestampString = String(url[range])
        return TimeInterval(timestampString)
    }

    private func getCachedHLSURL(for sourceURL: String) -> String? {
        let cacheFile = getCacheFilePath(for: sourceURL)

        guard FileManager.default.fileExists(atPath: cacheFile) else {
            return nil
        }

        do {
            let cachedURL = try String(contentsOfFile: cacheFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let expirationTimestamp = extractExpirationTimestamp(from: cachedURL) {
                let currentTimestamp = Date().timeIntervalSince1970
                let timeUntilExpiration = expirationTimestamp - currentTimestamp

                if timeUntilExpiration > 0 {
                    return cachedURL
                } else {
                    try? FileManager.default.removeItem(atPath: cacheFile)
                    return nil
                }
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: cacheFile)
            guard let modificationDate = attributes[.modificationDate] as? Date else {
                return nil
            }

            let age = Date().timeIntervalSince(modificationDate)
            if age < cacheExpirationSeconds {
                return cachedURL
            } else {
                try? FileManager.default.removeItem(atPath: cacheFile)
                return nil
            }
        } catch {
            return nil
        }
    }

    private func cacheHLSURL(_ url: String, for sourceURL: String) {
        let cacheFile = getCacheFilePath(for: sourceURL)
        do {
            try url.write(toFile: cacheFile, atomically: true, encoding: .utf8)
        } catch {
            Log.extraction.error("Failed to cache extracted URL: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func getExtractionLockPath(for url: String) -> String {
        let hash = md5Hash(url)
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "screensaver_\(hash)_lock")
    }

    /// Takes the extraction lock, or reports that someone else holds it.
    ///
    /// `O_CREAT | O_EXCL` creates the file only if it does not already exist,
    /// and the kernel makes that test-and-create atomic. The previous
    /// check-then-create left a window in which two processes could both decide
    /// the lock was free and both spawn yt-dlp.
    private func acquireExtractionLock(at path: String) -> Bool {
        let descriptor = open(path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    /// Removes a lock left behind by an extraction that crashed or was killed.
    private func clearStaleExtractionLock(at path: String) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let lockTimestamp = attributes[.modificationDate] as? Date,
            Date().timeIntervalSince(lockTimestamp) >= extractionTimeoutSeconds
        else {
            return
        }
        Log.extraction.notice("Clearing stale extraction lock")
        try? FileManager.default.removeItem(atPath: path)
    }

    private func extractHLSURL(_ sourceURL: String, forceRefresh: Bool = false) -> String? {
        if !forceRefresh, let cachedURL = getCachedHLSURL(for: sourceURL) {
            return cachedURL
        }

        let lockFile = getExtractionLockPath(for: sourceURL)
        clearStaleExtractionLock(at: lockFile)

        guard acquireExtractionLock(at: lockFile) else {
            Log.extraction.debug("Extraction already in progress for this URL; skipping")
            return nil
        }
        // One release point for every exit path below, including the throwing
        // ones. The old code released it in two places and missed a third.
        defer { try? FileManager.default.removeItem(atPath: lockFile) }

        guard let executablePath = findYtDlpPath() else {
            return nil
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = ["-g", sourceURL]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        var extractedURL: String?
        let startedAt = Date()

        do {
            try task.run()

            // Process has no timeout of its own, and yt-dlp will sit there
            // indefinitely against a stalled network. extractionTimeoutSeconds
            // previously governed only how long a lock file was considered
            // fresh -- nothing bounded the process itself.
            let timeout = DispatchWorkItem {
                guard task.isRunning else { return }
                Log.extraction.error(
                    "yt-dlp exceeded \(self.extractionTimeoutSeconds, privacy: .public)s; terminating")
                task.terminate()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + extractionTimeoutSeconds, execute: timeout)

            // Close the parent's copy of the write end, then drain before
            // waiting: a child that fills the pipe buffer blocks until someone
            // reads it, so waiting first can deadlock.
            try? pipe.fileHandleForWriting.close()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            timeout.cancel()

            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
                !output.isEmpty,
                let firstURL = output.components(separatedBy: .newlines).first
            {
                cacheHLSURL(firstURL, for: sourceURL)
                extractedURL = firstURL
            }

            let elapsed = Date().timeIntervalSince(startedAt)
            if extractedURL != nil {
                Log.extraction.info(
                    "Extracted stream URL in \(String(format: "%.1f", elapsed), privacy: .public)s")
            } else {
                Log.extraction.error(
                    "yt-dlp exited \(task.terminationStatus) with no URL after \(String(format: "%.1f", elapsed), privacy: .public)s"
                )
            }
        } catch {
            Log.extraction.error("yt-dlp failed to launch: \(error.localizedDescription, privacy: .public)")
        }

        return extractedURL
    }
}

// MARK: - LiveScreensaverView

@objc(LiveScreensaverView)
class LiveScreensaverView: ScreenSaverView {

    private var playerLayer: AVPlayerLayer?
    private var spinnerLayer: CAShapeLayer?
    private var startTime = Date()

    /// Our own copy of `isPreview`, so `deinit` can consult it without touching
    /// the superclass during deallocation.
    private var isPreviewInstance = false
    /// `exit(0)` skips `deinit`, so the shared player has to be released
    /// explicitly on that path. This guards against releasing it twice.
    private var hasReleasedPlayer = false

    /// The "Unable to stream" notice, and its DVD-logo drift.
    private var noticeLayer: CATextLayer?
    private var noticeOrigin: CGPoint = .zero
    private var noticeVelocity = CGVector(dx: 48, dy: 33)
    private var lastNoticeTick: Date?
    /// Bounds the notice was laid out against, so a resolution change can
    /// trigger a re-wrap rather than leaving it mis-sized or off-screen.
    private var noticeLayoutBounds: CGRect = .zero
    private var displayedError: StreamError?

    private func getSystemIdleTime() -> TimeInterval {
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .mouseMoved)
    }

    private func isScreenLocked() -> Bool {
        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }

        if let isLocked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return isLocked
        }

        return false
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        setupScreensaver()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupScreensaver()
    }

    private func showSpinner() {
        let size: CGFloat = 32
        let lineWidth: CGFloat = 3

        let spinner = CAShapeLayer()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = (size - lineWidth) / 2

        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: size/2, y: size/2), radius: radius,
                    startAngle: 0, endAngle: .pi * 1.5, clockwise: false)

        spinner.path = path
        spinner.fillColor = nil
        spinner.strokeColor = CGColor(gray: 1.0, alpha: 0.8)
        spinner.lineWidth = lineWidth
        spinner.lineCap = .round
        spinner.frame = CGRect(x: center.x - size/2, y: center.y - size/2, width: size, height: size)

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 1.0
        rotation.repeatCount = .infinity
        spinner.add(rotation, forKey: "spin")

        wantsLayer = true
        layer?.addSublayer(spinner)
        spinnerLayer = spinner
    }

    private func hideSpinner() {
        spinnerLayer?.removeAllAnimations()
        spinnerLayer?.removeFromSuperlayer()
        spinnerLayer = nil
    }

    private func setupScreensaver() {
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        isPreviewInstance = isPreview

        // System Settings instantiates this same class for the small preview
        // thumbnail. That instance must not open a stream -- a second download
        // for a thumbnail nobody is watching -- and must never reach the
        // idle-exit path in animateOneFrame(), which would terminate the process
        // hosting System Settings itself.
        guard !isPreviewInstance else {
            needsDisplay = true
            return
        }

        showSpinner()

        // Listen for player ready notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onSharedPlayerReady),
            name: .sharedPlayerReady,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onSharedPlayerFailed),
            name: .sharedPlayerFailed,
            object: nil
        )

        // Register with the shared player manager
        let manager = SharedPlayerManager.shared
        manager.registerView()

        // If player is already ready (another view already set it up), attach immediately
        if manager.player != nil {
            attachPlayerLayer()
        } else if let error = manager.currentError {
            // A second display attached after playback had already given up.
            showErrorNotice(error)
        }
    }

    /// Called by SharedPlayerManager when the player becomes ready
    @objc private func onSharedPlayerReady() {
        hideErrorNotice()
        attachPlayerLayer()
    }

    /// Called by SharedPlayerManager when playback has given up.
    @objc private func onSharedPlayerFailed() {
        guard let error = SharedPlayerManager.shared.currentError else { return }
        showErrorNotice(error)
    }

    // MARK: - Error notice

    /// Builds the notice: "Unable to stream" in bold, the reason underneath in
    /// regular weight, wrapped so the block sits close to 16:9.
    private func noticeText(for error: StreamError) -> NSAttributedString {
        let titleSize = max(16, bounds.height / 26)
        let bodySize = titleSize * 0.62

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let text = NSMutableAttributedString(
            string: "Unable to stream\n",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: titleSize),
                .foregroundColor: NSColor.white,
                .paragraphStyle: paragraph,
            ]
        )
        text.append(
            NSAttributedString(
                string: error.reason,
                attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                    .paragraphStyle: paragraph,
                ]
            )
        )
        return text
    }

    /// Finds the wrap width whose resulting text block is closest to 16:9.
    ///
    /// Height falls as width grows (the same words wrap into fewer lines), so
    /// the height-to-width ratio decreases monotonically and can be searched.
    private func noticeSize(for text: NSAttributedString) -> CGSize {
        func height(atWidth width: CGFloat) -> CGFloat {
            ceil(
                text.boundingRect(
                    with: CGSize(width: width, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                ).height)
        }

        var narrow = max(160, bounds.width * 0.15)
        var wide = max(narrow + 1, bounds.width * 0.6)
        let target: CGFloat = 9.0 / 16.0

        for _ in 0..<14 {
            let mid = (narrow + wide) / 2
            if height(atWidth: mid) / mid > target {
                narrow = mid
            } else {
                wide = mid
            }
        }
        return CGSize(width: ceil(wide), height: height(atWidth: wide))
    }

    private func showErrorNotice(_ error: StreamError) {
        guard !isPreviewInstance, bounds.width > 0, bounds.height > 0 else { return }

        hideSpinner()
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        noticeLayer?.removeFromSuperlayer()

        let text = noticeText(for: error)
        let size = noticeSize(for: text)

        let notice = CATextLayer()
        notice.string = text
        notice.isWrapped = true
        notice.alignmentMode = .center
        notice.contentsScale = window?.backingScaleFactor ?? 2
        notice.bounds = CGRect(origin: .zero, size: size)
        notice.anchorPoint = .zero

        // Start somewhere off-centre so multiple displays are not in lockstep.
        noticeOrigin = CGPoint(
            x: (bounds.width - size.width) * CGFloat.random(in: 0.15...0.85),
            y: (bounds.height - size.height) * CGFloat.random(in: 0.15...0.85)
        )
        notice.position = noticeOrigin
        lastNoticeTick = nil

        wantsLayer = true
        layer?.addSublayer(notice)
        noticeLayer = notice
        noticeLayoutBounds = bounds
        displayedError = error
    }

    private func hideErrorNotice() {
        noticeLayer?.removeFromSuperlayer()
        noticeLayer = nil
        lastNoticeTick = nil
        displayedError = nil
        noticeLayoutBounds = .zero
    }

    /// Drifts the notice across the screen, reflecting off the edges. Keeps the
    /// text moving so it cannot burn in, and makes it obvious the machine is
    /// alive rather than hung.
    private func advanceErrorNotice() {
        guard let notice = noticeLayer else { return }

        // Display reconfigured (resolution change, or the saver moved between
        // screens): re-wrap against the new bounds.
        if bounds != noticeLayoutBounds, let error = displayedError {
            showErrorNotice(error)
            return
        }

        let now = Date()
        defer { lastNoticeTick = now }
        guard let last = lastNoticeTick else { return }
        // Cap the step so a stalled frame cannot teleport the notice.
        let elapsed = min(now.timeIntervalSince(last), 0.1)
        guard elapsed > 0 else { return }

        let size = notice.bounds.size
        let maxX = max(0, bounds.width - size.width)
        let maxY = max(0, bounds.height - size.height)

        noticeOrigin.x += noticeVelocity.dx * elapsed
        noticeOrigin.y += noticeVelocity.dy * elapsed

        if noticeOrigin.x <= 0 {
            noticeOrigin.x = 0
            noticeVelocity.dx = abs(noticeVelocity.dx)
        } else if noticeOrigin.x >= maxX {
            noticeOrigin.x = maxX
            noticeVelocity.dx = -abs(noticeVelocity.dx)
        }

        if noticeOrigin.y <= 0 {
            noticeOrigin.y = 0
            noticeVelocity.dy = abs(noticeVelocity.dy)
        } else if noticeOrigin.y >= maxY {
            noticeOrigin.y = maxY
            noticeVelocity.dy = -abs(noticeVelocity.dy)
        }

        // Implicit layer animations would smear a per-frame move; the drift is
        // already continuous.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        notice.position = noticeOrigin
        CATransaction.commit()
    }

    private func attachPlayerLayer() {
        guard let player = SharedPlayerManager.shared.player else {
            return
        }

        // Remove old layer if exists
        playerLayer?.removeFromSuperlayer()

        hideSpinner()

        playerLayer = AVPlayerLayer(player: player)
        playerLayer?.frame = bounds
        playerLayer?.videoGravity = .resizeAspectFill

        if let pLayer = playerLayer, let selfLayer = self.layer {
            selfLayer.addSublayer(pLayer)
        }
    }

    override func draw(_ rect: NSRect) {
        NSColor.black.setFill()
        rect.fill()

        if isPreviewInstance {
            drawPreviewPlaceholder()
        }
    }

    /// A static stand-in for the System Settings preview: no network, no
    /// animation, just enough to show which stream is configured.
    private func drawPreviewPlaceholder() {
        let configured =
            ScreenSaverDefaults(forModuleWithName: ModuleName)?.string(forKey: URLKey) ?? DefaultURL
        let label = URL(string: configured)?.host ?? "Live Screensaver"

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(8, bounds.height / 12)),
            .foregroundColor: NSColor.white.withAlphaComponent(0.6),
        ]
        let attributed = NSAttributedString(string: label, attributes: attributes)
        let size = attributed.size()
        attributed.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func animateOneFrame() {
        // The preview has no player, no stream and no business quitting anything.
        guard !isPreviewInstance else { return }

        if Date().timeIntervalSince(startTime) > 2.0 {
            let idleTime = getSystemIdleTime()
            let screenLocked = isScreenLocked()
            if idleTime < 1.0 && !screenLocked {
                stopOnUserActivity()
            }
        }

        playerLayer?.frame = bounds
        advanceErrorNotice()

        // Let the shared manager handle stall detection and recovery
        SharedPlayerManager.shared.checkStall()
    }

    /// Ends the screensaver when the user comes back.
    ///
    /// `exit(0)` terminates the host process rather than just this view, and
    /// skips `deinit` on the way out, so the shared player is released
    /// explicitly first. Reached only on a real screensaver instance -- never in
    /// preview, where it would take System Settings down with it.
    private func stopOnUserActivity() {
        stopAnimation()
        releasePlayer()
        exit(0)
    }

    private func releasePlayer() {
        guard !isPreviewInstance, !hasReleasedPlayer else { return }
        hasReleasedPlayer = true
        SharedPlayerManager.shared.unregisterView()
    }

    private var configController: ConfigureWindowController?

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        configController = ConfigureWindowController()
        return configController?.window
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        playerLayer?.removeFromSuperlayer()
        releasePlayer()
    }
}

class ConfigureWindowController: NSWindowController, NSTextFieldDelegate {

    private enum ValidationState {
        case idle
        case validating
        case valid
        case invalid(String)
    }

    private let defaults = ScreenSaverDefaults(forModuleWithName: ModuleName)!
    private var urlTextField: NSTextField!
    private var okButton: NSButton!
    private var cancelButton: NSButton!
    private var statusLabel: NSTextField!  // Shows either error (red) or help text (grey)
    private var spinner: NSProgressIndicator!
    private var trackingArea: NSTrackingArea?
    private let helpText = "Supports stream.place, YouTube (via yt-dlp), or direct HLS streams"

    private var validationState: ValidationState = .idle
    private var validationTimer: Timer?
    private var validationTask: URLSessionDataTask?
    private var ytdlpProcess: Process?
    private var lastValidatedURL: String?
    private let debounceInterval: TimeInterval = 0.2
    private static let ytDlpValidationTimeout: TimeInterval = 20

    override init(window: NSWindow?) {
        let configWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 170),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        configWindow.title = "Live Screensaver Configuration"
        configWindow.center()

        super.init(window: configWindow)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let label = NSTextField(labelWithString: "Video URL:")
        label.frame = NSRect(x: 20, y: 110, width: 440, height: 20)
        contentView.addSubview(label)

        urlTextField = NSTextField()
        urlTextField.frame = NSRect(x: 20, y: 80, width: 440, height: 24)
        urlTextField.placeholderString = "Enter YouTube, stream.place, or HLS stream URL"
        urlTextField.stringValue = defaults.string(forKey: URLKey) ?? DefaultURL
        contentView.addSubview(urlTextField)

        // Spinner inside text input on the right (x: 20 + 440 - 16 - 6 padding = 438)
        spinner = NSProgressIndicator(frame: NSRect(x: 438, y: 84, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        contentView.addSubview(spinner)

        // Combined status label - shows help text (grey) or error (red)
        statusLabel = NSTextField(labelWithString: helpText)
        statusLabel.frame = NSRect(x: 20, y: 55, width: 440, height: 20)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        contentView.addSubview(statusLabel)

        cancelButton = NSButton(frame: NSRect(x: 270, y: 10, width: 90, height: 28))
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        contentView.addSubview(cancelButton)

        okButton = NSButton(frame: NSRect(x: 370, y: 10, width: 90, height: 28))
        okButton.title = "OK"
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.target = self
        okButton.action = #selector(okClicked)
        okButton.isEnabled = false
        contentView.addSubview(okButton)

        // Add tracking area for mouse hover on OK button
        setupOkButtonTracking()

        urlTextField.delegate = self
        window?.makeFirstResponder(urlTextField)

        // Assume existing URL is valid - no need to revalidate on open
        validationState = .valid
        okButton.isEnabled = true
    }

    private func setupOkButtonTracking() {
        guard let contentView = window?.contentView else { return }

        // Create a custom view to track mouse entering the OK button area
        let trackingView = OkButtonTrackingView(frame: okButton.frame)
        trackingView.onMouseEntered = { [weak self] in
            self?.onOkButtonHover()
        }
        contentView.addSubview(trackingView, positioned: .above, relativeTo: okButton)
    }

    private func onOkButtonHover() {
        // If we have a pending timer and haven't validated yet, validate immediately
        if validationTimer != nil {
            validationTimer?.invalidate()
            validationTimer = nil
            performValidation()
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        let urlString = urlTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Cancel any pending validation
        cancelPendingValidation()

        // Empty field is always valid (uses default)
        if urlString.isEmpty {
            validationState = .valid
            updateUI()
            return
        }

        // Immediately disable OK and reset to help text while typing
        okButton.isEnabled = false
        statusLabel.stringValue = helpText
        statusLabel.textColor = .secondaryLabelColor

        // Schedule validation after debounce interval
        scheduleValidation()
    }

    private func scheduleValidation() {
        validationTimer?.invalidate()
        validationTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false) {
            [weak self] _ in
            self?.performValidation()
        }
    }

    private func cancelPendingValidation() {
        validationTimer?.invalidate()
        validationTimer = nil
        validationTask?.cancel()
        validationTask = nil
        ytdlpProcess?.terminate()
        ytdlpProcess = nil
        spinner?.stopAnimation(nil)
    }

    private func performValidation() {
        guard urlTextField != nil, statusLabel != nil, okButton != nil else { return }

        let urlString = urlTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty field is valid
        if urlString.isEmpty {
            validationState = .valid
            updateUI()
            return
        }

        // Skip if already validated this exact URL
        if urlString == lastValidatedURL, case .valid = validationState {
            return
        }

        // Basic URL format check
        guard let url = URL(string: urlString) else {
            validationState = .invalid("Invalid URL format. Please check for typos.")
            updateUI()
            return
        }

        // http:// was previously accepted here and then blocked at playback time
        // by App Transport Security -- validation showed a green tick for a URL
        // that could never play. Rejecting it up front is the honest answer.
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            if url.scheme?.lowercased() == "http" {
                validationState = .invalid(
                    "macOS blocks plain http:// streams. Use an https:// URL.")
            } else {
                validationState = .invalid("URL must start with https://")
            }
            updateUI()
            return
        }

        guard let host = url.host, !host.isEmpty else {
            validationState = .invalid("URL must include a domain (e.g., youtube.com)")
            updateUI()
            return
        }

        // Start async validation
        validationState = .validating
        updateUI()

        if isStreamPlaceURL(urlString) {
            validateStreamPlaceURL(urlString)
        } else if !needsYtDlpExtraction(urlString) {
            // Direct HLS URL
            validateHLSURL(urlString)
        } else {
            // Needs yt-dlp extraction
            validateWithYtDlp(urlString)
        }
    }

    private func validateStreamPlaceURL(_ urlString: String) {
        guard let hlsURL = getStreamPlaceHLSURL(urlString) else {
            validationState = .invalid("Invalid stream.place URL. Use format: stream.place/username")
            updateUI()
            return
        }
        validateHLSURL(hlsURL.absoluteString)
    }

    private func validateHLSURL(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            validationState = .invalid("Invalid stream URL")
            updateUI()
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        // Only fetch first 512 bytes to verify accessibility without downloading entire manifest
        request.setValue("bytes=0-511", forHTTPHeaderField: "Range")

        validationTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self = self else { return }

                if let error = error as NSError? {
                    if error.code == NSURLErrorCancelled { return }
                    if error.code == NSURLErrorTimedOut {
                        self.validationState = .invalid("Connection timed out. Check your internet or try another URL.")
                    } else if error.code == NSURLErrorCannotFindHost {
                        self.validationState = .invalid("Server not found. Check the URL and try again.")
                    } else if error.code == NSURLErrorNotConnectedToInternet {
                        self.validationState = .invalid("No internet connection. Please check your network.")
                    } else {
                        self.validationState = .invalid("Connection failed: \(error.localizedDescription)")
                    }
                    self.updateUI()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self.validationState = .invalid("Invalid server response. This may not be a valid stream.")
                    self.updateUI()
                    return
                }

                switch httpResponse.statusCode {
                case 200...299:
                    // A 2xx alone is not enough: a captive portal or a site's
                    // custom 404 page answers 200 with HTML. Every HLS playlist
                    // starts with #EXTM3U, and the ranged request above asks for
                    // exactly the bytes that would contain it.
                    let head = String(decoding: data ?? Data(), as: UTF8.self)
                    guard head.contains("#EXTM3U") else {
                        self.validationState = .invalid(
                            "That URL responded, but not with a video stream. Check the link.")
                        self.updateUI()
                        return
                    }
                    self.lastValidatedURL = self.urlTextField.stringValue.trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    self.validationState = .valid
                case 401, 403:
                    self.validationState = .invalid(
                        "Access denied (HTTP \(httpResponse.statusCode)). This stream may require authentication.")
                case 404:
                    self.validationState = .invalid(
                        "Stream not found (HTTP 404). Check the URL or try another stream.")
                case 500...599:
                    self.validationState = .invalid(
                        "Server error (HTTP \(httpResponse.statusCode)). The stream service may be down.")
                default:
                    self.validationState = .invalid(
                        "Unexpected response (HTTP \(httpResponse.statusCode)). Try another URL.")
                }
                self.updateUI()
            }
        }
        validationTask?.resume()
    }

    private func validateWithYtDlp(_ urlString: String) {
        guard let executablePath = findYtDlpPath() else {
            validationState = .invalid(
                ytDlpIsInstalled()
                    ? StreamError.ytDlpUnsafe.reason
                    : "yt-dlp is required for this URL. Install with: brew install yt-dlp")
            updateUI()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["-g", "--no-warnings", urlString]

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            DispatchQueue.main.async {
                self?.ytdlpProcess = process
            }

            do {
                try process.run()

                // Without this a hung yt-dlp leaves the sheet spinning forever
                // with OK disabled and no way to tell what went wrong.
                let timeout = DispatchWorkItem {
                    guard process.isRunning else { return }
                    Log.config.error("yt-dlp validation timed out; terminating")
                    process.terminate()
                }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + Self.ytDlpValidationTimeout, execute: timeout)

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                let output = String(data: outputData, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines) ?? ""
                let errorOutput = String(data: errorData, encoding: .utf8)?.trimmingCharacters(
                    in: .whitespacesAndNewlines) ?? ""

                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.ytdlpProcess = nil

                    if process.terminationStatus == 0, !output.isEmpty {
                        // Successfully extracted URL, now validate it
                        if let firstURL = output.components(separatedBy: .newlines).first,
                            !firstURL.isEmpty
                        {
                            self.validateHLSURL(firstURL)
                        } else {
                            self.validationState = .invalid("Could not extract stream URL")
                            self.updateUI()
                        }
                    } else {
                        // Parse common yt-dlp errors
                        if errorOutput.contains("Video unavailable")
                            || errorOutput.contains("Private video")
                        {
                            self.validationState = .invalid(
                                "Video is unavailable or private. Try another URL.")
                        } else if errorOutput.contains("Sign in") {
                            self.validationState = .invalid(
                                "This video requires sign-in. Try another URL.")
                        } else if errorOutput.contains("not a valid URL")
                            || errorOutput.contains("Unsupported URL")
                        {
                            self.validationState = .invalid(
                                "URL not supported. Try a YouTube or other supported video URL.")
                        } else if errorOutput.contains("HTTP Error 404") {
                            self.validationState = .invalid(
                                "Video not found (404). Check the URL and try again.")
                        } else if errorOutput.contains("Live event will begin") {
                            self.validationState = .invalid(
                                "This is a scheduled live event that hasn't started yet.")
                        } else if errorOutput.contains("is offline") {
                            self.validationState = .invalid(
                                "This stream is currently offline. Try again later or use another URL."
                            )
                        } else if process.terminationReason == .uncaughtSignal {
                            self.validationState = .invalid(
                                "Timed out reading this URL. The site may be slow or blocking us.")
                        } else {
                            self.validationState = .invalid(
                                "Could not load video. Check the URL or try another.")
                        }
                        self.updateUI()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.ytdlpProcess = nil
                    self.validationState = .invalid("Failed to run yt-dlp: \(error.localizedDescription)")
                    self.updateUI()
                }
            }
        }
    }

    private func updateUI() {
        guard urlTextField != nil, statusLabel != nil, okButton != nil, spinner != nil else { return }

        switch validationState {
        case .idle:
            okButton.isEnabled = false
            statusLabel.stringValue = helpText
            statusLabel.textColor = .secondaryLabelColor
            spinner.stopAnimation(nil)

        case .validating:
            okButton.isEnabled = false
            statusLabel.stringValue = helpText
            statusLabel.textColor = .secondaryLabelColor
            spinner.startAnimation(nil)

        case .valid:
            okButton.isEnabled = true
            statusLabel.stringValue = helpText
            statusLabel.textColor = .secondaryLabelColor
            spinner.stopAnimation(nil)

        case .invalid(let message):
            okButton.isEnabled = false
            statusLabel.stringValue = message
            statusLabel.textColor = .systemRed
            spinner.stopAnimation(nil)
        }
    }

    @objc private func okClicked() {
        var urlString = urlTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if urlString.isEmpty {
            urlString = DefaultURL
        }

        Log.config.info("Saved stream URL \(Log.redact(urlString), privacy: .public)")
        defaults.set(urlString, forKey: URLKey)
        defaults.removeObject(forKey: StreamStartTimeKey)  // Reset sync time for new stream
        defaults.synchronize()
        closeWindow()
    }

    @objc private func cancelClicked() {
        cancelPendingValidation()
        closeWindow()
    }

    private func closeWindow() {
        if let window = window, let sheetParent = window.sheetParent {
            sheetParent.endSheet(window)
        }
        window?.orderOut(self)
    }

    deinit {
        cancelPendingValidation()
    }
}

// Custom view to detect mouse hover over OK button area
private class OkButtonTrackingView: NSView {
    var onMouseEntered: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseEntered(with event: NSEvent) {
        onMouseEntered?()
    }

    // Pass through all clicks to the button underneath
    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}

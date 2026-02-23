import AVFoundation
import Cocoa
import CryptoKit
import Quartz
import ScreenSaver

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

private func findYtDlpPath() -> String? {
    return ytdlpPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
}

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

    private let defaults = ScreenSaverDefaults(forModuleWithName: ModuleName)!
    private let cacheExpirationSeconds: TimeInterval = 300
    private let extractionTimeoutSeconds: TimeInterval = 15
    private let maxRetries = 3
    private let stallTimeoutSeconds: TimeInterval = 10
    private var stallDetectionTime: Date?

    private static let expirationRegex = try? NSRegularExpression(
        pattern: "expire/([0-9]+)", options: [])
    private static let preferredTimescale: CMTimeScale = 600

    private init() {}

    func registerView() {
        viewCount += 1
        if viewCount == 1 && player == nil && !isSettingUp {
            setupPlayer()
        }
    }

    func unregisterView() {
        viewCount -= 1
        if viewCount <= 0 {
            cleanup()
        }
    }

    private func notifyViewsPlayerReady() {
        NotificationCenter.default.post(name: .sharedPlayerReady, object: self)
    }

    private func setupPlayer() {
        guard !isSettingUp else {
            return
        }
        isSettingUp = true

        let originalURLString = defaults.string(forKey: URLKey) ?? DefaultURL

        if isStreamPlaceURL(originalURLString) {
            if let hlsURL = getStreamPlaceHLSURL(originalURLString) {
                loadVideo(url: hlsURL)
            }
            return
        }

        var urlString = originalURLString

        if needsYtDlpExtraction(originalURLString) {
            currentSourceURL = originalURLString

            if let cachedURL = getCachedHLSURL(for: originalURLString) {
                urlString = cachedURL

                DispatchQueue.global(qos: .background).async { [weak self] in
                    _ = self?.extractHLSURL(originalURLString, forceRefresh: true)
                }
            } else {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    if let hlsURL = self?.extractHLSURL(originalURLString) {
                        DispatchQueue.main.async {
                            if let url = URL(string: hlsURL) {
                                self?.loadVideo(url: url)
                            }
                        }
                    }
                }
                return
            }
        }

        guard let url = URL(string: urlString) else {
            isSettingUp = false
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
                    self?.isSettingUp = false
                    self?.notifyViewsPlayerReady()
                } else if item.status == .failed {
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
        player?.seek(to: .zero)
        player?.play()
    }

    private func synchronizePlayback() {
        guard let player = player, let playerItem = playerItem else { return }

        let streamStartTime: Date
        if let savedStartTime = defaults.object(forKey: StreamStartTimeKey) as? Date {
            streamStartTime = savedStartTime
        } else {
            let newStartTime = Date()
            defaults.set(newStartTime, forKey: StreamStartTimeKey)
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
        guard retryCount < maxRetries else {
            isSettingUp = false
            return
        }

        retryCount += 1

        if let sourceURL = currentSourceURL {
            let cacheFile = getCacheFilePath(for: sourceURL)
            try? FileManager.default.removeItem(atPath: cacheFile)
        }
        defaults.removeObject(forKey: StreamStartTimeKey)

        let delay = pow(2.0, Double(retryCount - 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.retryPlayback()
        }
    }

    private func retryPlayback() {
        player?.pause()
        stallDetectionTime = nil

        if let sourceURL = currentSourceURL {
            if let hlsURL = extractHLSURL(sourceURL), let url = URL(string: hlsURL) {
                loadVideo(url: url)
            } else {
                handlePlaybackFailure()
            }
        } else {
            isSettingUp = false
            setupPlayer()
        }
    }

    func checkStall() {
        if let stallTime = stallDetectionTime {
            let stallDuration = Date().timeIntervalSince(stallTime)
            if stallDuration > stallTimeoutSeconds {
                handlePlaybackFailure()
                return
            }
        }

        let isPlaying = player?.rate ?? 0 > 0
        let hasError = player?.error != nil || playerItem?.error != nil

        if hasError {
            handlePlaybackFailure()
            return
        }

        if !isPlaying {
            if stallDetectionTime == nil {
                stallDetectionTime = Date()
            }
            player?.play()
        } else {
            stallDetectionTime = nil
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
            NSLog("Failed to cache HLS URL: \(error)")
        }
    }

    private func getExtractionLockPath(for url: String) -> String {
        let hash = md5Hash(url)
        return (NSTemporaryDirectory() as NSString).appendingPathComponent(
            "screensaver_\(hash)_lock")
    }

    private func extractHLSURL(_ sourceURL: String, forceRefresh: Bool = false) -> String? {
        if !forceRefresh, let cachedURL = getCachedHLSURL(for: sourceURL) {
            return cachedURL
        }

        let lockFile = getExtractionLockPath(for: sourceURL)

        if FileManager.default.fileExists(atPath: lockFile) {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: lockFile)
                if let lockTimestamp = attributes[.modificationDate] as? Date {
                    let lockAge = Date().timeIntervalSince(lockTimestamp)

                    if lockAge < extractionTimeoutSeconds {
                        return nil
                    } else {
                        try? FileManager.default.removeItem(atPath: lockFile)
                    }
                }
            } catch {
                NSLog("Failed to check lock file attributes: \(error)")
            }
        }

        do {
            try "".write(toFile: lockFile, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Failed to create lock file: \(error)")
        }

        let task = Process()

        guard let executablePath = findYtDlpPath() else {
            try? FileManager.default.removeItem(atPath: lockFile)
            return nil
        }

        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = ["-g", sourceURL]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        var extractedURL: String?

        do {
            try task.run()
            task.waitUntilExit()

            try? pipe.fileHandleForWriting.close()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()

            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines),
                !output.isEmpty,
                let firstURL = output.components(separatedBy: .newlines).first
            {
                cacheHLSURL(firstURL, for: sourceURL)
                extractedURL = firstURL
            }
        } catch {
            NSLog("Failed to execute yt-dlp: \(error)")
        }

        try? FileManager.default.removeItem(atPath: lockFile)

        return extractedURL
    }
}

// MARK: - LiveScreensaverView

@objc(LiveScreensaverView)
class LiveScreensaverView: ScreenSaverView {

    private var playerLayer: AVPlayerLayer?
    private var spinnerLayer: CAShapeLayer?
    private var startTime = Date()

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
        showSpinner()

        // Listen for player ready notification
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onSharedPlayerReady),
            name: .sharedPlayerReady,
            object: nil
        )

        // Register with the shared player manager
        let manager = SharedPlayerManager.shared
        manager.registerView()

        // If player is already ready (another view already set it up), attach immediately
        if manager.player != nil {
            attachPlayerLayer()
        }
    }

    /// Called by SharedPlayerManager when the player becomes ready
    @objc private func onSharedPlayerReady() {
        attachPlayerLayer()
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
    }

    override func animateOneFrame() {
        if Date().timeIntervalSince(startTime) > 2.0 {
            let idleTime = getSystemIdleTime()
            let screenLocked = isScreenLocked()
            if idleTime < 1.0 && !screenLocked {
                exit(0)
            }
        }

        playerLayer?.frame = bounds

        // Let the shared manager handle stall detection and recovery
        SharedPlayerManager.shared.checkStall()
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
        SharedPlayerManager.shared.unregisterView()
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

        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            validationState = .invalid("URL must start with http:// or https://")
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

        validationTask = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
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
            validationState = .invalid("yt-dlp is required for this URL. Install with: brew install yt-dlp")
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
                process.waitUntilExit()

                let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
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

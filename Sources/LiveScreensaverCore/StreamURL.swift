import Foundation

// MARK: - Stream URL classification

func needsYtDlpExtraction(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString),
        let path = url.path.split(separator: "/").last
    else {
        return true
    }
    return !path.contains(".m3u8")
}

func isStreamPlaceURL(_ urlString: String) -> Bool {
    guard let url = URL(string: urlString),
        let host = url.host?.lowercased()
    else {
        return false
    }
    return host == "stream.place" || host.hasSuffix(".stream.place")
}

func getStreamPlaceHLSURL(_ urlString: String) -> URL? {
    guard let url = URL(string: urlString),
        let host = url.host
    else {
        return nil
    }

    // Splitting on "/" drops empty segments, so trailing slashes and doubled
    // separators need no special handling. The previous string-prefix approach
    // turned the bare URL ".../embed/" into a request for a user called
    // "embed", because after trimming slashes there was no "embed/" left to
    // match on.
    var segments = url.path.split(separator: "/").map(String.init)
    if segments.first == "embed" {
        segments.removeFirst()
    }
    guard let username = segments.first, !username.isEmpty else {
        return nil
    }

    return URL(string: "https://\(host)/api/playback/\(username)/hls/index.m3u8")
}

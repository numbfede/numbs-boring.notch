//
//  LyricsService.swift
//  boringNotch
//
//  Extracted from MusicManager for better separation of concerns.
//

import AppKit
import Foundation

/// Service responsible for fetching and parsing lyrics for the currently playing track.
@MainActor
final class LyricsService: ObservableObject {
    static let shared = LyricsService()

    @Published var currentLyrics: String = ""
    @Published var isFetchingLyrics: Bool = false
    @Published var syncedLyrics: [(time: Double, text: String)] = []

    // Cache to avoid redundant fetches; NSCache evicts under memory pressure
    // instead of growing for the whole session.
    private final class LyricsEntry {
        let plain: String
        let synced: [(time: Double, text: String)]
        init(plain: String, synced: [(time: Double, text: String)]) {
            self.plain = plain
            self.synced = synced
        }
    }
    private let lyricsCache = NSCache<NSString, LyricsEntry>()
    private var currentFetchTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

    /// Fetches lyrics for the given track, preferring native Apple Music lyrics when available.
    func fetchLyrics(bundleIdentifier: String?, title: String, artist: String, duration: Double? = nil) async {
        // Cancel any pending fetch
        currentFetchTask?.cancel()

        guard !title.isEmpty else {
            clearLyrics()
            return
        }

        // Check cache first
        let cacheKey = cacheKey(title: title, artist: artist)
        if let cached = lyricsCache.object(forKey: cacheKey as NSString) {
            currentLyrics = cached.plain
            syncedLyrics = cached.synced
            isFetchingLyrics = false
            return
        }

        isFetchingLyrics = true
        currentLyrics = ""
        syncedLyrics = []

        let task = Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Web results can be time-synced, so they win over Apple Music's
            // plain-text lyrics whenever a synced match exists.
            let webResult = await self.fetchLyricsFromWeb(title: title, artist: artist, duration: duration)
            guard !Task.isCancelled else { return }

            var plain = webResult.plain
            if webResult.synced.isEmpty,
               let bundleIdentifier, bundleIdentifier.contains(MediaAppBundleID.appleMusic),
               let nativeLyrics = await self.fetchAppleMusicLyrics() {
                guard !Task.isCancelled else { return }
                plain = nativeLyrics
            }

            self.currentLyrics = plain
            self.syncedLyrics = webResult.synced
            self.isFetchingLyrics = false
            if !plain.isEmpty {
                self.lyricsCache.setObject(LyricsEntry(plain: plain, synced: webResult.synced), forKey: cacheKey as NSString)
            }
        }

        currentFetchTask = task
        await task.value
    }

    /// Clears all lyrics data.
    func clearLyrics() {
        currentFetchTask?.cancel()
        currentFetchTask = nil
        currentLyrics = ""
        syncedLyrics = []
        isFetchingLyrics = false
    }

    /// Returns the lyric line at the given elapsed time for synced lyrics.
    func lyricLine(at elapsed: Double) -> String {
        lyricLineContext(at: elapsed).text
    }

    /// Returns the active synced lyric line and its timing window.
    func lyricLineContext(at elapsed: Double) -> (text: String, startTime: Double, endTime: Double?) {
        guard !syncedLyrics.isEmpty else { return (currentLyrics, 0, nil) }

        // Nothing to show until the first line starts.
        guard elapsed >= syncedLyrics[0].time else { return ("", -1, syncedLyrics[0].time) }

        // Binary search for last line with time <= elapsed
        var low = 0
        var high = syncedLyrics.count - 1
        var idx = 0
        while low <= high {
            let mid = (low + high) / 2
            if syncedLyrics[mid].time <= elapsed {
                idx = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        let nextIndex = syncedLyrics.index(after: idx)
        let endTime = nextIndex < syncedLyrics.endIndex ? syncedLyrics[nextIndex].time : nil
        return (syncedLyrics[idx].text, syncedLyrics[idx].time, endTime)
    }

    // MARK: - Private Methods

    private func cacheKey(title: String, artist: String) -> String {
        "\(LyricsMatching.cleaned(title))|\(LyricsMatching.cleaned(artist))"
    }

    private func fetchAppleMusicLyrics() async -> String? {
        let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: MediaAppBundleID.appleMusic)
        guard !runningApps.isEmpty else { return nil }

        let script = """
        tell application "Music"
            if it is running then
                if player state is playing or player state is paused then
                    try
                        set l to lyrics of current track
                        if l is missing value then
                            return ""
                        else
                            return l
                        end if
                    on error
                        return ""
                    end try
                else
                    return ""
                end if
            else
                return ""
            end if
        end tell
        """

        do {
            if let result = try await AppleScriptHelper.execute(script),
               let lyricsString = result.stringValue,
               !lyricsString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return lyricsString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // Fall through to return nil
        }
        return nil
    }

    private func fetchLyricsFromWeb(
        title: String,
        artist: String,
        duration: Double?
    ) async -> (plain: String, synced: [(time: Double, text: String)]) {
        let queries = LyricsMatching.searchQueries(title: title, artist: artist)

        for query in queries {
            guard let url = LyricsMatching.searchURL(for: query) else { continue }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 10
                request.setValue(
                    "Numbs-boring.notch (https://github.com/numbfede/numbs-boring.notch)",
                    forHTTPHeaderField: "User-Agent"
                )

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continue
                }

                guard let results = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                      let match = LyricsMatching.bestMatch(in: results, title: title, artist: artist, duration: duration)
                else { continue }

                let syncedText = (match["syncedLyrics"] as? String) ?? ""
                let plainText = ((match["plainLyrics"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                // Timings from a recording of a different length would drift.
                let synced = LyricsMatching.isDurationCompatible(match, duration: duration) ? LRCParser.parse(syncedText) : []
                let resolvedPlain = plainText.isEmpty
                    ? LRCParser.parse(syncedText).map { $0.text }.filter { !$0.isEmpty }.joined(separator: "\n")
                    : plainText

                if !resolvedPlain.isEmpty {
                    return (resolvedPlain, synced)
                }
            } catch {
                if Task.isCancelled { return ("", []) }
                continue
            }
        }

        return ("", [])
    }

}

/// Parses LRC text, including repeated timestamps, offsets and timed gaps.
enum LRCParser {
    private static let timestamp = try? NSRegularExpression(pattern: #"^\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
    private static let offsetTag = try? NSRegularExpression(pattern: #"^\[offset:\s*([+-]?\d+)\s*\]"#, options: .caseInsensitive)

    static func parse(_ lrc: String) -> [(time: Double, text: String)] {
        guard let timestamp else { return [] }
        var lines: [(time: Double, text: String)] = []
        var offset: Double = 0

        for rawLine in lrc.components(separatedBy: .newlines) {
            var rest = rawLine.trimmingCharacters(in: .whitespaces)
            let fullRange = NSRange(rest.startIndex..., in: rest)

            if let offsetTag, let match = offsetTag.firstMatch(in: rest, range: fullRange),
               let range = Range(match.range(at: 1), in: rest), let value = Double(rest[range]) {
                offset = value / 1000
                continue
            }

            // A line may carry several timestamps: [00:10.00][00:42.00]Chorus
            var times: [Double] = []
            while let match = timestamp.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
                  let whole = Range(match.range, in: rest),
                  let minutes = Range(match.range(at: 1), in: rest).flatMap({ Double(rest[$0]) }),
                  let seconds = Range(match.range(at: 2), in: rest).flatMap({ Double(rest[$0]) }) {
                var fraction = 0.0
                if let range = Range(match.range(at: 3), in: rest), let value = Double(rest[range]) {
                    fraction = value / pow(10, Double(rest[range].count))
                }
                times.append(minutes * 60 + seconds + fraction)
                rest = String(rest[whole.upperBound...])
            }

            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in times {
                lines.append((max(time - offset, 0), text))
            }
        }

        // Stable order, without leading or repeated blank lines.
        let sorted = lines.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map { $0.element }
        var result: [(time: Double, text: String)] = []
        for line in sorted where !(line.text.isEmpty && (result.last?.text.isEmpty ?? true)) {
            result.append(line)
        }
        return result.contains { !$0.text.isEmpty } ? result : []
    }
}

/// Builds LRCLIB queries and rejects results that belong to another song.
enum LyricsMatching {
    struct Query: Equatable {
        let title: String
        let artist: String?
    }

    /// Longer than this, a result is treated as a different recording.
    private static let maxDurationDifference: Double = 15

    static func cleaned(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\u{FFFD}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes decorations such as "(Remastered 2011)", "- Live" or "feat. X".
    static func strippedTitle(_ title: String) -> String {
        let decoration = "remaster|live|version|edit|mix|mono|stereo|bonus|deluxe|explicit|clean|official|audio|video|lyric|feat|ft\\.|with "
        var result = title
        for pattern in [
            "\\s*[\\(\\[][^\\)\\]]*(\(decoration))[^\\)\\]]*[\\)\\]]",
            "\\s+-\\s+[^-]*(\(decoration))[^-]*$",
            "\\s+(feat\\.?|ft\\.?)\\s+.*$",
        ] {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        let stripped = cleaned(result)
        return stripped.isEmpty ? cleaned(title) : stripped
    }

    /// Main artist from labels such as "A, B", "A feat. B" or "A - Topic".
    static func primaryArtist(_ artist: String) -> String {
        var result = artist.replacingOccurrences(of: "\\s+-\\s+Topic$", with: "", options: [.regularExpression, .caseInsensitive])
        result = result.replacingOccurrences(of: "\\s*(,|;|&|\\bfeat\\.?|\\bft\\.?|\\bx\\b).*$", with: "", options: [.regularExpression, .caseInsensitive])
        let primary = cleaned(result)
        return primary.isEmpty ? cleaned(artist) : primary
    }

    static func searchQueries(title: String, artist: String) -> [Query] {
        let fullTitle = cleaned(title)
        let fullArtist = cleaned(artist)
        let shortTitle = strippedTitle(fullTitle)
        let mainArtist = primaryArtist(fullArtist)

        var queries: [Query] = []
        for query in [
            Query(title: fullTitle, artist: fullArtist),
            Query(title: shortTitle, artist: fullArtist),
            Query(title: shortTitle, artist: mainArtist),
            Query(title: shortTitle, artist: nil),
        ] where !queries.contains(query) {
            if let artist = query.artist, artist.isEmpty { continue }
            queries.append(query)
        }
        return queries
    }

    static func searchURL(for query: Query) -> URL? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [URLQueryItem(name: "track_name", value: query.title)]
        if let artist = query.artist {
            components?.queryItems?.append(URLQueryItem(name: "artist_name", value: artist))
        }
        // URLComponents leaves "+" as is, and servers read it as a space.
        components?.percentEncodedQuery = components?.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components?.url
    }

    static func isDurationCompatible(_ result: [String: Any], duration: Double?) -> Bool {
        guard let duration, duration > 0, let candidate = result["duration"] as? Double else { return true }
        return abs(candidate - duration) <= maxDurationDifference
    }

    static func bestMatch(in results: [[String: Any]], title: String, artist: String, duration: Double?) -> [String: Any]? {
        let wantedTitle = comparable(strippedTitle(title))
        let wantedArtist = comparable(cleaned(artist))
        let wantedMainArtist = comparable(primaryArtist(artist))

        var best: [String: Any]?
        var bestScore = 0

        for result in results {
            if result["instrumental"] as? Bool == true { continue }
            let plain = result["plainLyrics"] as? String ?? ""
            let synced = result["syncedLyrics"] as? String ?? ""
            guard !plain.isEmpty || !synced.isEmpty else { continue }

            let candidateTitle = comparable(strippedTitle(result["trackName"] as? String ?? ""))
            let titleScore: Int
            if candidateTitle == wantedTitle {
                titleScore = 10
            } else if !candidateTitle.isEmpty, candidateTitle.contains(wantedTitle) || wantedTitle.contains(candidateTitle) {
                titleScore = 5
            } else {
                continue
            }

            var artistScore = 0
            if !wantedArtist.isEmpty {
                let candidateArtist = comparable(result["artistName"] as? String ?? "")
                if candidateArtist == wantedArtist {
                    artistScore = 8
                } else if !candidateArtist.isEmpty,
                          candidateArtist.contains(wantedMainArtist) || wantedArtist.contains(candidateArtist) {
                    artistScore = 4
                } else {
                    continue
                }
            }

            var score = titleScore + artistScore
            if !synced.isEmpty { score += 3 }
            if !plain.isEmpty { score += 1 }
            if let duration, duration > 0, let candidate = result["duration"] as? Double {
                let difference = abs(candidate - duration)
                if difference <= 2 {
                    score += 6
                } else if difference <= 5 {
                    score += 3
                } else if difference > maxDurationDifference {
                    score -= 6
                }
            }

            if score > bestScore {
                bestScore = score
                best = result
            }
        }

        return best
    }

    private static func comparable(_ string: String) -> String {
        string.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US"))
    }
}

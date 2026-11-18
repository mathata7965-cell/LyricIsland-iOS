import CryptoKit
import Foundation

private struct LRCLibRecord: Decodable {
    let id: Int
    let trackName: String?
    let artistName: String?
    let albumName: String?
    let duration: Double?
    let syncedLyrics: String?
    let plainLyrics: String?
}

private struct ITunesLookupResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let artworkUrl100: String?

    var artworkUrl600: URL? {
        guard let raw = artworkUrl100 else { return nil }
        return URL(string: raw.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }
}

actor LyricsLookupService {
    static let shared = LyricsLookupService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "LyricIsland-iOS/1.0 (Dynamic Island Live Lyrics)"
        ]
        return URLSession(configuration: config)
    }()

    private var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("LyricsCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func cachedLyrics(title: String, artist: String) -> String? {
        let url = cacheFileURL(title: title, artist: artist)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func saveCachedLyrics(_ lrc: String, title: String, artist: String) {
        let url = cacheFileURL(title: title, artist: artist)
        try? lrc.write(to: url, atomically: true, encoding: .utf8)
    }

    func autoFetchSyncedLyrics(title: String, artist: String, duration: TimeInterval) async -> (lrc: String, artworkURL: URL?)? {
        if let cached = cachedLyrics(title: title, artist: artist), !cached.isEmpty {
            let art = await fetchArtworkURL(title: title, artist: artist)
            return (cached, art)
        }

        let cleanTitle = Self.cleanTitle(title)
        let cleanArtist = Self.cleanArtist(artist)

        // 1. Exact LRCLIB /api/get
        if let exact = await fetchExact(track: title, artist: artist, duration: duration),
           let synced = exact.syncedLyrics, !synced.isEmpty {
            saveCachedLyrics(synced, title: title, artist: artist)
            let art = await fetchArtworkURL(title: cleanTitle, artist: cleanArtist)
            return (synced, art)
        }

        // 2. Cleaned LRCLIB /api/get
        if cleanTitle != title || cleanArtist != artist {
            if let cleanedExact = await fetchExact(track: cleanTitle, artist: cleanArtist, duration: duration),
               let synced = cleanedExact.syncedLyrics, !synced.isEmpty {
                saveCachedLyrics(synced, title: title, artist: artist)
                let art = await fetchArtworkURL(title: cleanTitle, artist: cleanArtist)
                return (synced, art)
            }
        }

        // 3. Fuzzy LRCLIB /api/search
        let searchQuery = [cleanArtist, cleanTitle].filter { !$0.isEmpty }.joined(separator: " ")
        let candidates = await queryLRCLibSearch(query: searchQuery)
        if let best = Self.pickBestMatch(candidates: candidates, targetTitle: cleanTitle, targetArtist: cleanArtist, targetDuration: duration),
           let content = best.syncedLyrics ?? best.plainLyrics,
           !content.isEmpty {
            saveCachedLyrics(content, title: title, artist: artist)
            let art = await fetchArtworkURL(title: cleanTitle, artist: cleanArtist)
            return (content, art)
        }

        return nil
    }

    func searchInteractive(query: String) async -> [LRCSearchCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        async let lrcTask = queryLRCLibSearch(query: trimmed)
        async let itunesTask = queryITunesTracks(query: trimmed)

        let records = await lrcTask
        let itunesTracks = await itunesTask

        var candidates = records.map { rec -> LRCSearchCandidate in
            let name = rec.trackName ?? "未知曲目"
            let artist = rec.artistName ?? "未知歌手"
            let art = Self.matchArtwork(track: name, artist: artist, pool: itunesTracks)
            return LRCSearchCandidate(
                id: rec.id,
                trackName: name,
                artistName: artist,
                albumName: rec.albumName ?? "",
                duration: rec.duration ?? 0,
                syncedLyrics: rec.syncedLyrics,
                plainLyrics: rec.plainLyrics,
                artworkURL: art
            )
        }

        candidates.sort { lhs, rhs in
            if lhs.isSynced != rhs.isSynced {
                return lhs.isSynced && !rhs.isSynced
            }
            return lhs.duration > rhs.duration
        }

        return candidates
    }

    func fetchArtworkURL(title: String, artist: String) async -> URL? {
        let query = [artist, title].filter { !$0.isEmpty }.joined(separator: " ")
        guard !query.isEmpty else { return nil }
        let items = await queryITunesTracks(query: query)
        return Self.matchArtwork(track: title, artist: artist, pool: items) ?? items.first?.artworkUrl600
    }

    // MARK: - Private Network Calls

    private func fetchExact(track: String, artist: String, duration: TimeInterval) async -> LRCLibRecord? {
        guard var comps = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        var items = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        if duration > 10 {
            items.append(URLQueryItem(name: "duration", value: String(Int(round(duration)))))
        }
        comps.queryItems = items
        guard let url = comps.url else { return nil }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(LRCLibRecord.self, from: data)
        } catch {
            return nil
        }
    }

    private func queryLRCLibSearch(query: String) async -> [LRCLibRecord] {
        guard var comps = URLComponents(string: "https://lrclib.net/api/search") else { return [] }
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = comps.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder().decode([LRCLibRecord].self, from: data)
        } catch {
            return []
        }
    }

    private func queryITunesTracks(query: String) async -> [ITunesTrack] {
        guard var comps = URLComponents(string: "https://itunes.apple.com/search") else { return [] }
        comps.queryItems = [
            URLQueryItem(name: "term", value: query),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "12")
        ]
        guard let url = comps.url else { return [] }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
            return try JSONDecoder().decode(ITunesLookupResponse.self, from: data).results
        } catch {
            return []
        }
    }

    // MARK: - Helpers

    private func cacheFileURL(title: String, artist: String) -> URL {
        let key = "\(artist.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))|\(title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent("\(hex).lrc")
    }

    private static func cleanTitle(_ title: String) -> String {
        var result = title
        let patterns = [
            #"\s*\([^)]*(feat\.|ft\.|live|remaster|version|edit|mono|stereo|instrumental|伴奏)[^)]*\)"#,
            #"\s*\[[^\]]*(explicit|remaster|live|feat\.|ft\.)[^\]]*\]"#,
            #"\s*-\s*(remastered|live|single|radio edit).*$"#
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanArtist(_ artist: String) -> String {
        let separators = [",", "&", " feat.", " ft.", " x ", " / "]
        var cleaned = artist
        for sep in separators {
            if let range = cleaned.range(of: sep, options: .caseInsensitive) {
                cleaned = String(cleaned[..<range.lowerBound])
            }
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pickBestMatch(
        candidates: [LRCLibRecord],
        targetTitle: String,
        targetArtist: String,
        targetDuration: TimeInterval
    ) -> LRCLibRecord? {
        guard !candidates.isEmpty else { return nil }
        let normTitle = targetTitle.lowercased()
        let normArtist = targetArtist.lowercased()

        return candidates.max { a, b in
            score(a, normTitle: normTitle, normArtist: normArtist, targetDuration: targetDuration)
            < score(b, normTitle: normTitle, normArtist: normArtist, targetDuration: targetDuration)
        }
    }

    private static func score(
        _ rec: LRCLibRecord,
        normTitle: String,
        normArtist: String,
        targetDuration: TimeInterval
    ) -> Int {
        var total = 0
        if let synced = rec.syncedLyrics, !synced.isEmpty {
            total += 1000
        } else if let plain = rec.plainLyrics, !plain.isEmpty {
            total += 100
        }
        if let d = rec.duration, targetDuration > 10 {
            let diff = abs(d - targetDuration)
            if diff <= 2.5 { total += 300 }
            else if diff <= 6.0 { total += 150 }
            else if diff <= 12.0 { total += 40 }
        }
        let rTitle = (rec.trackName ?? "").lowercased()
        let rArtist = (rec.artistName ?? "").lowercased()
        if rTitle == normTitle { total += 200 }
        else if rTitle.contains(normTitle) || normTitle.contains(rTitle) { total += 80 }
        if !normArtist.isEmpty {
            if rArtist == normArtist { total += 150 }
            else if rArtist.contains(normArtist) || normArtist.contains(rArtist) { total += 60 }
        }
        return total
    }

    private static func matchArtwork(track: String, artist: String, pool: [ITunesTrack]) -> URL? {
        let t = track.lowercased()
        let a = artist.lowercased()
        if let exact = pool.first(where: {
            ($0.trackName ?? "").lowercased().contains(t) &&
            (a.isEmpty || ($0.artistName ?? "").lowercased().contains(a))
        }) {
            return exact.artworkUrl600
        }
        return pool.first(where: { ($0.trackName ?? "").lowercased().contains(t) })?.artworkUrl600
            ?? pool.first?.artworkUrl600
    }
}

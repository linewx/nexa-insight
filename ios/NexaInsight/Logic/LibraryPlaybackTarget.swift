import Foundation

enum LibraryPlaybackTarget: Equatable {
    case youtube(videoId: String)
    case web(URL)
    case unavailable

    static func forEpisode(_ episode: EpisodeDTO) -> Self {
        if let videoId = episode.youtubeId,
           !videoId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .youtube(videoId: videoId)
        }
        guard let url = URL(string: episode.sourceUrl),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return .unavailable }
        return .web(url)
    }
}

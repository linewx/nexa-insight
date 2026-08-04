import Foundation

enum ImportTaskKind: Equatable {
    case importing
    case reprocessing
}

struct ImportTask: Equatable, Identifiable {
    let episode: EpisodeDTO
    var job: JobDTO
    let kind: ImportTaskKind

    var id: Int { episode.id }
    var episodeId: Int { episode.id }
    var jobId: Int { job.id }
    var progress: Int { job.progress }
    var isQueued: Bool { job.status == "queued" }
    var isFailed: Bool { job.status == "failed" }
}

struct ImportTaskStore: Equatable {
    private var tasks: [Int: ImportTask] = [:]
    private var order: [Int] = []

    var ordered: [ImportTask] { order.compactMap { tasks[$0] } }

    func task(for episodeId: Int) -> ImportTask? { tasks[episodeId] }

    mutating func upsert(_ task: ImportTask) {
        if tasks[task.episodeId] == nil { order.append(task.episodeId) }
        tasks[task.episodeId] = task
    }

    mutating func remove(episodeId: Int) {
        tasks[episodeId] = nil
        order.removeAll { $0 == episodeId }
    }
}

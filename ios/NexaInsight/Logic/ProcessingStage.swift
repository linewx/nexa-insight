import Foundation

// What the learner reads while an import runs.
//
// Lives here rather than in LibraryView because that file is `#if os(iOS)`, which put it out of
// reach of the test target — and this mapping had already drifted: the backend sends `audio` and
// `learning`, neither was listed, so both fell through to the raw name and a card read
// "Learning" for the 65% of an import that stage takes.

func processingStageTitle(_ stage: String) -> String {
    switch normalizedProcessingStage(stage) {
    case "upload", "uploading":
        return "Uploading"
    case "parsing":
        return "Parsing source"
    case "transcribing":
        return "Generating transcript"
    case "chapters":
        return "Generating chapters"
    case "translation", "translating":
        return "Preparing bilingual context"
    case "audio":
        return "Fetching audio"
    // The longest stage of an import, so it says what it is actually doing rather than
    // "Learning", which reads like the app is learning something.
    case "learning":
        return "Finding expressions"
    case "ready":
        return "Ready to discuss"
    default:
        return stage.isEmpty ? "Processing" : stage.capitalized
    }
}

func normalizedProcessingStage(_ stage: String) -> String {
    switch stage.lowercased() {
    case "upload", "uploading":
        return "uploading"
    case "download", "downloading", "parse", "parsing", "metadata", "extracting":
        return "parsing"
    case "transcript", "transcribing", "transcription", "asr":
        return "transcribing"
    // "indexing" is what the backend calls the chapter + classification step.
    case "chapters", "chaptering", "analysis", "analyzing", "summarizing", "indexing":
        return "chapters"
    case "translation", "translating":
        return "translation"
    // No case for "audio" or "learning": `default` lowercases, which is already the name
    // processingStageTitle matches on. Adding them read as a fix and changed nothing — the
    // missing half was the TITLE, where both fell through and surfaced raw as "Audio" and
    // "Learning" mid-import. Aliases only earn a case when they differ from the stage name,
    // as "scanning" would.
    case "complete", "completed", "ready":
        return "ready"
    default:
        return stage.lowercased()
    }
}

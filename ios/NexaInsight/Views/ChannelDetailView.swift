#if os(iOS)
import SwiftUI

// One channel: search inside it, or browse its recent uploads.
//
// Search is the primary surface because it is the only path that reaches the
// back catalog — a channel with years of history cannot be served by a
// "latest N" list.
struct ChannelDetailView: View {
    @StateObject var vm: ChannelDetailViewModel
    let importing: Bool
    var bylineLocale: Locale = DiscoverFormat.defaultLocale
    let onImport: (String) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NXSpacing.x6) {
                searchField

                if vm.isSearchActive {
                    searchSection
                } else {
                    uploadsSection
                }
            }
            .padding(.horizontal, NXSpacing.x4)
            .padding(.vertical, NXSpacing.x4)
        }
        .background(NXColor.background(scheme))
        .navigationTitle(vm.subscription.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if vm.uploads.isEmpty { await vm.loadUploads() } }
    }

    private var searchField: some View {
        HStack(spacing: NXSpacing.x3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(NXColor.textTertiary(scheme))
            TextField("Search in this channel", text: $vm.query)
                .font(NXFont.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await vm.runSearch() } }
            if vm.isSearchActive || !vm.query.isEmpty {
                Button(action: vm.clearSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, NXSpacing.x3)
        .frame(height: 48)
        .background(NXColor.surface1(scheme), in: RoundedRectangle(cornerRadius: NXRadius.surface))
    }

    @ViewBuilder
    private var searchSection: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Results")

            if vm.searchUnavailable {
                // Distinct from "no match": the page could not be read at all,
                // so point at the fallback that needs no page structure.
                NXErrorState(
                    message: "Browsing this channel is unavailable right now. You can paste a video link on Discover to import it.",
                    retry: { Task { await vm.runSearch() } })
            } else if vm.searching {
                ProgressView("Searching").font(NXFont.auxiliary)
            } else if vm.results.isEmpty {
                Text("No videos in this channel match \(vm.searchedTerm ?? "").")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                rows(vm.results)
                // Pagination would need the innertube API, so the cap is real
                // and stated rather than silently truncating.
                Text("Showing the top \(vm.results.count) matches.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
            }
        }
    }

    @ViewBuilder
    private var uploadsSection: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x4) {
            NXSectionHeader(title: "Recent uploads")

            if vm.loadingUploads && vm.uploads.isEmpty {
                ProgressView("Loading").font(NXFont.auxiliary)
            } else if vm.uploads.isEmpty {
                Text("Could not load recent uploads. Try searching instead.")
                    .font(NXFont.body)
                    .foregroundStyle(NXColor.textSecondary(scheme))
            } else {
                VStack(spacing: 0) {
                    ForEach(vm.uploads) { entry in
                        ChannelUploadRow(
                            entry: entry,
                            imported: vm.isImported(videoId: entry.videoId),
                            importing: importing,
                            bylineLocale: bylineLocale,
                            onImport: { onImport(entry.watchURL.absoluteString) })
                        if entry.id != vm.uploads.last?.id {
                            Divider().overlay(NXColor.border(scheme))
                        }
                    }
                }
                // The feed itself caps at 15; searching reaches older uploads.
                Text("The channel feed lists its \(vm.uploads.count) most recent uploads. Search to find older ones.")
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func rows(_ videos: [ChannelVideo]) -> some View {
        VStack(spacing: 0) {
            ForEach(videos) { video in
                ChannelVideoRow(
                    video: video,
                    imported: vm.isImported(videoId: video.videoId),
                    importing: importing,
                    onImport: { if let url = video.watchURL { onImport(url.absoluteString) } })
                if video.id != videos.last?.id {
                    Divider().overlay(NXColor.border(scheme))
                }
            }
        }
    }
}

private struct ChannelVideoRow: View {
    let video: ChannelVideo
    let imported: Bool
    let importing: Bool
    let onImport: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Text(video.title)
                .font(NXFont.bodyMedium)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Text(byline)
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
            if let summary = video.summary {
                Text(summary)
                    .font(NXFont.auxiliary)
                    .foregroundStyle(NXColor.textTertiary(scheme))
                    .lineLimit(2)
            }
            action
        }
        .padding(.vertical, NXSpacing.x3)
    }

    // Duration first: it is the strongest signal for whether a 4-hour episode is
    // worth committing to, and the pipeline run is expensive.
    private var byline: String {
        [video.durationText, video.publishedText, video.viewsText]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder
    private var action: some View {
        if imported {
            NXTag(text: "In your library", tint: NXColor.success)
        } else {
            NXSecondaryButton(
                title: importing ? "Adding" : "Add to Nexa",
                systemName: importing ? "clock" : "plus",
                action: onImport)
        }
    }
}

private struct ChannelUploadRow: View {
    let entry: DiscoverEntry
    let imported: Bool
    let importing: Bool
    var bylineLocale: Locale = DiscoverFormat.defaultLocale
    let onImport: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: NXSpacing.x2) {
            Text(entry.title)
                .font(NXFont.bodyMedium)
                .foregroundStyle(NXColor.text(scheme))
                .fixedSize(horizontal: false, vertical: true)
            // No duration here — the RSS feed carries none. Reusing
            // DiscoverFormat.byline keeps this consistent with the Discover feed.
            Text(DiscoverFormat.byline(entry, locale: bylineLocale))
                .font(NXFont.auxiliary)
                .foregroundStyle(NXColor.textSecondary(scheme))
            if imported {
                NXTag(text: "In your library", tint: NXColor.success)
            } else {
                NXSecondaryButton(
                    title: importing ? "Adding" : "Add to Nexa",
                    systemName: importing ? "clock" : "plus",
                    action: onImport)
            }
        }
        .padding(.vertical, NXSpacing.x3)
    }
}
#endif

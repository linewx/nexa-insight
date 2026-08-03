#if os(iOS)
import SwiftUI

// The channels you follow.
//
// This was a segmented control inside Discover, which meant a tab within a tab —
// two positions to remember at once. Promoting it to its own tab removed
// Discover's internal switch entirely, and gave following its own home rather
// than making it a mode of browsing.
struct ChannelsView: View {
    @ObservedObject var vm: DiscoverViewModel
    let onOpenChannel: (String, String) -> Void
    @State private var showAddChannel = false
    @State private var showYouTubeSubscriptions = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            BrandHeader {
                Button { showYouTubeSubscriptions = true } label: {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 19, weight: .medium))
                }
                .accessibilityLabel("View your YouTube subscriptions")

                Button { showAddChannel = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                }
                .accessibilityLabel("Follow a channel by link")
            }
            list
        }
        // Discover was the only screen that loaded the feed, so opening Channels
        // first left every row with nothing to say. IfNeeded, not refresh():
        // switching tabs re-runs .task, and N channels cost 2N requests.
        .task { await vm.loadFeedIfNeeded() }
    }

    // A List rather than a hand-rolled VStack: swipe-to-unfollow is a List
    // affordance, and using the real one means the gesture, the animation, and the
    // row insets all come from the system.
    private var list: some View {
        // Read once per render rather than per row: the lookup walks the whole feed,
        // and doing that inside ForEach would repeat it for every channel.
        let latest = vm.latestByChannel
        return List {
            if vm.subscriptions.isEmpty {
                NXEmptyState(
                    title: "No channels yet",
                    message: "Search a video in Discover and tap its channel name to follow it.",
                    actionTitle: "Paste a channel link",
                    action: { showAddChannel = true })
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(vm.subscriptions) { subscription in
                    Button {
                        onOpenChannel(subscription.channelId, subscription.title)
                    } label: {
                        ChannelRow(
                            subscription: subscription,
                            latest: latest[subscription.channelId])
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(NXColor.background(scheme))
                    // The avatar column already sets the rhythm of the list, so a
                    // rule between every pair of rows was drawing a boundary the
                    // layout states on its own.
                    .listRowSeparator(.hidden)
                    // Reclaimed from the separator's own inset. The default leaves
                    // room for a rule that is no longer drawn.
                    .listRowInsets(EdgeInsets(top: NXSpacing.x1, leading: NXSpacing.x4,
                                              bottom: NXSpacing.x1, trailing: NXSpacing.x4))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            vm.removeSubscription(channelId: subscription.channelId)
                        } label: {
                            Label("Unfollow", systemImage: "minus.circle")
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(NXColor.background(scheme))
        // Now that the rows carry what is new, they can go stale — and this is the
        // only way to force the reload that .task deliberately skips. Discover has
        // had this for the same feed all along.
        .refreshable { await vm.refresh() }
        // One header per screen: the brand row above. Left visible, the navigation
        // bar drew a second band behind it in a different tone.
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
        .sheet(isPresented: $showYouTubeSubscriptions) {
            WebPageSheet(
                title: "YouTube subscriptions",
                url: YouTubeWeb.subscriptions,
                // Stated plainly: a cross-origin page's contents are unreadable to
                // us, so this cannot import anything. Implying otherwise would send
                // someone looking for a button that does not exist.
                note: "Read-only. Copy a channel link and paste it with + to follow it here.")
        }
    }
}

struct ChannelRow: View {
    let subscription: Subscription
    // Newest upload, when the feed has loaded. nil keeps the older two-line row.
    var latest: ChannelLatest?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: NXSpacing.x3) {
            ChannelAvatar(
                url: subscription.avatarURL,
                title: subscription.title,
                channelId: subscription.channelId,
                size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.title)
                    .font(NXFont.bodyMedium)
                    .foregroundStyle(NXColor.text(scheme))
                    .lineLimit(1)

                // What is new on this channel, which is the reason to open it. The
                // subscriber count it replaces described the channel's popularity —
                // true, unchanging, and not something you revisit this list to read.
                //
                // Age and title share one line rather than stacking: two lines would
                // make the row taller than the one it replaces and hand the
                // reclaimed space straight back.
                if let latest {
                    Text(latestByline(latest))
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textSecondary(scheme))
                        .lineLimit(1)
                } else if let subscriberText = subscription.subscriberText {
                    // Before the feed arrives, or for a channel it did not cover.
                    Text(subscriberText)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
            }

            Spacer(minLength: 0)

            // No chevron. On a list where every row opens something it marked the
            // rule rather than an exception, and it cost the title width on the
            // narrowest screens.
        }
        .padding(.vertical, NXSpacing.x2)
        .contentShape(Rectangle())
        // The row is one button, so it announces as one thing — otherwise VoiceOver
        // reads the channel and the byline as two separate stops.
        .accessibilityElement(children: .combine)
    }

    // Age leads: scanning this list is asking which channel has something recent,
    // and the date is what answers that. The title says what it is once the date has
    // earned a second look.
    private func latestByline(_ latest: ChannelLatest) -> String {
        [latest.ageText, latest.title]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}
#endif

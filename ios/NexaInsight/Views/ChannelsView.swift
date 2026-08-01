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
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // A List rather than a hand-rolled VStack: swipe-to-unfollow is a List
        // affordance, and using the real one means the gesture, the animation,
        // and the row insets all come from the system.
        List {
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
                        ChannelRow(subscription: subscription)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(NXColor.background(scheme))
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
        .navigationTitle("Channels")
        .toolbar {
            // Pasting a link is an action on this screen, so it belongs in the
            // toolbar rather than as a row pretending to be a channel.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddChannel = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Follow a channel by link")
            }
        }
        .sheet(isPresented: $showAddChannel) {
            AddChannelSheet(vm: vm)
        }
    }
}

struct ChannelRow: View {
    let subscription: Subscription
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
                if let subscriberText = subscription.subscriberText {
                    Text(subscriberText)
                        .font(NXFont.auxiliary)
                        .foregroundStyle(NXColor.textTertiary(scheme))
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(NXColor.textTertiary(scheme))
                .accessibilityHidden(true)   // the whole row is the button
        }
        .padding(.vertical, NXSpacing.x2)
        .contentShape(Rectangle())
    }
}
#endif

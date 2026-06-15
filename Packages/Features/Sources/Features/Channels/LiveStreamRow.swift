import SwiftUI
import TwitchKit
import NukeUI

/// Rich row for the Follows tab's Live segment. Models Twitch mobile's
/// Following → Live layout:
///
///   ┌────────────┐  [avatar] DisplayName ✓
///   │            │  Stream title text…
///   │ Thumbnail  │  Game · Category name
///   │  🔴 6K     │  [Tag] [Tag] [Tag] [Tag]
///   └────────────┘
///
/// Pure presentational struct. All data is passed in via two parameters:
/// the `TwitchStream` (live-stream metadata from `/streams/followed`) and an
/// optional `TwitchUser` for the profile image URL + broadcasterType (used
/// for the verified-partner checkmark).
///
/// Contrast with `ChannelRow` — that view is the compact single-line layout
/// used by the All segment, where most rows are offline channels and a
/// thumbnail wouldn't apply. The two views are intentionally separate rather
/// than one parameterized view because the layouts have very different
/// vertical rhythms and aspect-ratio constraints.
struct LiveStreamRow: View {
    let stream: TwitchStream
    /// Optional — loads lazily after `fetchUsers` populates the profile.
    /// While nil we show placeholder avatar and skip the verified badge.
    let profile: TwitchUser?

    /// Standard preview size from Twitch's CDN. 440×248 is 16:9 at 2x — sharp
    /// on @3x iPhones (downscale) without wasting bandwidth on @1x devices.
    /// We could ship two URLs and let the scaler pick, but 440 is the sweet
    /// spot Twitch's own mobile app uses for list previews.
    private static let thumbnailWidth = 440
    private static let thumbnailHeight = 248

    /// Tags shown before truncation. Twitch's UI caps at ~4 too; more than that
    /// becomes visual noise on a list row.
    /// Show only the top 2 tags by stream order. Twitch returns tags in
    /// relevance order (most-relevant first), so .prefix(2) IS top-by-
    /// relevance without needing a custom sort. Dropped from 4 because
    /// four tags consistently overflow the row width and produce a
    /// "truncation soup" — better to show fewer tags clearly.
    private static let tagDisplayCap = 2

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail
            metadata
        }
        .padding(.vertical, 6)
    }

    // MARK: - Thumbnail

    /// 16:9 stream preview with an overlaid LIVE-dot + viewer-count badge in
    /// the bottom-leading corner. The badge floats above the thumbnail with
    /// a semi-opaque black background so it remains readable across varied
    /// stream content.
    @ViewBuilder
    private var thumbnail: some View {
        LazyImage(url: thumbnailURL) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else if state.error != nil {
                // No thumbnail (rare — Twitch's CDN is fast). Show a neutral
                // placeholder rather than nothing so layout doesn't shift.
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "tv")
                        .foregroundStyle(.secondary)
                }
            } else {
                // Subtle placeholder during load.
                Color.secondary.opacity(0.15)
            }
        }
        .frame(width: 140, height: 79)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .bottomLeading) {
            // Solid-backdrop `.overlay` style — see `LiveBadge` for why this
            // surface can't use Clear glass over media.
            LiveBadge(viewerCount: stream.viewerCount, style: .overlay)
                .padding(6)
        }
    }

    /// Builds the concrete CDN URL by substituting Twitch's `{width}`/`{height}`
    /// template placeholders. Returns nil if the template is malformed (rare).
    private var thumbnailURL: URL? {
        let raw = stream.thumbnailUrl
            .replacingOccurrences(of: "{width}", with: String(Self.thumbnailWidth))
            .replacingOccurrences(of: "{height}", with: String(Self.thumbnailHeight))
        return URL(string: raw)
    }

    // MARK: - Metadata column

    @ViewBuilder
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 3) {
            headerLine
            if !stream.title.isEmpty {
                Text(stream.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            if !stream.gameName.isEmpty {
                Text(stream.gameName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            tagPills
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Profile avatar + display name + (if partner) verified checkmark.
    /// The avatar is small (20pt) — the thumbnail is doing the heavy visual
    /// lifting; the avatar is a secondary identity cue.
    @ViewBuilder
    private var headerLine: some View {
        HStack(spacing: 6) {
            avatar
            Text(stream.userName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            // Verified-partner checkmark removed. Reasons:
            //   - We weren't matching Twitch's actual partner badge
            //     (that's a per-channel chat badge with a unique CDN
            //     URL, not the generic checkmark.seal.fill we used).
            //   - In practice nearly every live channel is a partner,
            //     so the badge added visual noise that made names
            //     harder to scan rather than easier.
            //   - Twitch's official partner identity comes through the
            //     chat badges already (we render those in ChatRow).
            Spacer(minLength: 0)
        }
    }

    /// 20pt circle avatar. Placeholder while the profile fetch is in flight.
    @ViewBuilder
    private var avatar: some View {
        LazyImage(url: profile.flatMap { URL(string: $0.profileImageUrl) }) { state in
            if let image = state.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.secondary.opacity(0.5))
            }
        }
        .frame(width: 20, height: 20)
        .clipShape(Circle())
    }

    /// Up to 4 tag pills in a horizontal row. Truncates with ellipsis if names
    /// overflow rather than wrapping — keeps row height predictable.
    @ViewBuilder
    private var tagPills: some View {
        HStack(spacing: 6) {
            ForEach(stream.tags.prefix(Self.tagDisplayCap), id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.15), in: Capsule())
            }
        }
        .lineLimit(1)
    }
}

import SwiftUI
import Core
import Nuke
import os

private let logger = AppLogger.make("Features.Storage")

/// Settings → Accounts & Data → Storage. Shows how much disk space chattr's caches occupy and
/// offers a one-tap clear.
///
/// ## What counts as "cache" here
///
/// Only data that re-downloads on demand with zero user-visible loss:
///   - Emote & badge images — Nuke's `DataCache` (compressed image data,
///     200 MB LRU cap, see `ImagePipelineSetup`).
///   - Emote metadata — `JSONDiskCache` under `Caches/emote-cache/`
///     (global Twitch badge/emote tables + per-channel third-party emote
///     tables; `channels/` nests inside, so one root covers both).
///
/// Deliberately NOT included: UserDefaults (drafts, appearance, highlight
/// keywords), SwiftData (accounts), Keychain (tokens). Those are settings
/// and identity, not cache — clearing them would lose user data.
///
/// ## Measurement
///
/// Sizes are computed by `DiskUsage` (a Core actor) so directory walks
/// never run on the main actor. Measurement re-fires after a clear via
/// `measureToken` bumping the `.task(id:)`.
public struct StorageSettingsScreen: View {

    /// Bytes used by Nuke's image data cache; nil while measuring.
    @State private var imageCacheBytes: Int64?
    /// Bytes used by the emote-metadata JSON cache; nil while measuring.
    @State private var metadataCacheBytes: Int64?

    @State private var isClearing = false
    @State private var showingClearConfirm = false

    /// Bumped after a clear to re-fire the measuring `.task(id:)`.
    @State private var measureToken = 0

    public init() {}

    /// Root of the emote-metadata cache. `emote-cache/channels` nests under
    /// this, so measuring/removing the root covers both tiers.
    private var emoteMetadataDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(CacheSubdirectory.emoteGlobals, isDirectory: true)
    }

    /// Nuke's on-disk image cache directory, read from the live pipeline so
    /// this never drifts from `ImagePipelineSetup`'s configuration.
    private var imageCacheDirectory: URL? {
        (ImagePipeline.shared.configuration.dataCache as? DataCache)?.path
    }

    private var totalBytes: Int64? {
        guard let imageCacheBytes, let metadataCacheBytes else { return nil }
        return imageCacheBytes + metadataCacheBytes
    }

    public var body: some View {
        Form {
            Section {
                sizeRow(
                    title: "Emote & Badge Images",
                    systemImage: "photo.stack",
                    bytes: imageCacheBytes
                )
                sizeRow(
                    title: "Emote Metadata",
                    systemImage: "list.bullet.rectangle",
                    bytes: metadataCacheBytes
                )
                sizeRow(title: "Total", systemImage: "internaldrive", bytes: totalBytes)
                    .fontWeight(.semibold)
            } header: {
                Text("Cached Data")
            } footer: {
                Text("Images and emote data are cached so chat renders instantly without re-downloading. The image cache trims itself to 200 MB automatically.")
            }

            Section {
                Button(role: .destructive) {
                    showingClearConfirm = true
                } label: {
                    if isClearing {
                        HStack {
                            ProgressView()
                            Text("Clearing…")
                        }
                    } else {
                        Label("Clear Cache", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                }
                .disabled(isClearing || totalBytes == nil)
            } footer: {
                Text("Clearing is safe — emotes, badges, and metadata re-download as you use chat. Your settings, drafts, and accounts are not affected.")
            }
        }
        .navigationTitle("Storage")
        .toolbarTitleDisplayMode(.inlineLarge)
        .task(id: measureToken) {
            await measure()
        }
        .confirmationDialog(
            "Clear all cached data?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await clearCaches() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Emotes and badges will re-download as needed.")
        }
    }

    /// One labelled size row. nil bytes = still measuring → placeholder.
    private func sizeRow(title: String, systemImage: String, bytes: Int64?) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let bytes {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                Text("—")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func measure() async {
        let meter = DiskUsage()
        if let imageDir = imageCacheDirectory {
            imageCacheBytes = await meter.size(of: imageDir)
        } else {
            // No DataCache configured (shouldn't happen outside previews) —
            // report 0 so the UI doesn't sit on the placeholder forever.
            imageCacheBytes = 0
        }
        metadataCacheBytes = await meter.size(of: emoteMetadataDirectory)
    }

    private func clearCaches() async {
        isClearing = true
        defer { isClearing = false }

        // Nuke: one call clears BOTH the in-memory ImageCache and the
        // on-disk DataCache. removeAll only STAGES the disk deletion on
        // DataCache's internal queue, so flush() before re-measuring —
        // otherwise the directory still shows the old size. Both types are
        // Sendable; the detached task keeps flush()'s synchronous disk I/O
        // off the main actor.
        let pipeline = ImagePipeline.shared
        await Task.detached(priority: .utility) {
            pipeline.cache.removeAll()
            (pipeline.configuration.dataCache as? DataCache)?.flush()
        }.value

        // Emote metadata: drop the whole directory; JSONDiskCache.save
        // recreates it on the next fetch.
        await DiskUsage().removeDirectory(at: emoteMetadataDirectory)

        logger.notice("Cleared image + emote-metadata caches")
        measureToken += 1
    }
}

import Foundation
import Nuke

/// Configures Nuke's shared `ImagePipeline` with limits tuned for
/// chattr's chat-heavy usage. Called once at app launch by `RootView`
/// (via `ImagePipelineSetup.configure()`).
///
/// ## Why we override Nuke's defaults
///
/// Nuke ships sensible defaults for general apps, but chat has a
/// specific access pattern:
///   - Many SMALL images (badges 3 KB, emotes 10-100 KB)
///   - High recycle rate (same images materialize+recycle as you scroll)
///   - Strong locality (the visible window holds ~50 unique URLs at most)
///
/// The default 100 MB memory cap is wasteful for our payload sizes
/// (we'd never come close), and the default disk cache is undersized
/// for the long tail of channel-specific emotes.
///
/// Profile-guided tuning:
///   - Memory cache: 50 MB cap, 1000 image count cap. Covers a busy
///     channel's full unique set with comfortable headroom.
///   - Data cache: 200 MB. Animated emotes (slice 4) will inflate the
///     working set significantly; large disk cache reduces re-fetch
///     across app launches.
///   - Decompression: enabled, runs off-main on Nuke's serial
///     decompression queue. This is the default but worth being
///     explicit — it's the primary perf win over AsyncImage.
///
/// Idempotency: `configure()` is safe to call multiple times; only
/// the first call has an effect.
public enum ImagePipelineSetup {

    /// True after `configure()` has run successfully. Used by the
    /// guard inside `configure()` to make repeated calls cheap.
    /// `@MainActor` (not `nonisolated(unsafe)`) so the read-modify-write
    /// in `configure()` is compiler-checked rather than promised safe.
    @MainActor private static var didConfigure = false

    /// Sets Nuke's shared pipeline to chattr-tuned defaults. Call once
    /// at app launch (`chattrApp.init` is the canonical site — `App` is
    /// `@MainActor`, so the isolation is free for callers).
    @MainActor
    public static func configure() {
        guard !didConfigure else { return }
        didConfigure = true

        // Build a custom pipeline.
        let pipeline = ImagePipeline { configuration in
            // Memory cache for decoded UIImages. NSCache-backed so it
            // respects memory pressure automatically.
            let memoryCache = Nuke.ImageCache()
            memoryCache.costLimit = 50 * 1024 * 1024     // 50 MB
            memoryCache.countLimit = 1000                 // 1000 images
            configuration.imageCache = memoryCache

            // Disk cache for compressed image data. 200 MB covers a
            // long tail of channel-specific emotes across launches.
            // Nuke creates the cache directory automatically.
            if let dataCache = try? DataCache(name: "com.chattr.imagecache") {
                dataCache.sizeLimit = 200 * 1024 * 1024  // 200 MB
                configuration.dataCache = dataCache
                // DataCache is the only disk cache. Nuke's default loader
                // also writes every response into its own 150 MB URLCache,
                // so each emote/badge/avatar was stored on disk twice (and
                // Storage's "Clear cache" only emptied one of them). Same
                // setup as Nuke's own `withDataCache` preset.
                let sessionConfiguration = DataLoader.defaultConfiguration
                sessionConfiguration.urlCache = nil
                configuration.dataLoader = DataLoader(configuration: sessionConfiguration)
            }

            // Decompression off the main thread is Nuke's default.
            // Being explicit so we don't accidentally regress if a
            // future Nuke change flips the default.
            configuration.isDecompressionEnabled = true
        }

        ImagePipeline.shared = pipeline
    }
}

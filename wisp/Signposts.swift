import Foundation
import os
import os.signpost

/// Per-subsystem `OSSignposter` registry. Wrap a hot path with
/// `Signposts.feed.withIntervalSignpost("MyPath", id: ...) { ... }` and the
/// region appears in Instruments → Points of Interest / os_signpost. A no-op
/// when the host isn't being traced, so the cost in normal runs is one
/// virtual call per region.
///
/// `nonisolated` so the project's default `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` doesn't force every callee that emits a signpost onto main —
/// these are cross-actor instrumentation hooks by definition.
nonisolated enum Signposts {
    /// All four signposters use the special `PointsOfInterest` category so the
    /// Time Profiler template (and any template that includes the POI track)
    /// auto-captures them. Without this, xctrace's `Time Profiler` template
    /// drops custom-category signposts entirely and the POI track is empty.
    /// Distinct *subsystems* are kept so Instruments' subsystem filter still
    /// separates feed / engagement / render / media regions.
    private static let poiCategory = "PointsOfInterest"

    /// Feed pipeline regions: live-event debounced flush, viewport debounce
    /// fan-out, engagement subscription open, repost consolidation.
    static let feed = OSSignposter(subsystem: "app.wisp.feed", category: poiCategory)

    /// Engagement actor / repository regions: per-relay batch routing,
    /// processor flush, optimistic apply.
    static let engagement = OSSignposter(subsystem: "app.wisp.engagement", category: poiCategory)

    /// Rich-content rendering: parse cache miss, AttributedString rebuild,
    /// link-preview fetch.
    static let render = OSSignposter(subsystem: "app.wisp.render", category: poiCategory)

    /// Image / media decode regions: animated GIF decode, static thumbnail
    /// decode, video poster generation.
    static let media = OSSignposter(subsystem: "app.wisp.media", category: poiCategory)
}

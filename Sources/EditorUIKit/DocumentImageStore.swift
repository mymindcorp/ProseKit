#if canImport(UIKit)
import UIKit
import ImageIO
import DocumentModel

/// Decoded, **display-sized** images for the two renderers.
///
/// Two things here decide whether a document full of photographs scrolls.
///
/// The bitmap handed to `draw(in:)` is downsampled to the box it is actually
/// drawn in, so Core Graphics resamples a few hundred thousand pixels per frame
/// instead of the twelve million in a phone photo. And it is decoded up front —
/// off the main thread whenever the bytes come from a URL — because
/// `UIImage(data:)` does not decode: it defers that to the first `draw(in:)`,
/// which is a frame the reader is scrolling.
///
/// The downsampled image deliberately keeps the **natural point size** of the
/// original in `UIImage.size`. Layout measures an image's box from it
/// (`DocumentLayout.imageDisplaySize`), so shrinking the backing bitmap must not
/// shrink the picture; `UIImage.scale` absorbs the difference instead. That also
/// makes re-decoding at a larger size (a rotation, a split-view resize) purely a
/// question of sharpness — it can never move anything.
@MainActor
final class DocumentImageStore {
    /// The host's raw-bytes hook, consulted before any URL.
    var dataProvider: ImageDataProvider?
    /// The host's node → URL hook.
    var urlResolver: ImageURLResolver?
    /// The width of the content column. Layout caps every image to it, so it
    /// fixes the most pixels any of them can need.
    var maxPointWidth: CGFloat = 0
    /// The screen scale to decode for.
    var displayScale: CGFloat = 2
    /// Called (on the main actor, coalesced to one call per turn of the run
    /// loop) when images become drawable. `srcs` are the sources that arrived
    /// and `inline` is true if any of them sits inside a paragraph — the caller
    /// needs that to know whether typeset blocks have to be dropped.
    var onLoaded: ((_ srcs: Set<String>, _ inline: Bool) -> Void)?

    /// The budget for decoded bitmaps. Roughly a dozen full-width photographs on
    /// a phone; past it the least recently laid-out are dropped, and re-loaded
    /// if the reader scrolls back to them.
    ///
    /// Dropping an entry does not disturb what is on screen: a laid-out
    /// decoration holds its own reference to the image, so the pictures being
    /// *presented* stay alive for exactly as long as they are presented, and it
    /// is the ones that aren't that this reclaims.
    var byteBudget = 24 * 1024 * 1024

    /// Host bytes are keyed by node (the hook sees the whole node, and two nodes
    /// with the same `src` may legitimately resolve differently); loaded URLs are
    /// keyed by `src`, which is what the loader deduplicates on.
    private enum Key: Hashable {
        case host(Node)
        case url(String)
    }
    private struct Entry {
        let image: UIImage
        /// The content width this bitmap was decoded for. A wider column later
        /// (rotation) makes it stale — usable, but soft.
        let decodedForWidth: CGFloat
        let cost: Int
        var used: Int
    }
    private var entries: [Key: Entry] = [:]
    private var totalCost = 0
    private var clock = 0
    /// In-flight decodes, so a re-decode at a new width isn't started twice.
    private var refreshing: Set<Key> = []
    private let loads: ImageLoadTasks

    /// `loads` is owned by the view so that its `deinit` — which is not
    /// main-actor isolated — can still cancel what is in flight.
    init(loads: ImageLoadTasks) {
        self.loads = loads
    }

    // MARK: - Resolving

    /// The drawable for an image node, or nil to draw a placeholder (the layout
    /// records the node, and `load(_:)` fetches it).
    func image(for node: Node) -> UIImage? {
        if let image = use(.host(node)) { return image }
        // The host hook is synchronous by contract — callers expect bytes it
        // already has to show up in the very next layout — so this decode is not
        // deferred to a task. It is a *downsample*, though: the work is bounded
        // by the box the image draws in, not by the size of the file.
        if let data = dataProvider?(node) {
            guard let image = decodeDownsampledImage(data, maxPointWidth: maxPointWidth, displayScale: displayScale)
            else { return nil }
            store(image, for: .host(node))
            return image
        }
        return use(.url(src(of: node)))
    }

    /// Fetch the images a layout pass couldn't draw. Idempotent: a source
    /// already cached or already in flight is skipped.
    func load(_ nodes: [Node]) {
        for node in nodes {
            let src = src(of: node)
            guard !src.isEmpty, entries[.url(src)] == nil, !loads.contains(src),
                  let url = resolveImageURL(node, resolver: urlResolver) else { continue }
            let inline = node.type.spec.inline
            let width = maxPointWidth
            let scale = displayScale
            // Kept so a re-decode at a wider column can ask the host to resolve
            // the URL again — the resolver sees the whole node, not just `src`.
            refreshNodes[src] = node
            loads.start(src) { [weak self] in
                let image = await loadDownsampledImage(from: url, maxPointWidth: width, displayScale: scale)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.loads.finish(src)
                    guard let image else { return }
                    self.store(image, for: .url(src), decodedForWidth: width)
                    self.noteLoaded(src, inline: inline)
                }
            }
        }
    }

    // MARK: - Disposal

    /// Drop everything the document no longer refers to, and cancel any load
    /// still running for it — an image deleted (or edited away) while its bytes
    /// were in the air is work nobody is waiting for.
    ///
    /// Cheap to call on every document change: it walks the document once, and
    /// only when there is something to prune.
    func prune(keeping doc: Node) {
        guard !entries.isEmpty || !loads.isEmpty else { return }
        var nodes: Set<Node> = []
        var srcs: Set<String> = []
        func note(_ node: Node) {
            nodes.insert(node)
            srcs.insert(src(of: node))
        }
        if doc.isImage { note(doc) }
        doc.descendants { node, _, _, _ in
            if node.isImage { note(node) }
            return true
        }
        for (key, entry) in entries {
            switch key {
            case let .host(node) where nodes.contains(node): continue
            case let .url(src) where srcs.contains(src): continue
            default: totalCost -= entry.cost; entries[key] = nil
            }
        }
        refreshNodes = refreshNodes.filter { srcs.contains($0.key) }
        loads.cancel { !srcs.contains($0) }
    }

    /// Re-ask the host for every set of bytes it has already given us.
    func reloadHostImages() {
        for (key, entry) in entries {
            guard case .host = key else { continue }
            totalCost -= entry.cost
            entries[key] = nil
        }
        refreshing = refreshing.filter { if case .host = $0 { return false } else { return true } }
    }

    /// Drop every decoded bitmap and cancel every load — a memory warning, or a
    /// view that has left the screen. What is currently laid out survives (the
    /// decorations hold it); everything else is reclaimed.
    func purge() {
        entries.removeAll()
        refreshNodes.removeAll()
        totalCost = 0
        refreshing.removeAll()
        loads.cancelAll()
    }

    /// Test hooks: how much is resident.
    var debugEntryCount: Int { entries.count }
    var debugByteCost: Int { totalCost }
    var debugHasLoadsInFlight: Bool { !loads.isEmpty }

    // MARK: - Cache mechanics

    private func src(of node: Node) -> String { node.attrs["src"]?.stringValue ?? "" }

    /// The cached image for `key`, touched for LRU purposes — and re-decoded in
    /// the background if the column has grown wider than it was decoded for.
    private func use(_ key: Key) -> UIImage? {
        guard var entry = entries[key] else { return nil }
        clock += 1
        entry.used = clock
        entries[key] = entry
        if entry.decodedForWidth + 0.5 < maxPointWidth { refresh(key) }
        return entry.image
    }

    private func store(_ image: UIImage, for key: Key, decodedForWidth: CGFloat? = nil) {
        clock += 1
        let cost = Self.cost(of: image)
        if let previous = entries[key] { totalCost -= previous.cost }
        entries[key] = Entry(image: image, decodedForWidth: decodedForWidth ?? maxPointWidth,
                             cost: cost, used: clock)
        totalCost += cost
        evictIfOverBudget()
    }

    private func evictIfOverBudget() {
        guard totalCost > byteBudget else { return }
        for (key, entry) in entries.sorted(by: { $0.value.used < $1.value.used }) {
            guard totalCost > byteBudget else { return }
            totalCost -= entry.cost
            entries[key] = nil
        }
    }

    /// Decode again at the current width. The stale bitmap keeps drawing until
    /// it lands — it is the right *size*, just short of pixels — so nothing
    /// flickers and nothing reflows.
    private func refresh(_ key: Key) {
        guard !refreshing.contains(key) else { return }
        let width = maxPointWidth
        let scale = displayScale
        switch key {
        case let .host(node):
            guard let data = dataProvider?(node) else { return }
            refreshing.insert(key)
            Task { [weak self] in
                let image = await decodeOffMainActor(data, maxPointWidth: width, displayScale: scale)
                guard let self else { return }
                self.refreshing.remove(key)
                guard let image else { return }
                self.store(image, for: key, decodedForWidth: width)
                let src = self.src(of: node)
                if !src.isEmpty { self.noteLoaded(src, inline: node.type.spec.inline) }
            }
        case let .url(src):
            guard !loads.contains(src), let node = refreshNodes[src],
                  let url = resolveImageURL(node, resolver: urlResolver) else { return }
            refreshing.insert(key)
            loads.start(src) { [weak self] in
                let image = await loadDownsampledImage(from: url, maxPointWidth: width, displayScale: scale)
                await MainActor.run {
                    guard let self else { return }
                    self.loads.finish(src)
                    self.refreshing.remove(key)
                    guard let image else { return }
                    self.store(image, for: key, decodedForWidth: width)
                    self.noteLoaded(src, inline: node.type.spec.inline)
                }
            }
        }
    }

    /// The node each loaded `src` came from, so a re-decode can resolve its URL
    /// again (the host resolver sees the whole node, not just the source).
    private var refreshNodes: [String: Node] = [:]

    private static func cost(of image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        return cg.bytesPerRow * cg.height
    }

    // MARK: - Coalesced notification

    private var loadedSrcs: Set<String> = []
    private var loadedInline = false
    private var flushScheduled = false

    /// Several images finishing in the same turn of the run loop are one
    /// relayout, not one each.
    private func noteLoaded(_ src: String, inline: Bool) {
        loadedSrcs.insert(src)
        loadedInline = loadedInline || inline
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            let srcs = self.loadedSrcs
            let inline = self.loadedInline
            self.loadedSrcs = []
            self.loadedInline = false
            guard !srcs.isEmpty else { return }
            self.onLoaded?(srcs, inline)
        }
    }
}
#endif

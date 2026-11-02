#if canImport(UIKit)
public import UIKit
import DocumentModel
public import EditorCommands
public import SchemaKit

/// An open suggestion menu — the `/` slash menu, `[[` wiki links, `@` mentions —
/// handed to a `SuggestionMenuPresenter`, which takes full control of it: what
/// it looks like, how its keys behave, and what choosing does.
///
/// One object lives for as long as the menu stays open: typing more of the
/// query, the highlight moving and the view scrolling all update it in place and
/// present it again, so a presenter can hold on to it and diff (`changes` says
/// what moved). A menu opened afresh is a new object.
@MainActor
public final class SuggestionMenu {
    /// What changed since the menu was last presented.
    public struct Changes: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        /// The menu just opened: everything is new.
        public static let opened = Changes(rawValue: 1 << 0)
        public static let query = Changes(rawValue: 1 << 1)
        public static let entries = Changes(rawValue: 1 << 2)
        public static let highlight = Changes(rawValue: 1 << 3)
        public static let loading = Changes(rawValue: 1 << 4)
    }

    /// Which end of the typed text the menu hangs from.
    public enum Anchor: Sendable {
        /// The trigger's start — the `/` or the `[[` — on the caret's line, so
        /// the menu stays put while the query is typed (the default). Once the
        /// query wraps onto another line, the caret, so the menu doesn't cover
        /// what's being typed.
        case trigger
        /// The caret, at the end of the query: the menu follows the typing.
        case caret
    }

    /// Which side of the anchor the menu goes.
    public enum Position: Sendable {
        /// Below if it fits, else above if it fits — within the text view's
        /// visible area first, then the window's, clear of the keyboard — and
        /// otherwise the roomier side, shortened to fit (the default).
        case auto
        /// Always below, shortened to the room there if need be.
        case below
        /// Always above, likewise.
        case above
    }

    /// The side the editor actually put the menu on.
    public enum Placement: Sendable {
        case below, above
    }

    /// What opened the menu: `"/"`, `"[["`, `"@"`, or a custom source's own.
    public let trigger: String
    /// The source behind the menu, for a presenter that wants the raw rows
    /// rather than the editor's filtered ones: `source.entries("", editor)` is
    /// everything the slash menu offers, for instance, to filter and rank its
    /// own way. Rows it returns apply over this menu's range while it's open.
    public let source: any SuggestionSource
    /// The text typed after the trigger.
    public internal(set) var query: String
    /// Where the trigger starts in the document, and where the query ends (the
    /// caret). `replaceQuery(with:)` replaces this range.
    public let from: Int
    public internal(set) var to: Int
    /// The source's rows for `query`, filtered and in order — what the built-in
    /// popup would have shown. A
    /// presenter may draw them, reorder them, or ignore them and act through
    /// `replaceQuery(with:)` instead. Empty only for a presenter whose
    /// `presentsEmptyMenus` is true.
    public internal(set) var entries: [SuggestionEntry]
    /// The row Return and Tab choose when the presenter leaves those keys to
    /// the editor. The arrow keys move it too, unless the presenter handles
    /// them; a presenter may also set it itself, following the pointer say.
    public var highlightedIndex: Int
    /// Whether an asynchronous source is still fetching results for `query`,
    /// so `entries` are the previous query's, or none yet: "searching", not
    /// "no results".
    public internal(set) var isLoading: Bool
    /// The caret at the end of the query, and the start of the trigger — the
    /// menu's origin point — both in the text view's coordinates.
    public internal(set) var caretRect: CGRect
    public internal(set) var originRect: CGRect
    /// What changed since the last `present`.
    public internal(set) var changes: Changes = .opened

    /// Where the menu hangs from, and which side of it it goes. Set them in
    /// `present`; the editor reads them when it places the view.
    public var anchor: Anchor = .trigger
    public var position: Position = .auto
    /// The rect the menu is anchored to, per `anchor`, in the text view's
    /// coordinates.
    public internal(set) var anchorRect: CGRect = .zero
    /// The frame the editor gave the presenter's view, in
    /// `EditorTextView.overlayHost`'s coordinates, and the side it resolved
    /// to. Its height can be less than the view asked for, when neither side
    /// has room: the view should scroll. Current as of `didPlace`.
    public internal(set) var frame: CGRect = .zero
    public internal(set) var placement: Placement = .below
    /// The text view showing the menu, and its editor — for running commands,
    /// reading the document, or anything else a presenter needs.
    public internal(set) weak var textView: EditorTextView?
    public var editor: Editor? { textView?.editor }

    /// The document the entries and range were taken from.
    var doc: Node

    init(context: SuggestionContext, source: any SuggestionSource, entries: [SuggestionEntry], isLoading: Bool,
         caretRect: CGRect, originRect: CGRect, textView: EditorTextView) {
        self.trigger = context.trigger
        self.source = source
        self.query = context.query
        self.from = context.from
        self.to = context.to
        self.entries = entries
        self.highlightedIndex = 0
        self.isLoading = isLoading
        self.caretRect = caretRect
        self.originRect = originRect
        self.textView = textView
        self.doc = textView.editor.doc
    }

    /// Run the row's own action and close the menu. Still works after the menu
    /// has closed — a tap that moved the caret on its way in closes it first —
    /// provided the document hasn't changed since: a row never edits text it
    /// wasn't built for.
    public func choose(_ index: Int) {
        guard entries.indices.contains(index), let textView else { return }
        textView.choose(index, in: self)
    }

    /// Remove the trigger and query (`from`..<`to`), run `command` where they
    /// were, and close the menu — the presenter's own action, rather than a
    /// row's. For a `[[` menu, `insertWikiLink(text:targetId:targetType:)`
    /// links to a target of its choosing. Nothing changes unless the command
    /// runs, and nothing runs once the document has changed since the menu was
    /// presented. Like `choose`, it still works after a tap closed the menu.
    @discardableResult
    public func replaceQuery(with command: @escaping Command) -> Bool {
        guard let textView, textView.editor.doc == doc else { return false }
        return textView.replaceQuery(of: self, with: command)
    }

    /// Close the menu without choosing, as Escape does. The typed query stays,
    /// and the menu stays closed while the caret is still in it: it opens
    /// again only for a new trigger, or once the caret has left this one.
    public func dismiss() {
        textView?.dismissSuggestions(self)
    }

    /// The presenter's view wants a different size — its own content changed,
    /// outside a `present` — so measure and place it again.
    public func invalidateSize() {
        textView?.placePresentedMenu(self, remeasure: true)
    }
}

/// A key the editor offers a presenter before acting on it itself.
public enum SuggestionMenuKey: Sendable {
    case up, down, left, right
    /// Return, from a hardware or the on-screen keyboard.
    case enter
    case tab
    case escape
}

/// Takes full control of suggestion menus in place of the editor's built-in
/// popup. Set one on `EditorTextView.suggestionPresenter`.
///
/// The presenter decides what's drawn, how keys move through it, and what
/// choosing does: draw `entries` or anything else, and act with `choose(_:)`,
/// `replaceQuery(with:)`, or the `editor` directly. The editor decides when a
/// menu opens and closes, tracks the query, offers the presenter every key
/// first, and positions the presenter's view: it adds it above everything
/// (`overlayHost`), measures it, hangs it from `menu.anchor` on the side
/// `menu.position` asks for — flipping on `.auto` by the view's height and the
/// room in the text view's visible area and the window — keeps it clear of the
/// keyboard and moves with it, follows scrolling, and removes it on close.
///
/// The events, in order: `present` when a menu opens and whenever it changes
/// (`menu.changes`), `didPlace` each time the view is positioned (`menu.frame`,
/// `menu.placement`, `menu.anchorRect`), `handleKey` for each key while it's
/// open, and `close` once when it closes — however that happens: a choice,
/// Escape, the caret leaving the query, `menu.dismiss()`, or the presenter
/// being replaced.
///
/// A UIKit or SwiftUI view works equally well; for SwiftUI, return a
/// `UIHostingController`'s view.
@MainActor
public protocol SuggestionMenuPresenter: AnyObject {
    /// The view to show for `menu`, brought up to date with it. Called when a
    /// menu opens and whenever `menu.changes` is non-empty; return the same
    /// view each time to keep it, or another to swap. Set `menu.anchor` and
    /// `menu.position` here to change where it goes.
    ///
    /// Return nil to let the editor draw its built-in popup for this one — to
    /// take over only the slash menu, say, by checking `menu.trigger`.
    func present(_ menu: SuggestionMenu, in textView: EditorTextView) -> UIView?
    /// The size `view` wants for `menu`, no wider than `maxWidth`. The default
    /// asks Auto Layout for the smallest size that fits, which suits UIKit
    /// views and hosting views of content that sizes itself; a view that
    /// scrolls should give its content's size here instead.
    func preferredSize(for menu: SuggestionMenu, of view: UIView, maxWidth: CGFloat) -> CGSize
    /// The view was positioned: on opening, after each `present`, and as the
    /// text scrolls or the keyboard moves. `menu.frame`, `menu.placement` and
    /// `menu.anchorRect` say where. Called inside the keyboard's animation
    /// when it is the keyboard that moved.
    func didPlace(_ menu: SuggestionMenu, in textView: EditorTextView)
    /// A key pressed while `menu` is open, before the editor acts on it.
    /// Return true if you handled it; false (the default) leaves it to the
    /// editor, which moves `highlightedIndex` on up and down and presents
    /// again, chooses the highlighted row on Return and Tab, closes on Escape,
    /// and otherwise treats the key as typing in the document.
    func handleKey(_ key: SuggestionMenuKey, in menu: SuggestionMenu) -> Bool
    /// Whether to keep presenting a menu whose query matches nothing, with
    /// empty `entries`, so it can say "No results" (or, with `isLoading`,
    /// "Searching…"). False (the default) closes the menu instead, as the
    /// built-in popup does. With nothing to choose, keys the presenter doesn't
    /// handle go to the document as usual; Escape still closes.
    var presentsEmptyMenus: Bool { get }
    /// `menu` has closed. The editor has already taken its view down; let go of
    /// anything else that showed it. Called once for each menu this presenter
    /// accepted, however it closed.
    func close(_ menu: SuggestionMenu, in textView: EditorTextView)
}

public extension SuggestionMenuPresenter {
    func handleKey(_ key: SuggestionMenuKey, in menu: SuggestionMenu) -> Bool { false }
    var presentsEmptyMenus: Bool { false }
    func didPlace(_ menu: SuggestionMenu, in textView: EditorTextView) {}
    func preferredSize(for menu: SuggestionMenu, of view: UIView, maxWidth: CGFloat) -> CGSize {
        let fitted = view.systemLayoutSizeFitting(
            CGSize(width: maxWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .fittingSizeLevel, verticalFittingPriority: .fittingSizeLevel)
        return CGSize(width: min(fitted.width, maxWidth), height: fitted.height)
    }
}
#endif

#if canImport(UIKit)
public import UIKit
public import SchemaKit

/// An open suggestion menu — the `/` slash menu, `[[` wiki links, `@` mentions —
/// handed to a `SuggestionMenuPresenter` to draw however it likes.
///
/// One object lives for as long as the menu stays open: typing more of the
/// query, the highlight moving and the view scrolling all update it in place and
/// present it again, so a presenter can hold on to it and diff. A menu opened
/// afresh is a new object.
@MainActor
public final class SuggestionMenu {
    /// What opened the menu: `"/"`, `"[["`, `"@"`, or a custom source's own.
    public let trigger: String
    /// The text typed after the trigger.
    public internal(set) var query: String
    /// The rows, in order. Each carries its id, title, subtitle, icon, section
    /// and metadata. Empty only for a presenter whose `presentsEmptyMenus` is true.
    public internal(set) var entries: [SuggestionEntry]
    /// The row Return and Tab choose. The arrow keys move it and present the
    /// menu again; a presenter may move it too, following the pointer say.
    public var highlightedIndex: Int
    /// The caret at the end of the query, in the text view's coordinates.
    /// Pass it to `EditorTextView.placeOverlay` to sit a view where the
    /// built-in popup would, clear of the keyboard; the frame it returns may be
    /// shorter than you asked for, so be ready to scroll.
    public internal(set) var caretRect: CGRect

    /// Where the trigger starts: with `trigger`, what makes this the same menu.
    let from: Int
    weak var textView: EditorTextView?

    init(context: SuggestionContext, entries: [SuggestionEntry], caretRect: CGRect, textView: EditorTextView) {
        self.trigger = context.trigger
        self.query = context.query
        self.from = context.from
        self.entries = entries
        self.highlightedIndex = 0
        self.caretRect = caretRect
        self.textView = textView
    }

    /// Run the row's action and close the menu. Still works after the menu
    /// has closed — a tap that moved the caret on its way in closes it first —
    /// provided the document hasn't changed since: a row never edits text it
    /// wasn't built for.
    public func choose(_ index: Int) {
        guard entries.indices.contains(index), let textView else { return }
        textView.choose(index, in: self)
    }

    /// Close the menu without choosing, as Escape does. The typed query stays.
    public func dismiss() {
        textView?.dismissSuggestions(self)
    }
}

/// Draws suggestion menus in place of the editor's built-in popup. Set one on
/// `EditorTextView.suggestionPresenter`.
///
/// The editor still decides when a menu is open and what is in it, and still
/// handles the hardware keyboard: the arrow keys move `highlightedIndex`, Return
/// and Tab choose, Escape closes. The presenter owns everything on screen.
///
/// A UIKit or SwiftUI view works equally well; for SwiftUI, host it in a
/// `UIHostingController` and place its view. Add it to
/// `EditorTextView.overlayHost` (as `placeOverlay` does) so a scroll view can't
/// clip it, and keep it out of the text view's own hierarchy: a touch that
/// reaches the text view moves the caret, which closes the menu.
@MainActor
public protocol SuggestionMenuPresenter: AnyObject {
    /// Show `menu`, or bring what's on screen up to date with it. Called when
    /// a menu opens, when its query, rows or highlight change, and on every
    /// scroll tick and keyboard move while it's open (only `caretRect` or the
    /// room around it changes then), so keep it cheap.
    ///
    /// Return false to let the editor draw its built-in popup for this one —
    /// to take over only the slash menu, say, by checking `menu.trigger`.
    func present(_ menu: SuggestionMenu, in textView: EditorTextView) -> Bool
    /// Whether to keep presenting a menu whose query matches nothing, with
    /// empty `entries`, so it can say "No results". False (the default) closes
    /// the menu instead, as the built-in popup does. With nothing to choose,
    /// the arrow keys, Return and Tab go to the document as usual; Escape still
    /// closes. A source fetching asynchronously looks the same until its results
    /// arrive, so an empty menu can mean "still loading".
    var presentsEmptyMenus: Bool { get }
    /// Take down the menu last presented. Called once when a menu this
    /// presenter accepted closes, however it closed.
    func dismissSuggestions(in textView: EditorTextView)
}

public extension SuggestionMenuPresenter {
    var presentsEmptyMenus: Bool { false }
}
#endif

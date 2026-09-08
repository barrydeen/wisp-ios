import Foundation
import Testing
@testable import wisp

/// Filters for a long-form article's comment thread.
///
/// NIP-22 requires replies to a kind-30023 article to be kind 1111, and puts
/// the *root* scope in uppercase tags with the immediate parent in lowercase.
/// The article view subscribed to kind 1 on lowercase tags only, so it showed
/// almost none of a thread the web renders in full — including comments Wisp
/// itself had published.
struct ArticleCommentFilterTests {

    private let coordinate = "30023:ee6ea13ab9fe5c4a68eaf9b1a34fe014a66b40117c50ee2a614f4cda959b6e74:nostr-forever"

    private func json(_ filter: NostrFilter) -> [String: Any] {
        let data = filter.toJSON().data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    // MARK: - Uppercase tags reach the wire

    /// `#A` is what returns a whole thread. Without it the filter can only ask
    /// for comments attached directly to the article.
    @Test func capitalATagSerializes() {
        var f = NostrFilter()
        f.capitalATags = [coordinate]
        #expect(json(f)["#A"] as? [String] == [coordinate])
    }

    @Test func capitalETagSerializes() {
        var f = NostrFilter()
        f.capitalETags = ["abc123"]
        #expect(json(f)["#E"] as? [String] == ["abc123"])
    }

    /// Uppercase and lowercase are different scopes and must not collide:
    /// `#a` is the parent, `#A` the root.
    @Test func lowercaseAndUppercaseAreDistinct() {
        var f = NostrFilter()
        f.aTags = ["parent-coordinate"]
        f.capitalATags = [coordinate]
        let dict = json(f)
        #expect(dict["#a"] as? [String] == ["parent-coordinate"])
        #expect(dict["#A"] as? [String] == [coordinate])
    }

    /// Unset uppercase tags stay out of the filter entirely — an empty `#A`
    /// would narrow every other subscription to nothing.
    @Test func unsetUppercaseTagsAreOmitted() {
        var f = NostrFilter()
        f.kinds = [1, Nip22.kindComment]
        let dict = json(f)
        #expect(dict["#A"] == nil)
        #expect(dict["#E"] == nil)
    }

    // MARK: - Comment kinds

    /// Kind 1 stays for older clients that replied with a plain note.
    @Test func commentKindsCoverBothConventions() {
        var f = NostrFilter()
        f.kinds = [1, Nip22.kindComment]
        let kinds = json(f)["kinds"] as? [Int]
        #expect(kinds?.contains(1) == true)
        #expect(kinds?.contains(1111) == true)
    }

    @Test func nip22CommentKindIs1111() {
        #expect(Nip22.kindComment == 1111)
    }
}

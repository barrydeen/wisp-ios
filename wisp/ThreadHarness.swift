import Foundation

#if DEBUG
/// Launch-argument harness: launch with `-ThreadHarnessSeed <event id>` (and
/// optionally `-ThreadHarnessAuthor <pubkey>`, the same `authorHint` a
/// `ThreadRoute` carries) to push the thread screen at launch. Exists so
/// relay-driven verification of `ThreadViewModel` on the simulator needs no
/// UI driving. No-op without the launch argument.
enum ThreadHarness {
    static var seedEventId: String? { value(of: "-ThreadHarnessSeed") }
    static var authorHint: String? { value(of: "-ThreadHarnessAuthor") }

    private static func value(of flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
#endif

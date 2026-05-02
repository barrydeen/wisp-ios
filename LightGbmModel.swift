import Foundation

/// Pure-Swift port of LightGBM's text-format model file. Mirrors Android's
/// `com.wisp.app.ml.LightGbmModel`. Each tree is a flat array of nodes; positive node indices
/// point to the next split, negative indices mean "leaf at index `-node - 1`".
nonisolated final class LightGbmModel: @unchecked Sendable {
    struct Tree: Sendable {
        let splitFeature: [Int32]
        let threshold: [Float]
        let leftChild: [Int32]
        let rightChild: [Int32]
        let leafValue: [Float]
    }

    let trees: [Tree]

    init(trees: [Tree]) {
        self.trees = trees
    }

    /// Sum of leaf values across the forest. Caller applies sigmoid + calibration.
    func rawMargin(features: [Float]) -> Double {
        var sum: Double = 0.0
        let nFeatures = features.count
        for t in trees {
            var node: Int32 = 0
            while node >= 0 {
                let i = Int(node)
                let idx = Int(t.splitFeature[i])
                let x: Float = idx < nFeatures ? features[idx] : 0
                node = x <= t.threshold[i] ? t.leftChild[i] : t.rightChild[i]
            }
            sum += Double(t.leafValue[Int(-node - 1)])
        }
        return sum
    }

    enum LoadError: Error {
        case invalidUTF8
        case missingField(String)
    }

    static func parse(data: Data) throws -> LightGbmModel {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LoadError.invalidUTF8
        }
        return try parse(text: text)
    }

    /// Streamed-line parser. Reads only `Tree=...` blocks and the five fields we need;
    /// every other line in the LightGBM text format is ignored.
    static func parse(text: String) throws -> LightGbmModel {
        var trees: [Tree] = []
        trees.reserveCapacity(512)
        var current: [String: String] = [:]
        var inTree = false

        // Split-by-newlines is enough — model.txt uses LF and the line count fits comfortably.
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" }) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Tree=") {
                if inTree {
                    trees.append(try buildTree(current))
                }
                current.removeAll(keepingCapacity: true)
                inTree = true
            } else if line == "end of trees" {
                if inTree {
                    trees.append(try buildTree(current))
                    inTree = false
                }
                break
            } else if inTree {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq])
                if Self.treeFields.contains(key) {
                    current[key] = String(line[line.index(after: eq)...])
                }
            }
        }
        if inTree { trees.append(try buildTree(current)) }
        return LightGbmModel(trees: trees)
    }

    private static let treeFields: Set<String> = [
        "split_feature", "threshold", "left_child", "right_child", "leaf_value"
    ]

    private static func buildTree(_ f: [String: String]) throws -> Tree {
        guard let sf = f["split_feature"] else { throw LoadError.missingField("split_feature") }
        guard let th = f["threshold"] else { throw LoadError.missingField("threshold") }
        guard let lc = f["left_child"] else { throw LoadError.missingField("left_child") }
        guard let rc = f["right_child"] else { throw LoadError.missingField("right_child") }
        guard let lv = f["leaf_value"] else { throw LoadError.missingField("leaf_value") }
        return Tree(
            splitFeature: parseInts(sf),
            threshold: parseFloats(th),
            leftChild: parseInts(lc),
            rightChild: parseInts(rc),
            leafValue: parseFloats(lv)
        )
    }

    private static func parseInts(_ s: String) -> [Int32] {
        var out: [Int32] = []
        out.reserveCapacity(s.count / 2)
        for part in s.split(separator: " ", omittingEmptySubsequences: true) {
            if let v = Int32(part) { out.append(v) }
        }
        return out
    }

    private static func parseFloats(_ s: String) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(s.count / 4)
        for part in s.split(separator: " ", omittingEmptySubsequences: true) {
            if let v = Float(part) { out.append(v) }
        }
        return out
    }
}

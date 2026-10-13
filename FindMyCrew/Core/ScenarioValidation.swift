import CryptoKit
import Foundation

/// Shared, testable checks used by the labelled end-to-end benchmark.
enum ScenarioValidation {
    struct Expectations: Decodable {
        var mustSkipUnreadable: [String] = []
        var mustNotEnumerate: [String] = []
        var sidecars: [String] = []
        var rawPairs: [String] = []
        var duplicates: [String] = []

        enum CodingKeys: String, CodingKey {
            case mustSkipUnreadable = "must_skip_unreadable", mustNotEnumerate = "must_not_enumerate"
            case sidecars, rawPairs = "raw_pairs", duplicates
        }
    }

    static func excludedFromAccuracy(_ label: String) -> Bool {
        label == "#unreadable" || label == "#truncated"
    }

    static func accuracy(_ results: [PhotoResult], labels: [String: String], targets: Set<String>,
                         threshold: Float) -> (tp: Int, fp: Int, fn: Int, nearMiss: Int) {
        let matcher = Matcher(threshold: threshold)
        let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.item.relativePath, $0) })
        var tp = 0, fp = 0, fn = 0, near = 0
        for (path, label) in labels where !excludedFromAccuracy(label) {
            let positive = targets.contains(label)
            if let result = byPath[path], matcher.isMatch(result) {
                if positive { tp += 1 } else { fp += 1 }
            } else if positive {
                fn += 1
                if let result = byPath[path], matcher.isNearMiss(result) { near += 1 }
            }
        }
        return (tp, fp, fn, near)
    }

    static func scanProblems(items: [ScanItem], results: [PhotoResult], labels: [String: String],
                             expectations e: Expectations) -> [String] {
        let enumerated = Set(items.map(\.relativePath))
        let byPath = Dictionary(uniqueKeysWithValues: results.map { ($0.item.relativePath, $0) })
        var problems: [String] = []
        for path in enumerated {
            if labels[path] == nil { problems.append("unlabelled input: \(path)") }
            if e.mustNotEnumerate.contains(where: path.contains) { problems.append("forbidden enumeration: \(path)") }
            if byPath[path] == nil { problems.append("missing scan result: \(path)") }
        }
        for path in labels.keys where !enumerated.contains(path) {
            if !e.mustNotEnumerate.contains(where: path.contains) { problems.append("labelled input not enumerated: \(path)") }
        }
        for result in results where result.error != nil {
            let path = result.item.relativePath
            if !excludedFromAccuracy(labels[path] ?? "") && !e.mustSkipUnreadable.contains(path) {
                problems.append("unexpected unreadable input: \(path)")
            }
        }
        for path in e.mustSkipUnreadable where byPath[path]?.error == nil {
            problems.append("required unreadable skip absent: \(path)")
        }
        for path in e.rawPairs + e.duplicates where !enumerated.contains(path) {
            problems.append("required input not enumerated: \(path)")
        }
        return problems
    }

    /// Expected sidecars travel with selected photos sharing their directory and base name.
    static func sidecarProblems(selected: [ScanItem], operations: [CopyOperation], source: URL,
                                expectations: Expectations) -> [String] {
        let bases = Set(selected.map { ($0.relativePath as NSString).deletingPathExtension.lowercased() })
        let planned = Set(operations.map { FolderEnumerator.relativePath(of: $0.from, under: source) })
        return (expectations.sidecars + expectations.rawPairs).compactMap { path in
            guard bases.contains((path as NSString).deletingPathExtension.lowercased()), !planned.contains(path) else { return nil }
            return "missing selected sidecar: \(path)"
        }
    }

    static func digest(_ url: URL) throws -> Data {
        Data(SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)))
    }

    static func exportProblems(operations: [CopyOperation], summary: ExportSummary,
                               before: [URL: Data]) -> [String] {
        var problems = summary.failures.map { "\($0.path): \($0.message)" }
        if summary.cancelled { problems.append("export cancelled") }
        for op in operations {
            do {
                if try digest(op.from) != before[op.from] { problems.append("SOURCE MODIFIED: \(op.from.path)") }
                guard let output = summary.outputs.first(where: { $0.operation == op }) else {
                    problems.append("missing export output: \(op.to.path)"); continue
                }
                let actual = output.destination
                if try digest(actual) != before[op.from] { problems.append("content differs: \(actual.path)") }
                if !isDestination(actual, for: op) { problems.append("structure not preserved: \(actual.path)") }
                let a = try FileManager.default.attributesOfItem(atPath: op.from.path)[.modificationDate] as? Date
                let b = try FileManager.default.attributesOfItem(atPath: actual.path)[.modificationDate] as? Date
                if a != b { problems.append("modification date not preserved: \(actual.path)") }
            } catch { problems.append("verification failed for \(op.from.path): \(error.localizedDescription)") }
        }
        return problems
    }

    private static func isDestination(_ actual: URL, for op: CopyOperation) -> Bool {
        if actual == op.to { return true }
        guard actual.deletingLastPathComponent() == op.to.deletingLastPathComponent(),
              actual.pathExtension == op.to.pathExtension else { return false }
        let base = op.to.deletingPathExtension().lastPathComponent
        let stem = actual.deletingPathExtension().lastPathComponent
        let prefix = base + " ("
        guard stem.hasPrefix(prefix), stem.hasSuffix(")"),
              let number = Int(stem.dropFirst(prefix.count).dropLast()), number > 0 else { return false }
        return true
    }
}

import CoreGraphics
import Foundation

// fmc-eval — face verification benchmark for Find My Crew's pipeline.
//
//   fmc-eval <lfw-dir> --model <path.mlpackage|.mlmodelc> [--pairs pairs.txt] [--no-flip] [--resolution N]
//   fmc-eval scan …   end-to-end scan/review/export benchmark (see ScanBenchmark.swift)
//
// <lfw-dir> has one sub-folder per identity (LFW layout). If a standard LFW `pairs.txt` is found
// (next to <lfw-dir> or given with --pairs) the 6 000-pair protocol is used; otherwise random pairs.

struct Arguments {
    var root: URL
    var model: URL
    var pairs: URL?
    var flip = true
    var resolution = 2048
    var randomPairs = 3000

    static func parse() -> Arguments {
        var args = Array(CommandLine.arguments.dropFirst())
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            defer { args.removeSubrange(i...i + 1) }
            return args[i + 1]
        }
        let model = value("--model")
        let pairs = value("--pairs")
        let resolution = value("--resolution").flatMap(Int.init)
        let count = value("--random-pairs").flatMap(Int.init)
        let flip = !args.contains("--no-flip")
        args.removeAll { $0 == "--no-flip" }
        guard let rootPath = args.first, let model else {
            FileHandle.standardError.write(Data("usage: fmc-eval <lfw-dir> --model <model> [--pairs file] [--no-flip] [--resolution N]\n".utf8))
            exit(2)
        }
        let root = URL(filePath: rootPath)
        var a = Arguments(root: root, model: URL(filePath: model))
        a.pairs = pairs.map { URL(filePath: $0) } ?? {
            let candidate = root.deletingLastPathComponent().appending(path: "pairs.txt")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }()
        a.flip = flip
        if let resolution { a.resolution = resolution }
        if let count { a.randomPairs = count }
        return a
    }
}

struct Pair { var a: URL; var b: URL; var same: Bool }

func lfwPath(_ root: URL, _ name: String, _ n: Int) -> URL {
    root.appending(path: name).appending(path: String(format: "%@_%04d.jpg", name, n))
}

func loadPairs(_ file: URL, root: URL) throws -> [Pair] {
    let lines = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).dropFirst()
    return lines.compactMap { line in
        let f = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
        switch f.count {
        case 3: return Pair(a: lfwPath(root, f[0], Int(f[1])!), b: lfwPath(root, f[0], Int(f[2])!), same: true)
        case 4: return Pair(a: lfwPath(root, f[0], Int(f[1])!), b: lfwPath(root, f[2], Int(f[3])!), same: false)
        default: return nil
        }
    }
}

func randomPairs(root: URL, count: Int) throws -> [Pair] {
    var rng = SystemRandomNumberGenerator()
    let ids = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.hasDirectoryPath }
    let images = ids.map { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
    let multi = images.filter { $0.count >= 2 }
    var pairs: [Pair] = []
    for _ in 0..<count {
        let p = multi.randomElement(using: &rng)!.shuffled(using: &rng)
        pairs.append(Pair(a: p[0], b: p[1], same: true))
        let x = images.randomElement(using: &rng)!, y = images.randomElement(using: &rng)!
        if x.first?.deletingLastPathComponent() != y.first?.deletingLastPathComponent(),
           let xa = x.randomElement(), let yb = y.randomElement() {
            pairs.append(Pair(a: xa, b: yb, same: false))
        }
    }
    return pairs
}

/// The face closest to the image centre (LFW images are centred on the subject).
func centralFace(_ faces: [DetectedFace]) -> DetectedFace? {
    faces.min { a, b in
        func d(_ f: DetectedFace) -> CGFloat {
            let r = f.normalizedBox
            return hypot(r.midX - 0.5, r.midY - 0.5) - r.width * 0.5
        }
        return d(a) < d(b)
    }
}

func percentile(_ sorted: [Float], _ p: Double) -> Float {
    sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
}

if CommandLine.arguments.dropFirst().first == "scan" {
    let ok = try await ScanBenchmark.run(ScanBenchmark.parse(Array(CommandLine.arguments.dropFirst(2))))
    exit(ok ? 0 : 1)
}

let args = Arguments.parse()
let embedder = try await FaceEmbedder.load(modelAt: args.model, displayName: args.model.lastPathComponent)
var options = PipelineOptions()
options.flipAugmentation = args.flip
options.workingResolution = args.resolution
let pipeline = FacePipeline(embedder: embedder, options: options)

let pairs = try args.pairs.map { try loadPairs($0, root: args.root) } ?? randomPairs(root: args.root, count: args.randomPairs)
let uniqueImages = Array(Set(pairs.flatMap { [$0.a, $0.b] }))
print("Model: \(embedder.displayName)  dim=\(embedder.dimension)  input=\(embedder.inputSize)  default threshold=\(embedder.defaultThreshold)")
print("Pairs: \(pairs.count) (\(args.pairs != nil ? "LFW protocol" : "random"))  images: \(uniqueImages.count)  flipTTA=\(args.flip)")

// Embed every image with bounded concurrency.
let start = Date()
var embeddings: [URL: [Float]] = [:]
var noFace = 0
await withTaskGroup(of: (URL, [Float]?).self) { group in
    var it = uniqueImages.makeIterator()
    for _ in 0..<ProcessInfo.processInfo.activeProcessorCount {
        guard let url = it.next() else { break }
        group.addTask { (url, (try? await pipeline.process(url: url)).flatMap { centralFace($0.faces)?.embedding }) }
    }
    while let (url, e) = await group.next() {
        if let e { embeddings[url] = e } else { noFace += 1 }
        if (embeddings.count + noFace) % 1000 == 0 { print("  embedded \(embeddings.count + noFace)/\(uniqueImages.count)") }
        if let next = it.next() {
            group.addTask { (next, (try? await pipeline.process(url: next)).flatMap { centralFace($0.faces)?.embedding }) }
        }
    }
}
let elapsed = Date().timeIntervalSince(start)
print(String(format: "Throughput: %.1f images/s (%.1fs). No face detected: %d (%.2f%%)",
             Double(uniqueImages.count) / elapsed, elapsed, noFace, 100 * Double(noFace) / Double(uniqueImages.count)))

// Score pairs. A pair with a missing face counts as a non-match (score −1), as it would in the app.
var genuine: [Float] = [], impostor: [Float] = []
for p in pairs {
    let s: Float = if let a = embeddings[p.a], let b = embeddings[p.b] { Vector.dot(a, b) } else { -1 }
    if p.same { genuine.append(s) } else { impostor.append(s) }
}
genuine.sort(); impostor.sort()

@MainActor func tar(at threshold: Float) -> Double { Double(genuine.filter { $0 >= threshold }.count) / Double(genuine.count) }
@MainActor func far(at threshold: Float) -> Double { Double(impostor.filter { $0 >= threshold }.count) / Double(impostor.count) }

var best = (acc: 0.0, t: Float(0))
for t in stride(from: Float(-0.2), through: 0.9, by: 0.005) {
    let acc = (tar(at: t) * Double(genuine.count) + (1 - far(at: t)) * Double(impostor.count)) / Double(pairs.count)
    if acc > best.acc { best = (acc, t) }
}
print(String(format: "Genuine  mean %.3f  p5 %.3f | Impostor mean %.3f  p99 %.3f",
             genuine.reduce(0, +) / Float(genuine.count), percentile(genuine, 0.05),
             impostor.reduce(0, +) / Float(impostor.count), percentile(impostor, 0.99)))
print(String(format: "Best accuracy %.2f%% at threshold %.3f", best.acc * 100, best.t))
var tarAtFAR: [Double: Double] = [:]
for farTarget in [0.01, 0.001] {
    let t = percentile(impostor, 1 - farTarget) + 1e-6
    tarAtFAR[farTarget] = tar(at: t)
    print(String(format: "TAR @ FAR=%g: %.2f%% (threshold %.3f)", farTarget, tar(at: t) * 100, t))
}
let d = embedder.defaultThreshold
print(String(format: "At default threshold %.3f: TAR %.2f%%  FAR %.2f%%", d, tar(at: d) * 100, far(at: d) * 100))

// Acceptance (docs/plan/10-evaluation-tests.md, PRD §6): TAR ≥ 97 % at FAR = 1 %, and the measured
// best-accuracy threshold within ±0.05 of the model's shipped default.
let tarOK = (tarAtFAR[0.01] ?? 0) >= 0.97
let thresholdOK = abs(best.t - d) <= 0.05
print("Acceptance: TAR@FAR=1% ≥ 97%: \(tarOK ? "PASS" : "FAIL") · threshold within ±0.05 of default: \(thresholdOK ? "PASS" : "FAIL")")
if !(tarOK && thresholdOK) { exit(1) }

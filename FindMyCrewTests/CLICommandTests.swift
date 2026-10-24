import Foundation
import CoreGraphics
import Testing

private final class CLIBundleToken {}

/// Run the built CLI as a real process so parser exits, stdout, stderr and disk effects are covered.
private func runCLI(_ arguments: [String], executable: URL? = nil) throws -> (status: Int32, stdout: String, stderr: String) {
    let dir = try TempDir()
    let out = try dir.file("stdout", Data()), err = try dir.file("stderr", Data())
    let process = Process()
    process.executableURL = executable ?? Bundle(for: CLIBundleToken.self).bundleURL.deletingLastPathComponent().appending(path: "fmc")
    process.arguments = arguments
    let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
    defer { try? stdout.close(); try? stderr.close() }
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    return (process.terminationStatus, try String(contentsOf: out, encoding: .utf8), try String(contentsOf: err, encoding: .utf8))
}

@Suite(.serialized)
struct CLICommandTests {
    @discardableResult
    private func copy(_ fixture: String, to dir: TempDir, as name: String) throws -> URL {
        let url = try dir.file(name)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: Fixtures.url(fixture), to: url)
        return url
    }

    private func filterArguments(faces: URL, source: URL, output: URL) -> [String] {
        ["filter", "--faces", faces.path, "--source", source.path, "--output", output.path,
         "--model", Fixtures.modelURL.path]
    }

    @Test func extractDeduplicatesOverlapsAndRawJpegAndCanFeedFilter() throws {
        let dir = try TempDir()
        let jpeg = try copy("biden_2013.jpg", to: dir, as: "source/sub/photo.jpg")
        try dir.file("source/sub/photo.nef", Data("unreadable RAW should be skipped in favor of JPEG".utf8))
        let output = dir.url.appending(path: "faces")
        let extract = try runCLI(["extract", jpeg.path, jpeg.deletingLastPathComponent().path, jpeg.path,
                                  "-o", output.path, "--format", "png"])
        #expect(extract.status == 0, "\(extract.stderr)")
        #expect(extract.stderr.contains("1 faces from 1 photos"))
        #expect(try CLI.images(at: output).count == 1)
        let source = try dir.directory("search")
        let result = try runCLI(filterArguments(faces: output, source: source, output: dir.url.appending(path: "matches")) + ["--dry-run"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stderr.contains("1 reference faces"))
    }

    @Test func extractReportsFailuresAndRejectsInvalidArgumentsAndNestedOutput() throws {
        let dir = try TempDir()
        let jpeg = try copy("biden_2013.jpg", to: dir, as: "source/sub/photo.jpg")
        try dir.file("source/broken.jpg")
        let blank = try dir.file("source/blank.png")
        try TestImages.write(TestImages.make(width: 64, height: 64, left: TestImages.grey), to: blank, type: .png)
        let source = jpeg.deletingLastPathComponent().deletingLastPathComponent()
        let output = dir.url.appending(path: "faces")
        let failed = try runCLI(["extract", source.path, "-o", output.path, "--format", "png"])
        #expect(failed.status == 1, "\(failed.stderr)")
        #expect(failed.stderr.contains("1 faces from 1 photos") && failed.stderr.contains("1 failed"))
        #expect(failed.stderr.contains("1 photos had no faces"))
        #expect(try CLI.images(at: output).map(\.relativePath) == ["sub/photo_face1.png"])
        let invalid = try runCLI(["extract", jpeg.path, "-o", output.path, "--quality", "101"])
        #expect(invalid.status == 64)
        let nested = try runCLI(["extract", source.path, "-o", source.appending(path: "out").path])
        #expect(nested.status != 0)
    }

    @Test(arguments: ["dry-run", "no-match", "export"])
    func corruptSourcesFailEveryCompletionPath(_ mode: String) throws {
        let dir = try TempDir()
        let source = try dir.directory("source")
        try dir.file("source/broken.jpg")
        try copy("biden_2021.jpg", to: dir, as: "source/photo.jpg")
        let output = dir.url.appending(path: "out")
        var args = filterArguments(faces: Fixtures.url("biden_2013.jpg"), source: source, output: output)
        if mode == "dry-run" { args.append("--dry-run") }
        if mode == "no-match" { args += ["--threshold", "1"] }
        let result = try runCLI(args)
        #expect(result.status == 1, "\(result.stderr)")
        #expect(result.stderr.contains("1 unreadable"))
        if mode == "no-match" { #expect(result.stdout.isEmpty) }
        else { #expect(result.stdout.contains("\tphoto.jpg\tbiden_2013.jpg")) }
        #expect(FileManager.default.fileExists(atPath: output.appending(path: "photo.jpg").path) == (mode == "export"))
    }

    @Test(arguments: ["dry-run", "no-match", "export"])
    func mixedReferencesFailButRetainMatches(_ mode: String) throws {
        let dir = try TempDir()
        let refs = try dir.directory("refs"), source = try dir.directory("source")
        try copy("biden_2013.jpg", to: dir, as: "refs/good.jpg")
        try dir.file("refs/broken.jpg")
        let blank = try dir.file("refs/blank.png")
        try TestImages.write(TestImages.make(width: 64, height: 64, left: TestImages.grey), to: blank, type: .png)
        try copy("biden_2021.jpg", to: dir, as: "source/match.jpg")
        var args = filterArguments(faces: refs, source: source, output: dir.url.appending(path: "out"))
        if mode == "dry-run" { args.append("--dry-run") }
        if mode == "no-match" { args += ["--threshold", "1"] }
        let result = try runCLI(args)
        #expect(result.status == 1, "\(result.stderr)")
        #expect(result.stderr.contains("1 reference files failed"))
        #expect(result.stderr.contains("blank.png: no face found, skipped"))
        if mode == "no-match" { #expect(result.stdout.isEmpty) }
        else { #expect(result.stdout.contains("\tmatch.jpg\tgood.jpg")) }
    }

    @Test func completelyCorruptReferencesFailBeforeScanning() throws {
        let dir = try TempDir()
        let refs = try dir.file("broken.jpg"), source = try dir.directory("source")
        let result = try runCLI(filterArguments(faces: refs, source: source, output: dir.url.appending(path: "out")))
        #expect(result.status == 1)
        #expect(result.stderr.contains("1 reference files failed"))
        #expect(!result.stderr.contains("scanning"))
    }

    @Test func filterIndexesReferencesExcludesFacesAndCopiesSidecars() throws {
        let dir = try TempDir()
        let source = try dir.directory("source"), refs = try dir.directory("source/refs")
        try copy("harris_2021.jpg", to: dir, as: "source/refs/z-harris.jpg")
        try copy("biden_2013.jpg", to: dir, as: "source/refs/a-biden.jpg")
        try copy("obama_2012.jpg", to: dir, as: "source/refs/obama.jpg")
        try copy("apollo11_crew.jpg", to: dir, as: "source/refs/crew.jpg")
        try copy("biden_2021.jpg", to: dir, as: "source/sub/biden.jpg")
        try copy("harris_2021.jpg", to: dir, as: "source/sub/harris.jpg")
        let xmp = try dir.file("source/sub/biden.xmp", Data("sidecar".utf8))
        let output = dir.url.appending(path: "out")
        let args = filterArguments(faces: refs, source: source, output: output)
        let dry = try runCLI(args + ["--dry-run"])
        #expect(dry.status == 0, "\(dry.stderr)")
        #expect(dry.stderr.contains("4 reference faces") && dry.stderr.contains("scanning 2 photos"))
        #expect(dry.stdout.contains("\tsub/biden.jpg\ta-biden.jpg"))
        #expect(dry.stdout.contains("\tsub/harris.jpg\tz-harris.jpg"))
        let expectedThreshold = Matcher.defaultThreshold(model: PipelineTests.embedder.defaultThreshold, referenceCount: 4)
        #expect(dry.stderr.contains(String(format: "threshold %.3f", expectedThreshold)))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let copied = try runCLI(args)
        #expect(copied.status == 0, "\(copied.stderr)")
        #expect(copied.stdout == dry.stdout)
        #expect(try Data(contentsOf: output.appending(path: "sub/biden.xmp")) == Data(contentsOf: xmp))
        #expect(try Data(contentsOf: output.appending(path: "sub/biden.jpg")) == Data(contentsOf: source.appending(path: "sub/biden.jpg")))
        let repeated = try runCLI(args)
        #expect(repeated.status == 0 && repeated.stderr.contains("3 already there"))
        let noSidecars = dir.url.appending(path: "no-sidecars")
        let noSidecarResult = try runCLI(filterArguments(faces: refs, source: source, output: noSidecars) + ["--no-sidecars"])
        #expect(noSidecarResult.status == 0)
        #expect(!FileManager.default.fileExists(atPath: noSidecars.appending(path: "sub/biden.xmp").path))
    }

    @Test func copyFailuresExitUnsuccessfullyAfterPrintingMatches() throws {
        let dir = try TempDir()
        let source = try dir.directory("source")
        try copy("biden_2021.jpg", to: dir, as: "source/match.jpg")
        let output = try dir.file("out") // A file blocks creation of the output directory.
        let result = try runCLI(filterArguments(faces: Fixtures.url("biden_2013.jpg"), source: source, output: output))
        #expect(result.status == 1)
        #expect(result.stdout.contains("\tmatch.jpg\tbiden_2013.jpg"))
        #expect(result.stderr.contains("Copied 0 files") && result.stderr.contains("1 failed"))
    }

    @Test func symlinkedInstallFindsBundledModel() throws {
        let dir = try TempDir()
        let executable = Bundle(for: CLIBundleToken.self).bundleURL.deletingLastPathComponent().appending(path: "fmc")
        let alias = dir.url.appending(path: "fmc")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: executable)
        let source = try dir.directory("source")
        let result = try runCLI(["filter", "--faces", "/missing/references", "-s", source.path,
                                 "-o", dir.url.appending(path: "out").path], executable: alias)
        #expect(result.status == 64)
        #expect(result.stderr.contains("No such file or folder"))
        #expect(!result.stderr.contains("Built-in face model not found"))
    }

    @Test func largestReferenceFaceAndValidNoMatch() throws {
        let dir = try TempDir()
        let source = try dir.directory("source")
        try copy("biden_2021.jpg", to: dir, as: "source/photo.jpg")
        let result = try runCLI(filterArguments(faces: Fixtures.url("apollo11_crew.jpg"), source: source,
                                                output: dir.url.appending(path: "out")) + ["--threshold", "1"])
        #expect(result.status == 0, "\(result.stderr)")
        #expect(result.stderr.contains("3 faces, using the largest"))
        #expect(result.stderr.contains("1 reference faces"))
        #expect(result.stdout.isEmpty)
    }

    @Test func rejectsOutputInsideReferencesIncludingSymlinksBeforeLoadingModel() throws {
        let dir = try TempDir()
        let refs = try dir.directory("refs"), source = try dir.directory("source")
        let alias = dir.url.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: refs)
        for output in [refs, refs.appending(path: "out"), alias.appending(path: "out")] {
            for _ in 0..<2 {
                let result = try runCLI(["filter", "--faces", refs.path, "--source", source.path,
                                         "-o", output.path, "--model", "/missing/model.mlmodel"])
                #expect(result.status != 0)
                #expect(result.stderr.contains("destination"))
                #expect(!FileManager.default.fileExists(atPath: refs.appending(path: "out").path))
            }
        }
    }

    @Test(arguments: ["TooSmall", "Nonfinite"])
    func invalidModelsFailBeforeReferences(_ name: String) throws {
        let dir = try TempDir()
        let source = try dir.directory("source")
        let result = try runCLI(["filter", "--faces", "/missing/references", "-s", source.path,
                                 "-o", dir.url.appending(path: "out").path,
                                 "--model", Fixtures.url("Contracts/\(name).mlmodel").path])
        #expect(result.status == 1, "\(result.stderr)")
        #expect(!result.stderr.contains("No such file or folder"))
        #expect(!result.stderr.contains("scanning"))
    }
}

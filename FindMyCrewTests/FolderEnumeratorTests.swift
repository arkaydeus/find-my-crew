import Foundation
import Testing

struct FolderEnumeratorTests {
    @Test func findsImagesRecursivelySkippingHiddenFilesAndPackages() throws {
        let dir = try TempDir()
        try dir.file("root.jpg")
        try dir.file("2024/Summer/IMG_0002.HEIC")
        try dir.file("2024/Summer/IMG_0001.heic")
        try dir.file("2024/raw/DSC_1.NEF")
        try dir.file("2024/notes.txt")
        try dir.file("2024/clip.mov")
        try dir.file(".hidden.jpg")
        try dir.file(".cache/thumb.jpg")
        try dir.file("Old.photoslibrary/originals/inside.jpg")
        try dir.file("Tool.app/Contents/Resources/icon.png")

        let progress = Counter()
        let result = try FolderEnumerator.enumerate(root: dir.url) { progress.set($0) }

        #expect(result.items.map(\.relativePath) == [
            "2024/raw/DSC_1.NEF", "2024/Summer/IMG_0001.heic", "2024/Summer/IMG_0002.HEIC", "root.jpg",
        ])
        #expect(Set(result.skippedPackages) == ["Old.photoslibrary", "Tool.app"])
        #expect(result.folderCount == 3)   // 2024, 2024/Summer, 2024/raw
        #expect(result.items.allSatisfy { $0.fileSize == 1 })
        #expect(progress.value == 4)
    }

    @Test func relativePathsAndContainment() {
        let root = URL(filePath: "/Volumes/Photos/Trip", directoryHint: .isDirectory)
        #expect(FolderEnumerator.relativePath(of: URL(filePath: "/Volumes/Photos/Trip/a/b.jpg"), under: root) == "a/b.jpg")
        #expect(FolderEnumerator.isSameOrInside(URL(filePath: "/Volumes/Photos/Trip/a"), root))
        #expect(FolderEnumerator.isSameOrInside(root, root))
        #expect(!FolderEnumerator.isSameOrInside(URL(filePath: "/Volumes/Photos/Trip2"), root))
        #expect(!FolderEnumerator.isSameOrInside(URL(filePath: "/Volumes/Photos"), root))
    }

    @Test func emptyFolder() throws {
        let dir = try TempDir()
        let result = try FolderEnumerator.enumerate(root: dir.url)
        #expect(result.items.isEmpty && result.folderCount == 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    func set(_ v: Int) { lock.withLock { _value = v } }
    var value: Int { lock.withLock { _value } }
}

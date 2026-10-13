import CoreGraphics
import Foundation
import Testing

struct ImageLoaderTests {
    @Test(arguments: ["a.jpg", "b.JPEG", "c.heic", "d.HEIF", "e.png", "f.tiff", "g.webp", "h.gif", "i.bmp",
                      "j.CR2", "k.cr3", "l.nef", "m.arw", "n.dng", "o.raf", "p.orf", "q.rw2", "r.pef", "s.srw"])
    func supportsPhotoTypes(_ name: String) {
        #expect(ImageLoader.isSupported(URL(filePath: "/x/\(name)")))
    }

    @Test(arguments: ["a.txt", "b.mov", "c.mp4", "d.pdf", "e.svg", "f.xmp", "g.aae", "noextension", "h.icns"])
    func rejectsNonPhotos(_ name: String) {
        #expect(!ImageLoader.isSupported(URL(filePath: "/x/\(name)")))
    }

    @Test func longEdgeNeverExceedsMaxPixel() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "big.png")
        try TestImages.write(TestImages.make(width: 3000, height: 2000, left: TestImages.grey), to: url, type: .png)

        let image = try ImageLoader.load(url, maxPixel: 1024)
        #expect(max(image.width, image.height) <= 1024)
        #expect(image.width == 1024)
        #expect(abs(image.height - 683) <= 1)

        let thumb = try ImageLoader.thumbnail(url, maxPixel: 400)
        #expect(max(thumb.width, thumb.height) <= 400)
    }

    @Test func smallImagesAreNotUpscaledPastTheirSize() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "small.png")
        try TestImages.write(TestImages.make(width: 300, height: 200, left: TestImages.grey), to: url, type: .png)
        let image = try ImageLoader.load(url, maxPixel: 2048)
        #expect(max(image.width, image.height) <= 2048)
    }

    /// EXIF orientation 6 = stored rotated; viewers rotate 90° clockwise to display upright.
    @Test func exifRotatedImagesComeBackUpright() throws {
        let dir = try TempDir()
        let url = dir.url.appending(path: "rotated.jpg")
        // Stored 400×200: red left half, blue right half.
        let stored = TestImages.make(width: 400, height: 200, left: TestImages.red, right: TestImages.blue)
        try TestImages.write(stored, to: url, orientation: 6)

        let image = try ImageLoader.load(url, maxPixel: 2048)
        // Rotating 90° clockwise makes it portrait, with the stored left (red) on top.
        #expect(image.width == 200)
        #expect(image.height == 400)
        let top = TestImages.pixel(image, x: 100, y: 50)
        let bottom = TestImages.pixel(image, x: 100, y: 350)
        #expect(top.r > 200 && top.b < 60)
        #expect(bottom.b > 200 && bottom.r < 60)
    }

    @Test func corruptFilesThrowInsteadOfCrashing() throws {
        let dir = try TempDir()
        let url = try dir.file("broken.jpg", Data((0..<512).map { UInt8($0 % 251) }))
        #expect(throws: ImageLoadError.self) { try ImageLoader.load(url, maxPixel: 1024) }
        let empty = try dir.file("empty.heic", Data())
        #expect(throws: ImageLoadError.self) { try ImageLoader.load(empty, maxPixel: 1024) }
        #expect(throws: ImageLoadError.self) { try ImageLoader.load(dir.url.appending(path: "missing.jpg"), maxPixel: 1024) }
    }

    @Test func cropReturnsTheRequestedRegion() {
        let image = TestImages.make(width: 400, height: 200, left: TestImages.red, right: TestImages.blue)
        let crop = ImageUtils.crop(image, to: CGRect(x: 250, y: 50, width: 100, height: 100), maxSide: 50)!
        #expect(crop.width == 50 && crop.height == 50)
        let p = TestImages.pixel(crop, x: 25, y: 25)
        #expect(p.b > 200 && p.r < 30)
        #expect(ImageUtils.crop(image, to: CGRect(x: 500, y: 500, width: 10, height: 10), maxSide: 50) == nil)
    }
}

import CoreGraphics
import Foundation
import Testing

struct FaceCropsTests {
    @Test func cropIsASquareWithPaddingAroundTheFace() {
        let r = FaceCrops.cropRect(around: CGRect(x: 400, y: 300, width: 100, height: 120), padding: 0.4,
                                   in: CGSize(width: 1000, height: 1000))
        #expect(r.width == 120 * 1.8 && r.height == r.width)
        #expect(r.midX == 450 && r.midY == 360)
    }

    @Test func cropShiftsInsideTheImageWhereItFits() {
        let size = CGSize(width: 1000, height: 800)
        let corner = FaceCrops.cropRect(around: CGRect(x: 0, y: 0, width: 100, height: 100), padding: 0.5, in: size)
        #expect(corner == CGRect(x: 0, y: 0, width: 200, height: 200))
        let far = FaceCrops.cropRect(around: CGRect(x: 950, y: 750, width: 50, height: 50), padding: 0.5, in: size)
        #expect(far == CGRect(x: 900, y: 700, width: 100, height: 100))
        // Larger than the image in one dimension: stays centred on the face there (the crop clips it).
        let tall = FaceCrops.cropRect(around: CGRect(x: 100, y: 300, width: 400, height: 400), padding: 0.5,
                                      in: CGSize(width: 1000, height: 700))
        #expect(tall.minX == 0 && tall.midY == 500 && tall.width == 800)
    }

    @Test func facesAreNumberedLeftToRight() {
        let boxes = [CGRect(x: 300, y: 0, width: 10, height: 10), CGRect(x: 10, y: 50, width: 10, height: 10),
                     CGRect(x: 10, y: 5, width: 10, height: 10)]
        #expect(FaceCrops.readingOrder(boxes) == [2, 1, 0])
    }

    @Test func outputPathMirrorsTheInputAndNumbersFaces() {
        #expect(FaceCrops.outputPath(for: "2024/Party/IMG_0001.HEIC", face: 2, fileExtension: "webp")
                == "2024/Party/IMG_0001_face2.webp")
        #expect(FaceCrops.outputPath(for: "a.b.jpg", face: 1, fileExtension: "png") == "a.b_face1.png")
    }

    /// Crops are meant to be used as reference photos, so each must contain exactly one detectable face.
    @Test func everyCropOfAGroupPhotoIsDetectedAgain() async throws {
        let image = try ImageLoader.load(Fixtures.url("apollo11_crew.jpg"), maxPixel: 2048)
        let size = CGSize(width: image.width, height: image.height)
        let faces = try await FaceDetector().detect(in: image)
        try #require(faces.count == 3)
        for face in faces {
            let rect = FaceCrops.cropRect(around: face.boundingBox, padding: FaceCrops.defaultPadding, in: size)
            let crop = try #require(ImageUtils.crop(image, to: rect, maxSide: 512))
            #expect(try await FaceDetector().detect(in: crop).count == 1)
        }
    }
}

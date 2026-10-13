import CoreGraphics
import CoreVideo
import Foundation
import Testing

struct FaceAlignerTests {
    let template = FaceAligner.template112

    @Test func templateMapsToItselfWithIdentity() {
        let m = FaceAligner.similarityTransform(from: template, to: template)
        #expect(abs(m.a - 1) < 1e-9 && abs(m.d - 1) < 1e-9)
        #expect(abs(m.b) < 1e-9 && abs(m.c) < 1e-9)
        #expect(abs(m.tx) < 1e-9 && abs(m.ty) < 1e-9)
    }

    @Test(arguments: [(30.0, 2.5, 100.0, 50.0), (-75.0, 0.4, -20.0, 300.0), (180.0, 7.0, 1234.0, 987.0)])
    func recoversAKnownSimilarityTransform(degrees: Double, scale: Double, tx: Double, ty: Double) {
        let angle = degrees * .pi / 180
        let known = CGAffineTransform(a: scale * cos(angle), b: scale * sin(angle),
                                      c: -scale * sin(angle), d: scale * cos(angle), tx: tx, ty: ty)
        let photoPoints = template.map { $0.applying(known) }

        // Aligning the photo's landmarks must undo `known` exactly.
        let m = FaceAligner.similarityTransform(from: photoPoints, to: template)
        for (p, t) in zip(photoPoints, template) {
            let mapped = p.applying(m)
            #expect(abs(mapped.x - t.x) < 1e-6 && abs(mapped.y - t.y) < 1e-6)
        }
        let recoveredScale = (m.a * m.a + m.b * m.b).squareRoot()
        #expect(abs(recoveredScale - 1 / scale) < 1e-9)
    }

    @Test func leastSquaresFitIsRobustToLandmarkNoise() {
        let noisy = template.enumerated().map { i, p in
            CGPoint(x: p.x * 3 + 40 + (i.isMultiple(of: 2) ? 0.8 : -0.8), y: p.y * 3 + 10 + (i < 2 ? 0.5 : -0.5))
        }
        let m = FaceAligner.similarityTransform(from: noisy, to: template)
        let error = zip(noisy, template).map { hypot($0.applying(m).x - $1.x, $0.applying(m).y - $1.y) }.max()!
        #expect(error < 0.6)
    }

    @Test func producesOriginalAndMirroredCrops() throws {
        // Left half red, right half blue; an identity alignment keeps the halves in place.
        let image = TestImages.make(width: 112, height: 112, left: TestImages.red, right: TestImages.blue)
        let crops = FaceAligner.alignedCrops(from: image, landmarks: template, size: 112, includeFlipped: true)
        #expect(crops.count == 2)
        #expect(crops.allSatisfy { CVPixelBufferGetWidth($0) == 112 && CVPixelBufferGetHeight($0) == 112 })

        let original = bgra(crops[0], x: 20, y: 56), mirrored = bgra(crops[1], x: 20, y: 56)
        #expect(original.r > 200 && original.b < 50)   // left stays red
        #expect(mirrored.b > 200 && mirrored.r < 50)   // mirror puts blue on the left

        let single = FaceAligner.alignedCrops(from: image, landmarks: template, size: 112, includeFlipped: false)
        #expect(single.count == 1)
    }

    @Test func alignmentIsUprightForTopLeftLandmarks() {
        // Top half red, bottom half blue (top-left coordinates). Landmarks = template, so no rotation.
        let ctx = CGContext(data: nil, width: 112, height: 112, bitsPerComponent: 8, bytesPerRow: 0,
                            space: ImageUtils.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(TestImages.blue); ctx.fill(CGRect(x: 0, y: 0, width: 112, height: 56))   // CG bottom
        ctx.setFillColor(TestImages.red); ctx.fill(CGRect(x: 0, y: 56, width: 112, height: 56))   // CG top
        let image = ctx.makeImage()!
        let crop = FaceAligner.alignedCrops(from: image, landmarks: template, size: 112, includeFlipped: false)[0]
        #expect(bgra(crop, x: 56, y: 10).r > 200)
        #expect(bgra(crop, x: 56, y: 100).b > 200)
    }

    @Test func approximateLandmarksLieInsideTheBox() {
        let box = CGRect(x: 100, y: 200, width: 80, height: 100)
        let points = FaceAligner.landmarks(approximatingBox: box)
        #expect(points.count == 5)
        #expect(points.allSatisfy { box.contains($0) })
        #expect(points[0].x < points[1].x && points[3].x < points[4].x)   // left before right
        #expect(points[0].y < points[2].y && points[2].y < points[3].y)   // eyes, nose, mouth
    }

    private func bgra(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let row = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            + y * CVPixelBufferGetBytesPerRow(buffer)
        let p = row + x * 4
        return (p[2], p[1], p[0])
    }
}

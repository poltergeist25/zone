import Foundation
import Vision
import CoreVideo
import ImageIO
var buffer: CVPixelBuffer?
let status = CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nil, &buffer)
precondition(status == kCVReturnSuccess)
let image = buffer!
CVPixelBufferLockBaseAddress(image, [])
memset(CVPixelBufferGetBaseAddress(image), 0, CVPixelBufferGetDataSize(image))
CVPixelBufferUnlockBaseAddress(image, [])
let request = VNDetectHumanBodyPoseRequest()
try VNImageRequestHandler(cvPixelBuffer: image, orientation: .up).perform([request])
precondition((request.results ?? []).isEmpty)
print("PASS: native Vision initialized and correctly found no pose in a blank frame")

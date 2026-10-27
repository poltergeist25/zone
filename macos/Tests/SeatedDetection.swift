import Foundation
import Vision
import ImageIO
import CoreGraphics

@main struct SeatedDetectionChecks {
    static func main() throws {
        let detector=SeatedPoseDetector()
        let context=CGContext(data:nil,width:640,height:480,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:640,height:480))
        let empty=try detector.detect(VNImageRequestHandler(cgImage:context.makeImage()!,orientation:.up),aspect:640.0/480)
        precondition(empty.features == nil,"Blank frame must not track")
        let face=CGRect(x:0.3,y:0.3,width:0.3,height:0.4)
        func feature(_ shift:CGFloat=0,_ confidence:Double=1)->PoseFeatures? { SeatedGeometry.features(face:face.offsetBy(dx:shift,dy:0),leftEye:CGPoint(x:0.38+shift,y:0.57),rightEye:CGPoint(x:0.52+shift,y:0.57),nose:CGPoint(x:0.45+shift,y:0.48),chin:CGPoint(x:0.45+shift,y:0.32),confidence:confidence,aspect:4.0/3) }
        precondition(feature() != nil)
        precondition(feature(0,0.2) == nil)
        precondition(PostureEngine.deviation(feature(0.1)!,from:feature()!) < 1e-10,"Sideways motion must not change score")
        precondition(SeatedGeometry.features(face:face,leftEye:.zero,rightEye:.zero,nose:.zero,confidence:1,aspect:1) == nil)
        // A complete low-frame face can be yellow; a generous bottom margin
        // must not force full analysis for every sample merely because it is low.
        let lowFace=CGRect(x:0.3,y:0.08,width:0.3,height:0.4)
        guard SeatedGeometry.permitsLocalTracking(face:lowFace) else {
            print("FAIL: fully visible low-frame face unnecessarily forces full analysis")
            exit(1)
        }
        for clipped in [lowFace.offsetBy(dx:0,dy:-0.07),lowFace.offsetBy(dx:-0.25,dy:0),lowFace.offsetBy(dx:0.35,dy:0),lowFace.offsetBy(dx:0,dy:0.51)] {
            precondition(!SeatedGeometry.permitsLocalTracking(face:clipped),"Near-edge faces still require fresh full-model analysis")
        }
        let anchor=feature()!
        precondition(abs(anchor.centerY-(1-(0.57+0.57+0.48+0.32)/4))<1e-10,"Four landmarks have equal anchor weight")
        let alteredBox=SeatedGeometry.features(face:face.offsetBy(dx:0,dy:0.1),leftEye:CGPoint(x:0.38,y:0.57),rightEye:CGPoint(x:0.52,y:0.57),nose:CGPoint(x:0.45,y:0.48),chin:CGPoint(x:0.45,y:0.32),confidence:1,aspect:4.0/3)!
        precondition(alteredBox.centerY==anchor.centerY,"Anchor uses landmarks rather than face box position")
        let lowered=SeatedGeometry.features(face:face.offsetBy(dx:0,dy:-0.08),leftEye:CGPoint(x:0.38,y:0.49),rightEye:CGPoint(x:0.52,y:0.49),nose:CGPoint(x:0.45,y:0.40),chin:CGPoint(x:0.45,y:0.24),confidence:1,aspect:4.0/3)!
        precondition(PostureEngine.deviation(lowered,from:anchor)>0.8,"Downward movement raises thermometer")
        let tilted=SeatedGeometry.features(face:face,leftEye:CGPoint(x:0.38,y:0.60),rightEye:CGPoint(x:0.52,y:0.54),nose:CGPoint(x:0.45,y:0.48),chin:CGPoint(x:0.45,y:0.32),confidence:1,aspect:4.0/3)!
        precondition(PostureEngine.deviation(tilted,from:anchor)<1e-10,"Equal anchor height ignores eye-line tilt")
        precondition(empty.points.isEmpty,"No landmarks on tracking loss")
        print("PASS: blank frame, valid geometry, confidence, vertical anchor, lateral/tilt independence")
        guard CommandLine.arguments.count > 1 else{return}
        let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,nil)!
        let full=CGImageSourceCreateImageAtIndex(source,0,nil)!
        let crop=full.cropping(to:CGRect(x:Double(full.width)*0.033,y:Double(full.height)*0.358,width:Double(full.width)*0.568,height:Double(full.height)*0.433))!
        var found=0
        for scale in [1.0,0.75,0.5] {
            for brightness in [0.0,0.15] {
                let w=Int(Double(crop.width)*scale),h=Int(Double(crop.height)*scale)
                let ctx=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.draw(crop,in:CGRect(x:0,y:0,width:w,height:h))
                ctx.setFillColor(CGColor(gray:0,alpha:brightness));ctx.fill(CGRect(x:0,y:0,width:w,height:h))
                let result=try detector.detect(VNImageRequestHandler(cgImage:ctx.makeImage()!,orientation:.up),aspect:Double(w)/Double(h))
                precondition(result.features != nil,"Seated screenshot failed at scale \(scale), dimming \(brightness)")
                precondition(result.points.count==4,"Successful live detector includes both eyes, nose and chin")
                found += 1
            }
        }
        print("PASS: seated screenshot detected in all \(found) size/brightness variants")
    }
}

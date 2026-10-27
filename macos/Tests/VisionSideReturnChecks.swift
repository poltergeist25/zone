import Foundation
import Vision
import CoreGraphics
import ImageIO

/// Uses the same supplied screenshot fixture as VisionContinuityChecks; no camera.
@main struct VisionSideReturnChecks {
    static func check(_ value:Bool,_ message:String) {
        guard value else{fputs(message+"\n",stderr);exit(1)}
    }
    static func main() throws {
        let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,nil)!
        let full=CGImageSourceCreateImageAtIndex(source,0,nil)!
        let photo=full.cropping(to:CGRect(x:Double(full.width)*410/1920,y:Double(full.height)*203/1300,width:Double(full.width)*690/1920,height:Double(full.height)*390/1300))!
        let w=384,h=216
        let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        let detector=SeatedPoseDetector()
        func detect(_ dx:Double=0,blank:Bool=false)throws->SeatedDetection {
            context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:w,height:h))
            if !blank {context.draw(photo,in:CGRect(x:dx,y:0,width:Double(w),height:Double(h)))}
            return try detector.detect(VNImageRequestHandler(cgImage:context.makeImage()!,orientation:.up),aspect:16.0/9)
        }
        for direction in [-1.0,1.0] {
            for clipped in [false,true] {
                detector.reset()
                let anchor=try detect();check(anchor.features != nil,"Fixture must initially track")
                var visible=0
                let offsets=clipped ? [32.0,64,96,128,160,192,224,256]:[32.0,64,96]
                for offset in offsets {
                    let result=try detect(offset*direction)
                    if result.features != nil {visible += 1}
                }
                check(visible>=2,"Fixture must establish a lateral track before loss")
                let missing=try detect(blank:true);check(missing.features == nil,"Blank frame must be a real loss")
                if !clipped {check(missing.loss == .unknown,"Early loss must exercise return without a side-edge hint")}
                let returned=try detect()
                check(returned.features != nil,"Original subject must return after a left/right exit, including an unknown or clipped edge")
                check(abs(returned.features!.centerX-anchor.features!.centerX)<0.03 && abs(returned.features!.centerY-anchor.features!.centerY)<0.03,"Return must retain the original seated geometry")
                let stable=try detect();check(stable.features != nil,"Repeated return must stay stable")
                print("PASS: Vision \(direction<0 ? "left":"right") \(clipped ? "clipped edge":"early unknown loss") reacquires original subject at384px")
            }
        }
    }
}

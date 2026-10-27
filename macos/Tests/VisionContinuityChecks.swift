import Foundation
import Vision
import CoreGraphics
import ImageIO
import Darwin

@main struct VisionContinuityChecks {
    static func main() throws {
        setbuf(stdout,nil)
        let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,nil)!
        let full=CGImageSourceCreateImageAtIndex(source,0,nil)!
        let photo=full.cropping(to:CGRect(x:Double(full.width)*410/1920,y:Double(full.height)*203/1300,width:Double(full.width)*690/1920,height:Double(full.height)*390/1300))!
        let w=384,h=216
        let context=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue)!
        func frame(_ dy:Double=0,visitor:Bool=false)->CGImage {
            context.setFillColor(CGColor(gray:0,alpha:1));context.fill(CGRect(x:0,y:0,width:w,height:h))
            context.draw(photo,in:CGRect(x:0,y:dy,width:Double(w),height:Double(h)))
            if visitor {context.draw(photo,in:CGRect(x:245,y:12,width:Double(w)*0.48,height:Double(h)*0.48))}
            return context.makeImage()!
        }
        let detector=SeatedPoseDetector()
        func detect(_ dy:Double=0,visitor:Bool=false)throws->SeatedDetection {try detector.detect(VNImageRequestHandler(cgImage:frame(dy,visitor:visitor),orientation:.up),aspect:16.0/9)}
        let anchor=try detect();precondition(anchor.features != nil)
        let multiImage=frame(0,visitor:true)
        let faces=VNDetectFaceLandmarksRequest();try VNImageRequestHandler(cgImage:multiImage,orientation:.up).perform([faces])
        precondition((faces.results ?? []).count==2,"Fixture must actually contain two Vision-detected faces")
        for offset in [0.0,-4,-8,-12,-16,-8,-4,0] {
            let found=try detect(offset,visitor:true)
            precondition(found.features != nil && found.points.count==4,"A second detected face must not interrupt the established subject")
            precondition(abs(found.features!.centerX-anchor.features!.centerX)<0.04,"Target may not jump to the visitor")
            if offset == -16 {precondition(PostureEngine.deviation(found.features!,from:anchor.features!)>0.85,"Downward real-image translation must cross the tighter default red level")}
        }
        let recovered=try detect()
        precondition(recovered.features != nil && abs(recovered.features!.centerY-anchor.features!.centerY)<0.015)
        var bottomSeen=false
        for offset in stride(from:-8.0,through:-128.0,by:-8.0) {
            let result=try detect(offset)
            if result.features == nil && result.loss == .bottom {bottomSeen=true}
        }
        precondition(bottomSeen,"Real-image descent out of frame must retain bottom direction")
        let returned=try detect();precondition(returned.features != nil,"Original subject must return after clipping")
        detector.reset();let reset=try detect();precondition(reset.features != nil)
        print("PASS: Vision really detects two faces; target survives second-face entry, downward/red translation and green return at production384px. Supplied still image only, not live people.")
    }
}

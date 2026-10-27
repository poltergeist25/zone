import Foundation
import Vision
import CoreVideo
import CoreGraphics
import ImageIO
import Darwin

/// Local, user-supplied still-image qualification. Never opens a camera or
/// writes a frame; these checks are separate from live-person acceptance.
@main struct LightweightVisionChecks {
    static func cpu()->Double {
        var r=rusage();getrusage(RUSAGE_SELF,&r)
        return Double(r.ru_utime.tv_sec+r.ru_stime.tv_sec)+Double(r.ru_utime.tv_usec+r.ru_stime.tv_usec)/1e6
    }
    static func main() throws {
        setbuf(stdout,nil)
        let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,nil)!
        let full=CGImageSourceCreateImageAtIndex(source,0,nil)!
        let photo=full.cropping(to:CGRect(x:Double(full.width)*410/1920,y:Double(full.height)*203/1300,width:Double(full.width)*690/1920,height:Double(full.height)*390/1300))!
        let w=384,h=216
        func frame(dx:Double=0,dy:Double=0,visitor:Bool=false,blank:Bool=false)->CVPixelBuffer {
            var buffer:CVPixelBuffer?
            precondition(CVPixelBufferCreate(nil,w,h,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer)==kCVReturnSuccess)
            let value=buffer!;CVPixelBufferLockBaseAddress(value,[]);defer{CVPixelBufferUnlockBaseAddress(value,[])}
            let c=CGContext(data:CVPixelBufferGetBaseAddress(value),width:w,height:h,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(value),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            c.setFillColor(CGColor(gray:0,alpha:1));c.fill(CGRect(x:0,y:0,width:w,height:h))
            if !blank {c.draw(photo,in:CGRect(x:dx,y:dy,width:Double(w),height:Double(h)))}
            if visitor {c.draw(photo,in:CGRect(x:245,y:12,width:Double(w)*0.48,height:Double(h)*0.48))}
            return value
        }
        let still=frame(),detector=SeatedPoseDetector()
        let anchor=try detector.detect(still,aspect:16.0/9,at:0)
        guard var baseline=anchor.features,let landmarks=baseline.heightLandmarks else{fatalError("Local fixture must produce actual face landmarks")}
        baseline.landmarkHeight=LandmarkHeightCalibration.capture(landmarks)
        detector.setReference(baseline:baseline,yellow:0.45,red:0.85)
        var clock=0.1
        for _ in 0..<18 {
            let result=try detector.detect(still,aspect:16.0/9,at:clock);clock += 1.0/3
            precondition(result.features != nil && result.points.count==4)
            precondition(abs(result.features!.centerY-baseline.centerY)<0.003,"Static tracking must not drift")
        }
        precondition(detector.patchPasses>=6,"A real face must use the cheap path between full audits")
        precondition(detector.fullPasses>=4,"Full all-face audits remain bounded in time")
        let beforeCalibration=detector.patchPasses
        for _ in 0..<4 {_=try detector.detect(still,aspect:16.0/9,at:clock,allowLightweight:false);clock += 0.1}
        precondition(detector.patchPasses==beforeCalibration && detector.lastPath=="full","Calibration never uses patch observations")
        _=try detector.detect(frame(blank:true),aspect:16.0/9,at:clock);clock += 1.0/3
        precondition(detector.lastPath=="full","Blank pixels force same-frame full analysis")
        let blank=try detector.detect(frame(blank:true),aspect:16.0/9,at:clock);clock += 1.0/3
        precondition(blank.features==nil,"Missing faces cannot count as tracked posture")
        let returned=try detector.detect(still,aspect:16.0/9,at:clock);clock += 1.0/3
        precondition(returned.features != nil,"Original face recovers without a camera restart")
        for _ in 0..<3 {
            let visitor=try detector.detect(frame(visitor:true),aspect:16.0/9,at:clock);clock += 1.0/3
            precondition(detector.lastPath=="full","Visitor/scene change and multi-face ambiguity disable patch mode")
            precondition(visitor.features != nil && abs(visitor.features!.centerX-baseline.centerX)<0.04,"A visitor must not replace the selected subject")
        }
        detector.setReference(baseline:baseline,yellow:0.6,red:1)
        _=try detector.detect(still,aspect:16.0/9,at:clock);clock += 1.0/3
        precondition(detector.lastPath=="full","Threshold changes force a fresh full observation")
        detector.setReference(baseline:baseline,yellow:0.45,red:0.85)
        for direction in [-1.0,1.0] {
            detector.reset();detector.setReference(baseline:baseline,yellow:0.45,red:0.85)
            _=try detector.detect(still,aspect:16.0/9,at:clock);clock += 1.0/3
            for offset in [32.0,64,96,128,160,192,224,256] {
                _=try detector.detect(frame(dx:direction*offset),aspect:16.0/9,at:clock);clock += 1.0/3
            }
            _=try detector.detect(frame(blank:true),aspect:16.0/9,at:clock);clock += 1.0/3
            let recovery=try detector.detect(still,aspect:16.0/9,at:clock);clock += 1.0/3
            precondition(recovery.features != nil,"Clipped side exits must reacquire the original subject")
        }
        detector.reset();detector.setReference(baseline:baseline,yellow:0.45,red:0.85)
        _=try detector.detect(still,aspect:16.0/9,at:clock);clock += 1.0/3
        var bottom=false
        for offset in stride(from:-8.0,through:-128.0,by:-8.0) {
            let result=try detector.detect(frame(dy:offset),aspect:16.0/9,at:clock);clock += 1.0/3
            if result.features==nil && result.loss == .bottom {bottom=true}
        }
        precondition(bottom,"Actual bottom clipping must retain the existing exit direction")
        let bottomReturn=try detector.detect(still,aspect:16.0/9,at:clock)
        precondition(bottomReturn.features != nil)
        print("PASS: real-image patch use/three fresh anchors plus calibrated jaw/no drift, full audits, calibration isolation, blank/visitor fallback, threshold reset and side/bottom recovery; local still fixture only")
        for period in [1.0/3,0.5556] {
          for zone in ["green","yellow"] {
            var reference=baseline
            if zone=="yellow",let measured=baseline.landmarkHeight {
                let p=measured.landmarks
                let shift=(measured.referenceLineY-p.noseY)+(p.noseY-p.eyesY)*0.4
                reference.centerY -= shift
                reference.landmarkHeight=LandmarkHeightCalibration.capture(FaceHeightLandmarks(eyesY:p.eyesY-shift,noseY:p.noseY-shift,chinY:p.chinY-shift))
            }
            for lightweight in [false,true] {
                let d=SeatedPoseDetector(lightweight:lightweight)
                d.setReference(baseline:reference,yellow:0.45,red:0.85)
                var start=0.0,wall=0.0
                for i in 0..<100 {
                    if i==20 {start=cpu();wall=ProcessInfo.processInfo.systemUptime}
                    let result=try autoreleasepool {try d.detect(still,aspect:16.0/9,at:Double(i)*period)}
                    precondition(result.features != nil)
                    let deviation=PostureEngine.deviation(result.features!,from:reference)
                    precondition(zone=="green" ? deviation<0.45:(0.45..<0.85).contains(deviation))
                }
                let row:[String:Any]=["mode":lightweight ? "patch-with-audits":"full","zone":zone,"period":period,"cpu_ms":(cpu()-start)*1000/80,"wall_ms":(ProcessInfo.processInfo.systemUptime-wall)*1000/80,"full":d.fullPasses,"patch":d.patchPasses,"fallbacks":d.fallbackCounts]
                print(String(data:try JSONSerialization.data(withJSONObject:row,options:.sortedKeys),encoding:.utf8)!)
            }
          }
        }
    }
}

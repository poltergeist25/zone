import Foundation
import CoreVideo
import CoreGraphics

@main struct LandmarkPatchTrackerChecks {
    static func main() throws {
        let patchRadius=Int(CommandLine.arguments.dropFirst().first ?? "7") ?? 7
        let width=128,height=128
        let box=CGRect(x:0.2,y:0.15,width:0.6,height:0.7)
        let points=[CGPoint(x:0.35,y:0.67),CGPoint(x:0.62,y:0.67),CGPoint(x:0.49,y:0.49),CGPoint(x:0.49,y:0.28)]
        let centers=points.map{CGPoint(x:($0.x*Double(width-1)).rounded(),y:((1-$0.y)*Double(height-1)).rounded())}
        func texture(_ x:Int,_ y:Int,_ index:Int)->Double {
            var value=UInt64((x+20)*173+(y+20)*919+(index+1)*3121)
            value=(value &* 6364136223846793005) &+ 1442695040888963407
            value ^= value>>27;value=value &* 2862933555777941757
            return 65+Double((value>>32)%120)
        }
        func frame(dx:Int=0,dy:Int=0,exposure:Int=0,noise:Bool=false,blank:Bool=false,occlude:Bool=false,jawOccluded:Bool=false,occludeEye:Int?=nil,noseDrift:Int=0,scene:Bool=false,torso:Bool=false,periodic:Bool=false,format:OSType=kCVPixelFormatType_32BGRA)->CVPixelBuffer {
            var output:CVPixelBuffer?
            precondition(CVPixelBufferCreate(kCFAllocatorDefault,width,height,format,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&output)==kCVReturnSuccess)
            let buffer=output!;CVPixelBufferLockBaseAddress(buffer,[]);defer{CVPixelBufferUnlockBaseAddress(buffer,[])}
            let planar=format != kCVPixelFormatType_32BGRA
            let bytes=(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,0):CVPixelBufferGetBaseAddress(buffer))!.assumingMemoryBound(to:UInt8.self)
            let stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,0):CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<height {for x in 0..<width {
                var value=120.0
                if !blank {
                    for (index,center) in centers.enumerated() {
                        let px=x-Int(center.x)-dx,py=y-Int(center.y)-dy-(index==2 ? noseDrift:0)
                        if abs(px)<=9 && abs(py)<=9 {value=(occlude && index==2) || (jawOccluded && index==3) || occludeEye==index ? 120:texture(px,py,index)}
                    }
                }
                if periodic {value=65+Double(((x%5)*31+(y%5)*17)%120)}
                if scene && x<22 {value=(x+y).isMultiple(of:2) ? 0:250}
                if torso && y>100 && x>38 && x<90 {value=(x+y).isMultiple(of:2) ? 0:250}
                if noise {value+=Double((x*37+y*13)%3-1)}
                let pixel=UInt8(min(255,max(0,value+Double(exposure))))
                if planar {bytes[y*stride+x]=pixel}
                else {let i=y*stride+4*x;bytes[i]=pixel;bytes[i+1]=pixel;bytes[i+2]=pixel;bytes[i+3]=255}
            }}
            return buffer
        }
        func fractionalFrame(dx:Double,dy:Double)->CVPixelBuffer {
            let original=frame(),result=frame(blank:true)
            CVPixelBufferLockBaseAddress(original,.readOnly);CVPixelBufferLockBaseAddress(result,[])
            defer {CVPixelBufferUnlockBaseAddress(original,.readOnly);CVPixelBufferUnlockBaseAddress(result,[])}
            let source=CVPixelBufferGetBaseAddress(original)!.assumingMemoryBound(to:UInt8.self),target=CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to:UInt8.self)
            let sourceRow=CVPixelBufferGetBytesPerRow(original),targetRow=CVPixelBufferGetBytesPerRow(result)
            for y in 0..<height {for x in 0..<width {
                let sx=min(Double(width-2),max(0,Double(x)-dx)),sy=min(Double(height-2),max(0,Double(y)-dy))
                let ix=Int(floor(sx)),iy=Int(floor(sy)),fx=sx-floor(sx),fy=sy-floor(sy)
                func value(_ px:Int,_ py:Int)->Double {Double(source[py*sourceRow+px*4])}
                let top=value(ix,iy)*(1-fx)+value(ix+1,iy)*fx,bottom=value(ix,iy+1)*(1-fx)+value(ix+1,iy+1)*fx
                let v=UInt8((top*(1-fy)+bottom*fy).rounded()),i=y*targetRow+x*4
                target[i]=v;target[i+1]=v;target[i+2]=v;target[i+3]=255
            }}
            return result
        }
        func seed(_ tracker:LandmarkPatchTracker,format:OSType=kCVPixelFormatType_32BGRA) {
            precondition(tracker.remember(frame(format:format),box:box,points:points,at:0),"Synthetic textured face seeds frozen templates")
        }
        func check(_ result:LandmarkPatchTrack?,dx:Double,dy:Double) {
            guard let result else{preconditionFailure("Fresh translated points must be tracked")}
            precondition(result.points.count==4 && result.confidence>=0.9)
            for index in 0..<4 {
                // The measured patch offset retains the model seed's fractional
                // position rather than snapping the landmark to its raster center.
                let x=Double(result.points[index].x)*Double(width-1)
                let y=(1.0-Double(result.points[index].y))*Double(height-1)
                let expectedX=Double(points[index].x)*Double(width-1)+dx
                let expectedY=(1.0-Double(points[index].y))*Double(height-1)+dy
                precondition(abs(x-expectedX)<0.3 && abs(y-expectedY)<0.3,"Independent patch location follows the new frame")
            }
        }
        let tracker=LandmarkPatchTracker(radius:patchRadius)
        seed(tracker)
        for step in 1...8 {
            let stationary=tracker.track(frame(),at:Double(step)*0.1)!
            for index in 0..<4 {
                precondition(abs(stationary.points[index].x-points[index].x)<0.000000001 &&
                    abs(stationary.points[index].y-points[index].y)<0.000000001,"Static frames preserve the original subpixel landmarks without drift")
            }
        }
        for (dx,dy) in [(0.25,0.5),(-0.5,0.25),(0.5,-0.5),(-0.25,-0.5)] {
            seed(tracker);check(tracker.track(fractionalFrame(dx:dx,dy:dy),at:0.1),dx:dx,dy:dy)
        }
        seed(tracker)
        for step in 1...8 {
            let movement=Double(step)*0.25
            check(tracker.track(fractionalFrame(dx:movement,dy:movement/2),at:Double(step)*0.1),dx:movement,dy:movement/2)
        }
        seed(tracker)
        for step in 1...8 {check(tracker.track(frame(noise:true),at:Double(step)*0.1),dx:0,dy:0)}
        for step in 1...9 {
            seed(tracker);let amount=Double(step)/10
            check(tracker.track(fractionalFrame(dx:amount,dy:-amount),at:0.1),dx:amount,dy:-amount)
        }
        precondition(tracker.remember(frame(periodic:true),box:box,points:points,at:0))
        precondition(tracker.track(frame(periodic:true),at:0.1)==nil,"Repeated textures must not produce a confident unique match")
        seed(tracker);check(tracker.track(frame(torso:true),at:0.1),dx:0,dy:0)
        for (dx,dy) in [(0,2),(0,-3),(2,1),(-2,-1)] {
            seed(tracker);check(tracker.track(frame(dx:dx,dy:dy),at:0.1),dx:Double(dx),dy:Double(dy))
        }
        seed(tracker)
        for step in 1...4 {check(tracker.track(frame(dx:step,dy:step),at:Double(step)*0.15),dx:Double(step),dy:Double(step))}
        seed(tracker);check(tracker.track(frame(dx:2,dy:-1,exposure:18,noise:true),at:0.2),dx:2,dy:-1)
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            seed(tracker,format:format);check(tracker.track(frame(dx:1,dy:2,format:format),at:0.2),dx:1,dy:2)
        }
        precondition(tracker.remember(frame(),box:CGRect(x:0.2,y:0.32,width:0.6,height:0.5),points:points,at:0),"The full-model jaw contour may extend below its face rectangle; fresh primary anchors remain inside")
        check(tracker.track(frame(),at:0.1),dx:0,dy:0)
        precondition(!tracker.remember(frame(),box:CGRect(x:0.45,y:0.15,width:0.35,height:0.7),points:points,at:0),"Primary anchors outside the selected face still reject")
        seed(tracker)
        check(tracker.track(frame(jawOccluded:true),at:0.1),dx:0,dy:0)
        // Jaw expression/occlusion alone does not invent fresh jaw landmarks:
        // the calibrated jaw stays attached to three independently read anchors.
        for step in 2...8 {check(tracker.track(frame(dx:1,jawOccluded:true),at:Double(step)*0.1),dx:1,dy:0)}
        seed(tracker);precondition(tracker.track(frame(blank:true),at:0.1)==nil,"Blank frame cannot reuse old landmarks")
        seed(tracker)
        precondition(tracker.track(frame(noseDrift:4),at:0.1)==nil,"Nonrigid anchor changes need a full face model, not a translated jaw")
        for eye in [0,1] {
            seed(tracker);precondition(tracker.track(frame(occludeEye:eye),at:0.1)==nil,"Both primary eye anchors are mandatory fresh observations")
        }
        seed(tracker);precondition(tracker.track(frame(occlude:true),at:0.1)==nil,"A hidden primary eye/nose anchor rejects the entire pose")
        seed(tracker);precondition(tracker.track(frame(scene:true),at:0.1)==nil,"New motion outside selected face forces a full audit")
        seed(tracker);precondition(tracker.track(frame(dx:7),at:0.1)==nil,"A jump beyond search support cannot guess")
        seed(tracker);precondition(tracker.track(frame(),at:0.91)==nil,"Frozen templates expire")
        seed(tracker);precondition(tracker.track(frame(),at:-0.1)==nil,"Time rewind rejects the sequence")
        seed(tracker);tracker.reset();precondition(tracker.track(frame(),at:0.1)==nil,"Reset removes template authority")
        precondition(!tracker.remember(frame(),box:CGRect(x:-0.1,y:0,width:0.6,height:0.6),points:points,at:0),"Outside source bounds rejected")
        var edge=points;edge[0]=CGPoint(x:0.01,y:0.99)
        precondition(!tracker.remember(frame(),box:CGRect(x:0,y:0,width:1,height:1),points:edge,at:0),"Incomplete template support rejected")
        precondition(!tracker.remember(frame(blank:true),box:box,points:points,at:0),"Low contrast cannot seed")
        print("PASS: subpixel static/no-drift and fresh three-anchor translation with frozen jaw model/gradual motion, exposure/noise and BGRA/420v/420f; blank/occlusion/scene/jump/expiry/time/reset/bounds reject; synthetic only")
    }
}

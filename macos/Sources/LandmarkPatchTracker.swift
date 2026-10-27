import Foundation
import CoreVideo
import CoreGraphics

struct LandmarkPatchTrack {
    let box:CGRect
    let points:[CGPoint]
    let confidence:Double
}

/// Frozen, short-lived landmark templates. Eye/nose anchors are measured in
/// the new buffer. The calibrated jaw is projected from their
/// measured head translation; uncertainty asks the full model to take over.
final class LandmarkPatchTracker {
    private struct Frame {let width:Int;let height:Int;let storageWidth:Int;let originX:Int;let originY:Int;let luma:[Double];let scene:[Double]}
    private struct Patch {let pixels:[Double];let energy:Double}
    private let radius:Int
    init(radius:Int=7){self.radius=[7,10,12].contains(radius) ? radius:7}
    private var templates:[Patch]=[]
    private var templateOffsets:[CGPoint]=[]
    private var previousPoints:[CGPoint]=[]
    private var seedPoints:[CGPoint]=[]
    private var previousBox=CGRect.zero
    private var outside:[(Int,Double)]=[]
    private var dimensions=(0,0)
    private var rememberedAt=Double.nan
    private var lastAt=Double.nan
    private(set) var lastFailure:String?
    func reset(){templates=[];templateOffsets=[];previousPoints=[];seedPoints=[];previousBox = .zero;outside=[];dimensions=(0,0);rememberedAt = .nan;lastAt = .nan;lastFailure=nil}
    private func fail(_ reason:String)->LandmarkPatchTrack? {lastFailure=reason;templates=[];templateOffsets=[];previousPoints=[];seedPoints=[];outside=[];return nil}
    @discardableResult func remember(_ buffer:CVPixelBuffer,box:CGRect,points:[CGPoint],at time:Double)->Bool {
        reset()
        guard time.isFinite,points.count==4,points.allSatisfy({finite($0)}) else{lastFailure="invalid seed points";return false}
        guard valid(box) else{lastFailure="invalid seed box";return false}
        guard let frame=read(buffer,points:Array(points.prefix(3))) else{lastFailure="unreadable seed";return false}
        var patches:[Patch]=[],offsets:[CGPoint]=[]
        for point in points.prefix(3) {
            guard finite(point),box.insetBy(dx:-0.02,dy:-0.02).contains(point) else{lastFailure="seed geometry";return false}
            let center=pixel(point,frame)
            guard let patch=patch(frame,x:Int(center.x.rounded()),y:Int(center.y.rounded())) else{lastFailure="seed contrast or bounds";return false}
            patches.append(patch)
            offsets.append(CGPoint(x:center.x-center.x.rounded(),y:center.y-center.y.rounded()))
        }
        let padded=box.insetBy(dx:-0.04,dy:-0.04)
        // Ignore the tracked user's own torso/keyboard motion, while retaining
        // surrounding background and side regions as the visitor/scene guard.
        let torso=CGRect(x:max(0,box.midX-box.width*1.2),y:0,
            width:min(1,box.midX+box.width*1.2)-max(0,box.midX-box.width*1.2),height:points[3].y)
        for gy in 0..<12 {for gx in 0..<12 {
            let x=min(frame.width-1,(2*gx+1)*frame.width/24),y=min(frame.height-1,(2*gy+1)*frame.height/24)
            let normalized=CGPoint(x:Double(x)/Double(frame.width-1),y:1-Double(y)/Double(frame.height-1))
            if !padded.contains(normalized) && !torso.contains(normalized){let index=gy*12+gx;outside.append((index,frame.scene[index]))}
        }}
        guard outside.count>=12 else{lastFailure="insufficient scene guard";return false}
        templates=patches;templateOffsets=offsets;previousPoints=points;seedPoints=points;previousBox=box;dimensions=(frame.width,frame.height);rememberedAt=time;lastAt=time;return true
    }
    func track(_ buffer:CVPixelBuffer,at time:Double)->LandmarkPatchTrack? {
        guard templates.count==3,seedPoints.count==4 else{return fail("no template")}
        guard time.isFinite,lastAt.isFinite,time>lastAt,time-rememberedAt<=0.9 else{return fail("expired or invalid sequence")}
        guard let frame=read(buffer,points:Array(previousPoints.prefix(3))),frame.width==dimensions.0,frame.height==dimensions.1 else{return fail("source changed")}
        let changes=outside.map{frame.scene[$0.0]-$0.1}.sorted()
        let exposure=changes[changes.count/2]
        let residuals=outside.map{abs(frame.scene[$0.0]-$0.1-exposure)}
        guard residuals.reduce(0,+)/Double(residuals.count)<7,
              Double(residuals.filter{$0>18}.count)/Double(residuals.count)<0.08 else{return fail("scene motion")}
        var found:[CGPoint]=[],deltas:[CGPoint]=[],confidence=1.0
        for index in 0..<3 {
            let old=pixel(previousPoints[index],frame),cx=Int(old.x.rounded()),cy=Int(old.y.rounded())
            var scores=Array(repeating:-2.0,count:169),best = -2.0,bx=0,by=0
            for sy in -6...6 {for sx in -6...6 {
                let score=ncc(frame,x:cx+sx,y:cy+sy,template:templates[index])
                scores[(sy+6)*13+sx+6]=score
                if score>best{best=score;bx=sx;by=sy}
            }}
            guard abs(bx)<6,abs(by)<6 else{return fail("edge " + ["left eye","right eye","nose","chin"][index])}
            var second = -2.0,secondX=0,secondY=0
            for sy in -6...6 {for sx in -6...6 where abs(sx-bx)>2 || abs(sy-by)>2 {
                let value=scores[(sy+6)*13+sx+6]
                if value>second {second=value;secondX=sx;secondY=sy}
            }}
            func offset(_ before:Double,_ middle:Double,_ after:Double)->Double {
                let denominator=before-2*middle+after
                guard before > -1,middle > -1,after > -1,denominator < -0.00001 else{return 0}
                return min(0.5,max(-0.5,0.5*(before-after)/denominator))
            }
            func refine(_ sx:Int,_ sy:Int,_ score:Double)->(Double,Double,Double) {
                guard abs(sx)<6,abs(sy)<6,score<1-0.000000001 else{return (Double(sx),Double(sy),score)}
                let i=(sy+6)*13+sx+6
                let ox=offset(scores[i-1],score,scores[i+1]),oy=offset(scores[i-13],score,scores[i+13])
                let refined=ncc(frame,x:Double(cx+sx)+ox,y:Double(cy+sy)+oy,template:templates[index])
                return refined>score ? (Double(sx)+ox,Double(sy)+oy,refined):(Double(sx),Double(sy),score)
            }
            let peak=refine(bx,by,best),runner=refine(secondX,secondY,second)
            // Evaluate the actual bilinearly sampled new pixels, rather than
            // rejecting a strong correspondence between integer raster centers.
            // Both competing peaks receive the same refinement. No score floor
            // or ambiguity margin is relaxed.
            guard peak.2>=0.90 else{return fail("weak " + ["left eye","right eye","nose","chin"][index])}
            guard peak.2-runner.2>=0.015 else{return fail("ambiguous match")}
            let x=Double(cx)+peak.0+templateOffsets[index].x
            let y=Double(cy)+peak.1+templateOffsets[index].y
            let point=CGPoint(x:x/Double(frame.width-1),y:1-y/Double(frame.height-1))
            guard finite(point) else{return fail("point bounds")}
            found.append(point);deltas.append(CGPoint(x:x-old.x,y:y-old.y));confidence=min(confidence,peak.2)
        }
        let dx=deltas.reduce(0){$0+$1.x}/3,dy=deltas.reduce(0){$0+$1.y}/3
        // A frozen anatomical model avoids treating expression/jaw motion as
        // whole-head posture. The three primary anchors are measured in this
        // frame. Project jaw from the full-model seed, never from the previous
        // projected jaw, so interpolation errors cannot accumulate over time.
        let totalX=(0..<3).reduce(0.0){$0+Double(found[$1].x-seedPoints[$1].x)}/3
        let totalY=(0..<3).reduce(0.0){$0+Double(found[$1].y-seedPoints[$1].y)}/3
        guard (0..<3).allSatisfy({
            hypot(Double(found[$0].x-seedPoints[$0].x-totalX)*Double(frame.width-1),
                  Double(found[$0].y-seedPoints[$0].y-totalY)*Double(frame.height-1))<=1.5
        }) else{return fail("nonrigid head")}
        let jaw=CGPoint(x:seedPoints[3].x+totalX,y:seedPoints[3].y+totalY)
        guard finite(jaw) else{return fail("jaw bounds")}
        found.append(jaw)
        guard deltas.allSatisfy({hypot($0.x-dx,$0.y-dy)<=3.0}),
              found[3].y < min(found[0].y,found[1].y),
              found[2].y < (found[0].y+found[1].y)/2,
              (found[0].x-found[1].x)*(previousPoints[0].x-previousPoints[1].x)>0 else{return fail("inconsistent geometry")}
        let next=previousBox.offsetBy(dx:dx/Double(frame.width-1),dy:-dy/Double(frame.height-1))
        guard valid(next) else{return fail("face bounds")}
        previousPoints=found;previousBox=next;lastAt=time;lastFailure=nil
        return LandmarkPatchTrack(box:next,points:found,confidence:confidence)
    }
    private func finite(_ point:CGPoint)->Bool {point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)}
    private func valid(_ box:CGRect)->Bool {box.origin.x.isFinite && box.origin.y.isFinite && box.width.isFinite && box.height.isFinite && box.width>0 && box.height>0 && box.minX>=0 && box.minY>=0 && box.maxX<=1 && box.maxY<=1}
    private func pixel(_ point:CGPoint,_ frame:Frame)->CGPoint {CGPoint(x:point.x*Double(frame.width-1),y:(1-point.y)*Double(frame.height-1))}
    private func patch(_ frame:Frame,x:Int,y:Int)->Patch? {
        guard x>=radius,y>=radius,x+radius<frame.width,y+radius<frame.height else{return nil}
        var values:[Double]=[];let count=Double((radius*2+1)*(radius*2+1));values.reserveCapacity(Int(count))
        for dy in -radius...radius {for dx in -radius...radius{values.append(frame.luma[(y+dy-frame.originY)*frame.storageWidth+x+dx-frame.originX])}}
        let mean=values.reduce(0,+)/count
        values=values.map{$0-mean};let energy=values.reduce(0){$0+$1*$1}
        guard energy>=count*25 else{return nil}
        return Patch(pixels:values,energy:energy)
    }
    private func ncc(_ frame:Frame,x:Int,y:Int,template:Patch)->Double {
        guard x>=radius,y>=radius,x+radius<frame.width,y+radius<frame.height else{return -2}
        let count=Double((radius*2+1)*(radius*2+1))
        var sum=0.0,squares=0.0,dot=0.0,index=0
        for dy in -radius...radius {for dx in -radius...radius {
            let value=frame.luma[(y+dy-frame.originY)*frame.storageWidth+x+dx-frame.originX]
            sum+=value;squares+=value*value;dot+=value*template.pixels[index];index+=1
        }}
        let energy=max(0,squares-sum*sum/count)
        guard energy>=count*25 else{return -2}
        return min(1,max(-1,dot/sqrt(energy*template.energy)))
    }
    private func ncc(_ frame:Frame,x:Double,y:Double,template:Patch)->Double {
        let ix=Int(floor(x)),iy=Int(floor(y)),fx=x-floor(x),fy=y-floor(y)
        guard ix>=radius,iy>=radius,ix+radius+1<frame.width,iy+radius+1<frame.height else{return -2}
        let count=Double((radius*2+1)*(radius*2+1))
        var sum=0.0,squares=0.0,dot=0.0,index=0
        for dy in -radius...radius {for dx in -radius...radius {
            let i=(iy+dy-frame.originY)*frame.storageWidth+ix+dx-frame.originX
            let top=frame.luma[i]*(1-fx)+frame.luma[i+1]*fx
            let bottom=frame.luma[i+frame.storageWidth]*(1-fx)+frame.luma[i+frame.storageWidth+1]*fx
            let value=top*(1-fy)+bottom*fy
            sum+=value;squares+=value*value;dot+=value*template.pixels[index];index+=1
        }}
        let energy=max(0,squares-sum*sum/count)
        guard energy>=count*25 else{return -2}
        return min(1,max(-1,dot/sqrt(energy*template.energy)))
    }
    private func read(_ buffer:CVPixelBuffer,points:[CGPoint])->Frame? {
        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer)
        guard width>=24,height>=24,width<=512,height<=512 else{return nil}
        let format=CVPixelBufferGetPixelFormatType(buffer)
        let planar=format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || format==kCVPixelFormatType_32BGRA else{return nil}
        guard CVPixelBufferLockBaseAddress(buffer,.readOnly)==kCVReturnSuccess else{return nil}
        defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        guard let address=planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,0):CVPixelBufferGetBaseAddress(buffer) else{return nil}
        let bytes=address.assumingMemoryBound(to:UInt8.self),stride=planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,0):CVPixelBufferGetBytesPerRow(buffer)
        guard points.count==3,points.allSatisfy({finite($0)}) else{return nil}
        let pixels=points.map{CGPoint(x:$0.x*Double(width-1),y:(1-$0.y)*Double(height-1))}
        // Only the three search neighborhoods need filtered luma. Coordinates
        // remain full-image normalized; this is no crop or camera/FOV change.
        // Extra support covers search6 + template radius + interpolation1 + filter1.
        let margin=radius+8
        let x0=max(1,Int(pixels.map(\.x).min()!.rounded())-margin)
        let x1=min(width-2,Int(pixels.map(\.x).max()!.rounded())+margin)
        let y0=max(1,Int(pixels.map(\.y).min()!.rounded())-margin)
        let y1=min(height-2,Int(pixels.map(\.y).max()!.rounded())+margin)
        guard x0<=x1,y0<=y1 else{return nil}
        func luma(_ x:Int,_ y:Int)->Double {
            let i=y*stride+(planar ? x:4*x)
            return planar ? Double(bytes[i]):0.114*Double(bytes[i])+0.587*Double(bytes[i+1])+0.299*Double(bytes[i+2])
        }
        let originX=x0-1,originY=y0-1,storageWidth=x1-x0+3,storageHeight=y1-y0+3
        var values=Array(repeating:0.0,count:storageWidth*storageHeight)
        for y in 0..<storageHeight {for x in 0..<storageWidth {values[y*storageWidth+x]=luma(x+originX,y+originY)}}
        // Retain all144 original unfiltered scene samples independently of the
        // compact landmark scratch region. No full-image scratch allocations.
        var scene:[Double]=[];scene.reserveCapacity(144)
        for gy in 0..<12 {for gx in 0..<12 {
            let x=min(width-1,(2*gx+1)*width/24),y=min(height-1,(2*gy+1)*height/24)
            scene.append(luma(x,y))
        }}
        var horizontal=values,filtered=values
        for y in 0..<storageHeight {for x in 1..<(storageWidth-1) {
            let i=y*storageWidth+x
            horizontal[i]=(values[i-1]+2*values[i]+values[i+1])*0.25
        }}
        for y in 1..<(storageHeight-1) {for x in 1..<(storageWidth-1) {
            let i=y*storageWidth+x
            filtered[i]=(horizontal[i-storageWidth]+2*horizontal[i]+horizontal[i+storageWidth])*0.25
        }}
        return Frame(width:width,height:height,storageWidth:storageWidth,originX:originX,originY:originY,luma:filtered,scene:scene)
    }
}

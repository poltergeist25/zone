import CoreVideo
import CoreGraphics

/// A tiny luma comparison wakes full face analysis when the face moves. The
/// reference is the last analyzed frame, so gradual movement accumulates.
final class FaceMotionGate {
    private var reference:[Double]?
    private var region=CGRect.zero
    private(set) var difference=Double.infinity
    private(set) var verticalShift=0
    private var contrast=0.0
    func clear(){reference=nil;region = .zero;difference = .infinity;contrast=0;verticalShift=0}
    func interval(for buffer:CVPixelBuffer)->Double {
        guard let reference,let current=sample(buffer),reference.count==current.count,contrast>=8 else{return 1.0/3}
        func residual(_ values:[Double])->Double {
            let brightness=zip(values,reference).reduce(0.0){$0+$1.0-$1.1}/Double(values.count)
            return zip(values,reference).reduce(0.0){$0+abs($1.0-$1.1-brightness)}/Double(values.count)
        }
        let zero=residual(current)
        difference=zero;verticalShift=0
        // Compare the same face patch at small vertical offsets. Sensor noise,
        // exposure and local expressions do not consistently match a translated
        // head. A real upward/downward movement keeps the original fast cadence.
        var best=zero
        for offset in [-4,-2,2,4] {
            guard let values=sample(buffer,offsetY:offset) else{return 1.0/3}
            let error=residual(values)
            if error<best {best=error;verticalShift=offset}
        }
        let translated=verticalShift != 0 && best<zero*0.88 && zero-best>0.45
        let uncertain=zero>min(10,max(3.5,contrast*0.22))
        return translated || uncertain ? 1.0/3:0.53
    }
    func remember(_ buffer:CVPixelBuffer,points:[CGPoint]) {
        guard points.count==4 else{clear();return}
        let eyeWidth=abs(points[0].x-points[1].x)
        let eyeY=(points[0].y+points[1].y)/2,chinY=points[3].y
        let height=max(0.06,eyeY-chinY)
        let x=(points[0].x+points[1].x)/2-eyeWidth*1.5
        let bottom=chinY-height*0.2,top=eyeY+height*0.8
        region=CGRect(x:x,y:1-top,width:eyeWidth*3,height:top-bottom).intersection(CGRect(x:0,y:0,width:1,height:1))
        guard region.width>0.04,region.height>0.04 else{clear();return}
        reference=sample(buffer)
        if let reference {
            let mean=reference.reduce(0,+)/Double(reference.count)
            contrast=sqrt(reference.reduce(0){$0+($1-mean)*($1-mean)}/Double(reference.count))
        }
    }
    private func sample(_ buffer:CVPixelBuffer,offsetY:Int=0)->[Double]? {
        let format=CVPixelBufferGetPixelFormatType(buffer)
        let planar=format==kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format==kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard planar || format==kCVPixelFormatType_32BGRA,region.width>0 else{return nil}
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
        guard let base=planar ? CVPixelBufferGetBaseAddressOfPlane(buffer,0):CVPixelBufferGetBaseAddress(buffer) else{return nil}
        let bytes=base.assumingMemoryBound(to:UInt8.self)
        let row=planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer,0):CVPixelBufferGetBytesPerRow(buffer)
        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer)
        var values:[Double]=[];values.reserveCapacity(576)
        for y in 0..<24 {for x in 0..<24 {
            let px=min(width-1,max(0,Int((region.minX+region.width*(Double(x)+0.5)/24)*Double(width))))
            let py=min(height-1,max(0,Int((region.minY+region.height*(Double(y)+0.5)/24)*Double(height))+offsetY))
            var sum=0.0
            for dy in -1...1 {for dx in -1...1 {
                let sy=min(height-1,max(0,py+dy)),sx=min(width-1,max(0,px+dx))
                if planar {sum += Double(bytes[sy*row+sx])}
                else {let i=sy*row+sx*4;sum += Double(bytes[i])*0.114+Double(bytes[i+1])*0.587+Double(bytes[i+2])*0.299}
            }}
            values.append(sum/9)
        }}
        return values
    }
}

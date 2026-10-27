import CoreVideo
import Foundation
@main struct AnalysisFramesChecks {
    static func main() {
        let frames=AnalysisFrames()
        var source:CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault,1280,720,kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,[kCVPixelBufferIOSurfacePropertiesKey:[:] as [String:Any]] as CFDictionary,&source)==kCVReturnSuccess)
        let input=source!
        CVPixelBufferLockBaseAddress(input,[])
        let ptr=CVPixelBufferGetBaseAddressOfPlane(input,0)!.assumingMemoryBound(to:UInt8.self)
        let stride=CVPixelBufferGetBytesPerRowOfPlane(input,0)
        for y in 0..<720 {for x in 0..<1280 {ptr[y*stride+x]=x<640 ? (y<360 ? 40:120):(y<360 ? 80:160)}}
        memset(CVPixelBufferGetBaseAddressOfPlane(input,1)!,128,CVPixelBufferGetBytesPerRowOfPlane(input,1)*360)
        CVPixelBufferUnlockBaseAddress(input,[])
        let output=frames.resized(input)!
        precondition(CVPixelBufferGetWidth(output)==384 && CVPixelBufferGetHeight(output)==216,"Smaller full-aspect analysis frame")
        CVPixelBufferLockBaseAddress(output,.readOnly)
        let pixels=CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRow(output)
        for (x,y,v) in [(20,20,40),(364,20,80),(20,196,120),(364,196,160)] {precondition(abs(Int(pixels[y*row+x*4])-v)<=3,"All four corners retained without crop or flip")}
        CVPixelBufferUnlockBaseAddress(output,.readOnly)
        precondition(frames.resized(input) === output,"Reuse analysis allocation")
        precondition(frames.resized(output) === output,"Do not upsample smaller frames")
        frames.clear()
        precondition(frames.resized(input) != nil,"Pause releases buffer; resume recreates it")
        // Packed native camera YUV is converted only for an analyzed frame.
        var packed:CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault,1280,720,kCVPixelFormatType_422YpCbCr8,[kCVPixelBufferIOSurfacePropertiesKey:[:] as [String:Any]] as CFDictionary,&packed)==kCVReturnSuccess)
        let native=packed!
        CVPixelBufferLockBaseAddress(native,[])
        let bytes=CVPixelBufferGetBaseAddress(native)!.assumingMemoryBound(to:UInt8.self),packedRow=CVPixelBufferGetBytesPerRow(native)
        for y in 0..<720 {for x in Swift.stride(from:0,to:1280,by:2) {
            let luma:UInt8=x<640 ? (y<360 ? 40:120):(y<360 ? 80:160)
            let i=y*packedRow+x*2;bytes[i]=128;bytes[i+1]=luma;bytes[i+2]=128;bytes[i+3]=luma
        }}
        CVPixelBufferUnlockBaseAddress(native,[])
        let converted=frames.resized(native)!
        precondition(CVPixelBufferGetPixelFormatType(converted)==kCVPixelFormatType_32BGRA)
        CVPixelBufferLockBaseAddress(converted,.readOnly)
        let values=CVPixelBufferGetBaseAddress(converted)!.assumingMemoryBound(to:UInt8.self),convertedRow=CVPixelBufferGetBytesPerRow(converted)
        let corners=[values[20*convertedRow+20*4],values[20*convertedRow+364*4],values[196*convertedRow+20*4],values[196*convertedRow+364*4]]
        precondition(zip(corners,corners.dropFirst()).allSatisfy{$0<$1},"Native YUV retains all four corners and orientation")
        CVPixelBufferUnlockBaseAddress(converted,.readOnly)
        precondition(frames.resized(native) === converted,"Native conversion reuses allocation")
        print("PASS: full-FOV native and planar YUV conversion, orientation, buffer reuse and clear/resume")
    }
}

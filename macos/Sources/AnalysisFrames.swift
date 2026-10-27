import CoreVideo
import VideoToolbox

/// Reuse a smaller analysis frame without cropping or changing normalized geometry.
/// Camera preview keeps its original stream. Frames are never written to disk.
final class AnalysisFrames {
    private var transfer:VTPixelTransferSession?
    private var output:CVPixelBuffer?
    private var sourceWidth=0
    private var sourceHeight=0
    private var format:OSType=0

    func resized(_ source:CVPixelBuffer)->CVPixelBuffer? {
        let width=CVPixelBufferGetWidth(source),height=CVPixelBufferGetHeight(source)
        let pixelFormat=CVPixelBufferGetPixelFormatType(source)
        let targetWidth=min(384,width)
        guard width>384 || pixelFormat != kCVPixelFormatType_32BGRA else{return source}
        if output==nil || sourceWidth != width || sourceHeight != height || format != pixelFormat {
            clear()
            let targetHeight=max(2,Int((Double(height)*Double(targetWidth)/Double(width)/2).rounded())*2)
            guard VTPixelTransferSessionCreate(allocator:kCFAllocatorDefault,pixelTransferSessionOut:&transfer)==noErr,
                  CVPixelBufferCreate(kCFAllocatorDefault,targetWidth,targetHeight,kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey:[:] as [String:Any]] as CFDictionary,&output)==kCVReturnSuccess else{clear();return nil}
            sourceWidth=width;sourceHeight=height;format=pixelFormat
        }
        guard let transfer,let output,
              VTPixelTransferSessionTransferImage(transfer,from:source,to:output)==noErr else{return nil}
        return output
    }
    func clear() {
        if let transfer {VTPixelTransferSessionInvalidate(transfer)}
        transfer=nil;output=nil
    }
    deinit {clear()}
}

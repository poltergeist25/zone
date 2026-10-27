import Foundation
import CoreVideo
@main struct FaceMotionGateChecks {
 static func main() {
  var source:CVPixelBuffer?
  CVPixelBufferCreate(nil,640,360,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&source)
  let buffer=source!,gate=FaceMotionGate()
  let points=[CGPoint(x:0.4,y:0.6),CGPoint(x:0.6,y:0.6),CGPoint(x:0.5,y:0.5),CGPoint(x:0.5,y:0.3)]
  func fill(shift:Int=0,brightness:Int=0,noise:Bool=false,blank:Bool=false) {
   CVPixelBufferLockBaseAddress(buffer,[])
   let p=CVPixelBufferGetBaseAddressOfPlane(buffer,0)!.assumingMemoryBound(to:UInt8.self),row=CVPixelBufferGetBytesPerRowOfPlane(buffer,0)
   for y in 0..<360 {for x in 0..<640 {let raw=blank ? 120:60+((x/5*17+max(0,y-shift)/7*23)%120);p[y*row+x]=UInt8(raw+brightness+(noise ? (x+y)%3-1:0))}}
   CVPixelBufferUnlockBaseAddress(buffer,[])
  }
  fill();precondition(gate.interval(for:buffer)==1.0/3,"No face reference keeps full analysis")
  gate.remember(buffer,points:points);precondition(gate.interval(for:buffer)==0.53,"Still head can use quiet cadence")
  fill(brightness:10);precondition(gate.interval(for:buffer)==0.53,"Uniform exposure change is not head motion")
  fill(noise:true);precondition(gate.interval(for:buffer)==0.53,"Small sensor noise does not wake analysis")
  fill(shift:3);precondition(gate.interval(for:buffer)==1.0/3,"Small vertical movement immediately restores fast cadence")
  fill(shift:-3);precondition(gate.interval(for:buffer)==1.0/3,"Upward recovery immediately restores fast cadence")
  fill(blank:true);precondition(gate.interval(for:buffer)==1.0/3,"Face leaving view wakes detection")
  gate.clear();precondition(gate.interval(for:buffer)==1.0/3,"Reset prevents a stale reference")
  gate.remember(buffer,points:[]);precondition(gate.interval(for:buffer)==1.0/3,"Missing landmarks cannot enter quiet cadence")
  print("PASS: stillness, exposure, noise, 3px movement/recovery, absent face, reset and invalid landmarks")
 }
}

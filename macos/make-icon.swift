import AppKit
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
// Legacy .icns canvases include the macOS outer clearance. Scale the complete
// approved artwork together; do not add a border or alter its proportions.
let footprint=NSAffineTransform()
footprint.translateX(by:100,yBy:100)
footprint.scale(by:824.0/1024.0)
footprint.concat()
// Approved direction1a: twelve notches, empty center, no border.
NSColor(srgbRed:0.12,green:0.25,blue:0.20,alpha:1).setFill()
NSBezierPath(roundedRect:NSRect(x:0,y:0,width:1024,height:1024),xRadius:230,yRadius:230).fill()
NSColor(srgbRed:0.86,green:0.93,blue:0.76,alpha:1).setFill()
let center=NSAffineTransform();center.translateX(by:512,yBy:512);center.concat()
for index in 0..<12 {
 NSGraphicsContext.saveGraphicsState()
 let rotation=NSAffineTransform();rotation.rotate(byRadians:CGFloat(index)*2 * .pi/12);rotation.concat()
 NSBezierPath(roundedRect:NSRect(x:320-151.0/2,y:-40,width:151,height:80),xRadius:14.4,yRadius:14.4).fill()
 NSGraphicsContext.restoreGraphicsState()
}
image.unlockFocus()
let root=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {for scale in [1,2] {
 let pixels=size*scale;let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep);image.draw(in:NSRect(x:0,y:0,width:pixels,height:pixels));NSGraphicsContext.restoreGraphicsState()
 try rep.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"))
}}

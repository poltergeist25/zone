import AppKit
final class Paper:NSView {
 override var isOpaque:Bool{true}
 override func draw(_ dirtyRect:NSRect){NSColor(srgbRed:0.96,green:0.95,blue:0.93,alpha:1).setFill();dirtyRect.fill()}
}
@main struct SmokeMotion {
 static func main() throws {
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
  let w=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:700),styleMask:.borderless,backing:.buffered,defer:false);w.isReleasedWhenClosed=false
  let paper=Paper(frame:NSRect(x:0,y:0,width:1200,height:700));w.contentView=paper
  let smoke=SmokeHaloView(severity:2);smoke.frame=paper.bounds;paper.addSubview(smoke);paper.layoutSubtreeIfNeeded()
  func capture()->NSBitmapImageRep{let b=paper.bitmapImageRepForCachingDisplay(in:paper.bounds)!;paper.cacheDisplay(in:paper.bounds,to:b);return b}
  let first=capture();let c=first.colorAt(x:first.pixelsWide/2,y:first.pixelsHigh/2)!
  precondition(c.alphaComponent>0.99 && c.redComponent>0.9,"Embedded overlay must preserve document background")
  RunLoop.main.run(until:Date().addingTimeInterval(0.2))
  let second=capture()
  precondition(first.tiffRepresentation != second.tiffRepresentation,"Smoke must move across real timer ticks")
  try second.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
  smoke.setSeverity(0);RunLoop.main.run(until:Date().addingTimeInterval(0.2));let recovered=capture()
  let y=Int(20*CGFloat(recovered.pixelsWide)/1200)
  let outside=recovered.colorAt(x:recovered.pixelsWide/2,y:y)!
  precondition(outside.redComponent>0.9 && outside.greenComponent>0.9,"Recovery must clear previous deep colored pixels")
  print("PASS: native timer moves smoke; background survives compositing; recovery leaves no trails")
  w.close()
 }
}

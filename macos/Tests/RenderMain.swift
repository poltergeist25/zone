import SwiftUI
import AppKit
@main struct RenderMain {
 static func main() throws {
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
  let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  let model=CameraModel()
  for review in [false,true] {
   if review {model.active=true;model.hasPose=true;model.stage="review";model.state="yellow";model.score=0.8;model.yellow=0.6;model.red=1.2;model.message="Try moving through your zones. Adjust the boundaries below, then start monitoring."}
   let view=NSHostingView(rootView:MainView(model:model).preferredColorScheme(.light));let size=NSSize(width:1040,height:900)
   let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
   view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.15));view.layoutSubtreeIfNeeded()
   let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent(review ? "native-review-fixture.png":"native-main.png"));window.close();model.stop()
  }
  print("Rendered native initial screen and synthetic review-state fixture; no camera started")
 }
}

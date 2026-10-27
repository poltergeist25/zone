import SwiftUI
import AppKit
@main struct RenderGallery {
 static func main() throws {
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
  for size in [NSSize(width:850,height:600),NSSize(width:1800,height:1100)] {
   let view=NSHostingView(rootView:makeVisualGalleryView().preferredColorScheme(.light))
   let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
   view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.25));view.layoutSubtreeIfNeeded()
   let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:bitmap)
   try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("gallery-build5-\(Int(size.width)).png"));window.close()
  }
  print("Rendered compact and large gallery layouts")
 }
}

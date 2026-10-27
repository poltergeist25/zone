import SwiftUI
import AppKit
@main struct RenderLive {
 static func main() throws {
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited);app.appearance=NSAppearance(named:.aqua)
  let root=VStack(spacing:20){makeLiveFocusView().frame(width:740,height:450);HStack{makeLiveHaloView().frame(width:355,height:200);makeLiveHaloView(yellow:true).frame(width:355,height:200)}}.padding(20).background(Color(red:0.95,green:0.94,blue:0.9)).preferredColorScheme(.light)
  let view=NSHostingView(rootView:root),size=NSSize(width:780,height:710)
  let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false);window.isReleasedWhenClosed=false;window.contentView=view;view.frame=NSRect(origin:.zero,size:size)
  view.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.25));view.layoutSubtreeIfNeeded()
  let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:bitmap)
  try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]));window.close()
  print("Rendered live focus and halo views")
 }
}

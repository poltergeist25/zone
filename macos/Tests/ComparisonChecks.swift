import AppKit
@main struct ComparisonChecks {
 static func main() throws {
  let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
  let out=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
  for s in [0.0,0.5,1,1.5,2,3] {precondition(SmokeGeometry.depth(s,scale:4)==4*SmokeGeometry.depth(s),"Every depth is exactly4×")}
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:700),styleMask:.borderless,backing:.buffered,defer:false)
  window.isReleasedWhenClosed=false;window.isOpaque=false;window.backgroundColor = .clear
  let smoke=SmokeHaloView(severity:2,time:2,depthScale:4);window.contentView=smoke
  smoke.frame=NSRect(x:0,y:0,width:1200,height:700);smoke.layoutSubtreeIfNeeded()
  func capture(_ view:NSView)->NSBitmapImageRep{view.layoutSubtreeIfNeeded();let b=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:b);return b}
  func alpha(_ b:NSBitmapImageRep,_ y:CGFloat)->CGFloat {b.colorAt(x:b.pixelsWide/2,y:Int(y*CGFloat(b.pixelsHigh)/700))!.alphaComponent}
  let wide=capture(smoke)
  precondition(alpha(wide,45)>0.01 && alpha(wide,210)==0 && alpha(wide,350)==0,"Wide smoke extends inward with clear center")
  try wide.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("smoke-4x.png"))
  smoke.setDepthScale(1);let narrow=capture(smoke)
  precondition(alpha(narrow,45)==0,"Switching back clears deeper smoke")
  smoke.setDepthScale(4);smoke.setSeverity(0);let recovered=capture(smoke)
  precondition(alpha(recovered,45)==0,"Recovery clears deeper smoke immediately")
  window.close()
  let glow=MenuBarGlowController();glow.present(true,severity:0)
  precondition(glow.panels.count==NSScreen.screens.count)
  let ids=glow.panels.map{ObjectIdentifier($0)}
  for (panel,screen) in zip(glow.panels,NSScreen.screens) {
   precondition(panel.frame.width==screen.frame.width && panel.frame.maxY==screen.frame.maxY && panel.frame.height<80,"Tint spans the top menu bar, not the screen")
   precondition(panel.ignoresMouseEvents && !panel.isOpaque && panel.level.rawValue>NSWindow.Level.mainMenu.rawValue && panel.level.rawValue<NSWindow.Level.popUpMenu.rawValue,"Native menus stay clickable and above tint")
  }
  glow.present(true,severity:2,progress:1);precondition(glow.panels.map{ObjectIdentifier($0)}==ids,"Updates reuse panels")
  glow.present(false);precondition(glow.panels.isEmpty,"Lost/pause/stop clear tint")
  let live=LiveZoneVisualsController();live.showsSmoke=false;live.showsMenuGlow=true
  live.present(.redFocus,severity:2,progress:1)
  precondition(app.windows.filter{$0.isVisible && !$0.ignoresMouseEvents}.count==1,"Menu glow keeps same red card")
  live.present(.greenHalo,severity:0)
  precondition(app.windows.filter{$0.isVisible && !$0.ignoresMouseEvents}.isEmpty,"Recovery clears card")
  live.present(.hidden);precondition(app.windows.filter{$0.isVisible}.isEmpty,"Stop clears all comparison windows")
  for (name,s) in [("green",0.0),("yellow",1.0),("red",2.0)] {
   let view=MenuBarGlowView(severity:s,progress:1,time:0.25/MenuBarIcon.pulseFrequency)
   view.frame=NSRect(x:0,y:0,width:1200,height:28)
   let b=capture(view);let color=b.colorAt(x:b.pixelsWide/2,y:b.pixelsHigh/2)!.usingColorSpace(.sRGB)!
   precondition(color.alphaComponent>0.1 && color.alphaComponent<0.5,"Tint remains visible and translucent")
   if s==0 {precondition(color.greenComponent>color.redComponent)}
   if s==2 {precondition(color.redComponent>color.greenComponent)}
   try b.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("menu-bar-\(name).png"))
  }
  precondition(MenuBarGlowView.opacity(severity:2,progress:1,time:0,reduceMotion:true)>MenuBarGlowView.opacity(severity:0,progress:1,time:0,reduceMotion:true))
  print("PASS: exact4× depths; clear center; switch/recovery clears smoke; full-width menu-bar tint; click-through/pop-up layering; reusable panels; red-card recovery; three native color renders")
 }
}

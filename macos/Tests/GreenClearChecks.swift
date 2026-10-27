import AppKit
@main struct GreenClearChecks {
 static func main() {
  let app=NSApplication.shared
  let controller=LiveZoneVisualsController();controller.showsMenuGlow=true
  controller.present(.greenHalo,severity:0)
  precondition(!app.windows.contains{$0.isVisible},"Green has no smoke, tint or card")
  controller.present(.yellowHalo,severity:1.4)
  precondition(app.windows.filter{$0.isVisible && $0.ignoresMouseEvents}.count==2*NSScreen.screens.count,"Yellow has smoke and menu glow on each screen")
  controller.smokeDepthScale=0
  precondition(app.windows.filter{$0.isVisible && $0.ignoresMouseEvents}.count==NSScreen.screens.count,"Zero disables smoke but keeps menu glow")
  controller.present(.yellowHalo,severity:1.6)
  precondition(app.windows.filter{$0.isVisible && $0.ignoresMouseEvents}.count==NSScreen.screens.count,"New observations cannot revive zero-depth smoke")
  controller.present(.redFocus,severity:2,progress:1)
  precondition(app.windows.filter{$0.isVisible && !$0.ignoresMouseEvents}.count==1,"Zero depth retains red card")
  controller.smokeDepthScale=10
  precondition(app.windows.filter{$0.isVisible && $0.ignoresMouseEvents}.count==2*NSScreen.screens.count,"Raising depth restores smoke immediately")
  precondition(app.windows.filter{$0.isVisible && !$0.ignoresMouseEvents}.count==1,"Red still adds original focus card")
  controller.present(.greenHalo,severity:0)
  precondition(!app.windows.contains{$0.isVisible},"Returning to green immediately removes smoke, tint and card")
  controller.showsSmoke=false;controller.showsSmoke=true
  controller.showsMenuGlow=false;controller.showsMenuGlow=true
  precondition(!app.windows.contains{$0.isVisible},"Preference refresh cannot revive green effects")
  print("PASS: green clear; yellow smoke and glow; red original card; immediate green recovery")
 }
}

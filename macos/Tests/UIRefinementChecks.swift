import AppKit
@main struct UIRefinementChecks {
 static func main() throws {
  _=NSApplication.shared
  let iso=ISO8601DateFormatter()
  precondition(ZoneBranding.copyright(at:iso.date(from:"2027-01-01T04:59:59Z")!)=="© 2026 Gramercy Systems Inc")
  precondition(ZoneBranding.copyright(at:iso.date(from:"2027-01-01T05:00:00Z")!)=="© 2027 Gramercy Systems Inc")
  let screen=NSScreen.main!.visibleFrame
  let prior=NSApp.windows.filter{$0.isVisible}.count
  VisualStylesController.shared.showFocusPreview()
  let previews=NSApp.windows.filter{$0.isVisible && $0 is NSPanel}
  precondition(previews.count==1,"One explicit preview panel")
  precondition(previews[0].frame==FocusCardLayout.frame(in:screen),"Preview uses original live red-card size")
  RunLoop.main.run(until:Date().addingTimeInterval(5.2))
  precondition(NSApp.windows.filter{$0.isVisible}.count==prior,"Preview dismisses after five seconds")
  print("PASS: current Eastern copyright year and original-size timed red preview")
 }
}

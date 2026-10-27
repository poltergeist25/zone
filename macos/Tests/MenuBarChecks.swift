import AppKit
import Foundation
@main struct MenuBarChecks {
 static func main() throws {
  let app=NSApplication.shared
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-menu-check-\(UUID().uuidString)")
  defer{try? FileManager.default.removeItem(at:directory)}
  let model=CameraModel(store:PreferencesStore(url:directory.appendingPathComponent("preferences.json")))
  precondition(model.smokeDepth==8,"First launch defaults to8x")
  for depth in [0.0,10,8] {
   model.setSmokeDepth(depth)
   let restored=try PreferencesStore(url:directory.appendingPathComponent("preferences.json")).load()!
   precondition(model.smokeDepth==depth && restored.resolvedSmokeDepth==depth,"Live slider writes actual preference")
  }
  let delegate=ZoneAppDelegate(model:model);app.delegate=delegate
  delegate.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
  precondition(app.activationPolicy() == .regular,"Open controls appear in Dock and Command-Tab")
  precondition(!model.active && !model.loading,"Launching must not start camera")
  var window=delegate.controlsWindow!
  let status=delegate.statusItem!
  precondition(window.isVisible && window.title=="Zone" && status.button != nil)
  precondition(window.contentView!.frame.size == ZoneWindowLayout.size && !window.styleMask.contains(.resizable),"Controls keep their compact fixed size")
  precondition(!window.hidesOnDeactivate && window.level == .normal,"Controls stay open without floating above other apps")
  precondition(window.collectionBehavior.contains(.managed) && !window.collectionBehavior.contains(.canJoinAllSpaces) && !window.collectionBehavior.contains(.canJoinAllApplications),"Controls use ordinary desktop/window ordering")
  let attached=window.contentView
  let peer=NSWindow(contentRect:window.frame,styleMask:.titled,backing:.buffered,defer:false)
  peer.isReleasedWhenClosed=false;peer.title="Ordinary app window fixture";peer.orderFrontRegardless()
  peer.makeKeyAndOrderFront(nil)
  let order=app.orderedWindows
  precondition(window.level==peer.level && order.firstIndex(of:peer)! < order.firstIndex(of:window)!,"The clicked normal window must come in front of Zone")
  precondition(window.isVisible && window.contentView === attached,"Covered controls remain open and retain content")
  app.deactivate()
  RunLoop.main.run(until:Date().addingTimeInterval(0.15))
  precondition(window.isVisible && window.contentView === attached,"Native test-app deactivation must retain visible controls and content")
  peer.close();delegate.showControls()
  precondition(app.activationPolicy() == .regular,"Covering or deactivating open controls keeps Dock/Command-Tab presence")
  precondition(status.menu==nil,"Status icon has no permanent menu to intercept left-click")
  precondition(status.button?.target as? ZoneAppDelegate === delegate && status.button?.action == #selector(ZoneAppDelegate.statusItemClicked(_:)),"Status button routes left and right clicks separately")
  precondition(!ZoneAppDelegate.opensStatusMenu(for:nil) && !ZoneAppDelegate.opensStatusMenu(for:.leftMouseUp),"Ordinary left-click and accessibility activation open controls")
  precondition(ZoneAppDelegate.opensStatusMenu(for:.rightMouseUp),"Right-click opens contextual commands")
  precondition(ZoneAppDelegate.opensStatusMenu(for:.leftMouseUp,controlPressed:true),"Control-click also supports the native contextual menu")
  let contextual=delegate.makeStatusMenu()
  precondition(contextual.items.map(\.title)==["Open Zone","","Quit app"],"Right-click menu stays minimal")
  precondition(contextual.items[0].target as? ZoneAppDelegate === delegate && contextual.items[0].action == #selector(ZoneAppDelegate.showControls),"Contextual Open uses the existing controls action")
  let quit=contextual.items[2]
  precondition(quit.target as? ZoneAppDelegate === delegate && quit.action == #selector(ZoneAppDelegate.quitZone) && quit.keyEquivalent=="q","Contextual Quit uses existing camera-stop and termination action")
  precondition(status.menu==nil && model.active==false,"Building right-click commands neither installs a permanent menu nor starts tracking")
  func settle(_ condition:()->Bool) {
   let deadline=Date().addingTimeInterval(2)
   while !condition() && Date()<deadline {RunLoop.main.run(until:Date().addingTimeInterval(0.01))}
   precondition(condition(),"Published state must automatically refresh the menu-bar presentation")
  }
  model.loading=true
  settle{status.button!.toolTip?.contains("Starting camera")==true}
  model.loading=false
  settle{status.button!.toolTip?.contains("Camera off")==true}
  model.active=true;model.stage="monitoring";model.state="inside";model.hasPose=true;model.score=0
  let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5]);precondition(model.engine.restoreValidated(baseline:baseline,yellow:0.8,red:1.8,delay:2))
  delegate.refreshStatus()
  precondition(status.button!.toolTip!.contains("Green"))
  func pixelColor()->NSColor {
   let image=status.button!.image!;let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
   var strongest=NSColor.clear
   for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {
    if let color=bitmap.colorAt(x:x,y:y)?.usingColorSpace(.sRGB),color.alphaComponent>strongest.alphaComponent{strongest=color}
   }}
   precondition(strongest.alphaComponent>0.25,"Status icon must have visible pixels even at 1x rasterization")
   return strongest
  }
  precondition(!status.button!.image!.isTemplate && pixelColor().greenComponent>pixelColor().redComponent,"Green must render colored pixels")
  let steadyGreen=status.button!.image!
  for amount in [0.1,0.3,0.7,0.95,0.2] {
   model.score=model.yellow*amount;delegate.refreshStatus()
   precondition(status.button!.image === steadyGreen,"Movement within green must not redraw the status icon")
  }
  model.paused=true
  settle{status.button!.image?.isTemplate==true && status.button!.toolTip?.contains("paused")==true}
  model.paused=false;delegate.refreshStatus()
  precondition(!status.button!.image!.isTemplate && !delegate.isMenuIconAnimating,"Resume redraws static green without a timer")
  model.score=model.yellow;model.state="yellow";delegate.refreshStatus()
  let amber=pixelColor();precondition(amber.redComponent>0.8 && amber.greenComponent>0.5 && amber.blueComponent<0.2,"Yellow icon follows personal boundary")
  let steadyYellow=status.button!.image!
  for fraction in [0.1,0.5,0.9,0.3] {
   model.score=model.yellow+(model.red-model.yellow)*fraction;delegate.refreshStatus()
   precondition(status.button!.image === steadyYellow,"Movement within yellow must not redraw the color icon")
  }
  model.score=model.yellow;model.setMenuBarStyle(.score)
  let iconClock=ProcessInfo.processInfo.systemUptime
  delegate.refreshStatus(at:iconClock)
  precondition(model.menuBarStyle == .color,"Retired numeric choice resolves to the color icon")
  precondition(status.length==NSStatusItem.squareLength && status.button!.image!.size==MenuBarIcon.colorStatusSize,"Menu icon always retains compact square art")
  let unchanged=status.button!.image!
  model.score=(model.yellow+model.red)/2;delegate.refreshStatus(at:iconClock+0.2)
  delegate.refreshStatus(at:iconClock+1.01)
  precondition(status.button!.image === unchanged && !status.button!.toolTip!.contains("/100"),"Score movement never adds a number or redraws the zone art")
  model.score=model.red;model.state="outside";delegate.refreshStatus(at:iconClock+1.02)
  precondition(pixelColor().redComponent>0.8 && pixelColor().greenComponent<0.4,"Red color changes on the same update")
  model.setMenuBarStyle(.color);delegate.refreshStatus()
  precondition(status.length==NSStatusItem.squareLength,"Color icon keeps compact status width")
  model.score=model.red;model.state="outside";delegate.refreshStatus()
  let red=pixelColor();precondition(red.redComponent>0.8 && red.greenComponent<0.4,"Red icon appears before delayed focus card")
  model.setReminderMode(.menuBar);model.warningProgress=0.8;delegate.refreshStatus()
  precondition(!delegate.isMenuIconAnimating && status.button?.layer?.animation(forKey:"zone-breath")==nil,"Live icon keeps spectrum without continuous button animation")
  precondition(ControlsPage.allCases == [.posture,.progress,.settings],"Posture, Progress and Settings navigation")
  precondition(model.active && model.engine.baseline?.values==baseline.values,"Mode switch preserves monitoring and calibration")
  model.receive(PoseFeatures([0,0.4,0,0.3,0.6,0.8]),at:200)
  model.receive(nil,at:200.3,loss:.bottom);delegate.refreshStatus()
  precondition(model.bottomExitHeld && !model.hasPose && !status.button!.image!.isTemplate && pixelColor().redComponent>0.8,"Bottom hold retains the red menu icon")
  model.receive(nil,at:200.4,loss:.side);delegate.refreshStatus()
  precondition(status.button!.image!.isTemplate,"Side loss clears the held red menu icon")
  model.hasPose=true
  model.score=0;model.state="inside";delegate.refreshStatus()
  precondition(pixelColor().greenComponent>pixelColor().redComponent,"Recovery immediately redraws green despite stale warning progress")
  model.hasPose=false;delegate.refreshStatus();precondition(status.button!.image!.isTemplate && !delegate.isMenuIconAnimating,"Tracking loss clears stale color and timer")
  model.hasPose=true;model.setReminderMode(.smoke);delegate.refreshStatus()
  precondition(!delegate.isMenuIconAnimating,"Green does not run a redundant icon animation timer")
  model.hasPose=true;model.score=0;model.state="inside";delegate.refreshStatus()
  model.togglePause();precondition(model.paused && !model.cameraEnabled,"Pause updates camera switch off")
  model.setCameraEnabled(true);precondition(!model.paused && model.cameraEnabled,"Switch on resumes a paused session")
  delegate.showSettings()
  precondition(model.controlsPage == .settings && window.isVisible,"Settings has a direct native action")
  precondition(window.contentView!.frame.size==ZoneWindowLayout.size,"Settings preserves fixed window")
  model.controlsPage = .posture
  model.setReminderMode(.smoke);delegate.refreshStatus()
  let rememberedFrame=window.frame
  window.performClose(nil)
  precondition(delegate.controlsWindow==nil,"Closing releases the native controls window")
  precondition(window.contentView==nil,"Hidden controls release preview and chart rendering")
  precondition(!window.isVisible && model.active && model.engine.baseline != nil,"Red close must hide without stopping/resetting")
  settle{app.activationPolicy() == .accessory}
  precondition(NSRunningApplication.current.activationPolicy == .accessory,"Closed controls return to menu-bar-only activation")
  precondition(!delegate.applicationShouldTerminateAfterLastWindowClosed(app))
  status.button!.performClick(nil)
  precondition(delegate.controlsWindow !== window && delegate.statusItem === status,"Status icon recreates controls without recreating the camera owner")
  window=delegate.controlsWindow!
  precondition(window.isVisible && window.frame==rememberedFrame,"Recreated controls retain the same position and size")
  precondition(app.windows.filter{$0.identifier==NSUserInterfaceItemIdentifier("posture-main") && $0.isVisible}.count==1,"Only one controls window may be visible")
  precondition(app.activationPolicy() == .regular,"Status-button reopen restores Dock and Command-Tab")
  NotificationCenter.default.post(name:NSApplication.didResignActiveNotification,object:app)
  precondition(window.isVisible && model.active,"Focus loss must not hide controls or stop monitoring")
  NotificationCenter.default.post(name:NSWindow.willCloseNotification,object:window)
  precondition(model.active,"Old window-close camera-stop observer is gone")
  delegate.hideControls();precondition(!window.isVisible && model.active)
  delegate.showControls();window=delegate.controlsWindow!
  RunLoop.main.run(until:Date().addingTimeInterval(0.1))
  precondition(window.isVisible && app.activationPolicy() == .regular && model.active,"Rapid reopen cancels deferred Dock removal and preserves tracking")
  window.miniaturize(nil)
  settle{window.isMiniaturized}
  precondition(window.isMiniaturized && app.activationPolicy() == .regular,"Minimized controls remain findable in the Dock")
  precondition(model.updateWindowContext?().visible == true,"Minimized controls count as open for update continuity")
  delegate.hideControls();settle{app.activationPolicy() == .accessory}
  precondition(delegate.controlsWindow==nil && !window.isVisible && model.active,"Closing minimized controls releases their window and Dock presence without stopping tracking")
  model.paused=true;delegate.refreshStatus();precondition(status.button!.toolTip!.contains("paused") && status.button!.image!.isTemplate,"Paused icon must be neutral")
  precondition(status.menu == nil,"Paused state does not reattach a command menu")
  delegate.showControls();window=delegate.controlsWindow!
  precondition(window.contentView != nil && model.paused && app.activationPolicy() == .regular,"Reopening recreates Dock-visible controls without resuming a pause")
  let snapshot=NSHostingViewPlaceholder.capture(window)
  if CommandLine.arguments.count>1 {try snapshot.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))}
  delegate.hideControls()
  delegate.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
  precondition(!model.active && delegate.statusItem==nil,"Explicit termination stops capture and removes status item")
  print("PASS: open Dock/Command-Tab and closed accessory policy; rapid reopen and minimize continuity; launch camera off; persistent camera/icon and recreated positioned controls; close and focus loss preserve tracking; left-click controls and right/control-click command routing, contextual Quit action, Settings navigation; termination cleanup")
 }
}
enum NSHostingViewPlaceholder {
 static func capture(_ window:NSWindow)->Data {
  let view=window.contentView!;view.layoutSubtreeIfNeeded()
  let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!;view.cacheDisplay(in:view.bounds,to:bitmap)
  return bitmap.representation(using:.png,properties:[:])!
 }
}

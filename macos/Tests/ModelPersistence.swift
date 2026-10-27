import Foundation
import AppKit

@main struct ModelPersistenceChecks {
 static func main() throws {
  _=NSApplication.shared
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("posture-model-check-\(UUID().uuidString)",isDirectory:true)
  defer{try? FileManager.default.removeItem(at:directory)}
  let store=PreferencesStore(url:directory.appendingPathComponent("preferences.json"))
  let baseline=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
  let first=CameraModel(store:store,observesLifecycle:false,presentsVisuals:false)
  first.select("test-studio-camera");first.delay=3;first.applyThresholds()
  let partial=try store.load()
  precondition(partial?.delay == 3)
  precondition(partial?.calibration(for:"test-studio-camera") == nil,"Partial settings must not invent calibration")
  first.engine.restoreValidated(baseline:baseline,yellow:0.8,red:1.8,delay:3)
  first.active=true;first.stage="review";first.yellow=0.8;first.red=1.8
  var low=baseline;low.centerY=0.8
  first.receive(low,at:0);first.receive(low,at:0.5);first.receive(baseline,at:0.6);first.confirm()
  precondition(first.hasSavedCalibration && first.persistenceMessage == nil)
  first.stop()
  let second=CameraModel(store:PreferencesStore(url:store.url),observesLifecycle:false,presentsVisuals:false)
  precondition(!second.active && !second.loading && second.stage=="idle","Relaunch must not start the camera")
  precondition(second.selectedID=="test-studio-camera" && second.hasSavedCalibration && second.delay==3)
  precondition(second.yellow==0.8 && second.red==1.8)
  second.yellow=0.9;second.red=2.2;second.delay=2.5;second.applyThresholds()
  let third=CameraModel(store:PreferencesStore(url:store.url),observesLifecycle:false,presentsVisuals:false)
  precondition(third.hasSavedCalibration && third.yellow==0.9 && third.red==2.2 && third.delay==2.5,"Idle edits must save")
  let persisted=try store.load()!
  precondition(persisted.calibration(for:"test-studio-camera")!.baseline==baseline.values)
  third.setReminderMode(.menuBar)
  let modeSaved=try store.load()!
  precondition(modeSaved.reminderMode == .menuBar && modeSaved.calibration(for:"test-studio-camera")!.baseline==baseline.values,"Mode change preserves confirmed calibration")
  let modeReload=CameraModel(store:PreferencesStore(url:store.url),observesLifecycle:false,presentsVisuals:false)
  precondition(modeReload.reminderMode == .menuBar && !modeReload.active,"Comparison choice restores without starting camera")
  third.setReminderMode(.smokeWide)
  precondition(CameraModel(store:PreferencesStore(url:store.url),observesLifecycle:false,presentsVisuals:false).smokeDepth == third.smokeDepth,"Wide smoke survives restart")
  third.select("another-camera")
  precondition(!third.hasSavedCalibration,"Never reuse a different camera's calibration")
  third.select("test-studio-camera")
  precondition(third.hasSavedCalibration && third.yellow==0.9)
  third.restartSetup()
  let fourth=CameraModel(store:PreferencesStore(url:store.url),observesLifecycle:false,presentsVisuals:false)
  precondition(fourth.hasSavedCalibration,"Unfinished recalibration must retain confirmed baseline")
  precondition(fourth.delay==2.5,"Recalibrate keeps reminder preferences")
  fourth.yellow=3;fourth.red=1;fourth.delay=4.5;fourth.applyThresholds()
  let partialSetup=try store.load()!
  precondition(partialSetup.delay==4.5 && partialSetup.calibration(for:"test-studio-camera")?.baseline==baseline.values,"Delay must persist even during incomplete boundary setup")
  // Failed writes must be visible rather than claiming saved calibration.
  let blocker=directory.appendingPathComponent("file-instead-of-folder")
  try Data("x".utf8).write(to:blocker)
  let failure=CameraModel(store:PreferencesStore(url:blocker.appendingPathComponent("preferences.json")),observesLifecycle:false,presentsVisuals:false)
  failure.select("test-camera");failure.delay=4;failure.applyThresholds()
  precondition(failure.persistenceMessage != nil && !failure.hasSavedCalibration)
  print("PASS: model confirm/stop/relaunch, idle edits, camera binding, non-destructive recalibration, visible save failure; no camera started")
 }
}

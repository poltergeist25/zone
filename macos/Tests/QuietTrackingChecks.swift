import AppKit
import Combine

@main enum QuietTrackingChecks {
 static func main() {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("zone-quiet-"+UUID().uuidString)
  let model=CameraModel(store:PreferencesStore(url:directory.appendingPathComponent("settings.json")),observesLifecycle:false,presentsVisuals:false)
  let pose=PoseFeatures([0,0.4,0,0.3,0.6,0.5])
  precondition(model.engine.restoreValidated(baseline:pose,yellow:0.6,red:1,delay:2))
  model.active=true;model.stage="monitoring";model.yellow=0.6;model.red=1
  model.receive(pose,at:100)
  var changes=0
  let subscription=model.objectWillChange.sink{changes += 1}
  for time in [100.4,100.8,101.2,101.6] {model.receive(pose,at:time)}
  precondition(changes==0,"Unchanged tracking should not repeatedly wake controls/menu subscribers")
  precondition(model.hasPose && model.score==0 && model.state=="inside","Quiet publication must preserve live tracking")
  model.receive(PoseFeatures([0,0.4,0,0.3,0.6,0.56]),at:102)
  precondition(changes>0 && model.state=="yellow","Real score/zone changes must still publish")
  model.receive(pose,at:102.4)
  precondition(model.state=="inside" && model.score==0,"Recovery must publish on the first green observation")
  withExtendedLifetime(subscription){}
  model.stop()
  print("PASS: unchanged tracking avoids model notifications; real warnings and first-frame recovery publish")
 }
}

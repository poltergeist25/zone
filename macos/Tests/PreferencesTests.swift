import Foundation

@main struct PreferencesTests {
    static var checks=0
    static func check(_ condition:@autoclosure ()->Bool,_ name:String) {
        guard condition()else{fatalError("FAIL: \(name)")};checks += 1;print("PASS: \(name)")
    }
    static func main()throws {
        if CommandLine.arguments.count==3 && CommandLine.arguments[1]=="--read-saved" {
            let saved=try PreferencesStore(url:URL(fileURLWithPath:CommandLine.arguments[2])).load()
            guard let saved,let calibration=saved.calibration(for:"camera-A"),saved.selectedCameraID=="camera-A",saved.delay==3.5,calibration.baseline==[0,-0.6,0,0.4,0.5,0.5]else{exit(2)}
            print("Independent process restored saved geometry and settings");return
        }
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("posture-preferences-tests-\(UUID().uuidString)",isDirectory:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("preferences.json")
        let store=PreferencesStore(url:url)
        let missing=try store.load()
        check(missing==nil,"Missing file has no invented calibration")
        var preferences=PosturePreferences()
        preferences.selectedCameraID="camera-A";preferences.delay=3.5
        preferences.calibrations["camera-A"]=SavedCalibration(cameraID:"camera-A",baseline:[0,-0.6,0,0.4,0.5,0.5],yellow:0.8,red:1.3)
        try store.save(preferences)
        let restored=try PreferencesStore(url:url).load()!
        check(restored.selectedCameraID=="camera-A" && restored.delay==3.5,"Fresh store loads selected camera and delay")
        check(restored.calibration(for:"camera-A")?.baseline==preferences.calibration(for:"camera-A")?.baseline,"Six baseline values roundtrip exactly")
        check(restored.calibration(for:"camera-B")==nil,"Calibration never crosses camera IDs")
        check(restored.reminderMode == nil,"Existing settings without mode keep smoke default")
        check(restored.resolvedSmokeDepth==8,"Legacy profile defaults to requested8x")
        check(restored.resolvedMenuBarStyle == .color,"Existing profiles default to the color icon")
        check(restored.resolvedLiveChartMotion == .responsive,"Missing chart motion defaults to more frequent actual samples")
        for motion in LiveChartMotion.allCases {
            preferences.liveChartMotion=motion.rawValue;try store.save(preferences)
            let loaded=try store.load()!
            check(loaded.resolvedLiveChartMotion==motion && loaded.calibration(for:"camera-A")?.baseline==restored.calibration(for:"camera-A")?.baseline,"Chart motion persists without changing height")
        }
        preferences.liveChartMotion="future-motion";try store.save(preferences)
        let futureMotion=try store.load()!
        check(futureMotion.resolvedLiveChartMotion == .responsive && futureMotion.calibration(for:"camera-A") != nil,"Unknown chart motion does not invalidate calibration")
        preferences.liveChartMotion=nil
        for style in MenuBarStyle.allCases {
            preferences.menuBarStyle=style.rawValue;try store.save(preferences)
            let loaded=try store.load()!
            check(loaded.resolvedMenuBarStyle == .color && loaded.menuBarStyle==style.rawValue && loaded.calibration(for:"camera-A")?.baseline==restored.calibration(for:"camera-A")?.baseline,"Menu style persists without changing height")
        }
        preferences.menuBarStyle="future-appearance";try store.save(preferences)
        let future=try store.load()!
        check(future.resolvedMenuBarStyle == .color && future.calibration(for:"camera-A") != nil,"Unknown menu appearance keeps saved calibration usable")
        check(restored.resolvedRedAlertEnabled,"Existing profiles keep the red card enabled")
        for enabled in [false,true] {
            preferences.redAlertEnabled=enabled;try store.save(preferences)
            let loaded=try store.load()!
            check(loaded.resolvedRedAlertEnabled==enabled && loaded.calibration(for:"camera-A")?.baseline==restored.calibration(for:"camera-A")?.baseline,"Red-card toggle persists without changing height")
        }
        preferences.redAlertEnabled=nil
        preferences.menuBarStyle=nil
        for value in [0.0,2,8,10,25,50] {
            preferences.smokeDepth=value;try store.save(preferences)
            let loaded=try store.load()!
            check(loaded.resolvedSmokeDepth==min(10,value) && loaded.calibration(for:"camera-A")?.baseline==restored.calibration(for:"camera-A")?.baseline,"Depth \(value)x persists without recalibration")
        }
        for legacy in [ReminderMode.smoke2,.smokeWide,.smoke8,.smoke20] {
            preferences.reminderMode=legacy;preferences.smokeDepth=nil;try store.save(preferences)
            let loaded=try store.load()!
            check(loaded.resolvedSmokeDepth==8 && loaded.reminderMode==legacy,"Legacy preset decodes and migrates to8x")
        }
        preferences.reminderMode = .menuBar;try store.save(preferences)
        let modeRoundtrip=try store.load()!
        check(modeRoundtrip.reminderMode == .menuBar,"Comparison mode survives disk reload")
        for mode in ReminderMode.allCases {
            preferences.reminderMode=mode;try store.save(preferences)
            let modeSaved=try store.load()!
            check(modeSaved.reminderMode==mode && modeSaved.calibration(for:"camera-A")?.baseline==restored.calibration(for:"camera-A")?.baseline,"\(mode.title) saves without changing calibration")
        }
        preferences.reminderMode=nil;try store.save(preferences)
        let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--read-saved",url.path]
        let pipe=Pipe();child.standardOutput=pipe;child.standardError=pipe;try child.run();child.waitUntilExit()
        check(child.terminationStatus==0,"New process restores actual disk settings")
        let engine=PostureEngine();engine.calibrate();_=engine.update(PoseFeatures([0,-0.6,0,0.4,0.5,0.5]),at:0);engine.pause()
        let saved=restored.calibration(for:"camera-A")!
        check(engine.restoreValidated(baseline:PoseFeatures(saved.baseline),yellow:saved.yellow,red:saved.red,delay:restored.delay),"Validated saved calibration restores engine")
        check(!engine.paused && !engine.calibrating && !engine.alert && engine.baseline != nil,"Restore clears pause, calibration and alert history")
        let bent=PoseFeatures([0,-0.6,0,0.4,0.5,0.7])
        check(!engine.update(bent,at:100).alert,"Restored engine requires fresh sustained deviation")
        check(!engine.restoreValidated(baseline:PoseFeatures([Double.nan,0,0,0.4,0.5,0.5]),yellow:0.8,red:1.3,delay:2),"Nonfinite restored baseline rejected")
        check(!engine.restoreValidated(baseline:PoseFeatures(saved.baseline),yellow:0.8,red:0.9,delay:2),"Invalid restored zone order rejected")
        check(!engine.restoreValidated(baseline:PoseFeatures(saved.baseline),yellow:0.8,red:1.3,delay:9),"Invalid restored delay rejected")
        check(restored.featureSchema=="seated-height-v2" && saved.featureSchema=="seated-height-v2","New feature schema roundtrips")
        var legacy=preferences
        legacy.featureSchema="seated-face-v1"
        legacy.calibrations["camera-A"]?.featureSchema="seated-face-v1"
        legacy.reminderMode = .menuBar;legacy.smokeDepth=12.5;legacy.yellow=0.8;legacy.red=1.3
        try JSONEncoder().encode(legacy).write(to:url)
        let migrated=try store.load()!
        check(migrated.featureSchema=="seated-height-v2" && migrated.calibrations.isEmpty,"Validated legacy geometry is discarded during migration")
        check(migrated.selectedCameraID==legacy.selectedCameraID && migrated.delay==legacy.delay && migrated.reminderMode==legacy.reminderMode && migrated.smokeDepth==12.5,"Migration preserves camera, delay, style and fractional depth")
        check(migrated.yellow==0.6 && migrated.red==1,"Migration resets height boundaries")
        try store.save(migrated)
        let migratedAgain=try PreferencesStore(url:url).load()!
        check(migratedAgain.featureSchema=="seated-height-v2" && migratedAgain.calibrations.isEmpty && migratedAgain.smokeDepth==12.5,"Migrated settings persist in current schema")
        var malformedLegacy=legacy;malformedLegacy.calibrations["camera-A"]?.baseline=[0,0,0]
        try JSONEncoder().encode(malformedLegacy).write(to:url)
        do{_=try store.load();fatalError("Malformed legacy baseline migrated")}catch{checks += 1;print("PASS: Malformed legacy geometry rejected before migration")}
        malformedLegacy=legacy;malformedLegacy.calibrations["camera-A"]?.featureSchema="body-pose-v0"
        try JSONEncoder().encode(malformedLegacy).write(to:url)
        do{_=try store.load();fatalError("Mixed legacy feature schemas migrated")}catch{checks += 1;print("PASS: Mixed legacy schemas rejected")}
        malformedLegacy=legacy;malformedLegacy.version=99
        try JSONEncoder().encode(malformedLegacy).write(to:url)
        do{_=try store.load();fatalError("Unknown legacy version migrated")}catch{checks += 1;print("PASS: Unknown legacy version rejected")}
        malformedLegacy=legacy;malformedLegacy.red=0.85
        try JSONEncoder().encode(malformedLegacy).write(to:url)
        do{_=try store.load();fatalError("Invalid legacy boundaries migrated")}catch{checks += 1;print("PASS: Invalid legacy boundaries rejected")}
        try Data("not json".utf8).write(to:url)
        do{_=try store.load();fatalError("Corrupted preferences accepted")}catch{checks += 1;print("PASS: Corrupted JSON rejected")}
        var invalidFixtures:[(String,PosturePreferences)]=[]
        var bad=preferences;bad.version=999;invalidFixtures.append(("Unknown version",bad))
        bad=preferences;bad.featureSchema="body-pose-v0";invalidFixtures.append(("Unknown feature schema",bad))
        bad=preferences;bad.calibrations["camera-A"]?.featureSchema="body-pose-v0";invalidFixtures.append(("Old per-camera schema",bad))
        bad=preferences;bad.calibrations["camera-A"]?.cameraID="camera-B";invalidFixtures.append(("Mismatched record camera",bad))
        bad=preferences;bad.calibrations["camera-A"]?.baseline=[0,0,0,0.4,0.5];invalidFixtures.append(("Wrong baseline length",bad))
        bad=preferences;bad.calibrations["camera-A"]?.red=0.85;invalidFixtures.append(("Overlapping stored zones",bad))
        bad=preferences;bad.delay=0;invalidFixtures.append(("Out-of-range stored delay",bad))
        bad=preferences;bad.selectedCameraID=" ";invalidFixtures.append(("Empty selected camera",bad))
        bad=preferences;bad.smokeDepth = -1;invalidFixtures.append(("Depth below0",bad))
        bad=preferences;bad.smokeDepth=51;invalidFixtures.append(("Depth above50",bad))
        for (name,invalid) in invalidFixtures {
            try JSONEncoder().encode(invalid).write(to:url)
            do{_=try store.load();fatalError("\(name) accepted")}catch{checks += 1;print("PASS: \(name) rejected on disk")}
        }
        try store.save(preferences)
        preferences.calibrations.removeValue(forKey:"camera-A");try store.save(preferences)
        let invalidated=try PreferencesStore(url:url).load()
        check(invalidated?.calibration(for:"camera-A")==nil,"Explicit calibration invalidation survives reload")
        check(invalidated?.delay==3.5,"Invalidation preserves other settings")
        let blocked=directory.appendingPathComponent("blocked");try Data("file".utf8).write(to:blocked)
        do{try PreferencesStore(url:blocked.appendingPathComponent("preferences.json")).save(preferences);fatalError("Write failure not thrown")}catch{checks += 1;print("PASS: Save failure is surfaced")}
        print("\(checks) persistence checks passed")
    }
}

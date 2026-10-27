import Foundation

/// Presentation only. Every mode keeps the same five-minute time scale.
enum LiveChartMotion:String,CaseIterable,Identifiable {
    case original,responsive,smooth
    var id:String{rawValue}
    var title:String {switch self {case .original:return "Original";case .responsive:return "Responsive";case .smooth:return "Smooth"}}
    var interval:Double {switch self {case .original:return 1;case .responsive:return 1.0/3.0;case .smooth:return 1.0/12.0}}
}

enum MenuBarStyle:String,CaseIterable,Identifiable {
    case color,score
    var id:String{rawValue}
    var title:String{self == .color ? "Color icon":"Live score"}
}

enum ReminderMode:String,CaseIterable,Codable {
    case smoke,smoke2,smokeWide,smoke8,smoke20,menuBar
    static var allCases:[ReminderMode] {[.smoke,.menuBar]}
    var smokeScale:CGFloat {
        switch self {case .smoke,.menuBar:return 1;case .smoke2:return 2;case .smokeWide:return 4;case .smoke8:return 8;case .smoke20:return 20}
    }
    var title:String {self == .menuBar ? "Menu bar glow":"Layered smoke"}
    var detail:String {
        if self == .menuBar {return "The whole top menu bar shifts from green through yellow to red. The color grows stronger and pulses before the focus card appears."}
        return "Darker layers gather at the edge and fade gently inward. Smoke retreats as soon as your posture improves."
    }
}

enum EdgeEffectStyle:String,CaseIterable,Codable,Identifiable {
    case smoke,vignette,glow,corners,tide,horizon
    var id:String{rawValue}
    var title:String {switch self{case .smoke:return "A · Smoke";case .vignette:return "B · Vignette";case .glow:return "C · Edge glow";case .corners:return "D · Corners";case .tide:return "E · Side tide";case .horizon:return "F · Horizon"}}
    var detail:String {switch self{case .smoke:return "Layered, softly moving mist around every edge.";case .vignette:return "A smooth, still wash that deepens as you sink.";case .glow:return "A fine perimeter with a soft spill of light.";case .corners:return "Four warm brackets that lengthen as you sink.";case .tide:return "Soft color deepens from the sides, leaving the top and bottom clear.";case .horizon:return "A quiet band of color that lowers from the top edge."}}
}

struct SavedCalibration:Codable {
    static let currentFeatureSchema="seated-height-v2"
    var cameraID:String
    var featureSchema:String=Self.currentFeatureSchema
    var baseline:[Double]
    var yellow:Double
    var red:Double
    var landmarkHeight:LandmarkHeightCalibration?=nil
    var poseFeatures:PoseFeatures {
        var value=PoseFeatures(baseline);value.landmarkHeight=landmarkHeight;return value
    }
    var valid:Bool {valid(for:Self.currentFeatureSchema)}
    fileprivate func valid(for schema:String)->Bool {
        !cameraID.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && featureSchema==schema &&
        baseline.count==6 && baseline.allSatisfy(\.isFinite) && poseFeatures.valid &&
        PostureEngine.validThresholds(yellow:yellow,red:red)
    }
}

struct PosturePreferences:Codable {
    var version=1
    var featureSchema=SavedCalibration.currentFeatureSchema
    var selectedCameraID:String?
    var reminderMode:ReminderMode?
    var edgeEffectStyle:EdgeEffectStyle?
    // Unknown future display choices must not invalidate a saved height.
    var liveChartMotion:String?
    var resolvedLiveChartMotion:LiveChartMotion {LiveChartMotion(rawValue:liveChartMotion ?? "") ?? .responsive}
    var menuBarStyle:String?
    var resolvedMenuBarStyle:MenuBarStyle {.color}
    var redAlertEnabled:Bool?
    var resolvedRedAlertEnabled:Bool {redAlertEnabled ?? true}
    var smokeDepth:Double?
    static let defaultEffectStrength=8.0
    static let defaultAlertDelay=2.0
    var resolvedSmokeDepth:Double {min(10,max(0,smokeDepth ?? Self.defaultEffectStrength))}
    var delay=Self.defaultAlertDelay
    static let newYellow=PostureEngine.defaultYellow
    static let newRed=PostureEngine.defaultRed
    var yellow=Self.newYellow
    var red=Self.newRed
    var calibrations:[String:SavedCalibration]=[:]
    var valid:Bool {valid(for:SavedCalibration.currentFeatureSchema)}
    fileprivate func valid(for schema:String)->Bool {
        (smokeDepth == nil || (smokeDepth!.isFinite && (0...50).contains(smokeDepth!))) &&
        version==1 && featureSchema==schema && delay.isFinite && (1...5).contains(delay) &&
        (selectedCameraID == nil || !selectedCameraID!.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) &&
        PostureEngine.validThresholds(yellow:yellow,red:red) &&
        calibrations.allSatisfy { key,value in key==value.cameraID && value.valid(for:schema) }
    }
    func calibration(for cameraID:String)->SavedCalibration? {
        guard !cameraID.isEmpty,let saved=calibrations[cameraID],saved.cameraID==cameraID,saved.valid else{return nil}
        return saved
    }
}

enum PreferencesError:LocalizedError {
    case invalid
    var errorDescription:String? {"Saved settings were invalid or from an incompatible tracking version. Set your zones again."}
}

final class PreferencesStore {
    let url:URL
    init(url:URL=PreferencesStore.defaultURL) {self.url=url}
    static var defaultURL:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Posture Zone",isDirectory:true).appendingPathComponent("preferences.json")
    }
    func load()throws->PosturePreferences? {
        guard FileManager.default.fileExists(atPath:url.path)else{return nil}
        let data=try Data(contentsOf:url)
        guard var preferences=try? JSONDecoder().decode(PosturePreferences.self,from:data) else{throw PreferencesError.invalid}
        if preferences.featureSchema == "seated-face-v1" {
            // Validate the entire old record before discarding its incompatible
            // geometry. A malformed old file must never become a valid new one.
            guard preferences.valid(for:"seated-face-v1") else{throw PreferencesError.invalid}
            preferences.featureSchema=SavedCalibration.currentFeatureSchema
            preferences.calibrations=[:];preferences.yellow=0.6;preferences.red=1
        }
        guard preferences.valid else{throw PreferencesError.invalid}
        return preferences
    }
    func save(_ preferences:PosturePreferences)throws {
        guard preferences.valid else{throw PreferencesError.invalid}
        let data=try JSONEncoder().encode(preferences)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}

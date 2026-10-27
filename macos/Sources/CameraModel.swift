import SwiftUI
import AVFoundation
import Vision
import AppKit

struct CameraChoice: Identifiable { let id: String; let name: String }

final class CameraModel: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let liveScore=LiveScoreStore()
    let progressStore:ProgressStore
    let session=AVCaptureSession()
    let engine=PostureEngine()
    let sampler=BoundarySampler()
    let alerts=ZoneAlertController()
    let updateResumeStore:UpdateResumeStore
    var updateWindowContext:(()->(page:String,visible:Bool))?
    private var terminationHandled=false
    private var updatePausedSession=false
    private var updateResumeStarter:(()->Void)?
    private var updateAuthorizationOverride:Bool?
    private var updateAvailabilityOverride:Bool?
    private let queue=DispatchQueue(label:"PostureZone.camera",qos:.userInitiated,autoreleaseFrequency:.workItem)
    private let runToken=CameraRunToken()
    private let subjectToken=CameraRunToken()
    private let presentsVisuals:Bool
    private var setupCheck=SetupCheck()
    private var previousCalibration:SavedCalibration?
    private var lossSince:Double?
    private var reacquiredSince:Double?
    private var awaitingReacquisition=false
    private var reviewThresholds:(Double,Double)?
    private var generation=0
    private var captureGeneration=0
    private var captureSubject=0
    private var currentVideoOutput:AVCaptureVideoDataOutput?
    private var deliveredFrames=0
    private var analysisCPU=0.0
    private var resizeCPU=0.0
    private var visionCPU=0.0
    private weak var previewLayer:AVSampleBufferDisplayLayer?
    private var lastInference=0.0
    private var analysisPaused=false
    private var analysisInterval=1.0/3.0
    private var trackingRateCapture=false
    private var lastCapturePresentation:Double?
    private var lastFrame=0.0
    private var lastAnalysisTime=0.0
    private var displayedDay=DailyProgressCalendar.dateID(Date())
    private var staleTimer: Timer?
    private var activity:NSObjectProtocol?
    private var observers:[NSObjectProtocol]=[]
    private var pose:PoseFeatures?
    private let performance:TrackingPerformance
    private let store:PreferencesStore
    private var preferences=PosturePreferences()
    private let seatedDetector=SeatedPoseDetector()
    private let analysisFrames=AnalysisFrames()
    private let motionGate=FaceMotionGate()
    private var trackingGuidance="Looking for your face. Keep your eyes and nose visible."
    @Published var controlsPage:ControlsPage = .posture
    @Published var cameras:[CameraChoice]=[]
    @Published var selectedID=""
    @Published var active=false
    @Published var loading=false
    @Published var state="idle"
    @Published var message="Choose your camera. Your video stays on this Mac."
    @Published var stage="idle"
    @Published var capturing=false
    @Published var progress=0.0
    @Published var score:Double?
    @Published var warningProgress=0.0
    @Published private(set) var reminderMode:ReminderMode = .smoke
    @Published private(set) var smokeDepth=PosturePreferences.defaultEffectStrength
    @Published private(set) var edgeEffectStyle:EdgeEffectStyle = .tide
    @Published private(set) var liveChartMotion:LiveChartMotion = .responsive
    @Published private(set) var redAlertEnabled=true
    @Published private(set) var menuBarStyle:MenuBarStyle = .color
    @Published var hasPose=false
    @Published private(set) var bottomExitHeld=false
    @Published private(set) var landmarks:[CGPoint]=[]
    @Published private(set) var frameAspect=16.0/9.0
    @Published var yellow=PosturePreferences.newYellow
    @Published var red=PosturePreferences.newRed
    @Published var delay=PosturePreferences.defaultAlertDelay
    @Published var paused=false
    @Published private(set) var pauseUntil:Date?
    @Published private(set) var setupCheckPhase="lower"
    @Published private(set) var canUndoHeightReset=false
    var setupCheckComplete:Bool {setupCheckPhase == "done"}
    @Published private(set) var hasSavedCalibration=false
    @Published var persistenceMessage:String?
    var savedSetupDescription:String? {hasSavedCalibration ? "Your height and levels are saved.":nil}
    var monitoring:Bool { stage == "monitoring" }
    static func devices()->[AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.external,.continuityCamera],mediaType:.video,position:.unspecified).devices
    }
    override convenience init() {self.init(store:PreferencesStore())}
    init(store:PreferencesStore,observesLifecycle:Bool=true,presentsVisuals:Bool=true,updateBuild:String?=nil) {
        self.store=store;self.presentsVisuals=presentsVisuals
        self.updateResumeStore=UpdateResumeStore(directory:store.url.deletingLastPathComponent(),build:updateBuild ?? (Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "development"))
        self.performance=TrackingPerformance(directory:store.url.deletingLastPathComponent())
        self.progressStore=ProgressStore(url:store.url.deletingLastPathComponent().appendingPathComponent("daily-progress.json"))
        super.init()
        do {
            if let saved=try store.load() {preferences=saved;redAlertEnabled=saved.resolvedRedAlertEnabled;liveChartMotion=saved.resolvedLiveChartMotion;menuBarStyle=saved.resolvedMenuBarStyle;edgeEffectStyle=saved.edgeEffectStyle ?? .tide;reminderMode=saved.reminderMode == .menuBar ? .menuBar:.smoke;smokeDepth=saved.resolvedSmokeDepth;selectedID=saved.selectedCameraID ?? "";delay=saved.delay;yellow=saved.yellow;red=saved.red}
        } catch {persistenceMessage="Could not load saved settings. \(error.localizedDescription)"}
        alerts.setReminderMode(reminderMode,depth:CGFloat(smokeDepth))
        alerts.setEdgeEffectStyle(edgeEffectStyle)
        alerts.setRedAlertEnabled(redAlertEnabled)
        if observesLifecycle {refreshCameras()};refreshSavedState()
        if hasSavedCalibration {message="Your zones are saved. Start the camera to resume with this setup."}
        alerts.pauseAction={ [weak self] in self?.togglePause() }
        guard observesLifecycle else{return}
        for name in [AVCaptureDevice.wasConnectedNotification,AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.refreshCameras() })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in self?.stop("Camera stopped before sleep. Your saved zones are kept; start again when ready.") })
        observers.append(NotificationCenter.default.addObserver(forName:NSApplication.willTerminateNotification,object:nil,queue:.main) { [weak self] _ in self?.prepareForApplicationTermination() })
        observers.append(NotificationCenter.default.addObserver(forName:AVCaptureSession.runtimeErrorNotification,object:session,queue:.main) { [weak self] _ in self?.stop("Camera interrupted. Check the connection, then start again.") })
        staleTimer=Timer.scheduledTimer(withTimeInterval:0.3,repeats:true) { [weak self] _ in
            guard let self else{return}
            self.pollPause()
            self.performance.captureInfo["stage"]=self.stage
            self.performance.captureInfo["state"]=self.state
            self.performance.captureInfo["alert"]=self.engine.alert
            self.performance.captureInfo["bottom_exit_held"]=self.bottomExitHeld
            self.performance.captureInfo["menu_style"]=self.menuBarStyle.rawValue
            self.performance.report(active:self.active,paused:self.paused,valid:self.hasPose && self.score != nil && !self.paused)
            let day=DailyProgressCalendar.dateID(Date())
            if self.displayedDay != day {self.displayedDay=day;self.progressStore.objectWillChange.send()}
            self.checkCameraFreshness(at:ProcessInfo.processInfo.systemUptime)
        }
    }
    deinit {
        staleTimer?.invalidate()
        for observer in observers {NotificationCenter.default.removeObserver(observer);NSWorkspace.shared.notificationCenter.removeObserver(observer)}
        if let activity {ProcessInfo.processInfo.endActivity(activity)}
    }
    func refreshCameras() {
        let devices=Self.devices(); cameras=devices.map { CameraChoice(id:$0.uniqueID,name:$0.localizedName) }
        if selectedID.isEmpty { selectedID=(devices.first { $0.localizedName.localizedCaseInsensitiveContains("Studio Display") })?.uniqueID ?? "" }
        else if !devices.contains(where:{$0.uniqueID==selectedID}) && (active || loading) { stop("Selected camera disconnected. Choose a camera explicitly and start again.") }
        if !selectedID.isEmpty && !cameras.contains(where:{$0.id==selectedID}) {cameras.append(CameraChoice(id:selectedID,name:"Selected camera unavailable"))}
    }
    func select(_ id:String) {
        if id != selectedID {
            stop("Camera changed. Start again to use this camera’s zones.");selectedID=id
            yellow=preferences.yellow;red=preferences.red;refreshSavedState();persistSettings()
        }
    }
    /// The preview's switch describes capture, including paused and opening states.
    var cameraEnabled:Bool {loading || (active && !paused)}
    func setCameraEnabled(_ enabled:Bool) {
        if enabled {
            if active && paused {togglePause()}
            else if !active && !loading {start()}
        } else if active || loading {stop()}
    }
    func start() {startCamera(resumeSaved:true)}
    private func startCamera(resumeSaved:Bool) {
        guard !active && !loading else{return}
        updatePausedSession=false;updateResumeStarter=nil;updateAuthorizationOverride=nil;updateAvailabilityOverride=nil
        resetSubject();generation=runToken.advance(); let token=generation; warningProgress=0;loading=true; message="Waiting for camera permission…"
        let proceed: (Bool)->Void={ [weak self] allowed in DispatchQueue.main.async {
            guard let self,token==self.generation else{return}
            guard allowed else { self.loading=false; self.state="error"; self.message="Allow Zone in System Settings → Privacy & Security → Camera, then try again."; return }
            guard let device=Self.devices().first(where:{$0.uniqueID==self.selectedID}) else {self.loading=false;self.state="error";self.message="Choose an available camera, then start again.";return}
            self.message="Opening \(device.localizedName)…"
            self.queue.async { [weak self] in
                guard let self,self.runToken.accepts(token) else{return}
                do {
                    let input=try AVCaptureDeviceInput(device:device)
                    self.session.beginConfiguration()
                    self.session.inputs.forEach {self.session.removeInput($0)}
                    self.session.outputs.forEach {self.session.removeOutput($0)}
                    self.session.sessionPreset = .hd1280x720
                    let output=AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames=true
                    guard self.session.canAddInput(input),self.session.canAddOutput(output) else { self.session.commitConfiguration(); throw NSError(domain:"Camera unavailable",code:1) }
                    self.session.addInput(input);self.session.addOutput(output)
                    // Query formats only after connecting the input. Keep native
                    // uncompressed YUV so unsampled frames need no color conversion.
                    let native=CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription)
                    let uncompressed:[OSType]=[kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelFormatType_422YpCbCr8,kCVPixelFormatType_422YpCbCr8_yuvs]
                    let available=output.availableVideoPixelFormatTypes
                    let format=uncompressed.contains(native) && available.contains(native) ? native:(available.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:kCVPixelFormatType_32BGRA)
                    output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:format]
                    output.setSampleBufferDelegate(self,queue:self.queue)
                    self.session.commitConfiguration();self.currentVideoOutput=output;self.captureGeneration=token;self.lastInference=0;self.lastCapturePresentation=nil;self.analysisPaused=false;self.analysisInterval=1.0/3.0
                    guard self.runToken.accepts(token) else{return}
                    self.session.startRunning()
                    try self.configureCaptureRate(device)
                    DispatchQueue.main.async {
                        guard token==self.generation else{return}
                        guard self.session.isRunning else {self.stop("Camera did not start. Check the connection, then try again.");self.state="error";return}
                        self.loading=false;self.active=true;self.stage="green";self.state="ready";self.lastFrame=ProcessInfo.processInfo.systemUptime;self.lastAnalysisTime=self.lastFrame
                        self.activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep],reason:"On-device posture tracking while you work")
                        if resumeSaved,let saved=self.preferences.calibration(for:device.uniqueID),self.engine.restoreValidated(baseline:saved.poseFeatures,yellow:saved.yellow,red:saved.red,delay:self.delay) {
                            self.yellow=saved.yellow;self.red=saved.red;self.stage="monitoring";self.paused=false;self.score=nil;self.alerts.hide()
                            self.message="Resumed your saved zones. Keep your camera and seating setup in the same position."
                        } else {self.yellow=PosturePreferences.newYellow;self.red=PosturePreferences.newRed;self.message="Sit at a comfortable height. Set it once, then adjust the two levels on your meter."}
                    }
                } catch { DispatchQueue.main.async { guard token==self.generation else{return};self.stop("Could not open this camera. Close other camera apps and try again.");self.state="error" } }
            }
        }}
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized:proceed(true)
        case .notDetermined:AVCaptureDevice.requestAccess(for:.video,completionHandler:proceed)
        default:proceed(false)
        }
    }
    func stop(_ explanation:String="Camera off. Start whenever you’re ready.") {
        updatePausedSession=false;updateResumeStarter=nil;updateAuthorizationOverride=nil;updateAvailabilityOverride=nil
        progressStore.record(score:nil,yellow:yellow,red:red,eligible:false);progressStore.flush();liveScore.interrupt()
        resetSubject();generation=runToken.advance();active=false;loading=false;engine.reset();sampler.reset();alerts.hide()
        pauseUntil=nil;lossSince=nil;reacquiredSince=nil;awaitingReacquisition=false;setupCheck.reset();setupCheckPhase="lower"
        previousCalibration=nil;canUndoHeightReset=false;reviewThresholds=nil;refreshSavedState()
        if let activity {ProcessInfo.processInfo.endActivity(activity);self.activity=nil}
        pose=nil;hasPose=false;landmarks=[];score=nil;warningProgress=0;paused=false;capturing=false;progress=0;stage="idle";state="idle";message=explanation
        queue.async { [weak self] in guard let self else{return};self.currentVideoOutput=nil;self.analysisFrames.clear();self.motionGate.clear();self.seatedDetector.reset();if self.session.isRunning{self.session.stopRunning()} }
    }
    /// Queue-confined association resets plus an epoch reject any old in-flight result.
    private func resetSubject() {
        let subject=subjectToken.advance();bottomExitHeld=false
        queue.async { [weak self] in
            guard let self else{return}
            self.seatedDetector.reset();self.motionGate.clear();self.captureSubject=subject
        }
    }
    func prepareForApplicationTermination() {
        guard !terminationHandled else{return};terminationHandled=true
        let context=updateWindowContext?() ?? (page:controlsPage.rawValue,visible:true)
        do {
            let mode:UpdateSessionMode = monitoring && active ? (paused ? .paused:.tracking):(active || loading ? .setup:.off)
            let snapshot=UpdateSessionState(mode:mode,cameraID:selectedID,pauseUntilUnix:pauseUntil?.timeIntervalSince1970,page:context.page,controlsVisible:context.visible,preferencesDigest:try updateResumeStore.currentDigest())
            try updateResumeStore.prepareForTermination(snapshot)
        } catch {persistenceMessage="Could not prepare tracking to resume after update. \(error.localizedDescription)"}
        stop()
    }
    func consumeUpdateResume()->UpdateResumeReceipt? {
        do {
            let receipt=try updateResumeStore.consume()
            if let reason=updateResumeStore.rejection {message="Update installed. \(reason) Turn Camera on when ready."}
            return receipt
        } catch {message="Update installed, but tracking could not be restored safely. Turn Camera on when ready.";return nil}
    }
    /// Test closures replace capture only in isolated checks; production always
    /// validates existing permission/device and uses the ordinary capture path.
    func resumeAfterUpdate(_ snapshot:UpdateSessionState,cameraAuthorized:Bool?=nil,cameraAvailable:Bool?=nil,startCameraAction:(()->Void)?=nil) {
        guard snapshot.valid else{return}
        if snapshot.mode == .off {return}
        if snapshot.mode == .setup {message="Your saved setup is kept. Turn Camera on to finish setting your height.";return}
        guard snapshot.cameraID==selectedID,let saved=preferences.calibration(for:selectedID) else {
            state="error";message="Update installed. Your saved camera setup could not be restored. Choose your camera and set your height.";return
        }
        if snapshot.mode == .paused {
            guard engine.restoreValidated(baseline:saved.poseFeatures,yellow:saved.yellow,red:saved.red,delay:delay) else{return}
            yellow=saved.yellow;red=saved.red;active=true;paused=true;stage="monitoring";state="paused";engine.pause()
            pauseUntil=snapshot.pauseUntilUnix.map{Date(timeIntervalSince1970:$0)}
            updatePausedSession=true;updateResumeStarter=startCameraAction;updateAuthorizationOverride=cameraAuthorized;updateAvailabilityOverride=cameraAvailable
            message="Camera paused. Resume when you’re ready.";pollPause();return
        }
        let authorized=cameraAuthorized ?? (AVCaptureDevice.authorizationStatus(for:.video) == .authorized)
        let available=cameraAvailable ?? Self.devices().contains{$0.uniqueID==selectedID}
        guard authorized,available else {
            state="error";message=authorized ? "Update installed. Your selected camera is unavailable; reconnect it and turn Camera on.":"Update installed. Allow Camera access in System Settings, then turn Camera on.";return
        }
        if let startCameraAction{startCameraAction()}else{start()}
    }
    private func configureCaptureRate(_ device:AVCaptureDevice,calibrating:Bool=false) throws {
        trackingRateCapture=false
        try device.lockForConfiguration()
        defer {device.unlockForConfiguration()}
        // Preserve active format/FOV. Normal tracking consumes every3fps buffer;
        // calibration retains9fps. Unsupported devices keep the original gate.
        for fps in (calibrating ? [9.0]:[3.0,9.0]) {
            guard let range=device.activeFormat.videoSupportedFrameRateRanges.first(where:{$0.minFrameRate<=fps+0.01 && $0.maxFrameRate>=fps-0.01}) else{continue}
            let duration=abs(range.maxFrameRate-fps)<0.01 ? range.minFrameDuration:CMTime(seconds:1/fps,preferredTimescale:600)
            device.activeVideoMaxFrameDuration=duration
            device.activeVideoMinFrameDuration=duration
            trackingRateCapture=fps==3 && abs(CMTimeGetSeconds(device.activeVideoMinFrameDuration)-1.0/3)<0.002 && abs(CMTimeGetSeconds(device.activeVideoMaxFrameDuration)-1.0/3)<0.002
            lastCapturePresentation=nil
            return
        }
    }
    func setPreviewLayer(_ layer:AVSampleBufferDisplayLayer?) {
        queue.async { [weak self] in self?.previewLayer=layer }
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        guard output === currentVideoOutput,runToken.accepts(captureGeneration),!analysisPaused else{return}
        // Preview consumes the existing output. It never attaches another capture
        // connection or renegotiates the camera when controls open or close.
        if let previewLayer {previewLayer.sampleBufferRenderer.enqueue(sampleBuffer)}
        deliveredFrames += 1
        let frames=deliveredFrames
        let publishesLandmarks=previewLayer != nil
        let now=ProcessInfo.processInfo.systemUptime
        guard let buffer=CMSampleBufferGetImageBuffer(sampleBuffer) else{return}
        let observationGap=now-lastInference
        let presentation=CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let presentationGap=lastCapturePresentation.map{presentation-$0}
        lastCapturePresentation=presentation.isFinite ? presentation:nil
        let trackingDelivery=AnalysisCadence.isTrackingRateDelivery(configured:trackingRateCapture,presentationGap:presentationGap)
        guard let interval=AnalysisCadence.dueInterval(elapsed:observationGap,requested:analysisInterval,trackingRateDelivery:trackingDelivery,
                                                     motionInterval:{motionGate.interval(for:buffer)}) else{return}
        lastInference=now;let token=captureGeneration;let subject=captureSubject
        var features:PoseFeatures?
        var points:[CGPoint]=[]
        var loss=FaceLossReason.unknown
        var captureInfo:[String:Any]=["frames":frames,"format":CVPixelBufferGetPixelFormatType(buffer),"width":CVPixelBufferGetWidth(buffer),"height":CVPixelBufferGetHeight(buffer)]
        let aspect=Double(CVPixelBufferGetWidth(buffer))/Double(CVPixelBufferGetHeight(buffer))
        var guidance="Camera analysis interrupted. Keep your face visible and try again."
        let analysisStarted=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        do {
            let analysisBuffer=analysisFrames.resized(buffer) ?? buffer
            let visionStarted=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            resizeCPU += Double(visionStarted-analysisStarted)/1e9
            let trackerConfiguration=DiagnosticVisualPolicy.shared.trackerConfiguration
            let forcesFull=trackerConfiguration.forcesFull
            seatedDetector.setPatchRadius(trackerConfiguration.radius)
            let detection=try seatedDetector.detect(analysisBuffer,aspect:aspect,at:now,allowLightweight:analysisInterval>=0.2 && !forcesFull)
            captureInfo["tracker_ablation_full"]=forcesFull
            visionCPU += Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-visionStarted)/1e9
            features=detection.features;guidance=detection.guidance;points=detection.points;loss=detection.loss
        } catch { features=nil }
        if features != nil && !trackingDelivery {motionGate.remember(buffer,points:points)} else{motionGate.clear()}
        captureInfo["tracker_radius"]=seatedDetector.patchRadius
        captureInfo["tracker_path"]=seatedDetector.lastPath
        captureInfo["tracker_full_passes"]=seatedDetector.fullPasses
        captureInfo["tracker_faces"]=seatedDetector.lastFaceCount
        captureInfo["tracker_decision"]=seatedDetector.lastDecision
        captureInfo["features_valid"]=features != nil
        captureInfo["tracker_seed_failures"]=seatedDetector.seedFailureCounts
        captureInfo["tracker_patch_passes"]=seatedDetector.patchPasses
        captureInfo["tracker_fallbacks"]=seatedDetector.fallbackCounts
        if let failure=seatedDetector.lastSeedFailure {captureInfo["tracker_seed_failure"]=failure}
        captureInfo["tracking_rate_delivery"]=trackingDelivery
        captureInfo["analysis_interval"]=interval
        captureInfo["observation_gap"]=observationGap
        captureInfo["resize_cpu_seconds"]=resizeCPU;captureInfo["vision_cpu_seconds"]=visionCPU
        if motionGate.difference.isFinite {captureInfo["motion_difference"]=motionGate.difference}
        captureInfo["motion_vertical_shift"]=motionGate.verticalShift
        analysisCPU += Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)-analysisStarted)/1e9
        captureInfo["analysis_cpu_seconds"]=analysisCPU;captureInfo["preview_attached"]=previewLayer != nil
        DispatchQueue.main.async { [weak self] in
            guard let self,self.active,!self.paused,self.generation==token,self.subjectToken.accepts(subject) else{return}
            self.trackingGuidance=guidance
            if publishesLandmarks,self.landmarks != points {self.landmarks=points}
            if self.frameAspect != aspect {self.frameAspect=aspect}
            self.receive(features,at:now,loss:loss)
            captureInfo["reacquiring"]=self.awaitingReacquisition
            captureInfo["analysis_age_seconds"]=ProcessInfo.processInfo.systemUptime-self.lastAnalysisTime
            captureInfo["pipeline_ms"]=(ProcessInfo.processInfo.systemUptime-now)*1000
            self.performance.captureInfo=captureInfo
        }
    }
    func checkCameraFreshness(at now:Double) {
        guard active,!paused,now-lastAnalysisTime > 0.65 else{return}
        receive(nil,at:now,loss:.cameraStale,fromCameraFrame:false)
    }
    func receive(_ candidate:PoseFeatures?,at now:Double,loss:FaceLossReason = .unknown,fromCameraFrame:Bool=true) {
        guard now.isFinite else{return}
        defer {
            let eligible=active && monitoring && !paused && hasPose && score != nil
            performance.record(valid:eligible,band:state,at:now)
            progressStore.record(score:score,yellow:yellow,red:red,eligible:eligible)
            liveScore.record(deviation:score,yellow:yellow,red:red,eligible:eligible)
        }
        if fromCameraFrame {lastAnalysisTime=now}
        let value=candidate?.valid == true ? candidate:nil
        let frameGap=now-lastFrame
        if value != nil {lastFrame=now}
        pose=value;if hasPose != (value != nil) {hasPose=value != nil}
        guard !paused else{return}
        if value==nil {
            if loss == .bottom,(monitoring || stage=="review"),let held=engine.holdBottomExit(at:now) {
                bottomExitHeld=true;awaitingReacquisition=false;reacquiredSince=nil;lossSince=nil
                landmarks=[];score=held.score;state=held.state;warningProgress=held.alertProgress
                sampler.reset();setupCheck.interrupt()
                message="You moved below the camera. Come back up to your comfortable height."
                if presentsVisuals {alerts.update(held,monitoring:true,paused:false,tracking:true)}
                return
            }
            bottomExitHeld=false
            queue.async { [weak self] in self?.analysisInterval=1.0/3.0 }
            if lossSince == nil {lossSince=now}
            // The watchdog hides stale feedback at 0.65s, but one dropped 3fps
            // frame is not an observed face disappearance. Keep pending matched
            // return evidence across a short delivery gap. Actual no-face frames
            // and longer interruptions still require a fresh stable return.
            let briefDeliveryGap = !fromCameraFrame && loss == .cameraStale &&
                now-lastFrame>=0 && now-lastFrame<=1.5
            if !briefDeliveryGap {awaitingReacquisition=true;reacquiredSince=nil}
            landmarks=[];warningProgress=0;score=nil
            _=engine.update(nil,at:now);sampler.reset();progress=0;setupCheck.interrupt()
            alerts.hide()
            if now-lossSince! >= 1 {state="lost";message="Tracking paused. Bring your face back into view."}
            return
        }
        if bottomExitHeld {bottomExitHeld=false;awaitingReacquisition=false;reacquiredSince=nil}
        if awaitingReacquisition {
            if frameGap > 1.5 || frameGap < 0 {reacquiredSince=nil}
            if reacquiredSince == nil {reacquiredSince=now}
            guard now-reacquiredSince! >= 0.35 else {hasPose=false;alerts.hide();return}
            awaitingReacquisition=false;reacquiredSince=nil;engine.clearTiming()
        }
        lossSince=nil
        if state=="lost" {state="ready"}
        if stage=="green" && capturing {
            let result=engine.update(value,at:now);progress=result.progress
            if result.calibrated {
                queue.async { [weak self] in
                    guard let self else{return};self.analysisInterval=1.0/3.0
                    if let device=(self.session.inputs.first as? AVCaptureDeviceInput)?.device {try? self.configureCaptureRate(device)}
                }
                if engine.baseline?.landmarkHeight != nil {yellow=PosturePreferences.newYellow;red=PosturePreferences.newRed}
                capturing=false;progress=0;stage="review";score=0;state="inside"
                setupCheck.reset();setupCheckPhase="lower";reviewThresholds=(yellow,red)
                // A completed stable capture is the user's save/start action.
                // The existing commit path keeps failure visible and retryable.
                confirm()
            } else {message=result.unstable ? "A little movement. Hold steady to restart the three seconds." : "Hold your comfortable position for three seconds."}
        } else if engine.baseline != nil {
            if monitoring {
                let result=engine.update(value,at:now)
                if state != result.state {state=result.state}
                if score != result.score {score=result.score}
                if warningProgress != result.alertProgress {warningProgress=result.alertProgress}
                // Deep green needs fewer observations; approach to a boundary and
                // all warning/recovery states keep the original fast cadence.
                let interval=result.state=="inside" && (result.score ?? yellow)<yellow*0.65 ? 0.4:1.0/3.0
                let baseline=engine.baseline,yellow=self.yellow,red=self.red
                queue.async { [weak self] in
                    self?.analysisInterval=interval
                    self?.seatedDetector.setReference(baseline:baseline,yellow:yellow,red:red)
                }
                let nextMessage=result.state=="inside" ? "At your comfortable height. Keep doing your thing." : result.state=="yellow" ? "A little lower. Come back toward your line." : "You’ve sunk below your red level. Come back up when you’re ready."
                if message != nextMessage {message=nextMessage}
                if presentsVisuals {alerts.setReminderMode(reminderMode,depth:CGFloat(smokeDepth));alerts.update(result,monitoring:monitoring,paused:paused,tracking:hasPose)}
            } else if stage=="review" {
                refreshSetupCheckThresholds()
                let result=engine.update(value,at:now)
                score=result.score;state=result.state;warningProgress=result.alertProgress
                if let current=result.score {setupCheck.update(score:current,yellow:yellow,red:red,at:now);setupCheckPhase=setupCheck.phase}
                message=persistenceMessage == nil ? "Finishing your height setup…":"Your height could not be saved. Try saving again to start."
                if presentsVisuals {
                    if persistenceMessage != nil {alerts.hide()}
                    else {alerts.setReminderMode(reminderMode,depth:CGFloat(smokeDepth));alerts.update(result,monitoring:true,paused:paused,tracking:hasPose)}
                }
            }

        } else {state="ready";message="Sit comfortably, then set your height. That’s the only capture."}
    }
    func capture() {
        guard active,hasPose,stage=="green" else{return}
        resetSubject();engine.calibrate()
        queue.async { [weak self] in
            guard let self else{return};self.analysisInterval=0.1
            if let device=(self.session.inputs.first as? AVCaptureDeviceInput)?.device {try? self.configureCaptureRate(device,calibrating:true)}
        }
        capturing=true;progress=0
    }
    func restartSetup() {
        let needsStart=updatePausedSession,starter=updateResumeStarter
        if needsStart {updatePausedSession=false;updateResumeStarter=nil;updateAuthorizationOverride=nil;updateAvailabilityOverride=nil;active=false}
        progressStore.record(score:nil,yellow:yellow,red:red,eligible:false);progressStore.flush();liveScore.interrupt()
        setCapturePaused(false)
        if previousCalibration == nil {previousCalibration=preferences.calibration(for:selectedID)}
        canUndoHeightReset=previousCalibration != nil
        resetSubject();yellow=PosturePreferences.newYellow;red=PosturePreferences.newRed
        pose=nil;hasPose=false;lossSince=nil;reacquiredSince=nil;awaitingReacquisition=false
        engine.reset();sampler.reset();alerts.hide();warningProgress=0;stage="green";capturing=false;paused=false;pauseUntil=nil;progress=0;score=nil
        setupCheck.reset();setupCheckPhase="lower";reviewThresholds=nil
        message="Set your comfortable height again. Your saved height is kept until you finish."
        if needsStart {if let starter{starter()}else{startCamera(resumeSaved:false)}}
    }
    func undoHeightReset() {
        guard let saved=previousCalibration,saved.cameraID==selectedID,
              engine.restoreValidated(baseline:saved.poseFeatures,yellow:saved.yellow,red:saved.red,delay:delay) else{return}
        resetSubject();hasPose=false;pose=nil;yellow=saved.yellow;red=saved.red;capturing=false;progress=0;score=nil;warningProgress=0
        paused=false;pauseUntil=nil;stage=active ? "monitoring":"idle";state=active ? "ready":"idle"
        previousCalibration=nil;canUndoHeightReset=false;setupCheck.reset();setupCheckPhase="lower";reviewThresholds=nil
        setCapturePaused(false)
        alerts.hide();message="Your previous height and levels are restored.";persistSettings()
    }
    func back() {
        restartSetup()
    }
    func setHeightBoundary(_ value:Double,isRed:Bool) {
        guard value.isFinite else{return}
        if isRed {red=min(3,max(max(yellow*1.25,yellow+0.4),value))}
        else {yellow=max(0.15,min(min(red/1.25,red-0.4),value))}
        applyThresholds()
    }
    func confirm() {
        refreshSetupCheckThresholds()
        guard active,hasPose,!awaitingReacquisition,stage=="review",!paused,let baseline=engine.baseline,baseline.valid,PostureEngine.validThresholds(yellow:yellow,red:red),(1...5).contains(delay),!selectedID.isEmpty else{return}
        let confirmedPreferences=preferences
        applyThresholds();engine.resume();warningProgress=0;stage="monitoring";paused=false
        persistSettings(includeConfirmedBaseline:true)
        if persistenceMessage != nil {
            preferences=confirmedPreferences;refreshSavedState(loadBoundaries:false);stage="review"
            message="Your height could not be saved. Try saving again to start."
            return
        }
        previousCalibration=nil;canUndoHeightReset=false;reviewThresholds=nil
        message="Your zones are set. Monitoring continues while you use other apps."
    }
    private func refreshSetupCheckThresholds() {
        if stage=="review",reviewThresholds?.0 != yellow || reviewThresholds?.1 != red {
            setupCheck.reset();setupCheckPhase="lower";reviewThresholds=(yellow,red)
        }
    }
    func applyThresholds() {
        progressStore.record(score:nil,yellow:yellow,red:red,eligible:false);liveScore.interrupt()
        refreshSetupCheckThresholds()
        guard delay.isFinite,(1...5).contains(delay)else{return}
        engine.delay=delay
        if PostureEngine.validThresholds(yellow:yellow,red:red) {engine.yellowThreshold=yellow;engine.redThreshold=red}
        engine.clearTiming();warningProgress=0;alerts.hideReminder()
        let baseline=engine.baseline,yellow=self.yellow,red=self.red
        queue.async { [weak self] in self?.seatedDetector.setReference(baseline:baseline,yellow:yellow,red:red) }
        persistSettings()
    }
    private func refreshSavedState(loadBoundaries:Bool=true) {
        if let saved=preferences.calibration(for:selectedID) {hasSavedCalibration=true;if loadBoundaries{yellow=saved.yellow;red=saved.red}}
        else {hasSavedCalibration=false;if loadBoundaries{yellow=preferences.yellow;red=preferences.red}}
    }
    var usesLandmarkHeight:Bool {
        if let baseline=engine.baseline {return baseline.landmarkHeight != nil}
        return preferences.calibration(for:selectedID)?.landmarkHeight != nil
    }
    /// A single control moves both personal boundaries; the calibrated height stays fixed.
    var forgiveness:Double {
        min(1,max(0,0.5+log2(yellow/PosturePreferences.newYellow)/2))
    }
    func setForgiveness(_ value:Double) {
        guard value.isFinite else{return}
        let amount=min(1,max(0,value))
        let multiplier=pow(2,(amount-0.5)*2)
        yellow=PosturePreferences.newYellow*multiplier
        red=PosturePreferences.newRed*multiplier
        applyThresholds()
    }
    func setReminderMode(_ mode:ReminderMode) {
        guard mode != reminderMode else{return}
        reminderMode=mode;alerts.setReminderMode(mode,depth:CGFloat(smokeDepth));persistSettings()
    }
    func setEdgeEffectStyle(_ style:EdgeEffectStyle) {
        guard style != edgeEffectStyle else{return}
        edgeEffectStyle=style;alerts.setEdgeEffectStyle(style);persistSettings()
    }
    func setSmokeDepth(_ value:Double) {
        guard value.isFinite else{return}
        let next=min(10,max(0,value))
        guard next != smokeDepth else{return}
        smokeDepth=next
        alerts.setReminderMode(reminderMode,depth:CGFloat(next))
        persistSettings()
    }
    func setMenuBarStyle(_ style:MenuBarStyle) {
        // Retain legacy source callers without restoring the removed number mode.
        guard style == .color,menuBarStyle != .color else{return}
        menuBarStyle = .color;persistSettings()
    }
    func setRedAlertEnabled(_ enabled:Bool) {
        guard redAlertEnabled != enabled else{return}
        redAlertEnabled=enabled;alerts.setRedAlertEnabled(enabled);persistSettings()
    }
    func setLiveChartMotion(_ motion:LiveChartMotion) {
        guard liveChartMotion != motion else{return}
        liveChartMotion=motion;persistSettings()
    }
    private func persistSettings(includeConfirmedBaseline:Bool=false) {
        preferences.liveChartMotion=liveChartMotion.rawValue
        preferences.menuBarStyle=MenuBarStyle.color.rawValue
        preferences.redAlertEnabled=redAlertEnabled
        preferences.edgeEffectStyle=edgeEffectStyle
        preferences.reminderMode=reminderMode
        preferences.smokeDepth=smokeDepth
        preferences.selectedCameraID=selectedID.isEmpty ? nil:selectedID
        if delay.isFinite,(1...5).contains(delay){preferences.delay=delay}
        if (includeConfirmedBaseline || monitoring || !active),PostureEngine.validThresholds(yellow:yellow,red:red) {
            preferences.yellow=yellow;preferences.red=red
            if includeConfirmedBaseline,let baseline=engine.baseline,baseline.valid,!selectedID.isEmpty {
                preferences.calibrations[selectedID]=SavedCalibration(cameraID:selectedID,baseline:baseline.values,yellow:yellow,red:red,landmarkHeight:baseline.landmarkHeight)
            } else if previousCalibration == nil && (monitoring || !active),var saved=preferences.calibration(for:selectedID) {
                saved.yellow=yellow;saved.red=red;preferences.calibrations[selectedID]=saved
            }
        }
        writePreferences()
    }
    private func writePreferences() {
        do {try store.save(preferences);persistenceMessage=nil;refreshSavedState(loadBoundaries:false)}
        catch {hasSavedCalibration=false;persistenceMessage="Could not save settings on this Mac. \(error.localizedDescription)"}
    }
    func pauseFor(minutes:Int) {
        guard monitoring,minutes>0 else{return}
        pauseUntil=Date().addingTimeInterval(Double(minutes)*60)
        setPaused(true)
    }
    func pollPause(at date:Date=Date()) {
        guard paused,let deadline=pauseUntil,date>=deadline else{return}
        setPaused(false,automatic:true)
    }
    func togglePause() {
        guard monitoring || stage=="review" else{return}
        pauseUntil=nil;setPaused(!paused)
    }
    private func setCapturePaused(_ value:Bool) {
        let token=generation
        queue.async { [weak self] in
            guard let self,self.runToken.accepts(token) else{return}
            self.analysisPaused=value;self.analysisInterval=1.0/3.0
            guard self.currentVideoOutput != nil else{return}
            if value {
                if self.session.isRunning {self.session.stopRunning()}
                self.analysisFrames.clear()
            } else if !self.session.isRunning {
                self.lastInference=0
                self.session.startRunning()
                if let device=(self.session.inputs.first as? AVCaptureDeviceInput)?.device {try? self.configureCaptureRate(device)}
            }
        }
    }
    private func setPaused(_ value:Bool,automatic:Bool=false) {
        if !value,updatePausedSession {
            let starter=updateResumeStarter
            let authorized=updateAuthorizationOverride ?? (AVCaptureDevice.authorizationStatus(for:.video) == .authorized)
            let available=updateAvailabilityOverride ?? Self.devices().contains{$0.uniqueID==selectedID}
            updatePausedSession=false;updateResumeStarter=nil;updateAuthorizationOverride=nil;updateAvailabilityOverride=nil
            active=false;paused=false;pauseUntil=nil;engine.reset();hasPose=false;score=nil;state="idle";stage="idle"
            if automatic && (!authorized || !available) {state="error";message="Camera could not resume after the pause. Check your selected camera and permission.";return}
            if let starter{starter()}else{start()}
            return
        }
        progressStore.record(score:nil,yellow:yellow,red:red,eligible:false);progressStore.flush();liveScore.interrupt()
        bottomExitHeld=false;paused=value;hasPose=false;pose=nil;warningProgress=0;alerts.hide()
        if value,let activity {ProcessInfo.processInfo.endActivity(activity);self.activity=nil}
        else if !value,active,activity==nil {activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep],reason:"On-device posture tracking while you work")}
        setCapturePaused(value)
        if value {engine.pause();score=nil;state="paused";message=pauseUntil == nil ? "Camera and reminders paused. Resume whenever you’re ready.":"Camera and reminders paused for a little while."}
        else {
            pauseUntil=nil;engine.resume();lossSince=nil;reacquiredSince=nil;awaitingReacquisition=true
            state="ready";message="Resuming your zones…"
        }
    }
}

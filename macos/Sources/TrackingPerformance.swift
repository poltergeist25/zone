import Foundation
import Darwin

/// Diagnostic-only ablations. Missing/unknown modes preserve normal visuals.
enum DiagnosticVisualMode:String,CaseIterable {
    case full
    case noSmoke="no-smoke"
    case noGlow="no-glow"
    case frozenIcon="frozen-icon"
    case noVisuals="no-visuals"
    var showsSmoke:Bool {self != .noSmoke && self != .noVisuals}
    var showsMenuGlow:Bool {self != .noGlow && self != .noVisuals}
    var suppressesOverlays:Bool {self == .noVisuals}
    var freezesIcon:Bool {self == .frozenIcon}
}

/// Pure request validation, shared by production and synthetic checks. A request
/// must have an absolute Unix expiry in the next 15 minutes; longer leases fail
/// closed rather than being extended by each five-second reload.
struct DiagnosticVisualRequest:Decodable {
    let expires:Double
    let visual_mode:String?
    let tracker_mode:String?
    let tracker_radius:Int?
    static func parse(_ data:Data?,at now:Double)->DiagnosticVisualRequest? {
        guard now.isFinite,let data,
              let value=try? JSONDecoder().decode(Self.self,from:data),
              value.expires.isFinite,value.expires>now,value.expires-now<=900 else{return nil}
        return value
    }
    var mode:DiagnosticVisualMode {DiagnosticVisualMode(rawValue:visual_mode ?? "full") ?? .full}
}

/// Clock-injected state for deterministic checks, with no filesystem or AppKit.
struct DiagnosticVisualLease {
    private var request:DiagnosticVisualRequest?
    private var observed=false
    private var lastData:Data?
    private var lastExpiry:Double?
    private var deadline=0.0
    mutating func replace(data:Data?,wallTime:Double,uptime:Double) {
        // An unchanged invalid file must not turn itself on later when its
        // distant expiry eventually falls inside the allowed 15-minute window.
        guard !observed || data != lastData else{return}
        observed=true;lastData=data
        let next=DiagnosticVisualRequest.parse(data,at:wallTime)
        if let next,next.expires != lastExpiry {
            lastExpiry=next.expires;deadline=uptime+min(900,next.expires-wallTime)
        }
        request=next
    }
    func isEnabled(wallTime:Double,uptime:Double)->Bool {
        guard let request else{return false}
        return wallTime.isFinite && uptime.isFinite && wallTime<request.expires && uptime<deadline
    }
    func mode(wallTime:Double,uptime:Double)->DiagnosticVisualMode {
        isEnabled(wallTime:wallTime,uptime:uptime) ? (request?.mode ?? .full):.full
    }
    func forcesFullTracker(wallTime:Double,uptime:Double)->Bool {
        isEnabled(wallTime:wallTime,uptime:uptime) && request?.tracker_mode=="full"
    }
    func trackerRadius(wallTime:Double,uptime:Double)->Int {
        guard isEnabled(wallTime:wallTime,uptime:uptime),let radius=request?.tracker_radius,[7,10,12].contains(radius) else{return 7}
        return radius
    }
    func remaining(wallTime:Double,uptime:Double)->Double {
        max(0,min((request?.expires ?? wallTime)-wallTime,deadline-uptime))
    }
    mutating func expire(){deadline=0}
}

extension Notification.Name {
    static let diagnosticVisualPolicyChanged=Notification.Name("ZoneDiagnosticVisualPolicyChanged")
}

/// One in-memory policy for performance recording and visual consumers. File IO
/// occurs on configuration and every five seconds, never in a visual/frame update. The
/// common-mode timers also run while idle or tracking a status menu.
final class DiagnosticVisualPolicy {
    static let shared=DiagnosticVisualPolicy()
    private let lock=NSLock()
    private var lease=DiagnosticVisualLease()
    private var requestURL:URL?
    private var reloadTimer:Timer?
    private var expiryTimer:Timer?
    private(set) var publishedMode=DiagnosticVisualMode.full
    var isEnabled:Bool {
        lock.lock();defer{lock.unlock()}
        return lease.isEnabled(wallTime:Date().timeIntervalSince1970,uptime:ProcessInfo.processInfo.systemUptime)
    }
    var trackerConfiguration:(forcesFull:Bool,radius:Int) {
        lock.lock();defer{lock.unlock()}
        let wall=Date().timeIntervalSince1970,uptime=ProcessInfo.processInfo.systemUptime
        return (lease.forcesFullTracker(wallTime:wall,uptime:uptime),lease.trackerRadius(wallTime:wall,uptime:uptime))
    }
    var forcesFullTracker:Bool {
        lock.lock();defer{lock.unlock()}
        return lease.forcesFullTracker(wallTime:Date().timeIntervalSince1970,uptime:ProcessInfo.processInfo.systemUptime)
    }
    var mode:DiagnosticVisualMode {
        lock.lock();defer{lock.unlock()}
        return lease.mode(wallTime:Date().timeIntervalSince1970,uptime:ProcessInfo.processInfo.systemUptime)
    }
    func configure(directory:URL) {
        // CameraModel stays unchanged; its existing diagnostics initializer is
        // the sole source of the authorized local request directory.
        onMain { [self] in
            let url=directory.appendingPathComponent("performance-request.json")
            if requestURL != url {requestURL=url;refresh()}
            guard reloadTimer==nil else{return}
            let timer=Timer(timeInterval:5,repeats:true){[weak self] _ in self?.refresh()}
            reloadTimer=timer;RunLoop.main.add(timer,forMode:.common)
        }
    }
    private func refresh() {
        let uptime=ProcessInfo.processInfo.systemUptime
        guard let requestURL else{return}
        let now=Date().timeIntervalSince1970
        let data=try? Data(contentsOf:requestURL)
        lock.lock()
        // Preserve the monotonic deadline of an unchanged request, including
        // after wall-clock rollback. Reloading never renews the same lease.
        lease.replace(data:data,wallTime:now,uptime:uptime)
        if !lease.isEnabled(wallTime:now,uptime:uptime){lease.expire()}
        let remaining=lease.remaining(wallTime:now,uptime:uptime)
        lock.unlock()
        expiryTimer?.invalidate();expiryTimer=nil
        if remaining>0 {
            let timer=Timer(timeInterval:remaining,repeats:false){[weak self] _ in
                guard let self else{return}
                self.lock.lock();self.lease.expire();self.lock.unlock()
                self.publishMode()
            }
            expiryTimer=timer;RunLoop.main.add(timer,forMode:.common)
        }
        publishMode()
    }
    private func publishMode() {
        let next=mode
        guard next != publishedMode else{return}
        publishedMode=next
        NotificationCenter.default.post(name:.diagnosticVisualPolicyChanged,object:self)
    }
    private func onMain(_ action:@escaping ()->Void) {
        if Thread.isMainThread{action()}else{DispatchQueue.main.async(execute:action)}
    }
}

/// Temporary, local-only diagnostics. An expiring opt-in file enables aggregate
/// CPU and valid-tracking counters. Never includes images, landmarks or scores.
final class TrackingPerformance {
    var captureInfo:[String:Any]=[:]
    private let output:URL
    private var lastValid:Double?
    private var tracked=0.0
    private var samples=0
    private var bands:[String:Int]=[:]
    private var lastReport=0.0
    private var rows:[[String:Any]]=[]
    init(directory:URL) {
        output=directory.appendingPathComponent("performance-samples.json")
        DiagnosticVisualPolicy.shared.configure(directory:directory)
    }
    func record(valid:Bool,band:String,at now:Double) {
        guard DiagnosticVisualPolicy.shared.isEnabled else{lastValid=nil;return}
        if valid {
            if let lastValid,now>=lastValid,now-lastValid<=0.65 {tracked += now-lastValid}
            lastValid=now;samples += 1;bands[band,default:0] += 1
        } else {lastValid=nil}
    }
    func report(active:Bool,paused:Bool,valid:Bool) {
        let now=ProcessInfo.processInfo.systemUptime
        guard DiagnosticVisualPolicy.shared.isEnabled else{return}
        guard now-lastReport>=5 else{return};lastReport=now
        var usage=rusage();guard getrusage(RUSAGE_SELF,&usage)==0 else{return}
        let cpu=Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1_000_000
        rows.append(["uptime":now,"cpu_seconds":cpu,"tracked_seconds":tracked,"valid_samples":samples,"bands":bands,"active":active,"paused":paused,"valid":valid,"capture":captureInfo,"visual_mode":DiagnosticVisualPolicy.shared.mode.rawValue])
        if rows.count>180 {rows.removeFirst()}
        if let data=try? JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]) {try? data.write(to:output,options:.atomic)}
    }
}

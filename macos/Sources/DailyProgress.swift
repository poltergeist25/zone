import Foundation
import Combine

// Local daily posture statistics. Time is integrated only between two consecutive
// eligible, timestamped samples; frames are never counted, so a fast camera cannot
// weight the denominator. Days and hours follow America/New_York wall time.

enum PostureBand:Int,Codable {
    case green,yellow,red
    // Matches PostureEngine: score >= red is red ("outside"/"alert"), score >= yellow is yellow.
    static func classify(score:Double?,yellow:Double,red:Double)->PostureBand? {
        guard let score,score.isFinite,PostureEngine.validThresholds(yellow:yellow,red:red)else{return nil}
        let value=max(0,score)
        return value >= red ? .red:value >= yellow ? .yellow:.green
    }
}

struct HourProgress:Codable,Equatable {
    var greenSeconds:Double=0
    var yellowSeconds:Double=0
    var redSeconds:Double=0
    var trackedSeconds:Double {greenSeconds+yellowSeconds+redSeconds}
    var score:Double? {DayProgress.score(green:greenSeconds,yellow:yellowSeconds,tracked:trackedSeconds)}
    mutating func add(_ seconds:Double,_ band:PostureBand) {
        switch band {case .green:greenSeconds += seconds;case .yellow:yellowSeconds += seconds;case .red:redSeconds += seconds}
    }
    var valid:Bool {[greenSeconds,yellowSeconds,redSeconds].allSatisfy{$0.isFinite && $0 >= 0 && $0 <= 7200}}
}

struct DayProgress:Codable,Equatable,Identifiable {
    var dateID:String
    var greenSeconds:Double=0
    var yellowSeconds:Double=0
    var redSeconds:Double=0
    // Index is the Eastern wall-clock hour (0...23). On fall-back days both 1 AM hours share index 1.
    var hours:[HourProgress]=Array(repeating:HourProgress(),count:24)
    var id:String {dateID}
    var trackedSeconds:Double {greenSeconds+yellowSeconds+redSeconds}
    // nil when nothing was tracked: missing time is never shown as green or as zero.
    var greenFraction:Double? {trackedSeconds>0 ? greenSeconds/trackedSeconds:nil}
    var yellowFraction:Double? {trackedSeconds>0 ? yellowSeconds/trackedSeconds:nil}
    var redFraction:Double? {trackedSeconds>0 ? redSeconds/trackedSeconds:nil}
    var score:Double? {Self.score(green:greenSeconds,yellow:yellowSeconds,tracked:trackedSeconds)}
    init(dateID:String) {self.dateID=dateID}
    static func score(green:Double,yellow:Double,tracked:Double)->Double? {
        tracked>0 ? 100*(green+0.5*yellow)/tracked:nil
    }
    mutating func add(_ seconds:Double,_ band:PostureBand,hour:Int) {
        switch band {case .green:greenSeconds += seconds;case .yellow:yellowSeconds += seconds;case .red:redSeconds += seconds}
        hours[hour].add(seconds,band)
    }
    var valid:Bool {
        guard DailyProgressCalendar.isDateID(dateID),hours.count==24,hours.allSatisfy(\.valid),
              [greenSeconds,yellowSeconds,redSeconds].allSatisfy({$0.isFinite && $0 >= 0}),trackedSeconds <= 25*3600 else{return false}
        // Day totals must agree with the hourly buckets they summarize.
        let tolerance=0.01
        return abs(hours.reduce(0){$0+$1.greenSeconds}-greenSeconds)<tolerance
            && abs(hours.reduce(0){$0+$1.yellowSeconds}-yellowSeconds)<tolerance
            && abs(hours.reduce(0){$0+$1.redSeconds}-redSeconds)<tolerance
    }
}

enum DailyProgressCalendar {
    static let timeZoneID="America/New_York"
    static let calendar:Calendar={
        var calendar=Calendar(identifier:.gregorian)
        calendar.timeZone=TimeZone(identifier:timeZoneID)!
        calendar.locale=Locale(identifier:"en_US_POSIX")
        return calendar
    }()
    static func dateID(_ date:Date)->String {
        let c=calendar.dateComponents([.year,.month,.day],from:date)
        return String(format:"%04d-%02d-%02d",c.year!,c.month!,c.day!)
    }
    static func date(fromID id:String)->Date? {
        let parts=id.split(separator:"-").compactMap{Int($0)}
        guard parts.count==3 else{return nil}
        guard let date=calendar.date(from:DateComponents(year:parts[0],month:parts[1],day:parts[2],hour:12)),dateID(date)==id else{return nil}
        return calendar.startOfDay(for:date)
    }
    static func isDateID(_ id:String)->Bool {id.count==10 && date(fromID:id) != nil}
}

struct DailyProgressFile:Codable {
    static let currentVersion=1
    var version=currentVersion
    var timeZone=DailyProgressCalendar.timeZoneID
    var days:[DayProgress]
}

final class ProgressStore:ObservableObject {
    static var defaultURL:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Posture Zone",isDirectory:true).appendingPathComponent("daily-progress.json")
    }
    @Published private(set) var days:[DayProgress]=[]
    @Published private(set) var errorMessage:String?
    let url:URL
    // Samples further apart than this are a break in monitoring, not posture time.
    let maxSampleGap:TimeInterval
    let saveInterval:TimeInterval
    let publishInterval:TimeInterval
    private let now:()->Date
    private var storage:[String:DayProgress]=[:]
    private var anchor:(date:Date,band:PostureBand)?
    private var dirty=false
    private var lastSave:Date?
    private var lastPublish:Date?
    private var writeBlocked=false
    private(set) var rejectedSamples=0

    init(url:URL=ProgressStore.defaultURL,now:@escaping ()->Date=Date.init,maxSampleGap:TimeInterval=1.5,saveInterval:TimeInterval=30,publishInterval:TimeInterval=1) {
        self.url=url;self.now=now;self.maxSampleGap=maxSampleGap;self.saveInterval=saveInterval;self.publishInterval=publishInterval
        load()
    }

    var currentDate:Date {now()}
    var today:DayProgress {day(for:now())}
    func day(for date:Date)->DayProgress {
        let id=DailyProgressCalendar.dateID(date)
        return storage[id] ?? DayProgress(dateID:id)
    }
    func day(id:String)->DayProgress? {storage[id]}
    // Tracked share of the day's elapsed wall time (whole day for past days).
    func coverage(of day:DayProgress)->Double? {
        guard let start=DailyProgressCalendar.date(fromID:day.dateID),
              let end=DailyProgressCalendar.calendar.date(byAdding:.day,value:1,to:start)else{return nil}
        let elapsed=min(end,max(start,now())).timeIntervalSince(start)
        return elapsed>0 ? min(1,day.trackedSeconds/elapsed):nil
    }

    // Call on the main thread for every engine result. eligible must be false while paused, lost, off,
    // calibrating or in setup; such samples end the current interval and count nothing.
    func record(score:Double?,yellow:Double,red:Double,at date:Date=Date(),eligible:Bool) {
        guard date.timeIntervalSinceReferenceDate.isFinite else{rejectedSamples += 1;anchor=nil;return}
        if let previous=anchor {
            if date<previous.date {rejectedSamples += 1;anchor=nil;return}
            if date==previous.date {
                if !eligible || PostureBand.classify(score:score,yellow:yellow,red:red)==nil {anchor=nil}
                return
            }
        }
        let band=eligible ? PostureBand.classify(score:score,yellow:yellow,red:red):nil
        if let previous=anchor,band != nil {
            let gap=date.timeIntervalSince(previous.date)
            if gap <= maxSampleGap {integrate(from:previous.date,to:date,band:previous.band)}
        }
        anchor=band.map{(date:date,band:$0)}
        maybePersist(at:date)
    }

    func flush() {
        publish()
        guard dirty else{return}
        save()
    }

    private func integrate(from start:Date,to end:Date,band:PostureBand) {
        let calendar=DailyProgressCalendar.calendar
        var cursor=start
        while cursor<end {
            guard let hour=calendar.dateInterval(of:.hour,for:cursor)else{return}
            let stop=min(end,hour.end)
            let id=DailyProgressCalendar.dateID(cursor)
            var day=storage[id] ?? DayProgress(dateID:id)
            day.add(stop.timeIntervalSince(cursor),band,hour:calendar.component(.hour,from:cursor))
            storage[id]=day
            cursor=stop
        }
        dirty=true
    }

    private func maybePersist(at date:Date) {
        guard dirty else{return}
        if lastPublish.map({abs(date.timeIntervalSince($0))>=publishInterval}) ?? true {publish();lastPublish=date}
        if let lastSave {
            if abs(date.timeIntervalSince(lastSave))>=saveInterval {save();self.lastSave=date}
        } else {self.lastSave=date}
    }

    private func publish() {
        let sorted=storage.values.sorted{$0.dateID<$1.dateID}
        if sorted != days {days=sorted}
    }

    private func save() {
        guard !writeBlocked else{return}
        do {
            try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let data=try encoder.encode(DailyProgressFile(days:storage.values.sorted{$0.dateID<$1.dateID}))
            try data.write(to:url,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            dirty=false
            if errorMessage != nil {errorMessage=nil}
        } catch {
            errorMessage="Could not save daily progress: \(error.localizedDescription)"
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath:url.path)else{return}
        do {
            let file=try JSONDecoder().decode(DailyProgressFile.self,from:Data(contentsOf:url))
            guard file.version==DailyProgressFile.currentVersion,file.timeZone==DailyProgressCalendar.timeZoneID,
                  file.days.allSatisfy(\.valid),Set(file.days.map(\.dateID)).count==file.days.count else{
                throw CocoaError(.fileReadCorruptFile)
            }
            storage=Dictionary(uniqueKeysWithValues:file.days.map{($0.dateID,$0)})
            days=file.days.sorted{$0.dateID<$1.dateID}
        } catch {
            // Keep unreadable history aside instead of overwriting it with a fresh file.
            let aside=url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            let moved=(try? FileManager.default.moveItem(at:url,to:aside)) != nil
            writeBlocked = !moved
            errorMessage=moved ? "Daily progress was unreadable and was set aside at \(aside.lastPathComponent). Starting a new history."
                : "Daily progress could not be read and will not be overwritten: \(error.localizedDescription)"
        }
    }
}

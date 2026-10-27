import SwiftUI

struct LiveScorePoint {let date:Date;let value:Double?;var originalSample:Bool=true}
final class LiveScoreStore:ObservableObject {
    @Published private(set) var points:[LiveScorePoint]=[]
    @Published private(set) var current:Double?
    private var lastRecorded=Date.distantPast
    private var lastOriginalRecorded=Date.distantPast
    static func value(deviation:Double?,yellow:Double,red:Double)->Double? {
        guard let raw=deviation,raw.isFinite,PostureEngine.validThresholds(yellow:yellow,red:red) else{return nil}
        let d=max(0,raw)
        if d<yellow{return 100-15*d/yellow}
        if d<red{return 85-35*(d-yellow)/(red-yellow)}
        return max(0,50-50*(d-red)/max(red,0.4))
    }
    func record(deviation:Double?,yellow:Double,red:Double,at date:Date=Date(),eligible:Bool) {
        guard date.timeIntervalSinceReferenceDate.isFinite,date>=lastRecorded else{return}
        let next=eligible ? Self.value(deviation:deviation,yellow:yellow,red:red):nil
        let changedAvailability=(next==nil) != (current==nil)
        current=next
        guard changedAvailability || date.timeIntervalSince(lastRecorded)>=0.28 else{return}
        // A long interruption starts a new segment; never join across an unseen interval.
        if date.timeIntervalSince(lastRecorded)>1.5,!points.isEmpty {points.append(LiveScorePoint(date:date.addingTimeInterval(-0.01),value:nil))}
        let originalSample=changedAvailability || date.timeIntervalSince(lastOriginalRecorded)>=1
        points.append(LiveScorePoint(date:date,value:next,originalSample:originalSample));lastRecorded=date
        if originalSample {lastOriginalRecorded=date}
        points.removeAll{$0.date<date.addingTimeInterval(-300)}
        if points.count>2400 {points.removeFirst(points.count-2400)}
    }
    func interrupt(at date:Date=Date()){record(deviation:nil,yellow:0.6,red:1,at:date,eligible:false)}

    func currentEndpoint(at date:Date)->LiveScorePoint? {
        guard current != nil,let last=points.last,last.value != nil,
              (0...1.5).contains(date.timeIntervalSince(last.date)) else{return nil}
        return last
    }
    func historyDescription(at date:Date,inactiveStatus:String)->String {
        var minimum=Double.infinity,maximum = -Double.infinity
        var hasGaps=false
        for sample in points where sample.date>=date.addingTimeInterval(-300) && sample.date<=date {
            if let value=sample.value {minimum=min(minimum,value);maximum=max(maximum,value)}
            else {hasGaps=true}
        }
        let status=currentEndpoint(at:date)?.value.map{"Current score \(Int($0.rounded())) out of 100."} ?? "\(inactiveStatus)."
        guard minimum.isFinite else{return "\(status) No readings in the last five minutes."}
        return "\(status) Available readings in the last five minutes ranged from \(Int(minimum.rounded())) to \(Int(maximum.rounded()))." + (hasGaps ? " Gaps are time without valid tracking; dotted links connect their measured endpoints.":"")
    }
}

struct LiveScoreChart:View {
    @ObservedObject var store:LiveScoreStore
    var inactiveStatus="Tracking unavailable"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            HStack(alignment:.center) {
                VStack(alignment:.leading,spacing:6) {
                    Text("Live score").font(.system(size:16,weight:.semibold))
                }
                Spacer()
                HStack(alignment:.firstTextBaseline,spacing:5) {
                    Text(store.current.map{String(Int($0.rounded()))} ?? "—")
                        .font(.system(size:58,weight:.medium,design:.rounded)).monospacedDigit()
                    Text("/ 100").font(.system(size:12)).foregroundStyle(.secondary)
                }
            }
            TimelineView(.periodic(from:.now,by:reduceMotion ? 1:1.0/3.0)) {timeline in
                let now=timeline.date
                Canvas {context,size in
                    func point(_ sample:LiveScorePoint,_ value:Double)->CGPoint {
                        CGPoint(x:4+(size.width-10)*(1+sample.date.timeIntervalSince(now)/300),y:6+(size.height-12)*(1-value/100))
                    }
                    for value in [0.0,50,100] {
                        let y=6+(size.height-12)*(1-value/100)
                        var rule=Path();rule.move(to:CGPoint(x:0,y:y));rule.addLine(to:CGPoint(x:size.width,y:y))
                        context.stroke(rule,with:.color(.gray.opacity(0.13)),style:StrokeStyle(lineWidth:0.5,dash:[3,4]))
                    }
                    var previous:LiveScorePoint?
                    var interrupted=false
                    var bridges=Path()
                    var paths=[Path(),Path(),Path()]
                    for sample in store.points where sample.date>=now.addingTimeInterval(-300) && sample.date<=now {
                        guard let value=sample.value else {interrupted=true;continue}
                        if let old=previous,let oldValue=old.value {
                            if interrupted || sample.date.timeIntervalSince(old.date)>1.5 {
                                bridges.move(to:point(old,oldValue));bridges.addLine(to:point(sample,value))
                            } else {
                                let band=value>=85 ? 0:value>=50 ? 1:2
                                paths[band].move(to:point(old,oldValue));paths[band].addLine(to:point(sample,value))
                            }
                        }
                        previous=sample;interrupted=false
                    }
                    context.stroke(bridges,with:.color(Color(red:0.13,green:0.25,blue:0.19).opacity(0.34)),
                                   style:StrokeStyle(lineWidth:1.3,lineCap:.round,dash:[3,5]))
                    let colors:[Color]=[Color(red:0.2,green:0.52,blue:0.34),Color(red:0.76,green:0.49,blue:0.1),Color(red:0.8,green:0.25,blue:0.22)]
                    for index in 0..<3 {
                        context.stroke(paths[index],with:.linearGradient(
                            Gradient(colors:[colors[index].opacity(0.42),colors[index]]),
                            startPoint:CGPoint(x:0,y:0),endPoint:CGPoint(x:size.width,y:0)),
                            style:StrokeStyle(lineWidth:2.2,lineCap:.round,lineJoin:.round))
                    }
                    if let latest=store.currentEndpoint(at:now),let value=latest.value {
                        let center=point(latest,value)
                        context.fill(Path(ellipseIn:CGRect(x:center.x-5,y:center.y-5,width:10,height:10)),with:.color(.white))
                        context.fill(Path(ellipseIn:CGRect(x:center.x-3.3,y:center.y-3.3,width:6.6,height:6.6)),with:.color(colors[value>=85 ? 0:value>=50 ? 1:2]))
                    }
                }.frame(minHeight:220,maxHeight:.infinity)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("Live score chart, last five minutes")
                .accessibilityValue(store.historyDescription(at:now,inactiveStatus:inactiveStatus))
            }.frame(maxHeight:.infinity)
            HStack {
                Text("Last 5 minutes")
                Spacer()
                Text(store.current == nil ? inactiveStatus:"Now")
            }.font(.system(size:10)).foregroundStyle(.secondary)
        }.padding(.leading,28).padding(.trailing,16).padding(.vertical,20).frame(maxHeight:.infinity)
        .background(.white.opacity(0.6),in:RoundedRectangle(cornerRadius:22))
        .accessibilityElement(children:.contain)
        .help("Live score: 100 at your chosen height, 85 at yellow and 50 at red. Dotted links span untracked time between measured readings; they do not count toward your score. Your daily score separately measures time in each zone.")
    }
}

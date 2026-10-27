import SwiftUI

private let forest=Color(red:0.13,green:0.25,blue:0.19)
private let mint=Color(red:0.88,green:0.93,blue:0.86)
private let greenZone=Color(red:0.29,green:0.55,blue:0.40)
private let yellowZone=Color(red:0.80,green:0.53,blue:0.16)
private let redZone=Color(red:0.76,green:0.29,blue:0.25)

// Display calculations only. Stored history, scoring and sampling are unchanged.
enum ProgressTimeline {
    static func week(containing date:Date,offset:Int=0)->[Date] {
        let calendar=DailyProgressCalendar.calendar
        let start=calendar.startOfDay(for:date)
        let weekday=(calendar.component(.weekday,from:start)+5)%7
        guard let monday=calendar.date(byAdding:.day,value:offset*7-weekday,to:start)else{return []}
        return (0..<7).compactMap{calendar.date(byAdding:.day,value:$0,to:monday)}
    }
    static func hours(for day:DayProgress)->ClosedRange<Int> {
        let recorded=day.hours.indices.filter{day.hours[$0].trackedSeconds>0}
        return min(9,recorded.first ?? 9)...max(16,recorded.last ?? 16)
    }
    static func title(_ date:Date,_ format:String)->String {
        let formatter=DateFormatter();formatter.calendar=DailyProgressCalendar.calendar
        formatter.timeZone=DailyProgressCalendar.calendar.timeZone
        formatter.locale=Locale(identifier:"en_US_POSIX");formatter.dateFormat=format
        return formatter.string(from:date)
    }
    static func hourLabel(_ hour:Int)->String {
        let value=hour%24
        return "\(value%12==0 ? 12:value%12) \(value<12 ? "AM":"PM")"
    }
    static func duration(_ seconds:Double)->String {
        let total=max(0,Int(seconds.rounded(.down)))
        if total<60{return "\(total)s"}
        let hours=total/3600,minutes=total%3600/60
        if hours==0{return "\(minutes)m"}
        return minutes==0 ? "\(hours)h":"\(hours)h \(minutes)m"
    }
    static func percent(_ fraction:Double?)->String {
        fraction.map{"\(Int(($0*100).rounded()))%"} ?? "—"
    }
}

struct ProgressViewPanel:View {
    @ObservedObject var store:ProgressStore
    @State private var selectedID:String?
    @State private var weekOffset=0
    var body:some View {
        TimelineView(.everyMinute){_ in content}
    }
    private var content:some View {
        let today=store.today
        let date=selectedID.flatMap(DailyProgressCalendar.date(fromID:)) ?? store.currentDate
        let selected=selectedID.flatMap{store.day(id:$0)} ?? (selectedID==nil ? today:DayProgress(dateID:DailyProgressCalendar.dateID(date)))
        let isToday=selected.dateID==today.dateID
        let week=ProgressTimeline.week(containing:store.currentDate,offset:weekOffset)
        return VStack(alignment:.leading,spacing:18){
            HStack(alignment:.center){
                VStack(alignment:.leading,spacing:8){
                    Text("Progress").font(.system(size:33,design:.serif))
                    Text(isToday ? "Today":ProgressTimeline.title(date,"EEEE, MMM d"))
                        .font(.system(size:13)).foregroundStyle(forest.opacity(0.65))
                }
                Spacer()
                VStack(alignment:.trailing,spacing:0) {
                    HStack(alignment:.firstTextBaseline,spacing:5){
                        Text(selected.score.map{"\(Int($0.rounded()))"} ?? "—").font(.system(size:66,design:.serif)).monospacedDigit()
                        Text("/ 100").font(.system(size:14)).foregroundStyle(forest.opacity(0.55))
                    }
                    Text("Daily score").font(.system(size:12,weight:.medium)).foregroundStyle(forest.opacity(0.7))
                }.accessibilityElement(children:.ignore)
                    .accessibilityLabel(selected.score.map{"Daily score \(Int($0.rounded())) out of 100"} ?? "No tracked daily score yet")
                    .help("Green earns full credit, yellow half credit. Only valid tracked time counts.")
            }
            DailyBalanceChart(day:selected)
            VStack(spacing:10){
                HStack{
                    Button{moveWeek(-1)}label:{Image(systemName:"chevron.left")}.accessibilityLabel("Previous week")
                    Text(weekTitle(week)).font(.system(size:11,weight:.medium)).foregroundStyle(forest.opacity(0.65))
                    Button{moveWeek(1)}label:{Image(systemName:"chevron.right")}.disabled(weekOffset==0).accessibilityLabel("Next week")
                    Spacer()
                    if selectedID != nil || weekOffset != 0 {
                        Button("Today"){selectedID=nil;weekOffset=0}.font(.system(size:11))
                    }
                }.buttonStyle(.plain)
                HStack(spacing:10){
                    ForEach(week,id:\.self){date in weekDay(date,selected:selected.dateID)}
                }
            }
            if let message=store.errorMessage {
                Label(message,systemImage:"exclamationmark.circle").font(.system(size:11)).foregroundStyle(redZone)
                    .fixedSize(horizontal:false,vertical:true)
            }
            Text("Score uses tracked time only. Pauses and time away are excluded.")
                .font(.system(size:11)).foregroundStyle(forest.opacity(0.65))
        }.padding(.horizontal,32).padding(.vertical,18)
            .frame(maxWidth:.infinity,alignment:.topLeading).foregroundStyle(forest)
    }
    private func moveWeek(_ change:Int) {
        weekOffset=min(0,weekOffset+change)
        let week=ProgressTimeline.week(containing:store.currentDate,offset:weekOffset)
        // Select an actual recorded day when available; otherwise show an honest empty day.
        selectedID=week.reversed().map(DailyProgressCalendar.dateID).first{store.day(id:$0)?.trackedSeconds ?? 0 > 0}
            ?? week.first.map(DailyProgressCalendar.dateID)
    }
    private func weekTitle(_ dates:[Date])->String {
        guard let first=dates.first,let last=dates.last else{return "This week"}
        return "\(ProgressTimeline.title(first,"MMM d")) – \(ProgressTimeline.title(last,"MMM d, yyyy"))"
    }
    private func weekDay(_ date:Date,selected:String)->some View {
        let id=DailyProgressCalendar.dateID(date)
        let day=store.day(id:id)
        let future=date>DailyProgressCalendar.calendar.startOfDay(for:store.currentDate)
        let chosen=id==selected
        return Button{selectedID=id}label:{
            VStack(spacing:6){
                Text(ProgressTimeline.title(date,"EEE")).font(.system(size:10,weight:chosen ? .semibold:.regular))
                Text(day?.score.map{"\(Int($0.rounded()))"} ?? "—").font(.system(size:22,design:.serif)).monospacedDigit()
            }.frame(maxWidth:.infinity).padding(.vertical,10)
                .background(chosen ? mint:Color.clear,in:RoundedRectangle(cornerRadius:12))
                .contentShape(RoundedRectangle(cornerRadius:12))
                .foregroundStyle(forest.opacity(future ? 0.4:1))
        }.buttonStyle(.plain).disabled(future)
            .accessibilityLabel("\(ProgressTimeline.title(date,"EEEE, MMMM d")), \(day?.score.map{"score \(Int($0.rounded()))"} ?? "no tracked time")")
            .accessibilityAddTraits(chosen ? [.isSelected]:[])
            .help(day.map{"\(ProgressTimeline.duration($0.trackedSeconds)) tracked"} ?? "No tracked time")
    }
}

struct DailyBalanceSegment:Identifiable {
    let id:Int
    let title:String
    let seconds:Double
    let fraction:Double?
    let start:Double
    let end:Double
}

enum DailyBalanceSummary {
    static func segments(_ day:DayProgress)->[DailyBalanceSegment] {
        let values=[day.greenSeconds,day.yellowSeconds,day.redSeconds]
        let total=day.trackedSeconds
        var start=0.0
        return values.enumerated().map {index,seconds in
            let fraction=total>0 ? seconds/total:nil
            let end=min(1,start+(fraction ?? 0))
            let value=DailyBalanceSegment(id:index,title:["Green","Yellow","Red"][index],seconds:seconds,fraction:fraction,start:start,end:end)
            start=end;return value
        }
    }
    static func duration(_ seconds:Double)->String {
        guard seconds>0 else{return "0s"}
        if seconds<1{return "<1s"}
        let total=Int(seconds.rounded(.down))
        if total<60{return "\(total)s"}
        if total<3600 {
            let minutes=total/60,remainder=total%60
            return remainder==0 ? "\(minutes)m":"\(minutes)m \(remainder)s"
        }
        return ProgressTimeline.duration(Double(total))
    }
}

struct DailyBalanceChart:View {
    let day:DayProgress
    private let colors=[greenZone,yellowZone,redZone]
    var body:some View {
        let segments=DailyBalanceSummary.segments(day)
        return HStack(spacing:36){
            ZStack {
                Circle().stroke(forest.opacity(0.07),lineWidth:13)
                ForEach(segments){segment in
                    if let fraction=segment.fraction,fraction>0 {
                        let gap=fraction>=1 ? 0:min(0.004,fraction/4)
                        Circle().trim(from:segment.start+gap,to:segment.end-gap)
                            .stroke(colors[segment.id],style:StrokeStyle(lineWidth:13,lineCap:.butt))
                            .rotationEffect(.degrees(-90))
                    }
                }
                VStack(spacing:4){
                    Text(day.trackedSeconds>0 ? ProgressTimeline.duration(day.trackedSeconds):"—")
                        .font(.system(size:32,design:.serif)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("tracked").font(.system(size:11)).foregroundStyle(forest.opacity(0.65))
                }.padding(.horizontal,15)
            }.frame(width:160,height:160).padding(7)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel(day.trackedSeconds>0 ? "\(DailyBalanceSummary.duration(day.trackedSeconds)) total tracked time":"No tracked time yet")
            VStack(alignment:.leading,spacing:18){
                Text("TIME IN ZONE").font(.system(size:10,weight:.semibold)).tracking(1.6)
                VStack(alignment:.leading,spacing:16){
                    ForEach(segments){segment in
                        HStack(spacing:10) {
                            HStack(spacing:7){
                                Circle().fill(colors[segment.id]).frame(width:7,height:7)
                                Text(segment.title).font(.system(size:14,weight:.medium)).fixedSize()
                            }.frame(width:66,alignment:.leading)
                            Text(day.trackedSeconds>0 ? DailyBalanceSummary.duration(segment.seconds):"—")
                                .font(.system(size:13)).monospacedDigit().foregroundStyle(forest.opacity(0.65))
                                .lineLimit(1).frame(width:62,alignment:.leading)
                            Text(ProgressTimeline.percent(segment.fraction))
                                .font(.system(size:17,weight:.medium)).monospacedDigit()
                                .lineLimit(1).frame(width:48,alignment:.trailing)
                        }.accessibilityElement(children:.ignore)
                            .accessibilityLabel(day.trackedSeconds>0 ? "\(segment.title), \(DailyBalanceSummary.duration(segment.seconds)), \(ProgressTimeline.percent(segment.fraction))":"\(segment.title), no tracked time")
                    }
                }
            }.fixedSize(horizontal:true,vertical:false)
        }.frame(maxWidth:.infinity,minHeight:174).padding(22)
            .foregroundStyle(forest)
            .background(Color.white.opacity(0.55),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).stroke(forest.opacity(0.12)))
    }
}

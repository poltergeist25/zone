import AppKit

@main struct MenuIconChecks {
    static var checks=0
    static func check(_ condition:@autoclosure ()->Bool,_ name:String){guard condition()else{fatalError("FAIL: \(name)")};checks += 1;print("PASS: \(name)")}
    static func main() {
        _=NSApplication.shared
        check(MenuBarIcon.severity(score:0,yellow:0.8,red:1.6)==0,"Neutral maps to zero")
        check(MenuBarIcon.severity(score:0.8,yellow:0.8,red:1.6)==1,"Personal yellow maps to one")
        check(MenuBarIcon.severity(score:1.6,yellow:0.8,red:1.6)==2,"Personal red maps to two")
        check(MenuBarIcon.severity(score:10,yellow:0.8,red:1.6)==3,"Severity clamps at three")
        check(MenuBarIcon.severity(score:Double.nan,yellow:0.8,red:1.6)==0,"Invalid score is bounded")
        let green=MenuBarIcon.metrics(severity:0,progress:0,time:0)
        let middle=MenuBarIcon.metrics(severity:0.5,progress:0,time:0)
        let yellow=MenuBarIcon.metrics(severity:1,progress:0,time:0)
        let red=MenuBarIcon.metrics(severity:2,progress:0,time:0)
        let urgent=MenuBarIcon.metrics(severity:2,progress:1,time:0)
        check(green.green>green.red && red.red>red.green,"Green and red anchors remain distinct")
        check(abs(middle.red-(green.red+yellow.red)/2)<0.000001,"Color interpolates continuously")
        check(green.dotRadius<yellow.dotRadius && yellow.dotRadius<red.dotRadius,"Dotted mark grows fuller with severity")
        check(urgent.lineWidth>red.lineWidth && urgent.centerRadius>red.centerRadius,"Red dwell increases urgency")
        check(MenuBarIcon.pulseFrequency>0 && MenuBarIcon.pulseFrequency<=1.5,"Pulse remains restrained")
        let peak=MenuBarIcon.metrics(severity:2,progress:1,time:0.25/MenuBarIcon.pulseFrequency)
        let trough=MenuBarIcon.metrics(severity:2,progress:1,time:0.75/MenuBarIcon.pulseFrequency)
        check(peak.dotRadius>trough.dotRadius && trough.ringOpacity>0.5,"Pulse breathes without flashing off")
        let stillA=MenuBarIcon.metrics(severity:2,progress:1,time:0,reduceMotion:true)
        let stillB=MenuBarIcon.metrics(severity:2,progress:1,time:10,reduceMotion:true)
        check(stillA.dotRadius==stillB.dotRadius && stillA.ringOpacity==stillB.ringOpacity,"Reduce Motion stops the pulse")
        check(green.urgency<urgent.urgency,"Recovered geometry reduces urgency without animation history")
        check(MenuBarIcon.metrics(severity:0,progress:1,time:0).urgency==green.urgency,"Recovery ignores stale red dwell")
        for severity in [0.0,0.5,1,1.5,2,3] {
            let image=MenuBarIcon.render(severity:severity,progress:0.6,time:1)
            check(image.size==NSSize(width:18,height:18) && !image.isTemplate,"Fixed 18pt non-template image at severity \(severity)")
            guard let data=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data)else{fatalError("Icon rasterization failed")}
            var count=0
            for y in 0..<bitmap.pixelsHigh {for x in 0..<bitmap.pixelsWide {if let color=bitmap.colorAt(x:x,y:y),color.alphaComponent>0.1{count += 1}}}
            check(count>10 && count<bitmap.pixelsWide*bitmap.pixelsHigh,"Legible transparent-bounded raster at severity \(severity)")
        }
        print("\(checks) menu icon checks passed")
    }
}

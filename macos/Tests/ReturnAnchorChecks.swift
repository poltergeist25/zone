import Foundation
import CoreGraphics

@main struct ReturnAnchorChecks {
    static func face(_ cx:Double=0.50,_ cy:Double=0.49,_ w:Double=0.22,_ h:Double=0.28,
                     _ sig:[Double]=[0.42,0.63],green:Bool=false)->FaceCandidate {
        FaceCandidate(box:CGRect(x:cx-w/2,y:cy-h/2,width:w,height:h),signature:sig,returnAnchorEligible:green)
    }
    static func seated(_ green:Bool)->FaceContinuity {
        var tracker=FaceContinuity()
        precondition(tracker.select([face(0.5,0.70,0.11,0.14)],at:0).index==0)
        precondition(tracker.select([face(0.5,0.62,0.15,0.19)],at:0.3).index==0)
        precondition(tracker.select([face(0.5,0.54,0.19,0.24)],at:0.6).index==0)
        for time in [0.9,1.2334,1.5668] {precondition(tracker.select([face(green:green)],at:time).index==0)}
        return tracker
    }
    static func depart(_ tracker:inout FaceContinuity,at time:Double) {
        _=tracker.select([face(0.36)],at:time)
        _=tracker.select([face(0.22)],at:time+0.3334)
        _=tracker.select([],at:time+0.6668)
    }
    static func main() {
        var first=FaceContinuity()
        precondition(first.select([face(0.5,0.49,0.1,0.12,[])],at:0).index==nil,
                     "Incomplete observations must never establish the subject")
        precondition(first.selectedBox==nil)
        precondition(first.select([face()],at:0.3334).index==0)

        var tracker=seated(true)
        depart(&tracker,at:1.9)
        precondition(tracker.select([face(0.5,0.49,0.1,0.12,[])],at:2.9).index==nil)
        precondition(tracker.select([face()],at:3.2334).index==0,
                     "A stable verified-green seat must recover despite a bad first anchor")
        _=tracker.select([],at:3.5668)
        precondition(tracker.select([face(0.5,0.49,0.22,0.28,[0.8,0.28])],at:3.9).index==nil,
                     "The new anchor cannot bypass subject proportions")
        let two=tracker.select([face(0.48),face(0.52)],at:4.2334)
        precondition(two.index==nil && two.loss == .ambiguous,
                     "Two plausible returners retain ambiguity protection")
        precondition(tracker.select([face()],at:4.5668).index==0)

        var unverified=seated(false)
        depart(&unverified,at:1.9)
        precondition(unverified.select([face()],at:2.9).index==nil,
                     "Accepted but non-green positions cannot create a recovery corridor")

        var slow=FaceContinuity()
        _=slow.select([face(0.5,0.70,0.11,0.14)],at:0)
        _=slow.select([face(0.5,0.62,0.15,0.19)],at:0.3)
        _=slow.select([face(0.5,0.54,0.19,0.24)],at:0.6)
        for time in [0.9,1.5668,2.2336] {_=slow.select([face(green:true)],at:time)}
        depart(&slow,at:2.6)
        precondition(slow.select([face()],at:3.6).index==0,
                     "Dropped frames must still allow three stable green readings to establish the seated return")

        var interrupted=FaceContinuity()
        _=interrupted.select([face(0.5,0.70,0.11,0.14)],at:0)
        _=interrupted.select([face(0.5,0.62,0.15,0.19)],at:0.3)
        _=interrupted.select([face(0.5,0.54,0.19,0.24)],at:0.6)
        _=interrupted.select([face(green:true)],at:0.9)
        _=interrupted.select([face(green:true)],at:1.2334)
        _=interrupted.select([],at:1.4)
        _=interrupted.select([face(green:true)],at:1.5668)
        depart(&interrupted,at:1.9)
        precondition(interrupted.select([face()],at:2.9).index==nil,
                     "Separated sightings cannot manufacture a stable return anchor")

        var bottom=seated(true)
        _=bottom.select([face(0.5,0.33)],at:1.9)
        let edge=bottom.select([face(0.5,0.17)],at:2.2334)
        precondition(edge.index==0 && edge.loss == .bottom)
        precondition(bottom.select([],at:2.5668).loss == .bottom)
        precondition(bottom.select([face(0.5,0.7,0.11,0.14)],at:2.9).index==0,
                     "A recent green anchor must retain the original bottom-return anchor")
        print("PASS: incomplete first face, stable green seat return, partial recovery, visitor/ambiguity, unverified/intermittent isolation and retained bottom anchor")
    }
}

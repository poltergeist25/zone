import Foundation
import CoreGraphics

@main struct SideReturnChecks {
    static func face(_ x:Double=0.39,_ y:Double=0.35,width:Double=0.22,height:Double=0.28,signature:[Double]=[0.42,0.63,0.31])->FaceCandidate {
        FaceCandidate(box:CGRect(x:x,y:y,width:width,height:height),signature:signature)
    }
    static func check(_ condition:Bool,_ message:String="Assertion failed") {
        guard condition else {fputs(message+"\n",stderr);exit(1)}
    }
    static func main() {
        setbuf(stdout,nil)
        let original=face()
        for sign in [-1.0,1.0] {
            var tracker=FaceContinuity()
            check(tracker.select([original],at:0).index==0)
            check(tracker.select([face(0.39+sign*0.11)],at:0.3).index==0)
            check(tracker.select([face(0.39+sign*0.22)],at:0.6).index==0)
            let lost=tracker.select([],at:0.9)
            check(lost.index==nil && lost.loss == .unknown,"Vision may stop detecting before a side-edge box is observed")
            let visitor=face(signature:[0.8,0.25,0.7])
            check(tracker.select([visitor],at:1.2).index==nil,"Return fallback must not admit incompatible visitors")
            check(tracker.select([original],at:1.5).index==0,"A missed side exit must reacquire the original seated subject, not lock to the last lateral box")
            check(tracker.select([original],at:1.8).index==0)
        }
        var tracker=FaceContinuity()
        _=tracker.select([original],at:0)
        _=tracker.select([face(0.50)],at:0.3)
        _=tracker.select([face(0.61)],at:0.6)
        _=tracker.select([],at:0.9)
        let ambiguous=tracker.select([face(0.37),face(0.41)],at:1.2)
        check(ambiguous.index==nil && ambiguous.loss == .ambiguous,"Two plausible returns cannot silently choose an identity")
        check(tracker.select([original],at:1.5).index==0,"An unambiguous original return must recover after a crossing")
        _=tracker.select([],at:1.6)
        _=tracker.select([face(0.37),face(0.41)],at:1.7)
        let movedReturn=face(0.44,width:0.28,height:0.34,signature:[0.48,0.63,0.31])
        check(tracker.select([movedReturn],at:1.8).index==0,
              "An eligible unambiguous return with changed size must not be permanently rejected by a soft ranking cost")
        let distant=face(0.75,0.65)
        _=tracker.select([],at:2)
        check(tracker.select([distant],at:30).index==nil,"Elapsed time must not admit a distant new face")
        tracker.reset();_=tracker.select([original],at:0)
        _=tracker.select([face(0.50)],at:0.3)
        _=tracker.select([face(0.61)],at:0.6)
        check(tracker.select([face(0.76,width:0.13,height:0.20)],at:0.9).index==0,"Fixture must establish a smaller lateral box before return")
        _=tracker.select([],at:1.2)
        check(tracker.select([original],at:1.5).index==0,"Recovery scoring uses the original anchor rather than penalizing a clipped lateral box")
        print("PASS: unknown left/right exit return, visitor exclusion, ambiguous return resolution, distant-face rejection and clipped-side recovery")
    }
}

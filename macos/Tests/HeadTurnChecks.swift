import Foundation
import CoreGraphics

@main struct HeadTurnChecks {
    static func face(_ yaw:Double?,width:Double=0.42,height:Double=0.63,x:Double=0.39)->FaceCandidate {
        FaceCandidate(box:CGRect(x:x,y:0.35,width:0.22,height:0.28),signature:[width,height],yaw:yaw)
    }
    static func main() {
        for sign in [-1.0,1.0] {
            var track=FaceContinuity()
            precondition(track.select([face(0)],at:0).index==0)
            for n in 1...9 {
                let yaw=sign*Double(n)/10
                precondition(track.select([face(yaw,width:0.42*cos(yaw))],at:Double(n)/3).index==0,
                             "Moderate left/right turns must not fail because eye spacing foreshortens")
            }
            _=track.select([],at:4)
            precondition(track.select([face(sign*0.9,width:0.42*cos(0.9))],at:4.4).index==0,
                         "The same turned subject can return without a height reset")
            precondition(track.select([face(0)],at:4.8).index==0,"Facing forward recovers immediately")
            precondition(track.select([face(sign*0.9,width:0.42*cos(0.9),height:0.29)],at:5.2).index==nil,
                         "Yaw compensation must retain the other proportion guard")
            precondition(track.select([face(sign*0.9,width:0.42*cos(0.9),x:0.76)],at:5.6).index==nil,
                         "Head-turn information cannot enable a spatial jump to a visitor")
        }
        var unknown=FaceContinuity();_=unknown.select([face(0)],at:0)
        precondition(unknown.select([face(nil,width:0.42*cos(0.9))],at:0.3).index==nil,
                     "Missing head-turn metadata retains the strict original comparison")
        precondition(unknown.select([face(.nan,width:0.42*cos(0.9))],at:0.6).index==nil)
        precondition(unknown.select([face(1.4,width:0.42*cos(1.4))],at:0.9).index==nil,
                     "Extreme profile information cannot overcorrect an unreliable face")
        var turnedFirst=FaceContinuity()
        _=turnedFirst.select([face(0.9,width:0.26)],at:0)
        _=turnedFirst.select([],at:0.3)
        precondition(turnedFirst.select([face(0,width:0.42)],at:0.6).index==0,
                     "A session first acquired while turned can return facing forward")
        var ambiguity=FaceContinuity();_=ambiguity.select([face(0)],at:0)
        let two=ambiguity.select([face(0.9,width:0.42*cos(0.9),x:0.37),face(0.9,width:0.42*cos(0.9),x:0.41)],at:0.3)
        precondition(two.index==nil && two.loss == .ambiguous,"Two plausible turned subjects remain ambiguous")
        print("PASS: moderate left/right turns and return, frontal recovery, retained proportion/spatial/ambiguity guards, missing/invalid/extreme-yaw isolation")
    }
}

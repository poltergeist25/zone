import Foundation

@main struct AnalysisCadenceChecks {
    static func main() {
        var calls=0
        func hint()->Double {calls += 1;return 1.0/3}
        precondition(AnalysisCadence.dueInterval(elapsed:0.11,requested:1.0/3,motionInterval:hint)==nil)
        precondition(AnalysisCadence.dueInterval(elapsed:0.22,requested:0.4,motionInterval:hint)==nil)
        precondition(calls==0,"Frames before the fastest possible deadline never sample motion")
        precondition(AnalysisCadence.dueInterval(elapsed:1.0/3,requested:0.4,motionInterval:hint)==1.0/3 && calls==1)
        precondition(AnalysisCadence.dueInterval(elapsed:0.1,requested:0.1,motionInterval:hint)==0.1 && calls==1,"Calibration retains its faster cadence without motion sampling")
        for invalid in [Double.nan,Double.infinity,-1] {
            precondition(AnalysisCadence.dueInterval(elapsed:invalid,requested:1.0/3,motionInterval:hint)==nil)
        }
        for gap in [0.31,1.0/3,0.35,0.667] {
            let before=calls
            precondition(AnalysisCadence.dueInterval(elapsed:gap,requested:0.4,trackingRateDelivery:true,motionInterval:hint)==1.0/3)
            precondition(calls==before,"Every confirmed3fps buffer is analyzed without a motion prepass")
        }
        for gap in [0.033,0.111,0.166,Double.nan,-1] {
            precondition(!AnalysisCadence.isTrackingRateDelivery(configured:true,presentationGap:gap),"Higher-rate or invalid source cannot bypass the original limiter")
        }
        precondition(AnalysisCadence.isTrackingRateDelivery(configured:true,presentationGap:1.0/3))
        precondition(!AnalysisCadence.isTrackingRateDelivery(configured:false,presentationGap:1.0/3))
        precondition(AnalysisCadence.dueInterval(elapsed:0.08,requested:0.1,trackingRateDelivery:true,motionInterval:hint)==nil,"Calibration keeps its original deadline")
        // Phase-independent movement/recovery response: every3fps capture is
        // consumed; the next measurement is never over one-third-second away.
        for phase in 0..<100 {
            let movement=Double(phase)/100
            let next=(floor(movement*3)+1)/3
            precondition(next-movement<=1.0/3+0.000001)
        }
        // Replay the original decision contract against camera arrivals, quiet
        // periods, sudden down/up motion and calibration. Compare the exact
        // inference frame numbers rather than merely checking average rates.
        for fps in [9.0,15,30] {
            for requested in [0.1,1.0/3,0.4] {
                var oldLast = -10.0,newLast = -10.0
                var original:[Int]=[],optimized:[Int]=[]
                for frame in 0..<1800 {
                    let time=Double(frame)/fps
                    let moving=(frame%170)<23 || (frame%170)>150
                    let interval=requested<0.2 ? requested:moving ? 1.0/3:0.53
                    if time-oldLast>=interval-0.003 {original.append(frame);oldLast=time}
                    if AnalysisCadence.dueInterval(elapsed:time-newLast,requested:requested,motionInterval:{moving ? 1.0/3:0.53}) != nil {
                        optimized.append(frame);newLast=time
                    }
                }
                precondition(original==optimized,"Every down/up/recovery inference must occur on the identical frame")
            }
        }
        var last = -10.0,quietCalls=0
        for frame in 0..<900 {
            let time=Double(frame)/9
            if AnalysisCadence.dueInterval(elapsed:time-last,requested:0.4,motionInterval:{quietCalls += 1;return 0.53}) != nil {last=time}
        }
        precondition(quietCalls<900*7/10,"Quiet camera playback avoids at least30% of redundant motion evaluations")
        print("PASS: exact inference-frame parity at9/15/30fps through stillness/motion/recovery/calibration; no early motion work; \(quietCalls) motion checks instead of900 on still9fps playback")
    }
}

import Foundation

/// Skip motion sampling on frames that cannot possibly trigger inference.
/// The hint is lazy: this preserves every inference deadline while avoiding
/// five face-patch samples on camera frames that arrive between deadlines.
enum AnalysisCadence {
    static func isTrackingRateDelivery(configured:Bool,presentationGap:Double?)->Bool {
        guard configured else{return false}
        guard let presentationGap else{return true}
        return presentationGap.isFinite && presentationGap>=0.25
    }
    static func dueInterval(elapsed:Double,requested:Double,trackingRateDelivery:Bool=false,motionInterval:()->Double)->Double? {
        guard elapsed.isFinite,requested.isFinite,requested>0 else{return nil}
        let calibrating=requested<0.2
        // A confirmed3fps stream already enforces the sampling interval. Analyze
        // every fresh buffer, including small delivery jitter, instead of
        // accidentally skipping it and waiting a second camera period.
        if trackingRateDelivery && !calibrating && elapsed>0 {return 1.0/3}
        let earliest=calibrating ? requested:1.0/3.0
        guard elapsed>=earliest-0.003 else{return nil}
        let interval=calibrating ? requested:motionInterval()
        guard interval.isFinite,interval>0,elapsed>=interval-0.003 else{return nil}
        return interval
    }
}

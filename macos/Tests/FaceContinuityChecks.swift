import Foundation
import CoreGraphics

@main struct FaceContinuityChecks {
    static let targetSignature = [0.42, 0.63, 0.31]
    static let visitorSignature = [0.75, 0.29, 0.70]
    static func face(_ x: Double = 0.39, _ y: Double = 0.35,
                     width: Double = 0.22, height: Double = 0.28,
                     signature: [Double] = targetSignature) -> FaceCandidate {
        FaceCandidate(box: CGRect(x: x, y: y, width: width, height: height), signature: signature)
    }
    static func main() {
        var tracker = FaceContinuity()
        let target = face()
        precondition(tracker.select([target], at: 0).index == 0)
        let visitor = face(0.60, 0.22, width: 0.34, height: 0.42, signature: visitorSignature)
        precondition(tracker.select([visitor, face(0.40, 0.34)], at: 0.2).index == 1,
                     "New larger visitor must not replace the tracked subject")
        precondition(tracker.select([face(0.40, 0.34), visitor], at: 0.4).index == 0,
                     "Detection ordering must not determine the subject")
        let lostWithVisitor = tracker.select([visitor], at: 0.6)
        precondition(lostWithVisitor.index == nil && lostWithVisitor.loss == .unknown,
                     "No spatial jump to visitor after the target disappears")
        precondition(tracker.select([target], at: 0.8).index == 0)
        precondition(tracker.select([face(signature: visitorSignature)], at: 1.0).index == nil,
                     "Same position alone does not override incompatible proportions")
        precondition(tracker.select([face(signature: [])], at: 1.1).index == nil,
                     "Missing ratios do not bypass an established signature gate")

        tracker.reset()
        let initiallyAmbiguous = tracker.select([face(0.27), face(0.51)], at: 0)
        precondition(initiallyAmbiguous.index == nil && initiallyAmbiguous.loss == .ambiguous)
        precondition(tracker.selectedBox == nil)
        precondition(tracker.select([target], at: 0.2).index == 0)
        let crossing = tracker.select([face(0.36), face(0.42)], at: 0.4)
        precondition(crossing.index == nil && crossing.loss == .ambiguous,
                     "Indistinguishable crossing candidates must suspend association")
        precondition(tracker.selectedBox == target.box, "Ambiguity must not move the held target")
        precondition(tracker.select([target], at: 0.6).index == 0)

        tracker.reset()
        _ = tracker.select([target], at: 0)
        _ = tracker.select([face(0.39, 0.20)], at: 0.2)
        let partialBottom = tracker.select([face(0.39, 0.06)], at: 0.4)
        precondition(partialBottom.index == 0 && partialBottom.loss == .bottom,
                     "Selected edge boxes retain a directional hint if landmarks are partial")
        let bottom = tracker.select([], at: 0.6)
        precondition(bottom.index == nil && bottom.loss == .bottom,
                     "Recent downward motion at bottom edge supports a bottom exit")
        precondition(tracker.select([visitor], at: 1).loss == .bottom,
                     "An unrelated visitor cannot release bottom-exit latch")
        precondition(tracker.select([], at: 30).loss == .bottom,
                     "Positive bottom exit remains latched until reacquisition/reset")
        precondition(tracker.select([target], at: 30.2).index == 0,
                     "Subject can return directly to original seated height")
        precondition(tracker.select([], at: 30.4).loss == .unknown,
                     "Reacquisition releases old bottom evidence")

        tracker.reset()
        _ = tracker.select([target], at: 0)
        _ = tracker.select([face(0.50, 0.28)], at: 0.2)
        _ = tracker.select([face(0.62, 0.16)], at: 0.4)
        let partialSide = tracker.select([face(0.76, 0.05)], at: 0.6)
        precondition(partialSide.index == 0 && partialSide.loss == .side,
                     "Selected lateral edge boxes retain a side hint")
        precondition(tracker.select([], at: 0.8).loss == .side,
                     "A diagonal exit through the side must not latch bottom")
        precondition(tracker.select([face(signature: visitorSignature)], at: 1.0).index == nil,
                     "Anchor return gates do not admit an incompatible visitor")
        let ambiguousReturn = tracker.select([face(0.37), face(0.41)], at: 1.1)
        precondition(ambiguousReturn.index == nil && ambiguousReturn.loss == .ambiguous,
                     "Two plausible returning subjects remain ambiguous")
        precondition(tracker.select([target], at: 1.2).index == 0,
                     "A side-exiting subject can return at the seated anchor")

        tracker.reset()
        _ = tracker.select([face(0.39, 0.09)], at: 0)
        _ = tracker.select([face(0.39, 0.08)], at: 0.2)
        let gentlePartial = tracker.select([face(0.39, 0.07)], at: 0.4)
        precondition(gentlePartial.index == 0 && gentlePartial.loss == .bottom,
                     "Two gentle downward steps near the edge carry a bottom hint")
        precondition(tracker.select([], at: 0.6).loss == .bottom,
                     "Accumulated gentle movement supports bottom disappearance")

        tracker.reset()
        _ = tracker.select([face(0.39, 0.15)], at: 0)
        let approachingBottom = tracker.select([face(0.39, 0.11)], at: 0.2)
        precondition(approachingBottom.index == 0 && approachingBottom.loss == .bottom,
                     "Directional evidence is available before full clipping")
        tracker.reset()
        _ = tracker.select([target], at: 0)
        let centralDescent = tracker.select([face(0.39, 0.31)], at: 0.2)
        precondition(centralDescent.index == 0 && centralDescent.loss == .unknown)
        precondition(tracker.select([], at: 0.4).loss == .unknown,
                     "Downward movement in the center is not bottom loss")

        tracker.reset()
        _ = tracker.select([target], at: 0)
        _ = tracker.select([face(0.39, 0.06)], at: 0.2) // Too far to associate.
        precondition(tracker.select([], at: 0.4).loss == .unknown,
                     "Unassociated edge observations cannot manufacture bottom evidence")
        tracker.reset()
        _ = tracker.select([face(0.39, 0.07)], at: 0)
        precondition(tracker.select([], at: 0.2).loss == .unknown,
                     "Being near bottom without downward trajectory is insufficient")
        tracker.reset()
        _ = tracker.select([target], at: 0)
        _ = tracker.select([face(0.39, 0.20)], at: 0.2)
        _ = tracker.select([face(0.39, 0.06)], at: 0.4)
        precondition(tracker.select([], at: 3).loss == .unknown,
                     "Old downward motion is not recent exit evidence")

        tracker.reset()
        _ = tracker.select([target],at:0)
        _ = tracker.select([face(0.39,0.20)],at:0.2)
        _ = tracker.select([face(0.39,0.06,height:0.16)],at:0.4)
        precondition(tracker.select([],at:0.6).loss == .bottom)
        precondition(tracker.select([target],at:0.7).index == 0,
                     "A full face can return immediately after a clipped, smaller box")

        tracker.reset()
        precondition(tracker.selectedBox == nil)
        let differentPerson = face(signature: visitorSignature)
        precondition(tracker.select([differentPerson], at: 0).index == 0,
                     "Explicit reset permits a new subject and a fresh timestamp epoch")
        precondition(tracker.select([target], at: 0.2).index == nil)
        precondition(tracker.select([], at: -1).loss == .cameraStale)
        precondition(tracker.select([face(signature: visitorSignature)], at: 0.4).index == 0)
        let invalid = FaceCandidate(box: CGRect(x: 0.4, y: 0.4, width: 0, height: 0.2), signature: [])
        tracker.reset()
        precondition(tracker.select([invalid], at: 0).index == nil)
        print("Face continuity checks passed: visitor/order, loss, crossing, bottom/side, reacquisition, reset, invalid input")
    }
}

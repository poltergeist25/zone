import SwiftUI

/// Geometry is shared by drawing and dragging, including when the meter stretches.
struct HeightMeterScale {
    static let top=25.0
    static let bottom=6.0
    static let range=3.0
    let travel:Double
    init(height:Double) {travel=max(1,height-Self.top-Self.bottom)}
    func y(_ value:Double)->Double {Self.top+min(Self.range,max(0,value))/Self.range*travel}
    func value(at y:Double)->Double {(y-Self.top)/travel*Self.range}
}

/// One downward scale, shared by the live marker and both adjustable boundaries.
struct HeightThermometer:View {
    let score:Double?
    let yellow:Double
    let red:Double
    var onChange:(Double,Bool)->Void
    private let green=Color(red:0.25,green:0.56,blue:0.40)
    private let amber=Color(red:0.83,green:0.55,blue:0.13)
    private let ochreText=Color(red:0.52,green:0.31,blue:0.04)
    private let coral=Color(red:0.78,green:0.28,blue:0.24)
    private let range=3.0
    var travel=204.0
    var fillsAvailableHeight=false
    var inactiveStatus="Finding your height"
    @FocusState private var focusedBoundary:Bool?
    private let top=HeightMeterScale.top
    private var color:Color {guard let score else{return .secondary};return score<yellow ? green:score<red ? amber:coral}
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            GeometryReader {geo in
                let scale=HeightMeterScale(height:geo.size.height)
                let actualTravel=scale.travel
                ZStack(alignment:.topLeading) {
                    VStack(spacing:0) {
                        green.opacity(0.38).frame(height:actualTravel*yellow/range)
                        amber.opacity(0.38).frame(height:actualTravel*(red-yellow)/range)
                        coral.opacity(0.38)
                    }.frame(width:18,height:actualTravel).clipShape(Capsule()).offset(x:14,y:top)
                    Text("CHOSEN HEIGHT").font(.system(size:8,weight:.bold)).tracking(0.8).offset(x:48,y:top-6)
                    Path {p in p.move(to:CGPoint(x:8,y:top));p.addLine(to:CGPoint(x:40,y:top))}
                        .stroke(green,style:StrokeStyle(lineWidth:1,dash:[3,3]))
                    boundary("Yellow starts here",value:yellow,color:amber,isRed:false,width:geo.size.width,scale:scale)
                    boundary("Red starts here",value:red,color:coral,isRed:true,width:geo.size.width,scale:scale)
                    if let score {
                        Circle().fill(color).frame(width:18,height:18).overlay(Circle().stroke(.white,lineWidth:3))
                            .shadow(color:color.opacity(0.2),radius:3,y:1).position(x:23,y:scale.y(score))
                            .accessibilityLabel("Current height")
                            .accessibilityValue(score<yellow ? "Green":score<red ? "Yellow":"Red")
                    }
                }.coordinateSpace(name:"height-meter")
            }.frame(minHeight:top+travel+HeightMeterScale.bottom,
                    maxHeight:fillsAvailableHeight ? .infinity:top+travel+HeightMeterScale.bottom)
            ViewThatFits(in:.horizontal) {
                HStack(spacing:6) {status;Spacer();dragHint}
                VStack(alignment:.leading,spacing:5) {status;dragHint}
            }
        }.padding(14).background(Color.white.opacity(0.6),in:RoundedRectangle(cornerRadius:14))
    }
    private var status:some View {
        HStack(spacing:6) {
            Circle().fill(color).frame(width:6,height:6)
            Text(score == nil ? inactiveStatus:score!<yellow ? "You’re in green":score!<red ? "You’re in yellow":"You’re in red")
                .font(.system(size:11,weight:.semibold)).fixedSize()
        }
    }
    private var dragHint:some View {
        Text("Drag the levels ↕").font(.system(size:10)).foregroundStyle(.secondary).fixedSize()
    }
    private func boundary(_ label:String,value:Double,color:Color,isRed:Bool,width:Double,scale:HeightMeterScale)->some View {
        // Keep the visible pill unchanged, and leave a point between targets.
        // The model's minimum 0.4 boundary gap leaves at least 19.2pt here.
        let targetHeight=min(32,max(18,abs(scale.y(red)-scale.y(yellow))-1))
        return HStack(spacing:6) {
            Rectangle().fill(color.opacity(0.6)).frame(width:12,height:1)
            Text(label).font(.system(size:10,weight:.medium)).foregroundStyle(isRed ? color:ochreText)
            Spacer(minLength:0)
            Image(systemName:"line.3.horizontal").font(.system(size:10,weight:.medium)).foregroundStyle(color)
        }.padding(.horizontal,6).frame(width:max(1,width-42),height:18)
            .background(.white.opacity(0.94),in:RoundedRectangle(cornerRadius:7))
            .overlay(RoundedRectangle(cornerRadius:7).stroke(color.opacity(0.2)))
            .overlay(RoundedRectangle(cornerRadius:7)
                .stroke(focusedBoundary == isRed ? Color(red:0.13,green:0.25,blue:0.19).opacity(0.7):.clear,lineWidth:1).padding(-1))
            .frame(height:targetHeight).contentShape(Rectangle())
            .focusable().focused($focusedBoundary,equals:isRed)
            // Use one quiet, shape-matched focus outline. The system accent
            // effect otherwise adds a second red rectangle around this row.
            .focusEffectDisabled()
            .onMoveCommand {direction in
                switch direction {
                case .up,.left:onChange(value-0.15,isRed)
                case .down,.right:onChange(value+0.15,isRed)
                @unknown default:break
                }
            }
            .gesture(DragGesture(minimumDistance:0,coordinateSpace:.named("height-meter")).onChanged {event in
                focusedBoundary=isRed
                onChange(scale.value(at:event.location.y),isRed)
            })
            .help("Drag this boundary up to be stricter or down to allow more sinking. When focused, use the arrow keys. Your chosen height stays fixed.")
            .accessibilityElement(children:.ignore).accessibilityLabel(label)
            .accessibilityValue("Level \(Int((value/range)*100)) of 100")
            .accessibilityHint("Move up for a closer boundary or down to allow more sinking.")
            .accessibilityAdjustableAction {direction in
                switch direction {case .increment:onChange(value+0.15,isRed);case .decrement:onChange(value-0.15,isRed);@unknown default:break}
            }
            .position(x:(width+42)/2,y:scale.y(value))
    }
}

struct FaceHeightGuide:View {
    let points:[CGPoint]
    let aspect:Double
    let baseline:Double?
    var body:some View {
        GeometryReader {geo in
            let width=min(geo.size.width,geo.size.height*aspect)
            let height=width/aspect
            let x=(geo.size.width-width)/2
            let y=(geo.size.height-height)/2
            ZStack(alignment:.topLeading) {
                if !points.isEmpty,let baseline {
                    Path {path in
                        path.move(to:CGPoint(x:x+width*0.15,y:y+height*baseline))
                        path.addLine(to:CGPoint(x:x+width*0.85,y:y+height*baseline))
                    }.stroke(.white.opacity(0.65),style:StrokeStyle(lineWidth:1,dash:[4,5]))
                }
                ForEach(Array(points.enumerated()),id:\.offset) {_,point in
                    Circle().fill(.white.opacity(0.9)).frame(width:5,height:5)
                        .shadow(color:.black.opacity(0.5),radius:2)
                        .position(x:x+(1-point.x)*width,y:y+(1-point.y)*height)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

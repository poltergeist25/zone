import AppKit
import QuartzCore

// Quiet alternatives to smoke. Four retained gradient layers, one shape, no
// redraw timer. A layer transition runs only when a new observation changes it.
final class PeripheralEffectView:NSView {
    let style:EdgeEffectStyle
    private(set) var severity:Double
    private(set) var depthScale:CGFloat
    private let gradients=(0..<4).map{_ in CAGradientLayer()}
    private let outline=CAShapeLayer()
    private var lastSize=CGSize.zero
    override var isFlipped:Bool{true}
    override var isOpaque:Bool{false}
    init(style:EdgeEffectStyle,severity:Double,depthScale:CGFloat) {
        self.style=style;self.severity=SmokeGeometry.clamp(severity)
        self.depthScale=depthScale.isFinite ? min(10,max(0,depthScale)):0
        super.init(frame:.zero)
        let host=CALayer();host.isGeometryFlipped=true
        host.actions=["bounds":NSNull(),"position":NSNull()]
        layer=host;wantsLayer=true
        for (index,gradient) in gradients.enumerated() {
            gradient.locations=[0,0.16,0.46,1]
            gradient.actions=["bounds":NSNull(),"position":NSNull(),"colors":NSNull()]
            switch index {
            case 0:gradient.startPoint=CGPoint(x:0.5,y:0);gradient.endPoint=CGPoint(x:0.5,y:1)
            case 1:gradient.startPoint=CGPoint(x:0.5,y:1);gradient.endPoint=CGPoint(x:0.5,y:0)
            case 2:gradient.startPoint=CGPoint(x:0,y:0.5);gradient.endPoint=CGPoint(x:1,y:0.5)
            default:gradient.startPoint=CGPoint(x:1,y:0.5);gradient.endPoint=CGPoint(x:0,y:0.5)
            }
            host.addSublayer(gradient)
        }
        if style == .tide {
            for (index,gradient) in gradients.enumerated() where index>=2 {
                gradient.type = .radial
                gradient.startPoint=CGPoint(x:index==2 ? 0:1,y:0.5)
                gradient.endPoint=CGPoint(x:index==2 ? 1:0,y:1)
            }
        }
        outline.fillColor=nil;outline.lineWidth=1.5
        outline.lineCap = .round;outline.lineJoin = .round
        outline.actions=["path":NSNull(),"strokeColor":NSNull(),"opacity":NSNull()]
        host.addSublayer(outline)
        update(animated:false)
    }
    required init?(coder:NSCoder){fatalError("Not supported")}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override func layout(){super.layout();if bounds.size != lastSize{update(animated:false)}}
    func setSeverity(_ value:Double) {
        let next=SmokeGeometry.clamp(value)
        guard next != severity else{return}
        let receding=next<severity;severity=next
        update(animated:!receding)
    }
    func setDepthScale(_ value:CGFloat) {
        let next=value.isFinite ? min(10,max(0,value)):0
        guard next != depthScale else{return}
        let receding=next<depthScale;depthScale=next
        update(animated:!receding)
    }
    private func update(animated:Bool) {
        lastSize=bounds.size
        let color=SmokeGeometry.color(max(1,severity))
        let glow=style == .glow
        let reach=SmokeGeometry.depth(severity,scale:max(1,depthScale)) * (glow ? 0.32:style == .horizon ? 0.6:1)
        let depth=max(1,reach * min(1,depthScale))
        let horizontal=min(depth,bounds.height*0.42),vertical=min(depth,bounds.width*0.42)
        var frames=[CGRect(x:0,y:0,width:bounds.width,height:horizontal),
                    CGRect(x:0,y:bounds.height-horizontal,width:bounds.width,height:horizontal),
                    CGRect(x:0,y:0,width:vertical,height:bounds.height),
                    CGRect(x:bounds.width-vertical,y:0,width:vertical,height:bounds.height)]
        if style == .tide {
            let width=min(depth*1.45,bounds.width*0.36)
            frames[2]=CGRect(x:0,y:0,width:width,height:bounds.height)
            frames[3]=CGRect(x:bounds.width-width,y:0,width:width,height:bounds.height)
        }
        let edge=(color.blended(withFraction:glow || style == .tide ? 0:0.48,of:.black) ?? color)
        let alpha:CGFloat=glow ? 0.28:style == .tide ? 0.6:0.66
        let colors=[edge.withAlphaComponent(alpha).cgColor,
                    color.withAlphaComponent(alpha*0.59).cgColor,
                    color.withAlphaComponent(alpha*0.18).cgColor,
                    color.withAlphaComponent(0).cgColor]
        CATransaction.begin();CATransaction.setDisableActions(true)
        let advances=animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for (index,gradient) in gradients.enumerated() {
            let priorBounds=gradient.presentation()?.bounds ?? gradient.bounds
            let priorPosition=gradient.presentation()?.position ?? gradient.position
            if advances {
                let transition=CABasicAnimation(keyPath:"colors")
                transition.fromValue=gradient.presentation()?.colors ?? gradient.colors
                transition.toValue=colors;transition.duration=0.28
                transition.timingFunction=CAMediaTimingFunction(name:.easeOut)
                gradient.add(transition,forKey:"zone.color")
            } else {gradient.removeAllAnimations()}
            gradient.frame=frames[index];gradient.colors=colors
            if advances {
                for (key,from,to) in [("bounds",NSValue(rect:priorBounds),NSValue(rect:gradient.bounds)),("position",NSValue(point:priorPosition),NSValue(point:gradient.position))] {
                    let movement=CABasicAnimation(keyPath:key)
                    movement.fromValue=from;movement.toValue=to;movement.duration=0.28
                    movement.timingFunction=CAMediaTimingFunction(name:.easeOut)
                    gradient.add(movement,forKey:"zone."+key)
                }
            }
            let used=style == .corners ? false:style == .tide ? index>=2:style == .horizon ? index==0:true
            gradient.isHidden=depthScale<=0 || !used
        }
        let oldPath=outline.presentation()?.path ?? outline.path
        if style == .corners {
            let length=min(min(bounds.width,bounds.height)*0.28,max(16,depth*0.75))
            let inset:CGFloat=3,radius:CGFloat=min(18,length*0.3)
            let corner=CGMutablePath()
            corner.move(to:CGPoint(x:length,y:inset))
            corner.addLine(to:CGPoint(x:inset+radius,y:inset))
            corner.addQuadCurve(to:CGPoint(x:inset,y:inset+radius),control:CGPoint(x:inset,y:inset))
            corner.addLine(to:CGPoint(x:inset,y:length))
            let path=CGMutablePath()
            for (x,y,sx,sy) in [(CGFloat(0),CGFloat(0),CGFloat(1),CGFloat(1)),(bounds.width,0,-1,1),(0,bounds.height,1,-1),(bounds.width,bounds.height,-1,-1)] {
                path.addPath(corner,transform:CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:x,ty:y))
            }
            outline.path=path
            outline.lineWidth=min(7,2+depthScale*0.24+CGFloat(max(0,severity-1))*1.4)
        } else {
            outline.path=CGPath(roundedRect:bounds.insetBy(dx:1,dy:1),cornerWidth:12,cornerHeight:12,transform:nil)
        }
        if advances && style == .corners,let oldPath {
            let movement=CABasicAnimation(keyPath:"path")
            movement.fromValue=oldPath;movement.toValue=outline.path;movement.duration=0.28
            movement.timingFunction=CAMediaTimingFunction(name:.easeOut)
            outline.add(movement,forKey:"zone.path")
        } else {outline.removeAllAnimations()}
        outline.strokeColor=color.withAlphaComponent(0.88).cgColor
        outline.isHidden = (!glow && style != .corners) || depthScale<=0
        CATransaction.commit()
    }
}

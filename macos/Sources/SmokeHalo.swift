import AppKit
import SwiftUI

// Geometry is measured in display points, never as a percentage of a large screen.
enum SmokeGeometry {
    static func clamp(_ severity:Double)->Double {severity.isFinite ? min(3,max(0,severity)):0}
    static func depth(_ severity:Double,scale:CGFloat=1)->CGFloat {
        let s=clamp(severity)
        return CGFloat(s<=1 ? 5+s*10:s<=2 ? 15+(s-1)*15:30+(s-2)*10) * (scale.isFinite ? min(50,max(1,scale)):1)
    }
    static func color(_ severity:Double)->NSColor {
        let s=clamp(severity)
        let green=[0.21,0.65,0.43],yellow=[0.96,0.70,0.17],red=[0.90,0.22,0.20]
        let a=s<=1 ? green:yellow,b=s<=1 ? yellow:red,t=min(1,s<=1 ? s:s-1)
        return NSColor(srgbRed:a[0]+(b[0]-a[0])*t,green:a[1]+(b[1]-a[1])*t,blue:a[2]+(b[2]-a[2])*t,alpha:1)
    }
}

final class SmokeHaloView:NSView {
    private var edges:[SmokeEdgeView]=[]
    private var live:CompositedSmoke?
    private(set) var depthScale:CGFloat=1
    private var timer:Timer?
    private var target=0.0
    private var current=0.0
    private var previousTime=0.0
    private var originTime=ProcessInfo.processInfo.systemUptime
    private var fixedTime:Double?
    private var stripExtent:CGFloat=0
    var displayedSeverity:Double{current}
    var isAnimating:Bool{live?.isAnimating ?? (timer != nil)}
    var animationPhase:Double{live != nil ? ProcessInfo.processInfo.systemUptime-originTime:(edges.first?.time ?? 0)}
    override var isOpaque:Bool{false}
    override var isFlipped:Bool{true}
    init(severity:Double=0,time:Double?=nil,depthScale:CGFloat=1) {
        self.depthScale=depthScale.isFinite ? min(50,max(1,depthScale)):1
        target=SmokeGeometry.clamp(severity);current=target;fixedTime=time
        super.init(frame:.zero)
        if time==nil {
            let host=CALayer();host.isGeometryFlipped=true;host.actions=["bounds":NSNull(),"position":NSNull()]
            layer=host;wantsLayer=true;live=CompositedSmoke(host:host)
        } else {
            for side in 0..<4 {let edge=SmokeEdgeView(side:side);edges.append(edge);addSubview(edge)}
        }
        paint(time:time ?? 0)
    }
    required init?(coder:NSCoder){fatalError("Not supported")}
    deinit{timer?.invalidate()}
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow();timer?.invalidate();timer=nil
        if let live {live.setAttached(window != nil);return}
        guard window != nil,fixedTime==nil else{return}
        previousTime=ProcessInfo.processInfo.systemUptime
        let refresh=Timer(timeInterval:1/20,repeats:true){[weak self] _ in self?.tick()}
        refresh.tolerance=0.003;timer=refresh
        // Include the default loop explicitly during early window setup, then
        // common modes so the same timer continues while menus are tracking.
        RunLoop.main.add(refresh,forMode:.default)
        RunLoop.main.add(refresh,forMode:.common)
    }
    override func setFrameSize(_ newSize:NSSize) {
        super.setFrameSize(newSize);needsLayout=true
    }
    override func layout() {
        super.layout()
        if let live {live.update(size:bounds.size,severity:target,scale:depthScale,animated:false);return}
        let strip=ceil(SmokeGeometry.depth(fixedTime == nil ? 3:current,scale:depthScale))+2
        stripExtent=strip
        // Nominal depth remains exact. On small displays, a separate soft center
        // protection mask prevents opposite large-scale tails from filling the desk.
        let horizontal=min(strip,bounds.height*0.46),vertical=min(strip,bounds.width*0.46)
        edges[0].frame=NSRect(x:0,y:0,width:bounds.width,height:horizontal)
        edges[1].frame=NSRect(x:0,y:bounds.height-horizontal,width:bounds.width,height:horizontal)
        edges[2].frame=NSRect(x:0,y:0,width:vertical,height:bounds.height)
        edges[3].frame=NSRect(x:bounds.width-vertical,y:0,width:vertical,height:bounds.height)
        for edge in edges {edge.centerProtection=(edge.side<2 ? horizontal:vertical)<strip;edge.needsDisplay=true}
    }
    func setDepthScale(_ value:CGFloat) {
        let next=value.isFinite ? min(50,max(1,value)):1
        guard depthScale != next else{return}
        depthScale=next
        if let live {live.update(size:bounds.size,severity:target,scale:depthScale,animated:true);return}
        needsLayout=true;layoutSubtreeIfNeeded();setNeedsDisplay(bounds)
        paint(time:fixedTime ?? ProcessInfo.processInfo.systemUptime-originTime)
    }
    func setSeverity(_ severity:Double) {
        target=SmokeGeometry.clamp(severity)
        if let live {current=target;live.update(size:bounds.size,severity:target,scale:depthScale,animated:true);return}
        // Retreat begins with the received observation, before the next display tick.
        if target<current {current += (target-current)*(1-exp(-(1/60)/0.04))}
        if fixedTime != nil {current=target}
        paint(time:fixedTime ?? ProcessInfo.processInfo.systemUptime-originTime)
    }
    private func tick() {
        let now=ProcessInfo.processInfo.systemUptime,dt=min(0.1,max(0,now-previousTime));previousTime=now
        advance(dt:dt)
    }
    func advance(dt:Double) {
        guard dt.isFinite,dt>=0 else{return}
        // About 95% settled in 0.12s retreat / 0.35s advance; no intentional delay.
        let tau=target<current ? 0.04:0.1167
        current += (target-current)*(1-exp(-dt/tau))
        paint(time:fixedTime ?? ProcessInfo.processInfo.systemUptime-originTime)
    }
    private func paint(time:Double) {
        if let live {live.update(size:bounds.size,severity:target,scale:depthScale,animated:false);return}
        if bounds.width>0 && bounds.height>0 && stripExtent != ceil(SmokeGeometry.depth(fixedTime == nil ? 3:current,scale:depthScale))+2 {
            // Invalidate old strip rectangles as they shrink, not the entire display.
            for edge in edges{setNeedsDisplay(edge.frame)}
            needsLayout=true;layoutSubtreeIfNeeded()
        }
        for edge in edges{edge.severity=current;edge.depthScale=depthScale;edge.time=time;edge.requestTextureUpdate()}
    }
}

private final class SmokeEdgeView:NSView {
    let side:Int
    var severity=0.0
    var depthScale:CGFloat=1
    var time=0.0
    var centerProtection=false
    var forcedDepth:CGFloat?
    private var raster:CGContext?
    private var rasterSize:CGSize = .zero
    private var renderedAt:Double = -.infinity
    private var renderedSeverity:Double = -.infinity
    private var renderedDepth:CGFloat = 0
    // Smoke has broad, soft gradients. Rasterize at a bounded resolution rather
    // than shading hundreds of overlapping gradients at full Retina resolution.
    static func rasterDimensions(_ size:CGSize,side:Int)->CGSize {
        let along=min(320,ceil(side<2 ? size.width:size.height))
        let across=min(64,ceil(side<2 ? size.height:size.width))
        return side<2 ? CGSize(width:along,height:across):CGSize(width:across,height:along)
    }
    override var isFlipped:Bool{true}
    override var isOpaque:Bool{false}
    override var wantsUpdateLayer:Bool{true}
    init(side:Int){
        self.side=side;super.init(frame:.zero)
        wantsLayer=true;layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.contentsGravity = .resize
        layer?.actions=["contents":NSNull(),"bounds":NSNull(),"position":NSNull()]
    }
    required init?(coder:NSCoder){fatalError("Not supported")}
    // Gate invalidation before AppKit schedules a display/transaction, not inside it.
    func requestTextureUpdate() {
        let now=ProcessInfo.processInfo.systemUptime
        if layer?.contents==nil || now-renderedAt>=0.25 || abs(severity-renderedSeverity)>=0.12 || depthScale != renderedDepth {needsDisplay=true}
    }
    override func updateLayer() {
        let now=ProcessInfo.processInfo.systemUptime
        // The visible motion is very slow. Four texture updates per second are
        // blended by the compositor; geometry still responds at 20Hz. Larger
        // posture changes and a user depth adjustment redraw immediately.
        guard layer?.contents==nil || now-renderedAt>=0.25 || abs(severity-renderedSeverity)>=0.12 || depthScale != renderedDepth else{return}
        guard let image=makeTexture(forLayer:true) else{return}
        if layer?.contents != nil,window?.isVisible == true,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let fade=CATransition();fade.type = .fade;fade.duration=severity<renderedSeverity ? 0.08:0.24
            layer?.add(fade,forKey:"smoke-drift")
        }
        layer?.contents=image
        renderedAt=now;renderedSeverity=severity;renderedDepth=depthScale
    }
    override func draw(_ dirtyRect:NSRect) {
        // Snapshot/printing fallback; live drawing uses updateLayer above.
        guard let destination=NSGraphicsContext.current?.cgContext,let image=makeTexture() else{return}
        destination.saveGState();defer{destination.restoreGState()}
        destination.interpolationQuality = .high
        destination.draw(image,in:bounds)
    }
    fileprivate func makeTexture(forLayer:Bool=false)->CGImage? {
        guard bounds.width>0,bounds.height>0 else{return nil}
        let size=Self.rasterDimensions(bounds.size,side:side)
        if raster==nil || rasterSize != size {
            raster=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)
            rasterSize=size
        }
        guard let ctx=raster else{return nil}
        ctx.clear(CGRect(origin:.zero,size:size))
        ctx.saveGState()
        if forLayer {ctx.translateBy(x:0,y:size.height);ctx.scaleBy(x:1,y:-1)}
        ctx.scaleBy(x:size.width/bounds.width,y:size.height/bounds.height)
        renderSmoke(in:ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }
    private func renderSmoke(in ctx:CGContext) {
        ctx.saveGState();defer{ctx.restoreGState()}
        let length:CGFloat=side<2 ? bounds.width:bounds.height
        switch side {
        case 1:ctx.translateBy(x:0,y:bounds.height);ctx.scaleBy(x:1,y:-1)
        case 2:ctx.concatenate(CGAffineTransform(a:0,b:1,c:1,d:0,tx:0,ty:0))
        case 3:ctx.concatenate(CGAffineTransform(a:0,b:1,c:-1,d:0,tx:bounds.width,ty:0))
        default:break
        }
        let depth=forcedDepth ?? SmokeGeometry.depth(severity,scale:depthScale),color=SmokeGeometry.color(severity)
        let extent=side<2 ? bounds.height:bounds.width
        let space=CGColorSpaceCreateDeviceRGB()
        ctx.beginTransparencyLayer(auxiliaryInfo:nil)
        // Broad, pale tails are overlaid with progressively shorter, darker folds.
        // Every fold is a feathered radial gradient, never a band or outline.
        let reaches:[CGFloat]=[1,0.80,0.59,0.40,0.24,0.12]
        let opacities:[CGFloat]=[0.09,0.11,0.14,0.23,0.30,0.36]
        let brightness:[CGFloat]=[0.52,0.32,0.10,-0.22,-0.44,-0.65]
        let intensity=CGFloat(0.72+SmokeGeometry.clamp(severity)*0.093)
        for layer in 0..<reaches.count {
            let phase=Double(side)*1.7+Double(layer)*2.2
            let count=max(4,min(18,Int(length/220)+2))
            let span=length/CGFloat(count-1)
            let alpha=opacities[layer]*intensity
            let shift=brightness[layer]
            let ink=shift>=0 ? (color.blended(withFraction:shift,of:.white) ?? color):(color.blended(withFraction:-shift,of:.black) ?? color)
            let colors=[ink.withAlphaComponent(alpha).cgColor,ink.withAlphaComponent(alpha*0.70).cgColor,ink.withAlphaComponent(alpha*0.20).cgColor,ink.withAlphaComponent(0).cgColor] as CFArray
            guard let gradient=CGGradient(colorsSpace:space,colors:colors,locations:[0,0.28,0.65,1])else{continue}
            for index in -1...count {
                let i=Double(index),wave=sin(i*1.21+time*0.23+phase),breath=cos(i*0.77-time*0.17+phase)
                let x=CGFloat(index)*span+CGFloat(sin(time*0.13+i+phase))*span*0.16
                let radiusX=span*CGFloat(0.80+0.16*wave)
                let radiusY=depth*reaches[layer]*CGFloat(0.75+0.12*wave+0.08*breath)
                ctx.saveGState();ctx.translateBy(x:x,y:-depth*reaches[layer]*0.015);ctx.scaleBy(x:radiusX,y:max(0.5,radiusY))
                ctx.drawRadialGradient(gradient,startCenter:.zero,startRadius:0,endCenter:.zero,endRadius:1,options:[])
                ctx.restoreGState()
            }
        }
        // Applied inside this edge's own transparency layer, so it cannot erase
        // neighboring edge views. The final eight percent of the center stays clear.
        if centerProtection,let mask=CGGradient(colorsSpace:space,colors:[NSColor.white.cgColor,NSColor.white.cgColor,NSColor.clear.cgColor] as CFArray,locations:[0,0.60,1]) {
            ctx.setBlendMode(.destinationIn)
            ctx.drawLinearGradient(mask,start:CGPoint(x:0,y:0),end:CGPoint(x:0,y:extent),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])
            ctx.setBlendMode(.normal)
        }
        ctx.endTransparencyLayer()
    }
}

/// Only precomputed textures are animated. Steady drift has no CPU timer, path
/// drawing, view invalidation, or growing texture cache.
private final class CompositedSmoke {
    // Retain only bounded image assets across green/yellow crossings. Panels and
    // animations still disappear immediately on green.
    private static let textureCache:NSCache<NSString,CGImage> = {
        let cache=NSCache<NSString,CGImage>();cache.countLimit=96;cache.totalCostLimit=8*1024*1024;return cache
    }()
    private let host:CALayer
    private var strips:[CALayer]=[]
    private var phases:[[CALayer]]=[]
    private var inks:[[[CALayer]]]=[]
    private var size:CGSize = .zero
    private var attached=false
    private var driftEnabled=false
    private var lastSeverity=0.0
    private var lastScale:CGFloat=0
    private let epoch=CACurrentMediaTime()
    var isAnimating:Bool {attached && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion}
    init(host:CALayer) {
        self.host=host
        for _ in 0..<4 {
            let strip=CALayer();strip.masksToBounds=true;strip.actions=["bounds":NSNull(),"position":NSNull(),"transform":NSNull()]
            host.addSublayer(strip);strips.append(strip)
            var pair:[CALayer]=[],colors:[[CALayer]]=[]
            for index in 0..<2 {
                let phase=CALayer();phase.opacity=index==0 ? 1:0;phase.actions=["bounds":NSNull(),"position":NSNull(),"opacity":NSNull()]
                strip.addSublayer(phase);pair.append(phase)
                var nodes:[CALayer]=[]
                for _ in 0..<3 {
                    let ink=CALayer();ink.contentsGravity = .resize;ink.actions=["contents":NSNull(),"bounds":NSNull(),"position":NSNull(),"opacity":NSNull()]
                    phase.addSublayer(ink);nodes.append(ink)
                }
                colors.append(nodes)
            }
            phases.append(pair);inks.append(colors)
        }
    }
    func setAttached(_ value:Bool) {
        if attached != value {attached=value}
        let enabled=isAnimating
        guard enabled != driftEnabled else{return}
        driftEnabled=enabled
        for side in 0..<4 {for index in 0..<2 {
            let phase=phases[side][index];phase.removeAnimation(forKey:"smoke-drift")
            guard enabled else{continue}
            let animation=CAKeyframeAnimation(keyPath:"opacity")
            animation.values=index==0 ? [1,0,1]:[0,1,0]
            animation.keyTimes=[0,0.5,1];animation.duration=14+Double(side)
            animation.timingFunctions=[CAMediaTimingFunction(name:.easeInEaseOut),CAMediaTimingFunction(name:.easeInEaseOut)]
            animation.repeatCount = .infinity;animation.beginTime=epoch-Double(side)*2
            phase.add(animation,forKey:"smoke-drift")
        }}
    }
    func update(size next:CGSize,severity:Double,scale:CGFloat,animated:Bool) {
        guard next.width>0,next.height>0 else{return}
        let rebuild=size != next
        guard rebuild || severity != lastSeverity || scale != lastScale else{return}
        let shrinking=SmokeGeometry.depth(severity,scale:scale)<SmokeGeometry.depth(lastSeverity,scale:lastScale)
        size=next;lastSeverity=severity;lastScale=scale
        let depth=SmokeGeometry.depth(severity,scale:scale)+2
        let horizontal=min(depth,next.height*0.46),vertical=min(depth,next.width*0.46)
        let frames=[CGRect(x:0,y:0,width:next.width,height:horizontal),CGRect(x:0,y:next.height-horizontal,width:next.width,height:horizontal),CGRect(x:0,y:0,width:vertical,height:next.height),CGRect(x:next.width-vertical,y:0,width:vertical,height:next.height)]
        let s=min(3,max(1,severity))
        let weights=s<=2 ? [2-s,s-1,0]:[0,3-s,s-2]
        let animate=animated && !rebuild && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let duration=shrinking ? 0.06:0.12
        CATransaction.begin();CATransaction.setDisableActions(true)
        for side in 0..<4 {
            let strip=strips[side],frame=frames[side]
            // Keep the existing strip -> phase -> ink hierarchy. Its children
            // stay at the texture's 42-point cross-section; only the strip's
            // transform and center move as the exact visual depth changes.
            let bounds=side<2 ? CGRect(x:0,y:0,width:next.width,height:42):CGRect(x:0,y:0,width:42,height:next.height)
            let transform=CATransform3DMakeScale(side<2 ? 1:frame.width/42,side<2 ? frame.height/42:1,1)
            let position=CGPoint(x:frame.midX,y:frame.midY)
            let transformChanged = !CATransform3DEqualToTransform(strip.transform,transform)
            let positionChanged=strip.position != position
            let oldTransform=animate && transformChanged ? (strip.presentation()?.transform ?? strip.transform):strip.transform
            let oldPosition=animate && positionChanged ? (strip.presentation()?.position ?? strip.position):strip.position
            if strip.bounds != bounds {strip.bounds=bounds}
            if transformChanged {strip.transform=transform}
            if positionChanged {strip.position=position}
            for phase in 0..<2 {
                if rebuild && phases[side][phase].frame != bounds {phases[side][phase].frame=bounds}
                for color in 0..<3 {
                    let ink=inks[side][phase][color]
                    if rebuild && ink.frame != bounds {ink.frame=bounds}
                    if rebuild {
                        let key="\(side)-\(phase)-\(color)-\(side<2 ? next.width:next.height)" as NSString
                        if let image=Self.textureCache.object(forKey:key) {
                            if (ink.contents as AnyObject?) !== image {ink.contents=image}
                        }
                        else {
                            let painter=SmokeEdgeView(side:side)
                            painter.frame=side<2 ? CGRect(x:0,y:0,width:next.width,height:42):CGRect(x:0,y:0,width:42,height:next.height)
                            painter.severity=Double(color+1);painter.forcedDepth=40;painter.time=Double(phase)*8
                            if let image=painter.makeTexture(forLayer:true) {
                                Self.textureCache.setObject(image,forKey:key,cost:image.bytesPerRow*image.height);ink.contents=image
                            }
                        }
                    }
                    let opacity=Float(weights[color])
                    if ink.opacity != opacity {
                        let previous=animate ? (ink.presentation()?.opacity ?? ink.opacity):ink.opacity
                        ink.opacity=opacity
                        if animate && previous != opacity {
                            let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=previous;fade.toValue=opacity
                            fade.duration=duration;ink.add(fade,forKey:"zone-color")
                        } else if ink.animation(forKey:"zone-color") != nil {ink.removeAnimation(forKey:"zone-color")}
                    }
                }
            }
            // Keep the inner tail clear even when opposite strips approach the center.
            if depth>(side<2 ? next.height:next.width)*0.46 {
                if strip.mask==nil {
                    let mask=CAGradientLayer()
                    mask.colors=[NSColor.white.cgColor,NSColor.white.cgColor,NSColor.clear.cgColor];mask.locations=[0,0.6,1]
                    switch side {case 0:mask.startPoint=CGPoint(x:0.5,y:0);mask.endPoint=CGPoint(x:0.5,y:1)
                    case 1:mask.startPoint=CGPoint(x:0.5,y:1);mask.endPoint=CGPoint(x:0.5,y:0)
                    case 2:mask.startPoint=CGPoint(x:0,y:0.5);mask.endPoint=CGPoint(x:1,y:0.5)
                    default:mask.startPoint=CGPoint(x:1,y:0.5);mask.endPoint=CGPoint(x:0,y:0.5)}
                    mask.frame=bounds;strip.mask=mask
                } else if strip.mask?.frame != bounds {strip.mask?.frame=bounds}
            } else if strip.mask != nil {strip.mask=nil}
            if animate {
                if transformChanged {
                    let animation=CABasicAnimation(keyPath:"transform");animation.fromValue=NSValue(caTransform3D:oldTransform);animation.toValue=NSValue(caTransform3D:transform);animation.duration=duration
                    strip.add(animation,forKey:"zone-depth")
                }
                if positionChanged {
                    let animation=CABasicAnimation(keyPath:"position");animation.fromValue=oldPosition;animation.toValue=position;animation.duration=duration
                    strip.add(animation,forKey:"zone-position")
                }
            } else {
                if strip.animation(forKey:"zone-depth") != nil {strip.removeAnimation(forKey:"zone-depth")}
                if strip.animation(forKey:"zone-position") != nil {strip.removeAnimation(forKey:"zone-position")}
            }
        }
        CATransaction.commit()
    }
}

struct SmokeHaloSurface:NSViewRepresentable {
    var severity:Double
    var time:Double?=nil
    var depthScale:CGFloat=1
    func makeNSView(context:Context)->SmokeHaloView{SmokeHaloView(severity:severity,time:time,depthScale:depthScale)}
    func updateNSView(_ view:SmokeHaloView,context:Context){view.setDepthScale(depthScale);view.setSeverity(severity)}
}

// Fixed-time rendering uses precisely the same native strips as the live overlay.
func makeSmokeHaloView(severity:Double,time:Double=0,depthScale:CGFloat=1)->some View {SmokeHaloSurface(severity:severity,time:time,depthScale:depthScale)}

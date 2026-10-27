import AppKit

struct MenuIconMetrics {
    let red:Double,green:Double,blue:Double
    let urgency:Double,dotRadius:CGFloat,lineWidth:CGFloat,centerRadius:CGFloat,ringOpacity:CGFloat
}

enum MenuBarIcon {
    static let size=NSSize(width:18,height:18)
    static let colorStatusSize=NSSize(width:20,height:20)
    private static let statusCache:NSCache<NSString,NSImage> = {
        let cache=NSCache<NSString,NSImage>();cache.countLimit=4;cache.totalCostLimit=4*40*40*4;return cache
    }()
    /// Option C: twelve solid radial notches with an empty center. Four cached
    /// 2x rasters cover every zone/neutral state; no animation or drawing timer.
    static func statusImage(zone:String)->NSImage {
        let zone=["green","yellow","red"].contains(zone) ? zone:"neutral"
        let key=zone as NSString
        if let cached=statusCache.object(forKey:key){return cached}
        let logical=colorStatusSize
        let width=Int(logical.width*2),height=Int(logical.height*2)
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:width*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:bitmap) else{return NSImage(size:logical)}
        let color:NSColor
        switch zone {
        case "green":color=NSColor(srgbRed:0.12,green:0.70,blue:0.36,alpha:1)
        case "yellow":color=NSColor(srgbRed:0.96,green:0.66,blue:0.08,alpha:1)
        case "red":color=NSColor(srgbRed:0.94,green:0.23,blue:0.24,alpha:1)
        default:color = .labelColor
        }
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        context.cgContext.clear(CGRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height)))
        context.shouldAntialias=true;context.cgContext.scaleBy(x:2,y:2)
        context.cgContext.translateBy(x:logical.width/2,y:logical.height/2)
        color.setFill()
        for index in 0..<12 {
            NSGraphicsContext.saveGraphicsState()
            let rotation=NSAffineTransform();rotation.rotate(byRadians:CGFloat(index)*2 * .pi/12);rotation.concat()
            NSBezierPath(roundedRect:NSRect(x:5,y:-0.9,width:3.4,height:1.8),xRadius:0.4,yRadius:0.4).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState();bitmap.size=logical
        let image=NSImage(size:logical);image.addRepresentation(bitmap);image.isTemplate=zone == "neutral"
        statusCache.setObject(image,forKey:key,cost:width*height*4)
        return image
    }
    static let pulseFrequency=0.85 // A slow breath, never a flash.

    static let liveRasterPixels=36
    static let liveCacheCountLimit=96
    static let liveCacheCostLimit=1024*1024
    static let liveRasterCost=liveRasterPixels*liveRasterPixels*4
    private static let liveCache:NSCache<NSNumber,NSImage> = {
        let cache=NSCache<NSNumber,NSImage>()
        cache.countLimit=liveCacheCountLimit;cache.totalCostLimit=liveCacheCostLimit
        return cache
    }()
    /// The live status item draws a tiny fixed bitmap, rather than retaining a
    /// vector callback that AppKit can replay on every status-bar composition.
    /// Quantization matches the existing twenty-step live severity updates.
    static func liveImage(severity:Double,progress:Double)->NSImage {
        let step=Int(((severity.isFinite ? min(3,max(0,severity)):0)*20).rounded())
        let progressStep=step>=40 ? Int(((progress.isFinite ? min(1,max(0,progress)):0)*20).rounded()):0
        let key=NSNumber(value:step*21+progressStep)
        if let image=liveCache.object(forKey:key){return image}
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:liveRasterPixels,pixelsHigh:liveRasterPixels,
            bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,
            bytesPerRow:liveRasterPixels*4,bitsPerPixel:32),let context=NSGraphicsContext(bitmapImageRep:bitmap) else {
            return NSImage(size:size)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current=context;context.shouldAntialias=true
        context.cgContext.scaleBy(x:2,y:2)
        render(severity:Double(step)/20,progress:Double(progressStep)/20,time:0,reduceMotion:true)
            .draw(in:NSRect(origin:.zero,size:size),from:.zero,operation:.copy,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        bitmap.size=size
        let image=NSImage(size:size);image.addRepresentation(bitmap);image.isTemplate=false
        liveCache.setObject(image,forKey:key,cost:liveRasterCost)
        return image
    }
    static func severity(score:Double,yellow:Double,red:Double)->Double {
        guard score.isFinite,yellow.isFinite,red.isFinite,yellow>0,red>yellow else{return 0}
        return min(3,max(0,score<=yellow ? score/yellow:1+(score-yellow)/(red-yellow)))
    }
    static func metrics(severity:Double,progress:Double,time:Double,reduceMotion:Bool=false)->MenuIconMetrics {
        let s=severity.isFinite ? min(3,max(0,severity)):0
        let p=s>=2 && progress.isFinite ? min(1,max(0,progress)):0
        let urgency=min(1,(s/2)*0.7+p*0.3)
        let green=[0.12,0.70,0.36],yellow=[0.96,0.66,0.08],red=[0.94,0.23,0.24]
        let a=s<=1 ? green:yellow,b=s<=1 ? yellow:red,t=min(1,s<=1 ? s:s-1)
        let clock=time.isFinite ? time:0
        let breath=reduceMotion ? 0.5:0.5+0.5*sin(clock*2*Double.pi*pulseFrequency)
        let strength=max(0,min(1,s-1))*(0.3+0.7*p)
        let pulse=(breath-0.5)*strength
        return MenuIconMetrics(red:a[0]+(b[0]-a[0])*t,green:a[1]+(b[1]-a[1])*t,blue:a[2]+(b[2]-a[2])*t,
            urgency:urgency,dotRadius:CGFloat(0.66+urgency*0.55+pulse*0.12),lineWidth:CGFloat(0.65+urgency*1.15+pulse*0.16),
            centerRadius:CGFloat(max(0,urgency-0.35)*2.7+pulse*0.14),ringOpacity:CGFloat(0.24+urgency*0.56+pulse*0.14))
    }
    /// Deterministic, fixed 18pt bounds. Color is baked into a non-template image.
    static func render(severity:Double,progress:Double,time:Double,reduceMotion:Bool=false)->NSImage {
        let m=metrics(severity:severity,progress:progress,time:time,reduceMotion:reduceMotion)
        let image=NSImage(size:size,flipped:false){rect in
            let color=NSColor(srgbRed:m.red,green:m.green,blue:m.blue,alpha:1)
            let center=NSPoint(x:rect.midX,y:rect.midY),radius:CGFloat=6.1
            // A thin opposing outline keeps the colored silhouette readable over
            // both light and dark menu bars without changing its fixed footprint.
            let outline=NSBezierPath(ovalIn:NSRect(x:center.x-radius-0.6,y:center.y-radius-0.6,width:(radius+0.6)*2,height:(radius+0.6)*2))
            NSColor.black.withAlphaComponent(0.17).setStroke();outline.lineWidth=0.45;outline.stroke()
            let ring=NSBezierPath(ovalIn:NSRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2))
            color.withAlphaComponent(m.ringOpacity).setStroke();ring.lineWidth=m.lineWidth;ring.stroke()
            color.setFill()
            for index in 0..<12 {
                let angle=CGFloat(index)*2*CGFloat.pi/12
                let x=center.x+cos(angle)*radius,y=center.y+sin(angle)*radius
                NSBezierPath(ovalIn:NSRect(x:x-m.dotRadius,y:y-m.dotRadius,width:m.dotRadius*2,height:m.dotRadius*2)).fill()
            }
            if m.centerRadius>0 {
                color.withAlphaComponent(0.85).setFill()
                NSBezierPath(ovalIn:NSRect(x:center.x-m.centerRadius,y:center.y-m.centerRadius,width:m.centerRadius*2,height:m.centerRadius*2)).fill()
            }
            return true
        }
        image.isTemplate=false;return image
    }
}

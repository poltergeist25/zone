import AppKit

// Integrator only, from the workspace root (no windows/camera/preferences):
// swiftc Sources/SmokeHalo.swift Sources/MenuBarIcon.swift Checks/VisualUpdateChecks.swift -o Checks/visual-update-checks
// Checks/visual-update-checks
 @main enum VisualUpdateChecks {
    static func check(_ value:Bool,_ message:String){precondition(value,message)}
    static func near(_ a:CGFloat,_ b:CGFloat)->Bool{abs(a-b)<0.000001}
    static func inks(_ root:CALayer)->[CALayer] {
        (root.sublayers ?? []).flatMap{($0.sublayers ?? []).flatMap{$0.sublayers ?? []}}
    }
    static func images(_ root:CALayer)->[CGImage] {inks(root).map{$0.contents as! CGImage}}
    static func pixels(_ root:CALayer,_ size:CGSize)->[UInt8] {
        let width=Int(size.width),height=Int(size.height)
        let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.clear(CGRect(origin:.zero,size:size))
        root.render(in:ctx)
        return Array(UnsafeBufferPointer(start:ctx.data!.assumingMemoryBound(to:UInt8.self),count:width*height*4))
    }
    // Reconstruct the accepted resize-based compositor with the exact same
    // cached textures. This independently checks the transform mapping/render.
    static func legacy(_ root:CALayer,_ size:CGSize)->CALayer {
        let old=CALayer();old.bounds=CGRect(origin:.zero,size:size);old.isGeometryFlipped=true
        for strip in root.sublayers! {
            let copy=CALayer();copy.frame=strip.frame;copy.masksToBounds=true;old.addSublayer(copy)
            if let source=strip.mask as? CAGradientLayer {
                let mask=CAGradientLayer();mask.colors=source.colors;mask.locations=source.locations
                mask.startPoint=source.startPoint;mask.endPoint=source.endPoint
                mask.frame=copy.bounds;copy.mask=mask
            }
            for phase in strip.sublayers! {
                let p=CALayer();p.frame=copy.bounds;p.opacity=phase.opacity;copy.addSublayer(p)
                for ink in phase.sublayers! {
                    let i=CALayer();i.frame=copy.bounds;i.contentsGravity = .resize
                    i.contents=ink.contents;i.opacity=ink.opacity;p.addSublayer(i)
                }
            }
        }
        return old
    }
    static func geometry(_ root:CALayer,_ size:CGSize,_ severity:Double,_ scale:CGFloat) {
        let depth=SmokeGeometry.depth(severity,scale:scale)+2
        let h=min(depth,size.height*0.46),v=min(depth,size.width*0.46)
        let expected=[CGRect(x:0,y:0,width:size.width,height:h),CGRect(x:0,y:size.height-h,width:size.width,height:h),
            CGRect(x:0,y:0,width:v,height:size.height),CGRect(x:size.width-v,y:0,width:v,height:size.height)]
        check(root.sublayers?.count == 4,"four edge strips")
        for (side,strip) in root.sublayers!.enumerated() {
            let a=strip.frame,b=expected[side]
            check(near(a.minX,b.minX) && near(a.minY,b.minY) && near(a.width,b.width) && near(a.height,b.height),"edge position/depth changed")
            check(strip.sublayers?.count == 2,"two drift phases")
            check(near(side<2 ? strip.bounds.height:strip.bounds.width,42),"parent canonical cross-section")
            for phase in strip.sublayers! {
                check(phase.frame == strip.bounds && phase.sublayers?.count == 3,"fixed phase geometry")
                for ink in phase.sublayers! {check(ink.frame == strip.bounds,"fixed ink geometry")}
            }
            check((strip.mask != nil) == (depth>(side<2 ? size.height:size.width)*0.46),"center protection mask lifetime")
        }
    }
    static func renderMatches(_ root:CALayer,_ size:CGSize) {
        let actual=pixels(root,size),expected=pixels(legacy(root,size),size)
        let count=Int(size.width*size.height)
        var different=0,visible=0
        for index in 0..<count {
            let offset=index*4
            if (0..<4).contains(where:{abs(Int(actual[offset+$0])-Int(expected[offset+$0]))>2}) {different += 1}
            if actual[offset+3]>0 {visible += 1}
        }
        check(visible>0,"smoke unexpectedly blank")
        check(Double(different)/Double(count)<0.002,"transform render differs from accepted resize layout")
        // The final eight percent of the center must remain fully transparent.
        for y in Int(size.height*0.46)+1..<Int(size.height*0.54)-1 {
            for x in Int(size.width*0.46)+1..<Int(size.width*0.54)-1 {
                check(actual[(y*Int(size.width)+x)*4+3] == 0,"center is not clear")
            }
        }
    }
    static func smoke() {
        let size=CGSize(width:640,height:400)
        let view=SmokeHaloView(severity:1.2)
        view.frame=CGRect(origin:.zero,size:size);view.layoutSubtreeIfNeeded();view.layout()
        let root=view.layer!,original=images(root),nodes=inks(root)
        check(original.count == 24,"cached texture count")
        for (severity,scale) in [(1.21,CGFloat(1)),(1.7,1),(2.2,1),(3,50),(1.2,1)] {
            view.setDepthScale(scale);view.setSeverity(severity)
            geometry(root,size,severity,scale)
            let current=images(root)
            check(zip(current,original).allSatisfy{$0.0 === $0.1},"severity/scale rerasterized textures")
            check(zip(inks(root),nodes).allSatisfy{$0.0 === $0.1},"severity/scale replaced child layers")
            renderMatches(root,size)
        }
        // Scale-only changes must not create any color fade, including the
        // unused red texture at a yellow severity. Geometry still changes now.
        nodes.forEach{$0.removeAnimation(forKey:"zone-color")}
        view.setDepthScale(2)
        check(nodes.allSatisfy{$0.animation(forKey:"zone-color")==nil},"scale-only opacity churn")
        geometry(root,size,1.2,2)
        view.setSeverity(1.2001)
        geometry(root,size,1.2001,2) // No quantization of smoke recovery.
        for strip in root.sublayers! {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(abs(strip.animation(forKey:"zone-depth")!.duration-0.12)<0.000001,"advance timing")
            }
        }
        view.setSeverity(1.1)
        geometry(root,size,1.1,2)
        for strip in root.sublayers! {
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                check(abs(strip.animation(forKey:"zone-depth")!.duration-0.06)<0.000001,"retreat timing")
            } else {check(strip.animation(forKey:"zone-depth")==nil,"reduce motion geometry animation")}
        }
        view.setDepthScale(0);check(view.depthScale == 1,"lower depth scale clamp")
        view.setDepthScale(100);check(view.depthScale == 50,"upper depth scale clamp")
        let reused=SmokeHaloView(severity:2)
        reused.frame=CGRect(origin:.zero,size:size);reused.layoutSubtreeIfNeeded();reused.layout()
        check(zip(images(reused.layer!),original).allSatisfy{$0.0 === $0.1},"cache identity across view recreation")
        view.frame=CGRect(x:0,y:0,width:800,height:500);view.layoutSubtreeIfNeeded();view.layout()
        geometry(root,CGSize(width:800,height:500),1.1,50)
        renderMatches(root,CGSize(width:800,height:500))
        // Detaching an already detached view remains idle; no drift is started.
        view.viewDidMoveToWindow();check(!view.isAnimating,"detached drift not cleared")
    }
    static func menu()throws {
        for (severity,r,g,b) in [(0.0,0.12,0.70,0.36),(1,0.96,0.66,0.08),(2,0.94,0.23,0.24)] {
            let m=MenuBarIcon.metrics(severity:severity,progress:0,time:0,reduceMotion:true)
            check(abs(m.red-r)<0.000001 && abs(m.green-g)<0.000001 && abs(m.blue-b)<0.000001,"spectrum color changed")
            let image=MenuBarIcon.render(severity:severity,progress:0,time:0,reduceMotion:true)
            check(!image.isTemplate && image.size == NSSize(width:18,height:18),"colored status icon contract")
        }
        let a=MenuBarIcon.metrics(severity:2.4,progress:0,time:0,reduceMotion:true)
        let b=MenuBarIcon.metrics(severity:2.4,progress:1,time:0,reduceMotion:true)
        check(b.urgency>a.urgency,"warning progress stopped responding")
    }
    static func main()throws {smoke();try menu();print("PASS: visual update source and synthetic compositor checks")}
}

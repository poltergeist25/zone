import SwiftUI
import AppKit

@main struct RenderLooks {
    static func main() throws {
        let app=NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance=NSAppearance(named:.aqua)
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        for zone in 0...2 {
            let view=NSHostingView(rootView:makeVisualGalleryView(zone:zone).preferredColorScheme(.light))
            let size=NSSize(width:1060,height:740)
            let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
            window.isReleasedWhenClosed=false
            window.contentView=view
            view.frame=NSRect(origin:.zero,size:size)
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date().addingTimeInterval(0.25))
            view.layoutSubtreeIfNeeded()
            let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds)!
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("native-looks-\(zone).png"))
            window.close()
        }
        let comparison=NSHostingView(rootView:makeVisualComparisonView().preferredColorScheme(.light))
        let size=NSSize(width:1120,height:940)
        let window=NSWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:.borderless,backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=comparison;comparison.frame=NSRect(origin:.zero,size:size)
        comparison.layoutSubtreeIfNeeded();RunLoop.main.run(until:Date().addingTimeInterval(0.25));comparison.layoutSubtreeIfNeeded()
        let bitmap=comparison.bitmapImageRepForCachingDisplay(in:comparison.bounds)!
        comparison.cacheDisplay(in:comparison.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("posture-native-options.png"))
        window.close()
        print("Rendered native gallery states and comparison")
    }
}

import Cocoa
import AVFoundation

// Live video wallpaper: plays every clip in ~/Wallpapers/clips, rotating on a timer.
let clipDir = NSString(string: "~/Wallpapers/clips-hd").expandingTildeInPath
let rotateSeconds: TimeInterval = Double(ProcessInfo.processInfo.environment["LW_ROTATE"] ?? "") ?? 15 * 60

final class Wall {
    let window: NSWindow
    var layer = AVPlayerLayer()
    let host: CALayer
    init(screen: NSScreen) {
        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        let v = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.wantsLayer = true
        host = v.layer!
        window.contentView = v
        Wall.style(layer, in: v.bounds)
        host.addSublayer(layer)
        window.orderFrontRegardless()
    }
    static func style(_ l: AVPlayerLayer, in b: CGRect) {
        l.frame = b
        l.videoGravity = .resizeAspectFill
        l.magnificationFilter = .nearest
        l.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }
    /// Shows `player` on a fresh layer and fades it in once its first frame is ready (no black flash).
    func swap(to player: AVPlayer) {
        let old = layer
        let new = AVPlayerLayer(player: player)
        Wall.style(new, in: host.bounds)
        new.opacity = 0
        host.addSublayer(new)
        layer = new
        var obs: NSKeyValueObservation?
        func reveal() {
            obs?.invalidate(); obs = nil
            CATransaction.begin(); CATransaction.setAnimationDuration(1.0)
            CATransaction.setCompletionBlock { old.removeFromSuperlayer(); old.player = nil }
            new.opacity = 1
            CATransaction.commit()
        }
        if new.isReadyForDisplay { reveal(); return }
        obs = new.observe(\.isReadyForDisplay, options: [.new]) { l, _ in
            if l.isReadyForDisplay { DispatchQueue.main.async { reveal() } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if new.opacity == 0 { reveal() } }  // safety net
    }
}

final class App: NSObject, NSApplicationDelegate {
    var walls: [Wall] = []
    var clips: [URL] = []
    var idx = 0
    var player: AVQueuePlayer?
    var looper: AVPlayerLooper?
    var timer: Timer?
    var item: NSStatusItem!
    var paused = false
    var asleep = false   // screen off / locked / another user: don't decode 4K video nobody can see

    func applicationDidFinishLaunching(_ n: Notification) {
        clips = ((try? FileManager.default.contentsOfDirectory(atPath: clipDir)) ?? [])
            .filter { $0.hasSuffix(".mp4") }.sorted().map { URL(fileURLWithPath: clipDir + "/" + $0) }
        guard !clips.isEmpty else { NSLog("no clips"); NSApp.terminate(nil); return }
        buildWalls()
        NotificationCenter.default.addObserver(self, selector: #selector(buildWalls),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(self, selector: #selector(sleepOn), name: n, object: nil)
        }
        for n in [NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification, NSWorkspace.didWakeNotification] {
            ws.addObserver(self, selector: #selector(sleepOff), name: n, object: nil)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sleepOn), name: .init("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(sleepOff), name: .init("com.apple.screenIsUnlocked"), object: nil)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🖼"
        let m = NSMenu()
        m.addItem(withTitle: "Next wallpaper", action: #selector(next), keyEquivalent: "n").target = self
        m.addItem(withTitle: "Pause / Resume", action: #selector(toggle), keyEquivalent: "p").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = m
        play(clips[idx])
        timer = Timer.scheduledTimer(withTimeInterval: rotateSeconds, repeats: true) { [weak self] _ in self?.next() }
    }
    @objc func buildWalls() {
        let screens = NSScreen.screens
        if walls.count == screens.count {
            for (w, s) in zip(walls, screens) where w.window.frame != s.frame { w.window.setFrame(s.frame, display: true) }
            return
        }
        walls.forEach { $0.window.orderOut(nil) }
        walls = screens.map { Wall(screen: $0) }
        if let p = player { walls.forEach { $0.layer.player = p } }
    }
    func play(_ url: URL) {
        let q = AVQueuePlayer()
        q.isMuted = true
        looper = AVPlayerLooper(player: q, templateItem: AVPlayerItem(url: url))
        let old = player
        player = q
        walls.forEach { $0.swap(to: q) }
        if !paused && !asleep { q.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { old?.pause() }
    }
    func applyRunState() { (paused || asleep) ? player?.pause() : player?.play() }
    @objc func sleepOn() { asleep = true; applyRunState() }
    @objc func sleepOff() { asleep = false; applyRunState() }
    @objc func next() { idx = (idx + 1) % clips.count; play(clips[idx]) }
    @objc func toggle() { paused.toggle(); applyRunState() }
    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let d = App()
app.delegate = d
app.run()

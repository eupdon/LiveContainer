//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//

import Foundation
import SwiftUI
import UIKit
import Combine

// MARK: - App Info Provider
class AppInfoProvider {
    
    static let shared = AppInfoProvider()
    
    private var infoCacheByUUID = [String: LCAppInfo]()
    private var infoCacheByName = [String: LCAppInfo]()
    private let cacheQueue = DispatchQueue(label: "com.livecontainer.appinfoprovider.cachequeue", attributes: .concurrent)
    
    private init() {}
    
    public func findAppInfo(appName: String, dataUUID: String) -> LCAppInfo? {
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) {
            return appInfo
        }
        if let appInfo = findAppInfo(byUUID: dataUUID) {
            return appInfo
        }
        return findAppInfo(byName: appName)
    }
    
    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) {
            return cachedInfo
        }
        
        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let appInfoDict = NSDictionary(contentsOfFile: path),
               let bundlePath = appInfoDict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cachedInfo = cacheQueue.sync(execute: { infoCacheByName[appName] }) {
            return cachedInfo
        }

        var searchPaths: [String] = []
        if let appGroupPath = LCSharedUtils.appGroupPath()?.path {
            searchPaths.append("\(appGroupPath)/LiveContainer/Applications")
        }
        if let docPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(docPath)/Applications")
        }

        for appsPath in searchPaths {
            guard let appDirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            
            for appDir in appDirs where appDir.hasSuffix(".app") {
                if let appInfo = LCAppInfo(bundlePath: "\(appsPath)/\(appDir)"), appInfo.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = appInfo }
                    return appInfo
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        
        for appModel in allApps {
            if appModel.appInfo.containers.contains(where: { $0.folderName == dataUUID }) {
                return appModel.appInfo
            }
        }
        
        for appModel in allApps {
            if appModel.appInfo.displayName() == appName {
                return appModel.appInfo
            }
        }
        return nil
    }
    
    public func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.infoCacheByUUID.removeAll()
            self.infoCacheByName.removeAll()
        }
    }
}

// MARK: - App Model for Dock
@objc class DockAppModel: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    @objc let appName: String
    @objc let appUUID: String
    let appInfo: LCAppInfo?
    let view: UIView?
    
    @objc init(appName: String, appUUID: String, appInfo: LCAppInfo? = nil, view: UIView?) {
        self.appName = appName
        self.appUUID = appUUID
        self.appInfo = appInfo
        self.view = view
        super.init()
    }
}

// MARK: - MultitaskDockView Manager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()
    
    @Published var apps: [DockAppModel] = []

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var homeBarController: UIHostingController<AnyView>?

    // The window that actually hosts the guest apps.
    private var hostWindowStorage: UIWindow?
    internal var isHomeBarVisible = false
    @Published internal var isHomeBarPressed: Bool = false

    public struct Constants {
        // MARK: - Home Bar (right edge)
        static let homeBarTouchWidth: CGFloat = 30.0
        static let homeBarVisualWidth: CGFloat = 6.0
        static let homeSwipeHomeDistance: CGFloat = 30.0
        // User setting: vertical length of the home bar capsule.
        static let defaultHomeBarLength: CGFloat = 88.0
        static var homeBarLength: CGFloat {
            let stored = LCUtils.appGroupUserDefault.double(forKey: "LCHomeBarLength")
            return stored > 0 ? CGFloat(stored) : defaultHomeBarLength
        }
        // Touch area: tall enough to grab, and never shorter than the capsule.
        static var homeBarTouchHeight: CGFloat {
            max(150.0, homeBarLength + 40.0)
        }

        // MARK: - Animation & Interaction
        static let standardAnimationDuration: TimeInterval = 0.3
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1

        static let bringToFrontScale: CGFloat = 1.02
    }

    internal var hostWindow: UIWindow? {
        if let storage = hostWindowStorage, storage.windowScene != nil {
            return storage
        }
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let fallback = scene?.windows.first
        hostWindowStorage = fallback
        return fallback
    }

    public var keyWindow: UIWindow? {
        return hostWindow
    }
    
    override init() {
        super.init()
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        hostWindowStorage = scene?.windows.first
        hostWindow!.rootViewController!.view.subviews.first!.addSubview(self.windowHostingView)
        // When the guest scene receives the touches itself (immersive fullscreen),
        // the injected TweakLoader reports the bar gesture from the guest process.
        HomeBarGuestBridge.install()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userDefaultsDidChange),
            name: UserDefaults.didChangeNotification,
            object: LCUtils.appGroupUserDefault
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            self.updateHomeBarFrame()
        }
    }
    
    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.updateHomeBarFrame()
        }
    }

    // MARK: - Home Bar

    /// Every window that is pinned to immersive fullscreen.
    private var immersiveWindowControllers: [DecoratedAppSceneViewController] {
        apps.compactMap { app in
            guard let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                  vc.immersiveFullscreen else { return nil }
            return vc
        }
    }

    /// True while at least one app occupies the whole screen in immersive mode.
    /// In that state the guest process receives every touch over its viewport.
    internal var hasImmersiveFullscreenApp: Bool {
        !immersiveWindowControllers.isEmpty
    }

    /// The home bar strip on the right screen edge, in the host window's space.
    internal var homeBarZoneRect: CGRect {
        guard let hostWindow else { return .zero }
        let bounds = hostWindow.bounds
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        var insets = hostWindow.safeAreaInsets
        // An immersive window covers the physical screen edge, so the bar hugs
        // that same edge. Otherwise the guest (which has no side safe area in
        // immersive mode) and the host would disagree about where the bar is.
        if hasImmersiveFullscreenApp {
            insets.left = 0
            insets.right = 0
        }
        return CGRect(x: bounds.width - Constants.homeBarTouchWidth - insets.right,
                      y: (bounds.height - Constants.homeBarTouchHeight) / 2,
                      width: Constants.homeBarTouchWidth,
                      height: Constants.homeBarTouchHeight)
    }

    internal func setHomeBarPressed(_ pressed: Bool) {
        if isHomeBarPressed != pressed {
            isHomeBarPressed = pressed
        }
    }

    /// The bar only draws itself. Its gestures are plain gesture recognizers on
    /// the hosting view, so the bar never interferes with the app windows.
    private func setupHomeBarView() {
        let homeBarView = AnyView(HomeBarSwiftView()
            .environmentObject(self))
        let controller = UIHostingController(rootView: homeBarView)
        controller.view.backgroundColor = .clear
        controller.view.alpha = 0
        controller.view.isUserInteractionEnabled = false

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleHomeBarPan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        controller.view.addGestureRecognizer(pan)
        homeBarController = controller
    }

    private func updateHomeBarFrame() {
        guard let controller = homeBarController else { return }
        let frame = homeBarZoneRect
        guard frame != .zero, controller.view.frame != frame else { return }
        controller.view.frame = frame
    }

    @objc public func showHomeBar() {
        guard isDockEnabled(), !apps.isEmpty else { return }
        DispatchQueue.main.async {
            guard let window = self.keyWindow else { return }
            if self.homeBarController == nil {
                self.setupHomeBarView()
            }
            guard let controller = self.homeBarController else { return }
            if self.isHomeBarVisible && controller.view.superview != nil { return }
            self.isHomeBarVisible = true
            controller.view.isUserInteractionEnabled = true
            if controller.view.superview == nil {
                window.addSubview(controller.view)
            } else {
                window.bringSubviewToFront(controller.view)
            }
            self.updateHomeBarFrame()
            UIView.animate(withDuration: Constants.shortAnimationDuration1) {
                controller.view.alpha = 1
            }
        }
    }

    @objc public func hideHomeBar() {
        DispatchQueue.main.async {
            guard let controller = self.homeBarController else { return }
            self.isHomeBarVisible = false
            self.setHomeBarPressed(false)
            controller.view.isUserInteractionEnabled = false
            UIView.animate(withDuration: Constants.shortAnimationDuration1) {
                controller.view.alpha = 0
            }
        }
    }

    // MARK: - Home Bar Gestures

    @objc private func handleHomeBarPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: recognizer.view)
        switch recognizer.state {
        case .began:
            setHomeBarPressed(true)
        case .ended, .cancelled, .failed:
            setHomeBarPressed(false)
            if translation.x <= -Constants.homeSwipeHomeDistance {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                goHome()
            }
        default:
            break
        }
    }

    // MARK: - Guest Process Signals

    /// Handles a signal posted by the tweak inside the guest app process. Only
    /// the gesture phase is sent; the guest resolves the distances itself.
    internal func handleGuestSignal(_ name: String) {
        let prefix = HomeBarGuestBridge.notificationPrefix
        guard name.hasPrefix(prefix) else { return }
        switch String(name.dropFirst(prefix.count)) {
        case HomeBarGuestBridge.beginSuffix:
            guard isHomeBarVisible else { return }
            setHomeBarPressed(true)
        case HomeBarGuestBridge.homeSuffix:
            setHomeBarPressed(false)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            goHome()
        default:
            setHomeBarPressed(false)
        }
    }

    // MARK: - Window Actions

    @objc public func terminateApp(_ appUUID: String) {
        DispatchQueue.main.async {
            guard let app = self.apps.first(where: { $0.appUUID == appUUID }) else { return }
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController {
                vc.closeWindow()
            }
        }
    }

    @objc public func goHome() {
        minimizeAllWindows()
        DispatchQueue.main.async {
            DataManager.shared.model.selectedTab = .apps
        }
    }

    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        // The window that actually hosts the app is authoritative: it is not
        // necessarily the first window of the scene once other windows exist.
        if let window = view?.window,
           window.windowLevel.rawValue <= UIWindow.Level.normal.rawValue {
            hostWindowStorage = window
        }
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }
    
    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        
        DispatchQueue.main.async {
            self.apps.removeAll { $0.appUUID == appUUID }
            
            if self.apps.isEmpty {
                self.hideHomeBar()
            }
        }
    }
    
    // Find and bring corresponding multitask view to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return false
        }

        for window in windowScene.windows {
            if let targetView = findMultitaskView(in: window, withUUID: uuid) {
                passURLSchemeToView(targetView)
                animateViewAppearance(targetView, from: center, in: window)
                return true
            }
        }
        
        return false
    }

    private func passURLSchemeToView(_ view: UIView) {
        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController {
                decoratedVC.appSceneVC.openURLScheme(launchUrl)
            }
        }
    }

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false
        
        // when a fullscreen multitask app is brought to front, optionally hide other windows
        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }
        
        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let decoratedVC = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: decoratedVC) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            
            self.bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut,
                animations: {
                    view.alpha = 1.0
                    view.transform = .identity
                    view.frame = origFrame
                }
            )
        } else {
            bringViewToFront(view, in: window)
            
            UIView.animate(withDuration: Constants.shortAnimationDuration1, animations: {
                let scale = Constants.bringToFrontScale
                view.transform = CGAffineTransform(scaleX: scale, y: scale)
            }) { _ in
                UIView.animate(withDuration: Constants.shortAnimationDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        if let superview = view.superview {
            superview.bringSubviewToFront(view)
        }
        if let windowSuperview = window.superview {
            windowSuperview.bringSubviewToFront(window)
        }
    }
    
    // Recursively find multitask view
    private func findMultitaskView(in view: UIView, withUUID uuid: String) -> UIView? {
        apps.first { $0.appUUID == uuid }?.view
    }
    
    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        
        if apps.contains(where: { $0.appUUID == appUUID }) {
            return
        }
        
        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)
        
        DispatchQueue.main.async {
            self.apps.append(appModel)
            
            if self.apps.count == 1 {
                // Only the home bar is shown; the app list shows the running apps.
                self.showHomeBar()
            }
        }
    }
    
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController,
                   vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    
    private init() {}
    
    func getIcon(for key: String) -> UIImage? {
        return cacheQueue.sync {
            return cache[key]
        }
    }
    
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) {
            self.cache[key] = icon
        }
    }
    
    func clearCache() {
        cacheQueue.async(flags: .barrier) {
            self.cache.removeAll()
        }
    }
}
// MARK: - Home Bar View
@available(iOS 16.0, *)
struct HomeBarSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    // Capsule length is user configurable (Settings > Multitasking).
    @AppStorage("LCHomeBarLength", store: LCUtils.appGroupUserDefault) private var homeBarLength: Double = 88

    private var barHeight: CGFloat {
        homeBarLength > 0 ? CGFloat(homeBarLength) : MultitaskDockManager.Constants.defaultHomeBarLength
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear

            Capsule(style: .continuous)
                .fill(Color.white.opacity(dockManager.isHomeBarPressed ? 0.9 : 0.55))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                )
                .frame(width: MultitaskDockManager.Constants.homeBarVisualWidth,
                       height: barHeight)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                .padding(.trailing, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: dockManager.isHomeBarPressed)
    }
}

// MARK: - Guest Process Bridge

/// In immersive fullscreen the guest app scene covers the whole screen and owns
/// every touch over its viewport, so none of the host-side paths above ever run.
/// The tweak injected into the guest process watches `UIApplication.sendEvent`
/// there and reports the home bar gesture through Darwin notifications instead.
/// Notifications carry no payload, so only the gesture phases are signalled and
/// the guest resolves the distances itself.
@available(iOS 16.0, *)
enum HomeBarGuestBridge {
    static let notificationPrefix = "com.eupdon.livecontainer.homebar."
    static let beginSuffix = "begin"
    static let homeSuffix = "home"
    static let endSuffix = "end"
    static let cancelSuffix = "cancel"

    static let allSuffixes = [beginSuffix, homeSuffix, endSuffix, cancelSuffix]

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for suffix in allSuffixes {
            let name = notificationPrefix + suffix
            CFNotificationCenterAddObserver(center,
                                            nil,
                                            homeBarGuestNotificationCallback,
                                            name as CFString,
                                            nil,
                                            .deliverImmediately)
        }
    }
}

/// Darwin notification callback for the guest bridge. It cannot capture state,
/// so the notification name is forwarded to the manager on the main queue,
/// where all home bar state lives.
private let homeBarGuestNotificationCallback: CFNotificationCallback = { _, _, name, _, _ in
    guard let name else { return }
    let rawName = name.rawValue as String
    DispatchQueue.main.async {
        if #available(iOS 16.0, *) {
            MultitaskDockManager.shared.handleGuestSignal(rawName)
        }
    }
}

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
    @Published var isVisible: Bool = false
    @Published @objc var isCollapsed: Bool = false
    @Published var isDockHidden: Bool = false
    @Published var settingsChanged: Bool = false

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?
    internal var homeBarController: UIHostingController<AnyView>?
    private var dockDismissView: UIView?
    private var homeBarTouchView: UIView?

    // The window that hosts the guest apps. It is captured once because the
    // dedicated overlay window below must never be mistaken for it.
    private var hostWindowStorage: UIWindow?
    // Transparent window that keeps the home bar / dock above the guest apps.
    private var overlayWindow: MultitaskOverlayWindow?
    private lazy var homeBarGestureHandler = HomeBarGestureHandler(manager: self)
    fileprivate var isHomeBarVisible = false
    @Published internal var isHomeBarPressed: Bool = false

    public struct Constants {
        // MARK: - Layout & Sizing
        static let defaultDockWidth: CGFloat = 90.0
        static let minAdaptiveDockWidth: CGFloat = 50.0
        static let minAdaptiveIconSize: CGFloat = 10.0
        static let maxIconSize: CGFloat = 100.0
        static let minCollapsedHeight: CGFloat = 60.0
        static let minCollapsedButtonSize: CGFloat = 44.0
        static let maxCollapsedButtonSize: CGFloat = 80.0
        static let initialDockShowHeight: CGFloat = 120.0

        // MARK: - Margins & Padding
        static let adaptiveWidthVerticalMargin: CGFloat = 20.0
        static let dockVerticalMargin: CGFloat = 30.0
        static let dockContentSpacing: CGFloat = 8.0
        static let dockVerticalPadding: CGFloat = 30.0
        // Extra padding is derived from dockVerticalPadding to match the SwiftUI layout exactly
        
        // MARK: - Ratios & Factors
        static let iconToWidthRatio: CGFloat = 0.75
        static let collapsedButtonToWidthRatio: CGFloat = 0.7
        static let maxHeightRatioOfAvailableArea: CGFloat = 0.85
        
        // MARK: - Animation & Interaction
        static var dockHiddenOffset: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans * 2 / 3
                } else {
                    return 50
                }
            }
        }
        static var hideGestureThreshold: CGFloat {
            get {
                let ans = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
                if ans != 0 {
                    return ans / 5
                } else {
                    return 16
                }
            }
        }
        static let edgeSwipeThreshold: CGFloat = 30.0

        // MARK: - Home Bar (right edge)
        static let homeBarTouchWidth: CGFloat = 30.0
        static let homeBarTouchHeight: CGFloat = 150.0
        static let homeBarVisualWidth: CGFloat = 6.0
        static let homeBarVisualHeight: CGFloat = 88.0
        static let homeSwipeHomeDistance: CGFloat = 30.0
        static let homeSwipeDockDistance: CGFloat = 110.0
        static let homeLongPressDelay: TimeInterval = 0.4
        
        static let standardAnimationDuration: TimeInterval = 0.3
        static let longAnimationDuration: TimeInterval = 0.4
        static let shortAnimationDuration1: TimeInterval = 0.15
        static let shortAnimationDuration2: TimeInterval = 0.1
        
        static let standardSpringDamping: CGFloat = 0.8
        static let showHideSpringDamping: CGFloat = 0.7
        static let standardSpringVelocity: CGFloat = 0.3
        static let showHideSpringVelocity: CGFloat = 0.5
        
        static let initialScale: CGFloat = 0.8
        static let bringToFrontScale: CGFloat = 1.02
    }
    
    // Original dock width from user settings (without auto-adjustment)
    private var originalDockWidth: CGFloat {
        let storedValue = LCUtils.appGroupUserDefault.double(forKey: "LCDockWidth")
        return storedValue > 0 ? CGFloat(storedValue) : Constants.defaultDockWidth
    }
    
    // Calculate adaptive dock width (auto-adjust when exceeding safe area)
    public var dockWidth: CGFloat {
        guard !apps.isEmpty else { return originalDockWidth }
        
        let totalVerticalMargin = Constants.adaptiveWidthVerticalMargin * 2
        let availableHeight = self.safeAreaHeight - totalVerticalMargin
        
        let maxSafeHeight = availableHeight * Constants.maxHeightRatioOfAvailableArea
        
        let userWidth = originalDockWidth
        let iconSize = calculateIconSize(for: userWidth)
        let requiredHeight = expandedDockHeight(for: userWidth, iconSize: iconSize)
        
        if requiredHeight > maxSafeHeight && !apps.isEmpty {
            let baseHeight = expandedDockBaseHeight()
            let availableForIcons = maxSafeHeight - baseHeight
            let maxAllowedIconSize = availableForIcons / CGFloat(apps.count)
            
            let targetIconSize = max(Constants.minAdaptiveIconSize, maxAllowedIconSize)
            
            let targetWidth = targetIconSize / Constants.iconToWidthRatio
            
            return max(Constants.minAdaptiveDockWidth, targetWidth)
        }
        
        return userWidth
    }
    
    // Calculate icon size based on dock width
    private func calculateIconSize(for width: CGFloat) -> CGFloat {
        let iconSize = width * Constants.iconToWidthRatio
        return max(Constants.minAdaptiveIconSize, min(Constants.maxIconSize, iconSize))
    }

    private func calculateButtonSize(for width: CGFloat) -> CGFloat {
        let targetSize = width * Constants.collapsedButtonToWidthRatio
        return max(Constants.minCollapsedButtonSize, min(Constants.maxCollapsedButtonSize, targetSize))
    }

    private func expandedDockBaseHeight() -> CGFloat {
        // The dock now only contains running-app icons (no collapse / minimize-all buttons)
        let spacingCount = max(self.apps.count - 1, 0)
        let totalSpacingHeight = CGFloat(spacingCount) * Constants.dockContentSpacing
        return Constants.dockVerticalPadding + totalSpacingHeight
    }

    private func expandedDockHeight(for width: CGFloat, iconSize: CGFloat) -> CGFloat {
        let baseHeight = expandedDockBaseHeight()
        let iconHeight = CGFloat(self.apps.count) * iconSize
        return baseHeight + iconHeight
    }

    private func collapsedDockHeight(for width: CGFloat) -> CGFloat {
        let buttonSize = calculateButtonSize(for: width)
        return Constants.dockVerticalPadding + buttonSize
    }
    

    // Calculate adaptive icon size
    public var adaptiveIconSize: CGFloat {
        return calculateIconSize(for: dockWidth)
    }

    internal var hostWindow: UIWindow? {
        if let storage = hostWindowStorage, storage.windowScene != nil {
            return storage
        }
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let fallback = scene?.windows.first(where: { $0 !== overlayWindow })
        hostWindowStorage = fallback
        return fallback
    }

    public var keyWindow: UIWindow? {
        return hostWindow
    }

    public var safeAreaInsets: UIEdgeInsets {
        if #available(iOS 11.0, *) {
            return keyWindow?.safeAreaInsets ?? .zero
        }
        return .zero
    }

    private var safeAreaHeight: CGFloat {
        keyWindow!.bounds.height - safeAreaInsets.top - safeAreaInsets.bottom
    }
    
    override init() {
        super.init()
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        hostWindowStorage = scene?.windows.first
        keyWindow!.rootViewController!.view.subviews.first!.addSubview(self.windowHostingView)
        setupDockView()
        setupHomeBarView()
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
            self.updateOverlayWindowFrame()
            if self.isVisible {
                self.updateDockFrame()
            }
            self.updateHomeBarFrame()
        }
    }
    
    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.settingsChanged.toggle()
            if self.isVisible {
                self.updateDockFrame()
            }
            self.updateHomeBarFrame()
        }
    }
    
    private func setupDockView() {
        DispatchQueue.main.async {
            let dockView = AnyView(MultitaskDockSwiftView()
                .environmentObject(self))
            
            self.hostingController = UIHostingController(rootView: dockView)
            self.hostingController?.view.autoresizingMask = [.flexibleTopMargin, .flexibleLeftMargin, .flexibleRightMargin, .flexibleBottomMargin]
            self.hostingController?.view.backgroundColor = .clear
        }
    }

    // MARK: - Home Bar

    // MARK: - Overlay Window

    /// Transparent passthrough window that keeps the home bar and dock above the
    /// guest app windows. Fullscreen guest scenes draw over the whole screen, so a
    /// plain subview of the main window can end up below them. A dedicated window
    /// stays on top, while `MultitaskOverlayWindow.hitTest` lets every touch that
    /// is not on the home bar / dock fall through to the windows below.
    @discardableResult
    private func setupOverlayWindow() -> MultitaskOverlayWindow? {
        if let existing = overlayWindow {
            let hostScene = hostWindow?.windowScene
            if let existingScene = existing.windowScene, existingScene === hostScene {
                return existing
            }
            // The host window moved to another scene (or the overlay was detached);
            // rebuild it there.
            existing.isHidden = true
            homeBarController?.view.removeFromSuperview()
            hostingController?.view.removeFromSuperview()
            removeDockDismissView()
            homeBarTouchView?.removeFromSuperview()
            homeBarTouchView = nil
            overlayWindow = nil
        }

        guard let hostWindow, let scene = hostWindow.windowScene else { return nil }

        let window = MultitaskOverlayWindow(windowScene: scene)
        window.frame = hostWindow.bounds
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue - 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.rootViewController = MultitaskOverlayViewController()
        window.rootViewController?.view.backgroundColor = .clear
        window.isHidden = true
        overlayWindow = window

        // Transparent target that keeps home bar touches inside the overlay window.
        let touchView = UIView()
        touchView.backgroundColor = .clear
        touchView.isUserInteractionEnabled = true
        window.rootViewController?.view.addSubview(touchView)
        homeBarTouchView = touchView

        homeBarGestureHandler.attach(to: window)
        homeBarGestureHandler.attach(to: hostWindow)
        return window
    }

    private func overlayContainerView() -> UIView? {
        return setupOverlayWindow()?.rootViewController?.view
    }

    private func updateOverlayWindowFrame() {
        guard let overlayWindow else { return }
        guard let hostWindow else { return }
        if overlayWindow.windowScene !== hostWindow.windowScene {
            setupOverlayWindow()
            return
        }
        if overlayWindow.frame != hostWindow.bounds {
            overlayWindow.frame = hostWindow.bounds
        }
    }

    private func refreshOverlayWindowVisibility() {
        guard let overlayWindow else { return }
        let shouldShow = isHomeBarVisible || isVisible || dockDismissView != nil
        if overlayWindow.isHidden == shouldShow {
            overlayWindow.isHidden = !shouldShow
        }
    }

    /// The home bar touch area in the host window's coordinate space.
    internal var homeBarTouchFrame: CGRect {
        guard let hostWindow else { return .zero }
        let insets = hostWindow.safeAreaInsets
        let bounds = hostWindow.bounds
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

    private func setupHomeBarView() {
        DispatchQueue.main.async {
            let homeBarView = AnyView(HomeBarSwiftView()
                .environmentObject(self))
            let controller = UIHostingController(rootView: homeBarView)
            controller.view.backgroundColor = .clear
            controller.view.alpha = 0
            // The visual bar never receives touches itself. The overlay window owns
            // gesture recognizers for the bar area, so a fullscreen guest scene can
            // no longer swallow the touches.
            controller.view.isUserInteractionEnabled = false
            self.homeBarController = controller
            self.updateHomeBarFrame()
        }
    }

    private func updateHomeBarFrame(animated: Bool = false) {
        guard let controller = homeBarController, hostWindow != nil else { return }
        updateOverlayWindowFrame()
        let frame = homeBarTouchFrame
        homeBarTouchView?.frame = frame
        guard controller.view.frame != frame else { return }
        if animated {
            UIView.animate(withDuration: Constants.shortAnimationDuration1) {
                controller.view.frame = frame
            }
        } else {
            controller.view.frame = frame
        }
    }

    @objc public func showHomeBar() {
        guard isDockEnabled(), !apps.isEmpty else { return }
        guard let controller = homeBarController, let container = overlayContainerView() else { return }

        DispatchQueue.main.async {
            self.isHomeBarVisible = true
            self.updateOverlayWindowFrame()

            if let touchView = self.homeBarTouchView, touchView.superview == nil {
                container.insertSubview(touchView, at: 0)
            }
            if controller.view.superview !== container {
                container.addSubview(controller.view)
            }
            if let touchView = self.homeBarTouchView, touchView.superview === container {
                container.insertSubview(controller.view, aboveSubview: touchView)
            }
            self.updateHomeBarFrame()

            // while the dock is open, keep the home bar underneath the dimming / dismiss layer
            if let dismissView = self.dockDismissView, dismissView.superview === container {
                container.insertSubview(controller.view, belowSubview: dismissView)
            } else {
                container.bringSubviewToFront(controller.view)
            }

            self.refreshOverlayWindowVisibility()

            UIView.animate(withDuration: Constants.shortAnimationDuration1) {
                controller.view.alpha = 1
            }
        }
    }

    @objc public func hideHomeBar() {
        guard let controller = homeBarController else { return }

        DispatchQueue.main.async {
            self.isHomeBarVisible = false
            self.setHomeBarPressed(false)
            UIView.animate(withDuration: Constants.shortAnimationDuration1) {
                controller.view.alpha = 0
            } completion: { _ in
                if self.apps.isEmpty {
                    controller.view.removeFromSuperview()
                    self.homeBarTouchView?.removeFromSuperview()
                } else {
                    // A new app started while the bar was fading out
                    self.showHomeBar()
                }
                self.refreshOverlayWindowVisibility()
            }
        }
    }

    private func insertDockDismissView(in container: UIView) {
        removeDockDismissView()

        let dismissView = UIView(frame: container.bounds)
        dismissView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dismissView.backgroundColor = UIColor.black.withAlphaComponent(0.12)
        dismissView.isUserInteractionEnabled = true

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDockDismissTap))
        dismissView.addGestureRecognizer(tapGesture)

        let swipeGesture = UISwipeGestureRecognizer(target: self, action: #selector(handleDockDismissSwipe))
        swipeGesture.direction = .left
        dismissView.addGestureRecognizer(swipeGesture)

        container.addSubview(dismissView)
        self.dockDismissView = dismissView
    }

    private func removeDockDismissView() {
        dockDismissView?.removeFromSuperview()
        dockDismissView = nil
    }

    @objc private func handleDockDismissTap() {
        hideDock()
    }

    @objc private func handleDockDismissSwipe() {
        goHome()
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
            self.hideDock()
        }
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hostingController = hostingController else { return }

        let screenBounds = keyWindow!.bounds
        let currentDockWidth = self.dockWidth
        
        let dockHeight = calculateTargetDockHeight(forWidth: currentDockWidth)

        let currentFrame = hostingController.view.frame
        let isOnRightSide = (currentFrame.midX > screenBounds.width / 2) || (currentFrame.isEmpty)
        let targetX = calculateTargetX(isDockHidden: self.isDockHidden, 
                                    isOnRightSide: isOnRightSide, 
                                    dockWidth: currentDockWidth, 
                                    screenWidth: screenBounds.width)

        let targetY = calculateTargetY(for: currentFrame, 
                                    dockHeight: dockHeight, 
                                    screenHeight: screenBounds.height)
        
        let newFrame = CGRect(x: targetX, y: targetY, width: currentDockWidth, height: dockHeight)
        
        applyNewFrame(newFrame, for: hostingController, animated: animated)
    }

    // MARK: - Frame Calculation Helpers

    private func calculateTargetDockHeight(forWidth width: CGFloat) -> CGFloat {
        if isCollapsed {
            let collapsedHeight = collapsedDockHeight(for: width)
            return max(Constants.minCollapsedHeight, collapsedHeight)
        } else {
            let currentIconSize = calculateIconSize(for: width)
            return expandedDockHeight(for: width, iconSize: currentIconSize)
        }
    }

    func calculateTargetX(isDockHidden: Bool, isOnRightSide: Bool, dockWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {

        let safeInsets = self.safeAreaInsets
        var ans : CGFloat
        if isOnRightSide {
            ans = screenWidth - dockWidth
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeLeft {
                ans -= safeInsets.right
            }
            
            if isDockHidden {
                ans += Constants.dockHiddenOffset
            }
        } else {
            ans = 0
            if self.hostingController?.view.window?.windowScene?.interfaceOrientation == UIInterfaceOrientation.landscapeRight {
                ans += safeInsets.left
            }
            if isDockHidden {
                ans -= Constants.dockHiddenOffset
            }
        }
        
        return ans;

    }

    private func calculateTargetY(for currentFrame: CGRect, dockHeight: CGFloat, screenHeight: CGFloat) -> CGFloat {
        let safeAreaMinY = self.safeAreaInsets.top + Constants.dockVerticalMargin
        let safeAreaMaxY = screenHeight - self.safeAreaInsets.bottom - dockHeight - Constants.dockVerticalMargin
        
        if currentFrame.height > 0 {
            let desiredY = currentFrame.midY - dockHeight / 2
            return max(safeAreaMinY, min(safeAreaMaxY, desiredY))
        } else {
            let safeAreaCenterY = safeAreaMinY + (safeAreaMaxY - safeAreaMinY) / 2
            return max(safeAreaMinY, min(safeAreaMaxY, safeAreaCenterY - dockHeight / 2))
        }
    }

    private func applyNewFrame(_ newFrame: CGRect, for hostingController: UIHostingController<AnyView>, animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.standardSpringDamping,
                initialSpringVelocity: Constants.standardSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.frame = newFrame
            }
        } else {
            hostingController.view.frame = newFrame
        }
    }
    
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        // The window that actually hosts the app is authoritative: it is not
        // necessarily the first window of the scene once other windows exist.
        if let window = view?.window, window !== overlayWindow,
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
                self.hideDock()
                self.hideHomeBar()
            } else if self.isVisible {
                self.updateDockFrame()
            }
            self.refreshOverlayWindowVisibility()
        }
    }
    
    @objc public func showDock() {
        guard isDockEnabled(), !apps.isEmpty else { return }
        guard !isVisible, let hostingController = hostingController else { return }
        
        guard let container = overlayContainerView(), let hostWindow = self.hostWindow else { return }
        
        DispatchQueue.main.async {
            self.isVisible = true
            self.updateOverlayWindowFrame()
            
            let screenBounds = hostWindow.bounds
            let currentDockWidth = self.dockWidth
            let initialHeight = Constants.initialDockShowHeight
            
            // If not already in view hierarchy, add it
            if hostingController.view.superview !== container {
                container.addSubview(hostingController.view)
                hostingController.view.frame = CGRect(
                    x: screenBounds.width - currentDockWidth,
                    y: (screenBounds.height - initialHeight) / 2,
                    width: currentDockWidth,
                    height: initialHeight
                )
            }

            // Dim / tap-out layer below the dock, above app windows and the home bar
            self.insertDockDismissView(in: container)
            container.bringSubviewToFront(hostingController.view)
            self.refreshOverlayWindowVisibility()
            
            self.updateDockFrame(animated: false) 
            
            hostingController.view.alpha = 0
            let initialScale = Constants.initialScale
            hostingController.view.transform = CGAffineTransform(scaleX: initialScale, y: initialScale)
            
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 1
                hostingController.view.transform = .identity
            }
        }
    }
    
    @objc public func hideDock() {
        guard isVisible, let hostingController = hostingController else { return }
        
        DispatchQueue.main.async {
            UIView.animate(
                withDuration: Constants.standardAnimationDuration,
                delay: 0,
                usingSpringWithDamping: Constants.showHideSpringDamping,
                initialSpringVelocity: Constants.showHideSpringVelocity,
                options: .curveEaseOut
            ) {
                hostingController.view.alpha = 0
                let finalScale = Constants.initialScale
                hostingController.view.transform = CGAffineTransform(scaleX: finalScale, y: finalScale)
                // Move off-screen to hide, but keep in view hierarchy
                let screenBounds = self.hostWindow?.bounds ?? UIScreen.main.bounds
                let currentDockWidth = self.dockWidth
                let targetX = self.calculateTargetX(isDockHidden: true, isOnRightSide: hostingController.view.frame.midX > screenBounds.width / 2, dockWidth: currentDockWidth, screenWidth: screenBounds.width)
                let targetY = hostingController.view.frame.origin.y // Keep current Y
                hostingController.view.frame.origin = CGPoint(x: targetX, y: targetY)
            } completion: { _ in
                self.isVisible = false
                hostingController.view.transform = .identity
                self.removeDockDismissView()
                self.showHomeBar()
                self.refreshOverlayWindowVisibility()
            }
        }
    }

    @objc public func animateFrame(to finalFrame: CGRect) {
        guard let hostingController = self.hostingController else { return }
        
        UIView.animate(
            withDuration: Constants.standardAnimationDuration,
            delay: 0,
            usingSpringWithDamping: Constants.standardSpringDamping,
            initialSpringVelocity: Constants.standardSpringVelocity,
            options: .curveEaseOut
        ) {
            hostingController.view.frame = finalFrame
        }
    }

    @objc public func updateFrameAfterAnimation(finalOffset: CGSize) {
        guard let hostingController = self.hostingController else { return }
        
        let newFrame = hostingController.view.frame.offsetBy(dx: finalOffset.width, dy: finalOffset.height)
        
        hostingController.view.frame = newFrame
    }

    func handleSwipeToHideOrShowGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        let isSwipingAway = (isOnRightSide && translation.width > 0) || (!isOnRightSide && translation.width < 0)
        
        if isSwipingAway {
            guard !self.isDockHidden else { return false }
            self.hideDockToSide()
            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
            impactFeedback.impactOccurred()
            return true
        } else {
            guard self.isDockHidden else { return false }
            self.showDockFromHidden()
            let impactFeedback = UIImpactFeedbackGenerator(style: .light)
            impactFeedback.impactOccurred()
            return true
        }
    }
    
    // Check if gesture is for cross-screen movement (left to right or vice versa)
    func isPositionChangeGesture(for originalFrame: CGRect, translation: CGSize) -> Bool {
        let horizontalDistance = abs(translation.width)
        let verticalDistance = abs(translation.height)
        
        guard !self.isDockHidden, horizontalDistance > verticalDistance else {
            return false
        }
        
        let screenWidth = keyWindow!.bounds.width
        let isOnRightSide = originalFrame.origin.x > screenWidth / 2
        
        guard !self.isDockHidden else { return false }
        
        let isMovingToOtherSide = (isOnRightSide && translation.width < 0) || (!isOnRightSide && translation.width > 0)
        guard isMovingToOtherSide else { return false }
        
        let draggedX = originalFrame.origin.x + translation.width
        let screenCenter = screenWidth / 2
        
        if isOnRightSide {
            return draggedX < screenCenter
        } else {
            return (draggedX + originalFrame.width) > screenCenter
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
    
    // Get view's dataUUID property through reflection
    private func getDataUUID(from view: UIView) -> String? {
        let mirror = Mirror(reflecting: view)
        
        if let child = (mirror.children.first { $0.label == "dataUUID" })?.value as? String {
            return child
        }
        
        if view.responds(to: NSSelectorFromString("dataUUID")) {
            return view.value(forKey: "dataUUID") as? String
        }
        
        return nil
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
                // The dock stays hidden until the home bar is used; only the home bar is shown
                self.showHomeBar()
            } else if self.isVisible {
                self.updateDockFrame()
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
    
    @objc public func toggleDockCollapse() {
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.updateDockFrame()
            self.notifyDockCollapseChanged()
        }
    }
    
    @objc public func notifyDockCollapseChanged() {
        self.updateDockFrame()
        // find fullscreen apps and hide its UINavigationBar
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }
    
    // Toggle dock hide/show state
    @objc public func toggleDockVisibility() {
        DispatchQueue.main.async {
            self.isDockHidden.toggle()
            self.updateDockFrame()
        }
    }
    
    @objc public func showDockFromHidden() {
        DispatchQueue.main.async {
            self.isDockHidden = false
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    @objc public func hideDockToSide() {
        DispatchQueue.main.async {
            self.isDockHidden = true
            self.updateDockFrame()
            self.setupEdgeGestureRecognizers()
        }
    }
    
    // Add edge gesture recognition areas when dock is hidden
    private func setupEdgeGestureRecognizers() {
        guard let keyWindow = hostWindow else { return }
        
        keyWindow.gestureRecognizers?.removeAll { gesture in
            return gesture is UITapGestureRecognizer || gesture is UIScreenEdgePanGestureRecognizer
        }
        
        if isDockHidden {
            let leftEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            leftEdgeGesture.edges = .left
            keyWindow.addGestureRecognizer(leftEdgeGesture)
            
            let rightEdgeGesture = UIScreenEdgePanGestureRecognizer(target: self, action: #selector(handleEdgeSwipe(_:)))
            rightEdgeGesture.edges = .right
            keyWindow.addGestureRecognizer(rightEdgeGesture)
        }
    }
    
    @objc private func handleEdgeSwipe(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard isDockHidden, gesture.state == .began || gesture.state == .changed else {
            return
        }
        
        let translation = gesture.translation(in: gesture.view)
        let swipeDistance = abs(translation.x)
        
        if swipeDistance > Constants.edgeSwipeThreshold {
            showDockFromHidden()
        }
    }
    
    // MARK: - Multitask Mode Check
    private func isDockEnabled() -> Bool {
        let multitaskMode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return multitaskMode == .virtualWindow
    }
}

// MARK: - SwiftUI Dock View
@available(iOS 16.0, *)
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    // Calculate dynamic padding based on user settings
    private var dynamicPadding: CGFloat {
        let basePadding: CGFloat = 4
        let extraPadding = (dockManager.dockWidth - MultitaskDockManager.Constants.defaultDockWidth) * 0.2
        return max(basePadding, basePadding + extraPadding)
    }
    
    public var body: some View {
        GeometryReader { g in
            // The dock only shows running apps: no collapse, maximize or minimize-all controls
            VStack(spacing: 8) {
                ForEach(dockManager.apps) { app in
                    AppIconView(app: app)
                }
            }
            .padding(dynamicPadding)
            .modifier { content in
                if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                    content.glassEffect(.regular, in: .rect(cornerRadius: 15))
                } else {
                    content.background(
                        RoundedRectangle(cornerRadius: 15)
                            .fill(Color.black.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: 15)
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    )
                }
            }
            .scaleEffect(dockManager.isVisible ? 1.0 : 0.8)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
        .ignoresSafeArea()
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.dockWidth)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.settingsChanged)
    }
    
    public init() {}
}

// MARK: - Collapsed Dock View
@available(iOS 16.0, *)
struct CollapsedDockView: View {
    let isHidden: Bool
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.blue.opacity(isHidden ? 0.4 : 0.8),
                            Color.blue.opacity(isHidden ? 0.3 : 0.6)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Group {
                if isHidden {
                    Image(systemName: "eye.slash")
                        .foregroundColor(.white.opacity(0.8))
                        .font(.system(size: dockManager.adaptiveIconSize * 0.35, weight: .bold))
                } else {
                    Image(systemName: "chevron.up")
                        .foregroundColor(.white)
                        .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .bold))
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(isHidden ? 0.2 : 0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 3, x: 0, y: 2)
        .scaleEffect(isHidden ? 0.9 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isHidden)
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Collapse Button View
@available(iOS 16.0, *)
struct CollapseButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)  
                .fill(Color.gray.opacity(0.8))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Image(systemName: "chevron.down")
                .foregroundColor(.white)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)  
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .animation(.spring(response: MultitaskDockManager.Constants.longAnimationDuration, dampingFraction: MultitaskDockManager.Constants.standardSpringDamping), value: dockManager.adaptiveIconSize)
    }
}

// MARK: - Minimize All Button View
@available(iOS 16.0, *)
struct MinimizeAllButtonView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager
    
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.8))
                .frame(width: dockManager.adaptiveIconSize, height: dockManager.adaptiveIconSize)
            
            Image(systemName: "rectangle.stack.badge.minus")
                .foregroundColor(.white)
                .font(.system(size: dockManager.adaptiveIconSize * 0.4, weight: .semibold))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
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

    private var visualWidth: CGFloat {
        MultitaskDockManager.Constants.homeBarVisualWidth
    }

    private var visualHeight: CGFloat {
        MultitaskDockManager.Constants.homeBarVisualHeight
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
                .contentShape(Rectangle())

            Capsule(style: .continuous)
                .fill(Color.white.opacity(dockManager.isHomeBarPressed ? 0.9 : 0.55))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
                )
                .frame(width: visualWidth, height: visualHeight)
                .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                .padding(.trailing, 2)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.15), value: dockManager.isHomeBarPressed)
    }
}

// MARK: - Overlay Window (home bar / dock passthrough)

/// Transparent window that keeps the home bar and dock above the guest apps.
/// Anything that is not an interactive subview is passed through to the windows
/// below, so the hosted app keeps receiving its own touches.
@available(iOS 16.0, *)
final class MultitaskOverlayWindow: UIWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeFocused: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hitView = super.hitTest(point, with: event) else { return nil }
        // Hitting the window / container itself means the point belongs to an app below.
        if hitView === self || hitView === rootViewController?.view {
            return nil
        }
        return hitView
    }
}

@available(iOS 16.0, *)
final class MultitaskOverlayViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isOpaque = false
    }
}

/// Owns the home bar gestures. They are attached to the windows (not to the bar
/// view) so a fullscreen guest scene drawing above the bar cannot steal them.
@available(iOS 16.0, *)
final class HomeBarGestureHandler: NSObject, UIGestureRecognizerDelegate {
    private weak var manager: MultitaskDockManager?
    private var recognizers: [UILongPressGestureRecognizer] = []
    private var longPressWorkItem: DispatchWorkItem?
    private var startLocation: CGPoint = .zero
    private var didTriggerDock = false
    private var isTracking = false

    init(manager: MultitaskDockManager) {
        self.manager = manager
        super.init()
    }

    func attach(to window: UIWindow) {
        guard !recognizers.contains(where: { $0.view === window }) else { return }

        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleTouch(_:)))
        // Track the touch from the moment it lands; the dock is opened by the
        // timer below, not by the recognizer's own minimum press duration.
        recognizer.minimumPressDuration = 0
        recognizer.allowableMovement = .greatestFiniteMagnitude
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delegate = self
        window.addGestureRecognizer(recognizer)
        recognizers.append(recognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let manager, manager.isHomeBarVisible, !manager.isVisible else { return false }
        guard let view = gestureRecognizer.view else { return false }
        return manager.homeBarTouchFrame.contains(touch.location(in: view))
    }

    @objc private func handleTouch(_ recognizer: UILongPressGestureRecognizer) {
        guard let manager else { return }
        let location = recognizer.location(in: recognizer.view)

        switch recognizer.state {
        case .began:
            isTracking = true
            didTriggerDock = false
            startLocation = location
            manager.setHomeBarPressed(true)
            scheduleLongPress()
        case .changed:
            guard isTracking else { return }
            // A long leftward swipe opens the dock immediately
            if startLocation.x - location.x >= MultitaskDockManager.Constants.homeSwipeDockDistance {
                triggerDock()
            }
        case .ended:
            guard isTracking else { return }
            isTracking = false
            cancelLongPress()
            manager.setHomeBarPressed(false)
            let triggeredDock = didTriggerDock
            didTriggerDock = false
            guard !triggeredDock else { return }

            // A quick, short leftward swipe goes home
            if startLocation.x - location.x >= MultitaskDockManager.Constants.homeSwipeHomeDistance {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                manager.goHome()
            }
        default:
            isTracking = false
            cancelLongPress()
            manager.setHomeBarPressed(false)
            didTriggerDock = false
        }
    }

    private func scheduleLongPress() {
        cancelLongPress()
        let item = DispatchWorkItem { [weak self] in
            self?.triggerDock()
        }
        longPressWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + MultitaskDockManager.Constants.homeLongPressDelay, execute: item)
    }

    private func cancelLongPress() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
    }

    private func triggerDock() {
        guard !didTriggerDock, let manager else { return }
        didTriggerDock = true
        cancelLongPress()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        manager.showDock()
    }
}

// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    @State private var isPressed = false
    @State private var isDragging = false
    @State private var dragTranslation = CGSize.zero
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    
    private var iconSize: CGFloat {
        return dockManager.adaptiveIconSize
    }
    
    var body: some View {
        Group {
            if isLoading && appIcon == nil {
                LoadingIconView()
            } else if let icon = appIcon {
                IconImageView(icon: icon)
            } else {
                RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.3))
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
        .scaleEffect(isPressed ? 1.15 : 1.0)
        .offset(dragTranslation)
        .opacity(isDragging ? 0.6 : 1.0)
        .animation(.easeInOut(duration: 0.1), value: isPressed)
        .animation(.easeInOut(duration: 0.1), value: isDragging)
        .animation(.easeInOut(duration: MultitaskDockManager.Constants.standardAnimationDuration), value: dockManager.settingsChanged)
        .onAppear {
            loadAppIcon()
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !isPressed {
                        isPressed = true
                    }
                    // Dragging an icon outside the dock window closes the app
                    let moved = max(abs(value.translation.width), abs(value.translation.height))
                    if moved > 6 {
                        isDragging = true
                        dragTranslation = value.translation
                    }
                }
                .onEnded { value in
                    isPressed = false
                    let wasDragging = isDragging
                    isDragging = false
                    dragTranslation = .zero

                    if wasDragging {
                        if shouldTerminate(with: value.translation) {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            dockManager.terminateApp(app.appUUID)
                        }
                    } else {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID, from: value.startLocation)
                        dockManager.hideDock()
                    }
                }
        )
        .contentShape(Rectangle())
    }

    private func shouldTerminate(with translation: CGSize) -> Bool {
        // The dock hugs the right edge, so an icon is considered dragged out once it
        // travels clearly left past the panel, or up/down beyond the panel bounds.
        // Using the drag translation avoids SwiftUI/UIKit coordinate-space mismatches.
        let panelSize = dockManager.hostingController?.view.bounds.size ?? CGSize.zero
        let dockWidth = panelSize.width > 0 ? panelSize.width : dockManager.dockWidth
        let iconSize = dockManager.adaptiveIconSize

        let leftwardDistance = -translation.width
        let horizontalThreshold = max(iconSize * 0.5, dockWidth * 0.5, 24)
        let verticalThreshold = max(panelSize.height * 0.5, iconSize)

        return leftwardDistance > horizontalThreshold || abs(translation.height) > verticalThreshold
    }
    
    private func loadAppIcon() {
        let cacheKey = "\(app.appName)_\(app.appUUID)"
        
        if let cachedIcon = IconCacheManager.shared.getIcon(for: cacheKey) {
            self.appIcon = cachedIcon
            self.isLoading = false
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            var finalIcon: UIImage?
            
            if let appInfo = self.app.appInfo {
                finalIcon = appInfo.iconIsDarkIcon(darkModeIcon)
            } else {
                if let foundAppInfo = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                    finalIcon = foundAppInfo.iconIsDarkIcon(darkModeIcon)
                }
            }
            
            DispatchQueue.main.async {
                self.isLoading = false
                if let icon = finalIcon {
                    self.appIcon = icon
                    IconCacheManager.shared.setIcon(icon, for: cacheKey)
                }
            }
        }
    }
}

// MARK: - Press Gesture Helper
extension View {
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if value.translation == CGSize.zero {
                        onPress()
                    }
                }
                .onEnded { value in
                    onRelease(value.startLocation)
                }
        )
    }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.3))
            
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}

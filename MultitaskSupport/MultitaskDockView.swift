//
//  MultitaskDockView.swift
//  LiveContainer
//
//  Created by boa-z on 2025/6/28.
//  Refactored: Right-edge fixed dock with iOS home gesture style
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

// MARK: - MultitaskDockManager
@available(iOS 16.0, *)
@objc public class MultitaskDockManager: NSObject, ObservableObject {
    @objc public static let shared = MultitaskDockManager()

    @Published var apps: [DockAppModel] = []
    @Published var isVisible: Bool = false
    /// true = dock panel is open (slid in from right edge)
    @Published var isDockOpen: Bool = false
    @Published @objc var isCollapsed: Bool = false
    @Published var settingsChanged: Bool = false

    @objc public var windowHostingView = VirtualWindowsHostView()
    internal var hostingController: UIHostingController<AnyView>?

    // MARK: - Constants
    public struct Constants {
        /// Width of the visible dock panel when open
        static let dockPanelWidth: CGFloat = 80.0
        /// Width of the always-visible edge handle strip
        static let handleWidth: CGFloat = 6.0
        /// Icon size inside the dock panel
        static let iconSize: CGFloat = 52.0
        /// Spacing between icons
        static let iconSpacing: CGFloat = 12.0
        /// Vertical padding inside panel
        static let panelVerticalPadding: CGFloat = 20.0

        // Gesture thresholds
        /// Upward drag distance to trigger minimize (short gesture)
        static let minimizeThreshold: CGFloat = 30.0
        /// Leftward drag distance on handle to open dock (long-ish pull)
        static let openDockThreshold: CGFloat = 40.0
        /// Long-press duration to open dock
        static let longPressDuration: TimeInterval = 0.4

        // Animation
        static let springResponse: TimeInterval = 0.35
        static let springDamping: CGFloat = 0.8
        static let shortAnimDuration: TimeInterval = 0.15
        static let shortAnimDuration2: TimeInterval = 0.1
        static let bringToFrontScale: CGFloat = 1.02
        static let initialScale: CGFloat = 0.8
    }

    // MARK: - Window / Safe Area
    public var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }

    public var safeAreaInsets: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? .zero
    }

    // MARK: - Init
    override init() {
        super.init()
        keyWindow!.rootViewController!.view.subviews.first!.addSubview(self.windowHostingView)
        setupDockView()
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
    }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            if self.isVisible { self.updateDockFrame(animated: false) }
        }
    }

    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async {
            self.settingsChanged.toggle()
        }
    }

    // MARK: - Setup
    private func setupDockView() {
        DispatchQueue.main.async {
            let dockView = AnyView(
                MultitaskDockSwiftView()
                    .environmentObject(self)
            )
            self.hostingController = UIHostingController(rootView: dockView)
            self.hostingController?.view.backgroundColor = .clear
            self.hostingController?.view.isUserInteractionEnabled = true
        }
    }

    // MARK: - Frame (right edge, full height)
    /// The dock hosting view always covers the full right edge of the screen.
    /// Its width equals handleWidth + dockPanelWidth so the handle is always
    /// visible and the panel slides in/out via SwiftUI offset.
    private func fullEdgeFrame() -> CGRect {
        guard let win = keyWindow else { return .zero }
        let b = win.bounds
        let totalWidth = Constants.handleWidth + Constants.dockPanelWidth
        return CGRect(
            x: b.width - totalWidth,
            y: 0,
            width: totalWidth,
            height: b.height
        )
    }

    private func updateDockFrame(animated: Bool = true) {
        guard let hc = hostingController else { return }
        let frame = fullEdgeFrame()
        if animated {
            UIView.animate(
                withDuration: Constants.springResponse,
                delay: 0,
                usingSpringWithDamping: Constants.springDamping,
                initialSpringVelocity: 0.3,
                options: .curveEaseOut
            ) { hc.view.frame = frame }
        } else {
            hc.view.frame = frame
        }
    }

    // MARK: - Show / Hide dock (the whole overlay)
   @objc public func showDock() {
        guard isDockEnabled() else { return }
        guard !isVisible, let hc = hostingController else { return }

        DispatchQueue.main.async {
            self.isVisible = true
            if hc.view.superview == nil {
                self.keyWindow?.addSubview(hc.view)
            }
            hc.view.frame = self.fullEdgeFrame()
            hc.view.alpha = 0
            UIView.animate(withDuration: Constants.springResponse) {
                hc.view.alpha = 1
            }
        }
    }

    @objc public func hideDock() {
        guard isVisible, let hc = hostingController else { return }
        DispatchQueue.main.async {
            UIView.animate(withDuration: Constants.springResponse) {
                hc.view.alpha = 0
            } completion: { _ in
                self.isVisible = false
                self.isDockOpen = false
            }
        }
    }

    // MARK: - Open / Close panel
    @objc public func openDockPanel() {
        guard !isDockOpen else { return }
        withMainAnimation { self.isDockOpen = true }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    @objc public func closeDockPanel() {
        guard isDockOpen else { return }
        withMainAnimation { self.isDockOpen = false }
    }

    @objc public func toggleDockPanel() {
        isDockOpen ? closeDockPanel() : openDockPanel()
    }

    // MARK: - App management
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let appInfo = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(appInfo, appUUID: appUUID, view: view)
    }

    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        guard !apps.contains(where: { $0.appUUID == appUUID }) else { return }

        let appName = appInfo?.displayName() ?? "Unknown App"
        let appModel = DockAppModel(appName: appName, appUUID: appUUID, appInfo: appInfo, view: view)

        DispatchQueue.main.async {
            self.apps.append(appModel)
            if self.apps.count == 1 {
                self.showDock()
            }
        }
    }

    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        DispatchQueue.main.async {
            self.apps.removeAll { $0.appUUID == appUUID }
            if self.apps.isEmpty { self.hideDock() }
        }
    }

    // MARK: - Minimize
    @objc public func minimizeAllWindows(except: DecoratedAppSceneViewController? = nil) {
        DispatchQueue.main.async {
            self.apps.forEach { app in
                if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc != except {
                    app.view?.layer.removeAllAnimations()
                    vc.minimizeWindow()
                }
            }
        }
    }

    // MARK: - Bring to front
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return false }
        for window in windowScene.windows {
            if let targetView = apps.first(where: { $0.appUUID == uuid })?.view {
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

        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }

        if isHidden {
            view.layer.removeAllAnimations()
            view.isHidden = true
            view.transform = .identity
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let vc = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: vc) {
                pipManager.stopPiP()
            } else {
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                view.isHidden = false
                let smaller = min(view.frame.size.width, view.frame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let center { view.center = center }
            }
            bringViewToFront(view, in: window)
            UIView.animate(
                withDuration: Constants.springResponse,
                delay: 0,
                usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0,
                options: .curveEaseInOut
            ) {
                view.alpha = 1.0
                view.transform = .identity
                view.frame = origFrame
            }
        } else {
            bringViewToFront(view, in: window)
            UIView.animate(withDuration: Constants.shortAnimDuration) {
                view.transform = CGAffineTransform(scaleX: Constants.bringToFrontScale, y: Constants.bringToFrontScale)
            } completion: { _ in
                UIView.animate(withDuration: Constants.shortAnimDuration2) {
                    view.transform = .identity
                }
            }
        }
    }

    private func bringViewToFront(_ view: UIView, in window: UIWindow) {
        view.superview?.bringSubviewToFront(view)
        window.superview?.bringSubviewToFront(window)
    }

    // MARK: - Collapse (kept for compatibility)
    @objc public func toggleDockCollapse() {
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.notifyDockCollapseChanged()
        }
    }

    @objc public func notifyDockCollapseChanged() {
        self.apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }

    // MARK: - Helpers
    private func withMainAnimation(_ block: @escaping () -> Void) {
        DispatchQueue.main.async {
            withAnimation(.spring(response: Constants.springResponse, dampingFraction: Constants.springDamping)) {
                block()
            }
        }
    }

    private func isDockEnabled() -> Bool {
        let mode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return mode == .virtualWindow
    }
}

// MARK: - Root Dock SwiftUI View
/// This view fills the hosting controller frame (handleWidth + dockPanelWidth × full height).
/// The handle strip is always visible on the right edge.
/// The panel slides in from the right over the handle when isDockOpen == true.
@available(iOS 16.0, *)
public struct MultitaskDockSwiftView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                // 배경
                Rectangle()
                    .fill(Color.clear)
                    .background(Color.black.opacity(0.001))
                    .contentShape(Rectangle())
                    .onTapGesture { 
                        dockManager.closeDockPanel() 
                    }

                HStack(spacing: 0) {
                    Spacer()

                    VStack {
                        Spacer()
                        DockPanelView()
                            .frame(width: MultitaskDockManager.Constants.dockPanelWidth, height: geo.size.height * 0.8)
                            .opacity(dockManager.isDockOpen ? 1 : 0)
                            .allowsHitTesting(dockManager.isDockOpen)
                        Spacer()
                    }

                    EdgeHandleView()
                        .frame(width: MultitaskDockManager.Constants.handleWidth, height: geo.size.height)
                }
            }
        }
        .ignoresSafeArea()
        .animation(
            .spring(
                response: MultitaskDockManager.Constants.springResponse,
                dampingFraction: MultitaskDockManager.Constants.springDamping
            ),
            value: dockManager.isDockOpen
        )
    }

    public init() {}
}

// MARK: - Edge Handle View
/// Thin strip on the right edge. Receives all gestures:
///   - Short upward swipe  → minimize frontmost app
///   - Long press OR leftward drag past threshold → open dock panel
@available(iOS 16.0, *)
struct EdgeHandleView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager

    /// Tracks whether a long-press fired so we don't double-trigger
    @State private var longPressFired = false
    /// Tracks live drag translation for the pill animation
    @State private var dragTranslation: CGSize = .zero

    // Pill visual feedback: compress vertically while dragging up
    private var pillScale: CGSize {
        let upDrag = max(0, -dragTranslation.height)
        let compress = max(0.6, 1.0 - upDrag / 200)
        return CGSize(width: 1.0, height: compress)
    }

    var body: some View {
        ZStack {
            // Subtle background
            Rectangle()
                .fill(Color.white.opacity(0.08))

            // Pill indicator (like iOS home bar)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.white.opacity(0.5))
                .frame(width: 4, height: 35)
                .scaleEffect(x: pillScale.width, y: pillScale.height, anchor: .bottom)
                .animation(.interactiveSpring(), value: dragTranslation)
        }
        .contentShape(Rectangle())
        .gesture(
            SimultaneousGesture(
                // Long-press to open dock
                LongPressGesture(minimumDuration: MultitaskDockManager.Constants.longPressDuration)
                    .onEnded { _ in
                        longPressFired = true
                        dockManager.openDockPanel()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    },

                // Drag for minimize (up) or open dock (left)
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .onChanged { value in
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        defer {
                            dragTranslation = .zero
                            longPressFired = false
                        }
                        guard !longPressFired else { return }

                        let dx = value.translation.width   // negative = leftward (into screen)
                        let dy = value.translation.height  // negative = upward

                        let isUpward  = dy < -MultitaskDockManager.Constants.minimizeThreshold
                        let isLeftward = dx < -MultitaskDockManager.Constants.openDockThreshold

                        if isUpward && !isLeftward {
                            // Short upward swipe → minimize frontmost app
                            let frontVC = frontmostDecoratedVC()
                            if let vc = frontVC {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                vc.minimizeWindow()
                            } else {
                                // fallback: minimize all
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                dockManager.minimizeAllWindows()
                            }
                        } else if isLeftward {
                            // Leftward pull → open dock
                            dockManager.openDockPanel()
                        }
                    }
            )
        )
    }

    /// Returns the DecoratedAppSceneViewController whose window is currently
    /// frontmost (highest z-order, visible, not minimized).
    private func frontmostDecoratedVC() -> DecoratedAppSceneViewController? {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return nil }
        // Walk windows in reverse z-order; pick first non-hidden, non-minimized decorated VC
        let candidates = dockManager.apps.compactMap { app -> (UIView, DecoratedAppSceneViewController)? in
            guard let view = app.view,
                  let vc = view._viewDelegate() as? DecoratedAppSceneViewController,
                  !view.isHidden, view.alpha > 0.1 else { return nil }
            return (view, vc)
        }
        // Prefer the one whose superview has the highest subview index
        return candidates.max(by: { a, b in
            let ia = a.0.superview?.subviews.firstIndex(of: a.0) ?? 0
            let ib = b.0.superview?.subviews.firstIndex(of: b.0) ?? 0
            return ia < ib
        })?.1
    }
}

// MARK: - Dock Panel View
/// The actual app list panel that slides in from the right.
@available(iOS 16.0, *)
struct DockPanelView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Apps")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                // Close handle
                Image(systemName: "chevron.right")
                    .foregroundColor(.white.opacity(0.5))
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.2))

            // Scrollable app list
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: MultitaskDockManager.Constants.iconSpacing) {
                    ForEach(dockManager.apps) { app in
                        AppIconView(app: app)
                            .onTapGesture {
                                dockManager.closeDockPanel()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
                                }
                            }
                    }
                }
                .padding(.vertical, MultitaskDockManager.Constants.panelVerticalPadding)
                .padding(.horizontal, 8)
            }

            Divider().background(Color.white.opacity(0.2))

            // Minimize-all button
            Button {
                dockManager.closeDockPanel()
                dockManager.minimizeAllWindows()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "rectangle.stack.badge.minus")
                        .font(.caption)
                    Text("Minimize All")
                        .font(.caption)
                }
                .foregroundColor(.white.opacity(0.7))
                .padding(.vertical, 12)
            }
        }
        .modifier { content in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                content.glassEffect(.regular, in: .rect(cornerRadius: 0))
            } else {
                content.background(
                    Rectangle()
                        .fill(Color.black.opacity(0.75))
                        .overlay(
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                        )
                )
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 12, x: -4, y: 0)
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)

    private init() {}

    func getIcon(for key: String) -> UIImage? {
        cacheQueue.sync { cache[key] }
    }

    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) { self.cache[key] = icon }
    }

    func clearCache() {
        cacheQueue.async(flags: .barrier) { self.cache.removeAll() }
    }
}

// MARK: - App Icon View
@available(iOS 16.0, *)
struct AppIconView: View {
    let app: DockAppModel
    @State private var isPressed = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false

    private var iconSize: CGFloat { MultitaskDockManager.Constants.iconSize }

    var body: some View {
        Button {
            dockManager.closeDockPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let _ = dockManager.bringMultitaskViewToFront(uuid: app.appUUID)
            }
        } label: {
            VStack(spacing: 4) {
                Group {
                    if isLoading && appIcon == nil {
                        LoadingIconView()
                    } else if let icon = appIcon {
                        IconImageView(icon: icon)
                    } else {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.gray.opacity(0.3))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 3)
                .scaleEffect(isPressed ? 0.9 : 1.0)
                .animation(.easeInOut(duration: 0.1), value: isPressed)

                Text(app.appName)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: iconSize)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
    }
}

// MARK: - Press Gesture Helper
extension View {
    func onPressGesture(onPress: @escaping () -> Void, onRelease: @escaping (_ location: CGPoint) -> Void) -> some View {
        self.simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if value.translation == .zero { onPress() }
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
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.gray.opacity(0.3))
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}

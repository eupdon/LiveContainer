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
        if let appInfo = findAppInfoFromSharedModel(appName: appName, dataUUID: dataUUID) { return appInfo }
        if let appInfo = findAppInfo(byUUID: dataUUID) { return appInfo }
        return findAppInfo(byName: appName)
    }

    public func findAppInfo(byUUID dataUUID: String) -> LCAppInfo? {
        if let cached = cacheQueue.sync(execute: { infoCacheByUUID[dataUUID] }) { return cached }

        guard let appGroupPath = LCSharedUtils.appGroupPath()?.path else { return nil }
        let searchPaths = [
            "\(appGroupPath)/LiveContainer/Data/Application/\(dataUUID)/LCAppInfo.plist",
            "\(appGroupPath)/Containers/\(dataUUID)/LCAppInfo.plist",
            "\(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "")/Data/Application/\(dataUUID)/LCAppInfo.plist"
        ]
        for path in searchPaths {
            if FileManager.default.fileExists(atPath: path),
               let dict = NSDictionary(contentsOfFile: path),
               let bundlePath = dict["bundlePath"] as? String,
               let appInfo = LCAppInfo(bundlePath: bundlePath) {
                cacheQueue.async(flags: .barrier) { self.infoCacheByUUID[dataUUID] = appInfo }
                return appInfo
            }
        }
        return nil
    }

    public func findAppInfo(byName appName: String) -> LCAppInfo? {
        if let cached = cacheQueue.sync(execute: { infoCacheByName[appName] }) { return cached }

        var searchPaths: [String] = []
        if let p = LCSharedUtils.appGroupPath()?.path { searchPaths.append("\(p)/LiveContainer/Applications") }
        if let p = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path {
            searchPaths.append("\(p)/Applications")
        }

        for appsPath in searchPaths {
            guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: appsPath) else { continue }
            for dir in dirs where dir.hasSuffix(".app") {
                if let info = LCAppInfo(bundlePath: "\(appsPath)/\(dir)"), info.displayName() == appName {
                    cacheQueue.async(flags: .barrier) { self.infoCacheByName[appName] = info }
                    return info
                }
            }
        }
        return nil
    }

    private func findAppInfoFromSharedModel(appName: String, dataUUID: String) -> LCAppInfo? {
        let allApps = DataManager.shared.model.apps + DataManager.shared.model.hiddenApps
        for m in allApps {
            if m.appInfo.containers.contains(where: { $0.folderName == dataUUID }) { return m.appInfo }
        }
        for m in allApps {
            if m.appInfo.displayName() == appName { return m.appInfo }
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
    /// true = 독 패널이 화면 안(오른쪽 변)으로 슬라이드인 된 상태
    @Published var isDockOpen: Bool = false
    /// 하위호환 유지
    @Published @objc var isCollapsed: Bool = false
    @Published var settingsChanged: Bool = false

    @objc public var windowHostingView = VirtualWindowsHostView()

    /// 독 패널을 담는 호스팅 컨트롤러 (기본: 화면 오른쪽 밖에 위치)
    internal var dockHostingController: UIHostingController<AnyView>?
    /// 오른쪽 변 80% 제스처 전용 투명 UIView
    internal var gestureOverlayView: EdgeGestureView?
    /// 독이 열렸을 때 바깥 영역 탭으로 닫기 위한 투명 오버레이
    private var dismissOverlay: UIView?
    /// Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Constants
    public struct Constants {
        /// 독 패널 너비
        static let dockPanelWidth: CGFloat = 76.0
        /// 독 패널 최소 높이
        static let dockPanelMinHeight: CGFloat = 120.0
        /// 아이콘 크기
        static let iconSize: CGFloat = 52.0
        /// 아이콘 간격
        static let iconSpacing: CGFloat = 10.0
        /// 패널 내부 수직 패딩
        static let panelVerticalPadding: CGFloat = 16.0

        /// 오른쪽 변 제스처 영역 너비 (투명)
        static let gestureStripWidth: CGFloat = 22.0
        /// 오른쪽 변 상하 여백 비율 (각 10% → 80% 활성 영역)
        static let gestureStripEdgeRatio: CGFloat = 0.10

        // 제스처 임계값
        /// 짧은 스와이프 최솟값 (최소화 트리거)
        static let shortSwipeMinX: CGFloat = 15.0
        /// 긴 스와이프 임계값 (독 열기 트리거)
        static let longSwipeThreshold: CGFloat = 65.0
        /// 속도 기반 독 열기 임계값 (pt/s)
        static let swipeVelocityThreshold: CGFloat = 500.0

        // 애니메이션
        static let springResponse: TimeInterval = 0.38
        static let springDamping: CGFloat = 0.82
        static let shortAnim1: TimeInterval = 0.15
        static let shortAnim2: TimeInterval = 0.10
        static let bringToFrontScale: CGFloat = 1.03
    }

    // MARK: - Window
    public var keyWindow: UIWindow? {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first
    }
    public var safeAreaInsets: UIEdgeInsets {
        keyWindow?.safeAreaInsets ?? .zero
    }

    // MARK: - Init
    override init() {
        super.init()
        guard let win = keyWindow,
              let rootVC = win.rootViewController,
              let firstSubview = rootVC.view.subviews.first else { return }
        firstSubview.addSubview(self.windowHostingView)
        setupDockPanel()
        setupGestureOverlay()
        subscribeToDockState()
        NotificationCenter.default.addObserver(self, selector: #selector(userDefaultsDidChange),
                                               name: UserDefaults.didChangeNotification,
                                               object: LCUtils.appGroupUserDefault)
        NotificationCenter.default.addObserver(self, selector: #selector(deviceOrientationDidChange),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func deviceOrientationDidChange() {
        DispatchQueue.main.async {
            self.updateDockFrame(animated: false)
            self.updateGestureOverlayFrame()
        }
    }

    @objc private func userDefaultsDidChange() {
        DispatchQueue.main.async { self.settingsChanged.toggle() }
    }

    // MARK: - 독 패널 setup
    private func setupDockPanel() {
        DispatchQueue.main.async {
            let view = AnyView(DockPanelView().environmentObject(self))
            let hc = UIHostingController(rootView: view)
            hc.view.backgroundColor = .clear
            hc.view.isUserInteractionEnabled = true
            self.dockHostingController = hc
            guard let win = self.keyWindow else { return }
            win.addSubview(hc.view)
            // 처음엔 화면 밖(숨김) 위치로 배치
            hc.view.frame = self.dockHiddenFrame()
        }
    }

    // MARK: - 제스처 오버레이 setup (오른쪽 변 80%)
    private func setupGestureOverlay() {
        DispatchQueue.main.async {
            guard let win = self.keyWindow else { return }
            let overlay = EdgeGestureView(manager: self)
            overlay.backgroundColor = .clear
            win.addSubview(overlay)
            self.gestureOverlayView = overlay
            self.updateGestureOverlayFrame()
        }
    }

    /// isDockOpen 변화 구독 → DismissOverlay show/hide
    private func subscribeToDockState() {
        $isDockOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOpen in
                if isOpen { self?.showDismissOverlay() } else { self?.hideDismissOverlay() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 독 패널 프레임 계산

    /// 화면 밖 숨김 위치: 오른쪽 변 중앙, X는 화면 우측 끝 밖
    private func dockHiddenFrame() -> CGRect {
        guard let win = keyWindow else { return .zero }
        let bounds = win.bounds
        let h = dockPanelHeight()
        return CGRect(
            x: bounds.width,                   // 화면 밖
            y: (bounds.height - h) / 2,
            width: Constants.dockPanelWidth,
            height: h
        )
    }

    /// 화면 안 열림 위치: 오른쪽 변 중앙 (safe area 고려)
    private func dockOpenFrame() -> CGRect {
        guard let win = keyWindow else { return .zero }
        let bounds = win.bounds
        let h = dockPanelHeight()
        let safeRight = safeAreaInsets.right
        return CGRect(
            x: bounds.width - Constants.dockPanelWidth - safeRight,
            y: (bounds.height - h) / 2,
            width: Constants.dockPanelWidth,
            height: h
        )
    }

    /// 앱 수에 따른 동적 패널 높이
    private func dockPanelHeight() -> CGFloat {
        let count = max(1, apps.count)
        let icons = CGFloat(count) * Constants.iconSize + CGFloat(count - 1) * Constants.iconSpacing
        return max(Constants.dockPanelMinHeight, icons + Constants.panelVerticalPadding * 2)
    }

    func updateDockFrame(animated: Bool = true) {
        guard let hc = dockHostingController else { return }
        let target = isDockOpen ? dockOpenFrame() : dockHiddenFrame()
        if animated {
            UIView.animate(
                withDuration: Constants.springResponse,
                delay: 0,
                usingSpringWithDamping: Constants.springDamping,
                initialSpringVelocity: 0.3,
                options: .curveEaseOut
            ) { hc.view.frame = target }
        } else {
            hc.view.frame = target
        }
    }

    func updateGestureOverlayFrame() {
        guard let win = keyWindow, let overlay = gestureOverlayView else { return }
        let bounds = win.bounds
        let margin = bounds.height * Constants.gestureStripEdgeRatio
        overlay.frame = CGRect(
            x: bounds.width - Constants.gestureStripWidth,
            y: margin,
            width: Constants.gestureStripWidth,
            height: bounds.height - margin * 2
        )
        // 제스처 오버레이 → 독 패널보다 아래에 위치 (독이 열리면 패널이 위에 있어야 함)
        if let hc = dockHostingController {
            win.insertSubview(overlay, belowSubview: hc.view)
        } else {
            win.bringSubviewToFront(overlay)
        }
    }

    // MARK: - 독 열기 / 닫기
    @objc public func openDock() {
        guard !isDockOpen else { return }
        DispatchQueue.main.async {
            // 먼저 숨김 위치로 snap (높이 변경 대응)
            self.dockHostingController?.view.frame = self.dockHiddenFrame()
            self.isDockOpen = true
            self.updateDockFrame(animated: true)
            // 독 패널을 화면 최상단으로
            if let win = self.keyWindow, let hc = self.dockHostingController {
                win.bringSubviewToFront(hc.view)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    @objc public func closeDock() {
        guard isDockOpen else { return }
        DispatchQueue.main.async {
            self.isDockOpen = false
            self.updateDockFrame(animated: true)
        }
    }

    // MARK: - 바깥 탭 오버레이 (독 닫기)
    private func showDismissOverlay() {
        guard dismissOverlay == nil, let win = keyWindow else { return }
        let overlay = UIView(frame: win.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissOverlayTapped))
        overlay.addGestureRecognizer(tap)
        // 독 패널 바로 아래에 삽입
        if let hc = dockHostingController {
            win.insertSubview(overlay, belowSubview: hc.view)
        } else {
            win.addSubview(overlay)
        }
        dismissOverlay = overlay
    }

    private func hideDismissOverlay() {
        dismissOverlay?.removeFromSuperview()
        dismissOverlay = nil
    }

    @objc private func dismissOverlayTapped() {
        closeDock()
    }

    // MARK: - 짧은 스와이프: 모든 앱 최소화 + 앱 목록 화면 표시
    @objc public func minimizeAllAndShowAppList() {
        DispatchQueue.main.async {
            self.minimizeAllWindows()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // LiveContainer 앱 목록 화면으로 전환 노티
            NotificationCenter.default.post(
                name: NSNotification.Name("LCShowAppListFromGesture"),
                object: nil
            )
        }
    }

    // MARK: - 앱 전환 (아이콘 탭)
    func switchToApp(uuid: String) {
        closeDock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.springResponse * 0.5) {
            let _ = self.bringMultitaskViewToFront(uuid: uuid)
        }
    }

    // MARK: - 앱 관리
    @objc public func addRunningApp(_ appName: String, appUUID: String, view: UIView?) {
        let info = AppInfoProvider.shared.findAppInfo(appName: appName, dataUUID: appUUID)
        addRunningAppWithInfo(info, appUUID: appUUID, view: view)
    }

    @objc public func addRunningAppWithInfo(_ appInfo: LCAppInfo?, appUUID: String, view: UIView?) {
        guard isDockEnabled() else { return }
        guard !apps.contains(where: { $0.appUUID == appUUID }) else { return }
        let name = appInfo?.displayName() ?? "Unknown App"
        let model = DockAppModel(appName: name, appUUID: appUUID, appInfo: appInfo, view: view)
        DispatchQueue.main.async {
            self.apps.append(model)
            // 앱 수 변화에 따른 패널 높이 갱신 (숨겨진 상태에서도 위치 미리 갱신)
            if !self.isDockOpen { self.updateDockFrame(animated: false) }
        }
    }

    @objc public func removeRunningApp(_ appUUID: String) {
        guard isDockEnabled() else { return }
        DispatchQueue.main.async {
            self.apps.removeAll { $0.appUUID == appUUID }
            if !self.isDockOpen { self.updateDockFrame(animated: false) }
        }
    }

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

    // MARK: - 앱 최전면 전환
    func bringMultitaskViewToFront(uuid: String, from center: CGPoint? = nil) -> Bool {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return false }
        guard let targetView = apps.first(where: { $0.appUUID == uuid })?.view else { return false }

        if let launchUrl = UserDefaults.standard.string(forKey: "launchAppUrlScheme") {
            UserDefaults.standard.removeObject(forKey: "launchAppUrlScheme")
            if let vc = targetView._viewDelegate() as? DecoratedAppSceneViewController {
                vc.appSceneVC.openURLScheme(launchUrl)
            }
        }
        for window in windowScene.windows {
            animateViewAppearance(targetView, from: center, in: window)
        }
        return true
    }

    private func animateViewAppearance(_ view: UIView, from center: CGPoint?, in window: UIWindow) {
        let isHidden = view.isHidden || view.alpha < 0.1
        let decoratedVC = view._viewDelegate() as? DecoratedAppSceneViewController
        let isMaximized = decoratedVC?.isMaximized ?? false

        if UserDefaults.lcShared().bool(forKey: "LCMaxOneAppOnStage") && isMaximized {
            MultitaskDockManager.shared.minimizeAllWindows(except: decoratedVC)
        }

        view.superview?.bringSubviewToFront(view)
        window.superview?.bringSubviewToFront(window)

        if isHidden {
            view.layer.removeAllAnimations()
            let origFrame = view.frame
            let pipManager = PiPManager.shared!
            if let vc = view._viewDelegate(), pipManager.isPiP(withDecoratedVC: vc) {
                pipManager.stopPiP()
            } else {
                view.isHidden = false
                view.alpha = 0
                view.transform = CGAffineTransform(scaleX: 0.1, y: 0.1)
                let smaller = min(origFrame.size.width, origFrame.size.height)
                view.frame.size = CGSize(width: smaller, height: smaller)
                if let c = center { view.center = c }
            }
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
            UIView.animate(withDuration: Constants.shortAnim1) {
                view.transform = CGAffineTransform(
                    scaleX: Constants.bringToFrontScale,
                    y: Constants.bringToFrontScale
                )
            } completion: { _ in
                UIView.animate(withDuration: Constants.shortAnim2) {
                    view.transform = .identity
                }
            }
        }
    }

    // MARK: - 하위호환 stubs
    @objc public func showDock() {}
    @objc public func hideDock() {}

    @objc public func toggleDockCollapse() {
        DispatchQueue.main.async {
            self.isCollapsed.toggle()
            self.notifyDockCollapseChanged()
        }
    }

    @objc public func notifyDockCollapseChanged() {
        apps.forEach { app in
            if let vc = app.view?._viewDelegate() as? DecoratedAppSceneViewController, vc.isMaximized {
                vc.updateVerticalConstraints()
            }
        }
    }

    // MARK: - Helper
    private func isDockEnabled() -> Bool {
        let mode = MultitaskMode(rawValue: LCUtils.appGroupUserDefault.integer(forKey: "LCMultitaskMode")) ?? .virtualWindow
        return mode == .virtualWindow
    }
}

// MARK: - EdgeGestureView
/// 오른쪽 변 80% 영역을 덮는 완전 투명 UIView.
/// 짧은 왼쪽 스와이프 → 최소화+앱 목록 / 긴 왼쪽 스와이프 → 독 열기
@available(iOS 16.0, *)
class EdgeGestureView: UIView {
    private weak var manager: MultitaskDockManager?
    private var touchStart: CGPoint = .zero
    private var touchStartTime: TimeInterval = 0

    init(manager: MultitaskDockManager) {
        self.manager = manager
        super.init(frame: .zero)
        isUserInteractionEnabled = true
    }
    required init?(coder: NSCoder) { fatalError() }

    // 독이 열려 있으면 이 뷰는 터치를 받지 않음 → 독 패널과 dismiss 오버레이가 처리
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let mgr = manager, !mgr.isDockOpen else { return nil }
        return bounds.contains(point) ? self : nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        touchStart = t.location(in: self)
        touchStartTime = t.timestamp
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let mgr = manager else { return }

        let end = t.location(in: self)
        // 왼쪽으로 이동한 거리 (양수 = 왼쪽)
        let dx = touchStart.x - end.x
        let dy = abs(touchStart.y - end.y)
        let dt = t.timestamp - touchStartTime
        let velocityX = dt > 0 ? dx / dt : 0

        // 수평 스와이프인지 확인 (세로 이동이 가로의 80% 미만)
        guard dy < dx * 1.5, dx >= MultitaskDockManager.Constants.shortSwipeMinX else { return }

        let isLong = dx >= MultitaskDockManager.Constants.longSwipeThreshold
        let isFast = velocityX >= MultitaskDockManager.Constants.swipeVelocityThreshold

        if isLong || isFast {
            // 긴 스와이프 or 빠른 스와이프 → 독 열기
            mgr.openDock()
        } else {
            // 짧은 스와이프 → 모든 앱 최소화 + 앱 목록 표시
            mgr.minimizeAllAndShowAppList()
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
}

// MARK: - DockPanelView (SwiftUI)
@available(iOS 16.0, *)
struct DockPanelView: View {
    @EnvironmentObject var dockManager: MultitaskDockManager

    var body: some View {
        VStack(spacing: MultitaskDockManager.Constants.iconSpacing) {
            ForEach(dockManager.apps) { app in
                DockIconView(app: app)
            }
        }
        .padding(.vertical, MultitaskDockManager.Constants.panelVerticalPadding)
        .padding(.horizontal, 10)
        .frame(width: MultitaskDockManager.Constants.dockPanelWidth)
        .modifier { content in
            if #available(iOS 26.0, *), SharedModel.isLiquidGlassEnabled {
                content.glassEffect(.regular, in: .rect(cornerRadius: 20))
            } else {
                content
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
                            )
                    )
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 16, x: -4, y: 0)
    }
}

// MARK: - DockIconView (SwiftUI)
@available(iOS 16.0, *)
struct DockIconView: View {
    let app: DockAppModel
    @EnvironmentObject var dockManager: MultitaskDockManager
    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) var darkModeIcon = false
    @State private var appIcon: UIImage?
    @State private var isLoading = true
    @State private var isPressed = false

    private let iconSize = MultitaskDockManager.Constants.iconSize

    var body: some View {
        Button {
            dockManager.switchToApp(uuid: app.appUUID)
        } label: {
            VStack(spacing: 4) {
                Group {
                    if isLoading && appIcon == nil {
                        LoadingIconView()
                    } else if let icon = appIcon {
                        IconImageView(icon: icon)
                    } else {
                        RoundedRectangle(cornerRadius: 13)
                            .fill(Color.gray.opacity(0.35))
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                .scaleEffect(isPressed ? 0.88 : 1.0)
                .animation(.easeInOut(duration: 0.08), value: isPressed)

                Text(app.appName)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: iconSize)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded   { _ in isPressed = false }
        )
        .onAppear { loadIcon() }
    }

    private func loadIcon() {
        let key = "\(app.appName)_\(app.appUUID)"
        if let cached = IconCacheManager.shared.getIcon(for: key) {
            appIcon = cached; isLoading = false; return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var img: UIImage?
            if let info = self.app.appInfo {
                img = info.iconIsDarkIcon(self.darkModeIcon)
            } else if let found = AppInfoProvider.shared.findAppInfo(appName: self.app.appName, dataUUID: self.app.appUUID) {
                img = found.iconIsDarkIcon(self.darkModeIcon)
            }
            DispatchQueue.main.async {
                self.isLoading = false
                if let i = img {
                    self.appIcon = i
                    IconCacheManager.shared.setIcon(i, for: key)
                }
            }
        }
    }
}

// MARK: - Icon Cache Manager
class IconCacheManager {
    static let shared = IconCacheManager()
    private var cache: [String: UIImage] = [:]
    private let cacheQueue = DispatchQueue(label: "icon.cache.queue", attributes: .concurrent)
    private init() {}

    func getIcon(for key: String) -> UIImage? { cacheQueue.sync { cache[key] } }
    func setIcon(_ icon: UIImage, for key: String) {
        cacheQueue.async(flags: .barrier) { self.cache[key] = icon }
    }
    func clearCache() { cacheQueue.async(flags: .barrier) { self.cache.removeAll() } }
}

// MARK: - Loading Icon View
struct LoadingIconView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13).fill(Color.gray.opacity(0.3))
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(1.2)
        }
    }
}

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

    /// 제스처 전용 별도 UIWindow
    /// 게스트 앱이 keyWindow 위에 올라와도 이 window는 항상 최상단에 위치함
    private var gestureWindow: EdgeGestureWindow?

    /// 독이 열렸을 때 바깥 탭으로 닫는 투명 오버레이
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

        /// 오른쪽 변 제스처 영역 너비
        static let gestureStripWidth: CGFloat = 22.0
        /// 오른쪽 변 상하 여백 비율 (각 10% → 80% 활성 영역)
        static let gestureStripEdgeRatio: CGFloat = 0.10

        // 시간 기반 제스처 임계값
        /// 이 시간 이내에 터치를 떼면 "짧게" → 최소화
        static let shortGestureMaxDuration: TimeInterval = 0.4
        /// 이 시간 이상 터치를 유지하면 "길게" → 독 열기 (햅틱 피드백 발생)
        static let longGestureMinDuration: TimeInterval = 0.4
        /// 제스처로 인정할 최소 이동 거리 (손이 살짝 움직인 것 무시)
        static let minSwipeDistance: CGFloat = 8.0

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
        setupGestureWindow()
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
            self.updateGestureWindowFrame()
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
            hc.view.frame = self.dockHiddenFrame()
        }
    }

    // MARK: - 제스처 전용 별도 UIWindow setup
    /// keyWindow와 완전히 별도의 UIWindow를 만들어 windowLevel을 높게 설정.
    /// 게스트 앱이 keyWindow의 어떤 서브뷰보다 위에 올라와도 이 window는 항상 그 위에 있음.
    private func setupGestureWindow() {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            let gw = EdgeGestureWindow(windowScene: scene, manager: self)
            // .alert + 1 → 게스트 앱 UIWindow를 포함한 모든 앱 레이어 위에 위치
            // 시스템 알림(alert)보다도 위지만 제스처 영역만 터치를 수신하므로 UX 방해 없음
            gw.windowLevel = UIWindow.Level.alert + 1
            gw.backgroundColor = .clear
            gw.isHidden = false
            self.gestureWindow = gw
            self.updateGestureWindowFrame()
        }
    }

    /// 오른쪽 변 80% 영역 프레임 갱신
    func updateGestureWindowFrame() {
        guard let win = keyWindow, let gw = gestureWindow else { return }
        let bounds = win.bounds
        let margin = bounds.height * Constants.gestureStripEdgeRatio
        gw.frame = CGRect(
            x: bounds.width - Constants.gestureStripWidth,
            y: margin,
            width: Constants.gestureStripWidth,
            height: bounds.height - margin * 2
        )
    }

    // MARK: - isDockOpen 구독 → dismissOverlay 관리
    private func subscribeToDockState() {
        $isDockOpen
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isOpen in
                if isOpen { self?.showDismissOverlay() } else { self?.hideDismissOverlay() }
            }
            .store(in: &cancellables)
    }

    // MARK: - 독 패널 프레임 계산

    private func dockHiddenFrame() -> CGRect {
        guard let win = keyWindow else { return .zero }
        let bounds = win.bounds
        let h = dockPanelHeight()
        return CGRect(x: bounds.width, y: (bounds.height - h) / 2,
                      width: Constants.dockPanelWidth, height: h)
    }

    private func dockOpenFrame() -> CGRect {
        guard let win = keyWindow else { return .zero }
        let bounds = win.bounds
        let h = dockPanelHeight()
        let safeRight = safeAreaInsets.right
        return CGRect(x: bounds.width - Constants.dockPanelWidth - safeRight,
                      y: (bounds.height - h) / 2,
                      width: Constants.dockPanelWidth, height: h)
    }

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

    // MARK: - 독 열기 / 닫기
    @objc public func openDock() {
        guard !isDockOpen else { return }
        DispatchQueue.main.async {
            self.dockHostingController?.view.frame = self.dockHiddenFrame()
            self.isDockOpen = true
            self.updateDockFrame(animated: true)
            if let win = self.keyWindow, let hc = self.dockHostingController {
                win.bringSubviewToFront(hc.view)
            }
        }
    }

    @objc public func closeDock() {
        guard isDockOpen else { return }
        DispatchQueue.main.async {
            self.isDockOpen = false
            self.updateDockFrame(animated: true)
        }
    }

    // MARK: - 바깥 탭 오버레이
    private func showDismissOverlay() {
        guard dismissOverlay == nil, let win = keyWindow else { return }
        let overlay = UIView(frame: win.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissOverlayTapped))
        overlay.addGestureRecognizer(tap)
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

    // MARK: - 짧게: 모든 앱 최소화 + 앱 목록 표시
    @objc public func minimizeAllAndShowAppList() {
        DispatchQueue.main.async {
            self.minimizeAllWindows()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            NotificationCenter.default.post(
                name: NSNotification.Name("LCShowAppListFromGesture"),
                object: nil
            )
        }
    }

    // MARK: - 앱 전환
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
                delay: 0, usingSpringWithDamping: 1.0,
                initialSpringVelocity: 0, options: .curveEaseInOut
            ) {
                view.alpha = 1.0
                view.transform = .identity
                view.frame = origFrame
            }
        } else {
            UIView.animate(withDuration: Constants.shortAnim1) {
                view.transform = CGAffineTransform(scaleX: Constants.bringToFrontScale,
                                                    y: Constants.bringToFrontScale)
            } completion: { _ in
                UIView.animate(withDuration: Constants.shortAnim2) { view.transform = .identity }
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

// MARK: - EdgeGestureWindow
/// 게스트 앱이 keyWindow 위를 덮어도 항상 그 위에 있는 별도 UIWindow.
/// windowLevel = .alert - 1 로 설정하여 게스트 앱 뷰보다 항상 위에 위치.
/// hitTest를 통해 독이 열린 상태에서는 터치를 통과시키고,
/// 닫힌 상태에서만 제스처 뷰가 터치를 처리.
@available(iOS 16.0, *)
class EdgeGestureWindow: UIWindow {
    private weak var manager: MultitaskDockManager?
    private let gestureView: EdgeGestureView

    init(windowScene: UIWindowScene, manager: MultitaskDockManager) {
        self.manager = manager
        self.gestureView = EdgeGestureView(manager: manager)
        super.init(windowScene: windowScene)
        self.rootViewController = EdgeGestureHostViewController(contentView: gestureView)
        self.backgroundColor = .clear
        self.isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 독이 열려 있거나 제스처 영역 밖이면 터치를 통과시킴
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let mgr = manager, !mgr.isDockOpen else { return nil }
        guard let gvc = rootViewController as? EdgeGestureHostViewController else { return nil }
        let converted = gvc.contentView.convert(point, from: self)
        guard gvc.contentView.bounds.contains(converted) else { return nil }
        return gvc.contentView
    }
}

/// EdgeGestureWindow의 rootViewController - 배경 없이 gestureView만 표시
@available(iOS 16.0, *)
class EdgeGestureHostViewController: UIViewController {
    let contentView: UIView  // EdgeGestureWindow.hitTest에서 접근

    init(contentView: UIView) {
        self.contentView = contentView
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.addSubview(contentView)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }
}

// MARK: - EdgeGestureView
/// 오른쪽 변 80% 영역의 실제 제스처 처리 뷰.
///
/// iOS 홈 버튼 제스처와 동일한 방식:
///   - 짧게 터치 후 떼기  (< 0.4초) → 모든 앱 최소화 + 앱 목록 표시
///   - 길게 누르고 있기   (≥ 0.4초, 햅틱 발생) → 터치 떼면 독 열기
@available(iOS 16.0, *)
class EdgeGestureView: UIView {
    private weak var manager: MultitaskDockManager?

    private var touchBeganTime: TimeInterval = 0
    private var longPressTriggered: Bool = false
    /// 길게 누르기 임계값 도달 시 실행되는 타이머
    private var longPressTimer: Timer?

    init(manager: MultitaskDockManager) {
        self.manager = manager
        super.init(frame: .zero)
        isUserInteractionEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        touchBeganTime = t.timestamp
        longPressTriggered = false

        // 길게 누르기 타이머 시작
        longPressTimer?.invalidate()
        longPressTimer = Timer.scheduledTimer(
            withTimeInterval: MultitaskDockManager.Constants.longGestureMinDuration,
            repeats: false
        ) { [weak self] _ in
            guard let self = self else { return }
            // 임계값 도달 → 햅틱으로 피드백 (아직 열지는 않고 손가락 떼는 것을 기다림)
            self.longPressTriggered = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        guard let mgr = manager else { return }

        if longPressTriggered {
            // 길게 눌렀다가 뗌 → 독 열기
            mgr.openDock()
        } else {
            // 짧게 뗌 → 최소화 + 앱 목록
            mgr.minimizeAllAndShowAppList()
        }

        longPressTriggered = false
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPressTimer?.invalidate()
        longPressTimer = nil
        longPressTriggered = false
    }
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

//
//  LCAppGridItem.swift
//  LiveContainerSwiftUI
//
//  Home screen style grid item for the app list.
//

import SwiftUI
import UIKit

struct LCAppGridItem: View {
    @ObservedObject var model: LCAppModel

    var onRun: (Bool?) -> Void
    var menuProvider: () -> [LCAppMenuItem]

    @AppStorage("darkModeIcon", store: LCUtils.appGroupUserDefault) private var darkModeIcon = false

    private let iconSize: CGFloat = 60
    private let iconCornerRadius: CGFloat = 13.5

    init(model: LCAppModel,
         onRun: @escaping (Bool?) -> Void,
         menuProvider: @escaping () -> [LCAppMenuItem]) {
        self._model = ObservedObject(wrappedValue: model)
        self.onRun = onRun
        self.menuProvider = menuProvider
    }

    var body: some View {
        Button {
            onRun(nil)
        } label: {
            VStack(spacing: 7) {
                iconView
                Text(model.displayName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LCAppGridButtonStyle())
        .contextMenu {
            menuContent
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.displayName)
        .accessibilityAddTraits(.isButton)
    }

    private var iconView: some View {
        Image(uiImage: model.appInfo.iconIsDarkIcon(darkModeIcon) ?? UIImage())
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: iconSize, height: iconSize)
            .clipShape(RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous))
            .overlay {
                if model.isAppRunning {
                    RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(0.25))
                }
            }
            .overlay {
                if model.isSigningInProgress {
                    ZStack {
                        RoundedRectangle(cornerRadius: iconCornerRadius, style: .continuous)
                            .fill(Color.black.opacity(0.45))
                        Circle()
                            .trim(from: 0, to: CGFloat(max(0.02, min(model.signProgress, 1))))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 26, height: 26)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if model.uiIsLocked && !model.uiIsHidden {
                    badge(systemImage: "lock.fill", background: sharedBadgeColor, size: 16)
                        .offset(x: -6, y: -6)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                HStack(spacing: 2) {
                    if model.uiIsShared {
                        badge(systemImage: "arrowshape.turn.up.left.fill", background: sharedBadgeColor, size: 14)
                    }
                    if model.uiIsJITNeeded {
                        badge(systemImage: "bolt.fill", background: jitBadgeColor, size: 14)
                    }
#if is32BitSupported
                    if model.uiIs32bit {
                        badge(text: "32", background: bit32BadgeColor, size: 14)
                    }
#endif
                }
                .offset(x: 4, y: 4)
            }
    }

    @ViewBuilder
    private var menuContent: some View {
        let items = menuProvider()
        ForEach(items) { item in
            if item.children.isEmpty {
                menuButton(item)
            } else {
                Menu {
                    ForEach(item.children) { child in
                        menuButton(child)
                    }
                } label: {
                    Label(item.title, systemImage: item.systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private func menuButton(_ item: LCAppMenuItem) -> some View {
        let role: ButtonRole? = item.role == .destructive ? .destructive : nil
        let systemImage = item.systemImage.isEmpty && item.isChecked ? "checkmark" : item.systemImage
        Button(role: role) {
            item.action?()
        } label: {
            Label {
                Text(item.title)
            } icon: {
                if !systemImage.isEmpty {
                    Image(systemName: systemImage)
                }
            }
        }
    }

    @ViewBuilder
    private func badge(systemImage: String, background: Color, size: CGFloat) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.55, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1))
    }

#if is32BitSupported
    @ViewBuilder
    private func badge(text: String, background: Color, size: CGFloat) -> some View {
        Text(text)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(background)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1))
    }
#endif

    private var sharedBadgeColor: Color {
        return Color(uiColor: UIColor(named: "BadgeColor") ?? .systemOrange)
    }

    private var jitBadgeColor: Color {
        return Color(uiColor: UIColor(named: "JITBadgeColor") ?? .systemPurple)
    }

#if is32BitSupported
    private var bit32BadgeColor: Color {
        return Color(uiColor: UIColor(named: "32BitBadgeColor") ?? .systemBlue)
    }
#endif
}

struct LCAppGridButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct LCAppGridSkeletonItem: View {
    var body: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 60, height: 60)
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 46, height: 10)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 32, height: 8)
            }
            .frame(height: 30, alignment: .top)
        }
    }
}

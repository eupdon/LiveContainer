//
//  LCAppContextMenu.swift
//  LiveContainerSwiftUI
//
//  Shared app context menu model, builder and actions used by both
//  the home screen style grid and the list style banner.
//

import Foundation
import UIKit

struct LCAppMenuItem: Identifiable {
    enum Role: Equatable {
        case normal
        case destructive
    }

    let id: String
    let title: String
    let systemImage: String
    var role: Role = .normal
    var isChecked: Bool = false
    // UIKit renders this item as an inline UIMenu (used for the container picker).
    var isInlineMenu: Bool = false
    var children: [LCAppMenuItem] = []
    var action: (() -> Void)? = nil
}

struct LCAppMenuHandlers {
    var selectContainer: (LCContainer) -> Void
    var openDataFolder: () -> Void
    var run: (Bool?) -> Void
    var copyLaunchURL: () -> Void
    var saveAppIcon: () -> Void
    var createAppClip: () -> Void
    var openSettings: () -> Void
    var uninstall: () -> Void
}

enum LCAppMenuBuilder {
    static func items(for model: LCAppModel, handlers: LCAppMenuHandlers) -> [LCAppMenuItem] {
        var items: [LCAppMenuItem] = []

        if model.uiContainers.count > 1 {
            let containerItems = model.uiContainers.map { container in
                LCAppMenuItem(
                    id: "container-\(container.folderName)",
                    title: container.name,
                    // UIKit draws the checkmark from the item state; SwiftUI derives it
                    // from isChecked so both styles show a single checkmark.
                    systemImage: "",
                    isChecked: container == model.uiSelectedContainer,
                    action: { handlers.selectContainer(container) }
                )
            }
            items.append(LCAppMenuItem(
                id: "containers",
                title: "lc.common.container".loc,
                systemImage: "shippingbox",
                isInlineMenu: true,
                children: containerItems
            ))
        }

        if !model.uiIsShared, model.uiSelectedContainer != nil {
            items.append(action(
                id: "openDataFolder",
                title: "lc.appBanner.openDataFolder".loc,
                systemImage: "folder",
                handler: handlers.openDataFolder
            ))
        }

        if #available(iOS 16.0, *) {
            let shouldLaunchInMultitaskMode = model.shouldLaunchInMultitaskMode
            items.append(action(
                id: "run",
                title: shouldLaunchInMultitaskMode ? "lc.appBanner.run".loc : "lc.appBanner.multitask".loc,
                systemImage: shouldLaunchInMultitaskMode ? "play.fill" : "macwindow.badge.plus",
                handler: { handlers.run(!shouldLaunchInMultitaskMode) }
            ))
        }

        items.append(LCAppMenuItem(
            id: "addToHomeScreen",
            title: "lc.appBanner.addToHomeScreen".loc,
            systemImage: "plus.app",
            children: [
                action(id: "copyLaunchURL", title: "lc.appBanner.copyLaunchUrl".loc, systemImage: "link", handler: handlers.copyLaunchURL),
                action(id: "saveAppIcon", title: "lc.appBanner.saveAppIcon".loc, systemImage: "square.and.arrow.down", handler: handlers.saveAppIcon),
                action(id: "createAppClip", title: "lc.appBanner.createAppClip".loc, systemImage: "appclip", handler: handlers.createAppClip)
            ]
        ))

        items.append(action(
            id: "settings",
            title: "lc.tabView.settings".loc,
            systemImage: "gear",
            handler: handlers.openSettings
        ))

        if !model.uiIsShared {
            items.append(action(
                id: "uninstall",
                title: "lc.appBanner.uninstall".loc,
                systemImage: "trash",
                role: .destructive,
                handler: handlers.uninstall
            ))
        }

        return items
    }

    private static func action(id: String,
                               title: String,
                               systemImage: String,
                               role: LCAppMenuItem.Role = .normal,
                               handler: @escaping () -> Void) -> LCAppMenuItem {
        return LCAppMenuItem(
            id: id,
            title: title,
            systemImage: systemImage,
            role: role,
            action: handler
        )
    }
}

enum LCAppMenuActions {
    static func launchURL(for model: LCAppModel) -> String? {
        guard let relativeBundlePath = model.appInfo.relativeBundlePath else {
            return nil
        }
        if let folderName = model.uiSelectedContainer?.folderName {
            return "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)&container-folder-name=\(folderName)"
        } else {
            return "livecontainer://livecontainer-launch?bundle-name=\(relativeBundlePath)"
        }
    }

    static func openDataFolder(for model: LCAppModel) {
        guard let folderName = model.uiSelectedContainer?.folderName,
              let url = URL(string: "shareddocuments://\(LCPath.dataPath.path)/\(folderName)") else {
            return
        }
        UIApplication.shared.open(url)
    }

    static func removeBundle(_ model: LCAppModel) throws {
        guard let bundlePath = model.appInfo.bundlePath() else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.removeItem(atPath: bundlePath)
    }

    static func removeContainers(_ containers: [LCContainer]) throws {
        for container in containers {
            let dataUUID = container.folderName
            try FileManager.default.removeItem(at: LCPath.dataPath.appendingPathComponent(dataUUID))
            LCUtils.removeAppKeychain(dataUUID: dataUUID)
        }
    }

    static func makeIconFile(for model: LCAppModel, style: GeneratedIconStyle) throws -> (directory: URL, fileURL: URL) {
        guard let image = model.appInfo.generateLiveContainerWrappedIcon(with: style),
              let imageData = image.pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawDisplayName = model.appInfo.displayName() ?? model.displayName
        let displayName = rawDisplayName.replacingOccurrences(of: "/", with: "_")
        let fileURL = directory.appendingPathComponent("\(displayName) Icon.png")
        try imageData.write(to: fileURL, options: .atomic)

        return (directory, fileURL)
    }

    static func appClipMdmData(for model: LCAppModel, style: GeneratedIconStyle) throws -> Data {
        guard let profile = model.appInfo.generateWebClipConfig(
            withContainerId: model.uiSelectedContainer?.folderName,
            iconStyle: style
        ) else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        return try PropertyListSerialization.data(fromPropertyList: profile, format: .xml, options: 0)
    }
}

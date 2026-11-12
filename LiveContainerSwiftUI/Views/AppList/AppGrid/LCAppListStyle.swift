//
//  LCAppListStyle.swift
//  LiveContainerSwiftUI
//

import Foundation

enum LCAppListStyle: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String {
        return rawValue
    }

    var displayName: String {
        switch self {
        case .grid:
            return "lc.settings.appListStyle.grid".loc
        case .list:
            return "lc.settings.appListStyle.list".loc
        }
    }
}

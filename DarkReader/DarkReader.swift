//
//  DarkReader.swift
//  DuckDuckGo
//
//  Copyright © 2022 DuckDuckGo. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
<<<<<<< HEAD
import UIKit

enum DarkReaderModeName: String {
    // Match system color scheme
    case systemDefault
    // Match Theme
=======

enum DarkReaderModeName: String {
    case systemDefault
>>>>>>> 6bded809 (more)
    case themeDefault
    case on
    case off
}

// TODO: add Dark Reader fixes protocol analagous to
// protocol Theme

class DarkReader {

    private lazy var appSettings = AppDependencyProvider.shared.appSettings

    init() {
        
    }
    
    func isEnabled() -> Bool {
<<<<<<< HEAD
        switch appSettings.currentDarkReaderModeName {
        case .systemDefault:
            switch UIScreen.main.traitCollection.userInterfaceStyle {
            case .dark:
                return true
            case .light:
                return false
            default:
                return true
            }
        case .themeDefault:
            switch appSettings.currentThemeName {
            case .dark:
                return true
            case .light:
                return false
            case .systemDefault:
                // This is analogus to ThemeManager.obtainSystemTheme()
                // Make sure to sync these two configs
                return UIScreen.main.traitCollection.userInterfaceStyle != .light
            }
=======
        // Dark Reader is enabled if:
        //
        switch appSettings.currentDarkReaderModeName {
        case .systemDefault:
            return true // TODO
        case .themeDefault:
            let theme = appSettings.currentThemeName
            return theme == .dark || theme == .systemDefault// TODO
>>>>>>> 6bded809 (more)
        case .on:
            return true
        case .off:
            return false
        }
    }
}

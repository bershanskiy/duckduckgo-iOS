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

enum DarkReaderModeName: String {
    case systemDefault
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
        // Dark Reader is enabled if:
        //
        switch appSettings.currentDarkReaderModeName {
        case .systemDefault:
            return true // TODO
        case .themeDefault:
            let theme = appSettings.currentThemeName
            return theme == .dark || theme == .systemDefault// TODO
        case .on:
            return true
        case .off:
            return false
        }
    }
}

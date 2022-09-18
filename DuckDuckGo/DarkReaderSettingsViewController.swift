//
//  DarkReaderSettingsViewController.swift
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

import UIKit
import Core

class DarkReaderSettingsViewController: UITableViewController {
    private typealias ModeEntry = (modeName: DarkReaderModeName, displayName: String)
    private lazy var appSettings = AppDependencyProvider.shared.appSettings
    
    private lazy var availableModes: [ModeEntry] = {
        return [(DarkReaderModeName.systemDefault, UserText.darkReaderModeNameSystemDefault),
                (DarkReaderModeName.themeDefault, UserText.darkReaderModeNameThemeDefault),
                (DarkReaderModeName.light, UserText.darkReaderModeNameLight),
                (DarkReaderModeName.dark, UserText.darkReaderModeNameDark),
                (DarkReaderModeName.off, UserText.darkReaderModeNameOff)]
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        
        applyTheme(ThemeManager.shared.currentTheme)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return availableModes.count
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        return tableView.dequeueReusableCell(withIdentifier: "DarkReaderModeItemCell", for: indexPath)
    }
 
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard let cell = cell as? DarkReaderModeItemCell else {
            fatalError("Expected DarkReaderModeItemCell")
        }

        let theme = ThemeManager.shared.currentTheme
        cell.backgroundColor = theme.tableCellBackgroundColor
        cell.setHighlightedStateBackgroundColor(theme.tableCellHighlightedBackgroundColor)
        
        // Checkmark color
        cell.tintColor = theme.buttonTintColor
        cell.darkReaderModeNameLabel.textColor = theme.tableCellTextColor
        
        cell.darkReaderModeName = availableModes[indexPath.row].displayName

        let modeName = availableModes[indexPath.row].modeName
        cell.accessoryType = modeName == appSettings.currentDarkReaderModeName ? .checkmark : .none
    }
    
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        
        let mode = availableModes[indexPath.row].modeName
        appSettings.currentDarkReaderModeName = mode
        tableView.reloadData()
    }
}

class DarkReaderModeItemCell: UITableViewCell {
    @IBOutlet weak var darkReaderModeNameLabel: UILabel!

    var darkReaderModeName: String? {
        get {
            return darkReaderModeNameLabel.text
        }
        set {
            darkReaderModeNameLabel.text = newValue
        }
    }
}

extension DarkReaderSettingsViewController: Themable {

    func decorate(with theme: Theme) {
        
        tableView.backgroundColor = theme.backgroundColor
        tableView.separatorColor = theme.tableCellSeparatorColor
        
        tableView.reloadData()
    }
}

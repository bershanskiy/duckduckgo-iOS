//
//  DynamicModeFixes.swift
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

class DynamicModeFixes {
    
private struct Fixes: Decodable {
    var index: [String: [Int]] = [:]
    var fixes: [Fix] = []
}

private struct Fix: Decodable, Encodable {
    let url: [String]
    let invert: [String]?
    let css: String?
    let ignoreInlineStyle: [String]?
    let ignoreImageAnalysis: [String]?
    let disableStyleSheetsProxy: Bool?
}

private func loadAllFixes() -> Fixes {
    // TODO: make sure to use the correct file path
    if let fixesURL = Bundle.main.url(forResource: "dynamic-theme-fixes", withExtension: "json") {
        if let fixesJSON = try? Data(contentsOf: fixesURL) {
            let fixes: Fixes = try! JSONDecoder().decode(Fixes.self, from: fixesJSON)
            return fixes
        }
    }
    return Fixes()
}

private func selectRelevantFixes(host: String, fixes: Fixes) -> [Fix] {
    var relevantFixes: [Fix] = []
    
    // Default fix has label "*"
    var relevantIndexes: Set<Int> = Set(fixes.index["*"] ?? [])

    // Find all site-specific fixes
    let labels: [String] = host.lowercased().components(separatedBy: ".")
    for first in 0..<labels.count {
        let host = labels.suffix(from: first).joined(separator: ".")
        if let fixes = fixes.index[host] {
            relevantIndexes = relevantIndexes.union(fixes)
        }
    }

    for index in relevantIndexes {
        relevantFixes.append(fixes.fixes[index])
    }

    return relevantFixes
}

private func fixesConfig(host: String, fixes: Fixes) -> String {
    let relevantFixes = selectRelevantFixes(host: host, fixes: fixes)
    let encoded = try! JSONEncoder().encode(relevantFixes)
    return String(data: encoded, encoding: String.Encoding.utf8) ?? ""
}

}

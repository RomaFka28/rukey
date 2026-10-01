// A stub executable so `swift build` produces a runnable binary from the start.
// The event tap is task 5; this only proves the package links.

import Foundation
import RukeyCore

let tables = [Language.english, Language.russian].map { language -> (Language, Result<LayoutTable, Error>) in
    (language, Result { try LayoutLoader.load(language: language) })
}

for (language, result) in tables {
    switch result {
    case .success(let table):
        print("\(language.rawValue): \(table.chars.count) letters read from the system")
    case .failure(let error):
        print("\(language.rawValue): FAILED - \(error)")
    }
}
import Foundation

/// The engine's user-data directory: custom maps, saved games and `Options.ini`.
///
/// On macOS the engine resolves this to `~/Documents/Command and Conquer Generals
/// Zero Hour Data/` by default, but honours the `GEN_USER_DATA` env var (see the
/// `__APPLE__` hook in GlobalData.cpp), so the launcher can relocate it. The
/// launcher persists the chosen path and passes it through at launch.
enum UserData {
    /// The fixed leaf folder name the engine appends under ~/Documents.
    static let leafName = "Command and Conquer Generals Zero Hour Data"

    /// Default location — matches the engine's `CSIDL_PERSONAL` shim
    /// (`.documentDirectory` resolves to ~/Documents).
    static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent(leafName, isDirectory: true)
    }

    /// Sub-folders pre-created so the folder is usable immediately.
    static let subfolders = ["Maps", "Save"]

    static func mapsDir(in base: URL) -> URL {
        base.appendingPathComponent("Maps", isDirectory: true)
    }
    static func saveDir(in base: URL) -> URL {
        base.appendingPathComponent("Save", isDirectory: true)
    }
    static func optionsIni(in base: URL) -> URL {
        base.appendingPathComponent("Options.ini")
    }
}

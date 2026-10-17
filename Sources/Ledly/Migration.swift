import Foundation

/// The first builds used the bundle ID com.egluu.ledly. Carry their settings over once.
enum Migration {
    static func fromEgluuBundleID() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromEgluu") else { return }
        if let old = defaults.persistentDomain(forName: "com.egluu.ledly") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromEgluu")
    }
}

import Foundation
import SwiftData

extension ModelContext {
    /// Saves pending changes, but if the save fails it rolls the context back to its last good
    /// state instead of leaving it wedged. SwiftData keeps a failed change pending, which makes
    /// *every* later `save()` throw too — so without this one bad write would silently stop the
    /// app from saving anything new. Returns true on a clean save.
    @discardableResult
    func saveIfPossible() -> Bool {
        guard hasChanges else { return true }
        do {
            try save()
            return true
        } catch {
            rollback()
            #if DEBUG
            print("⚠️ SwiftData save failed; rolled back to recover. \(error)")
            #endif
            return false
        }
    }
}

import CoreStorage
import SwiftData

public extension ModelContext {
    @MainActor
    func saveOrReport(_ errorCenter: AppErrorCenter, context: String) {
        do {
            try save()
        } catch {
            errorCenter.present(MovieBoxError.storage(error), context: context)
        }
    }
}

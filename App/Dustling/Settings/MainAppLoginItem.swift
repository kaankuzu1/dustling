import DustlingAppModel
import ServiceManagement

/// "Open Dustling at login" through `SMAppService.mainApp`. The model only talks to this through
/// `LoginItemService`, so tests never register a login item on the Mac.
struct MainAppLoginItem: LoginItemService {
    func status() -> LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
}

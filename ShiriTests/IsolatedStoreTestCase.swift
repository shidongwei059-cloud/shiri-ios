import XCTest
@testable import ShiriCore

class IsolatedStoreTestCase: XCTestCase {
    private var controllers: [PersistenceController] = []
    private var directories: Set<URL> = []
    func openTestPersistence(_ configuration: PersistenceConfiguration) async throws -> PersistenceController {
        let root = configuration.directory.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard root.path.hasPrefix(temporary.path + "/"), root.path.dropFirst(temporary.path.count + 1).hasPrefix("Shiri") else {
            throw ShiriError.validation("Test storage must be isolated in an owned temporary directory")
        }
        directories.insert(root)
        let controller = try await PersistenceController.open(configuration)
        controllers.append(controller); return controller
    }
    override func tearDown() async throws {
        // Detach every connection before removing any files, including tests using two stores.
        for controller in controllers { try await controller.detachStores() }
        controllers.removeAll()
        for directory in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        }
        directories.removeAll()
        try await super.tearDown()
    }
}

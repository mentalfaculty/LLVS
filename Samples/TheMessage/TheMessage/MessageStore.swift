import Foundation
import LLVS
import LLVSCloudKit
import CloudKit

@MainActor @Observable
class MessageStore {
    var message: String = "Let there be light!"

    private let storeCoordinator: StoreCoordinator
    private let messageId = Value.ID("MESSAGE")
    @ObservationIgnored nonisolated(unsafe) private var versionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var pollingTask: Task<Void, Never>?

    init() {
        LLVS.log.level = .verbose
        let coordinator = try! StoreCoordinator()
        let container = CKContainer(identifier: "iCloud.com.mentalfaculty.themessage")
        let exchange = CloudKitExchange(with: coordinator.store, storeIdentifier: "MainStore", cloudDatabaseDescription: .publicDatabase(container))
        coordinator.exchange = exchange
        self.storeCoordinator = coordinator

        versionTask = Task { [weak self] in
            guard let self else { return }
            for await _ in coordinator.currentVersionUpdates {
                self.message = self.fetchMessage() ?? "Let there be light!"
            }
        }

        startPolling()
    }

    private func fetchMessage() -> String? {
        guard let value = try? storeCoordinator.value(id: messageId) else { return nil }
        return String(data: value.data, encoding: .utf8)
    }

    func post(message: String) {
        let data = message.data(using: .utf8)!
        let newValue = Value(id: messageId, data: data)
        try! storeCoordinator.save(updating: [newValue])
        sync()
    }

    func sync() {
        Task {
            try? await storeCoordinator.exchange()
            storeCoordinator.merge()
        }
    }

    private func startPolling() {
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                try? await storeCoordinator.exchange()
                storeCoordinator.merge()
            }
        }
    }

    deinit {
        versionTask?.cancel()
        pollingTask?.cancel()
    }
}

import Foundation
import LLVS
import LLVSCloudKit
import CloudKit
import Combine

@Observable
class MessageStore {
    var message: String = "Let there be light!"

    private let storeCoordinator: StoreCoordinator
    private let messageId = Value.ID("MESSAGE")
    private var versionSubscriber: AnyCancellable?
    private var pollingTask: Task<Void, Never>?

    init() {
        LLVS.log.level = .verbose
        let coordinator = try! StoreCoordinator()
        let container = CKContainer(identifier: "iCloud.com.mentalfaculty.themessage")
        let exchange = CloudKitExchange(with: coordinator.store, storeIdentifier: "MainStore", cloudDatabaseDescription: .publicDatabase(container))
        coordinator.exchange = exchange
        self.storeCoordinator = coordinator

        versionSubscriber = coordinator.currentVersionSubject
            .map { [weak self] _ in self?.fetchMessage() ?? "Let there be light!" }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] msg in self?.message = msg }

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
        storeCoordinator.exchange { _ in
            self.storeCoordinator.merge()
        }
    }

    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                self?.sync()
            }
        }
    }

    deinit {
        pollingTask?.cancel()
    }
}

//
//  AppDelegate.swift
//  TheMessage
//
//  Created by Drew McCormack on 11/10/2019.
//  Copyright © 2019 Momenta B.V. All rights reserved.
//

import UIKit
import LLVS
import LLVSCloudKit
import CloudKit
import Combine
import CryptoKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, ObservableObject {
    
    lazy var storeCoordinator: StoreCoordinator = {
        LLVS.log.level = .verbose
        let coordinator = try! StoreCoordinator()
        let container = CKContainer(identifier: "iCloud.com.mentalfaculty.themessage")
        let exchange = CloudKitExchange(with: coordinator.store, storeIdentifier: "MainStore", cloudDatabaseDescription: .publicDatabase(container))
        coordinator.exchange = exchange
        return coordinator
    }()
    
    var store: Store { storeCoordinator.store }
    
    
    // MARK: Message
    
    let messageId: Value.ID = .init("MESSAGE") // Id in the store
    
    @Published var message: String = ""
    
    /// Fetch the message for the current version from the store
    func fetchMessage() -> String? {
        guard let value = try? storeCoordinator.value(id: messageId) else { return nil }
        return String(data: value.data, encoding: .utf8)
    }
    
    /// Update the message in the store, and sync it to the cloud
    func post(message: String) {
        let data = message.data(using: .utf8)!
        let newValue = Value(id: messageId, data: data)
        try! storeCoordinator.save(updating: [newValue])
        sync()
    }
    
    
    // MARK: Sync
    
    func sync() {
        // Exchange with the cloud
        storeCoordinator.exchange { _ in
            // Merge branches to get the latest version
            self.storeCoordinator.merge()
        }
    }
    
    
    // MARK: Subscribing to changes in store

    private var syncSubscriber: AnyCancellable!
    private var messageSubscriber: AnyCancellable!

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Monitor changes in the current version, and update the message when these are detected
        messageSubscriber = storeCoordinator.currentVersionSubject
            .map({ _ in self.fetchMessage() ?? "Let there be light!" })
            .receive(on: DispatchQueue.main)
            .assign(to: \.message, on: self)
        
        // Setup a regular timer to sync. The public database of CloudKit has no support
        // for push notifications when changes are made, so we just poll regularly
        syncSubscriber = Timer.publish(every: 15, on: .main, in: .common)
            .autoconnect()
            .sink { _ in self.sync() }
        
        return true
    }
    
    
    // MARK: Other

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

}


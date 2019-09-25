//
//  AppDelegate.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 05/06/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit
import LLVS
import LLVSCloudKit
import CloudKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    lazy var storeCoordinator: StoreCoordinator = {
        LLVS.log.level = .verbose
        let coordinator = try! StoreCoordinator()
        let container = CKContainer(identifier: "iCloud.com.mentalfaculty.loco-swiftui")
        let exchange = CloudKitExchange(with: coordinator.store, storeIdentifier: "MainStore", cloudDatabaseDescription: .privateDatabaseWithCustomZone(container, zoneIdentifier: "MainZone"))
        coordinator.exchange = exchange
        exchange.subscribeForPushNotifications()
        return coordinator
    }()
    
    lazy var dataSource: ContactsDataSource = {
        ContactsDataSource(storeCoordinator: storeCoordinator)
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UIApplication.shared.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        let preSyncVersion = storeCoordinator.currentVersion
        dataSource.sync { _ in
            let result: UIBackgroundFetchResult = self.storeCoordinator.currentVersion == preSyncVersion ? .noData : .newData
            completionHandler(result)
        }
    }


}


//
//  AppDelegate.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit
import LLVS
import CloudKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, UISplitViewControllerDelegate {

    var window: UIWindow?
    
    private let storeVersionKey = "storeVersion"
    
    lazy var rootStoreDirectory: URL = {
        let docDir = try! FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let rootDir = docDir.appendingPathComponent("ContactBook")
        try? FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true, attributes: nil)
        return rootDir
    }()
    
    lazy var store: Store = {
        return try! Store(rootDirectoryURL: rootStoreDirectory)
    }()
    
    lazy var contactBook: ContactBook = {
        let book: ContactBook
        let versionIdentifier: Version.Identifier
        if let versionString = UserDefaults.standard.string(forKey: storeVersionKey),
            let version = try! store.version(identifiedBy: .init(versionString)) {
            book = try! ContactBook(prevailingAt: version.identifier, loadingFrom: store)
            versionIdentifier = version.identifier
        } else if let version = store.mostRecentHead?.identifier {
            versionIdentifier = version
            book = try! ContactBook(prevailingAt: version, loadingFrom: store)
        } else {
            book = try! ContactBook(creatingIn: store)
            versionIdentifier = book.currentVersion
        }
        UserDefaults.standard.set(book.currentVersion.identifierString, forKey: self.storeVersionKey)
        UserDefaults.standard.synchronize()
        return book
    }()
    
    func application(_ application: UIApplication, willFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        log.level = .verbose
        return true
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NotificationCenter.default.addObserver(forName: .contactBookDidSaveLocalChanges, object: contactBook, queue: nil) { [unowned self] notif in
            self.storeCurrentVersion()
            self.contactBook.sync()
        }
        NotificationCenter.default.addObserver(forName: .contactBookDidSaveSyncChanges, object: contactBook, queue: nil) { [unowned self] notif in
            self.storeCurrentVersion()
        }
    
        let splitViewController = window!.rootViewController as! UISplitViewController
        let detailNavController = splitViewController.viewControllers.last as! UINavigationController
        detailNavController.topViewController!.navigationItem.leftBarButtonItem = splitViewController.displayModeButtonItem
        splitViewController.delegate = self
        
        let masterNavController = splitViewController.viewControllers.first as! UINavigationController
        let contactsController = masterNavController.topViewController as! ContactsViewController
        contactsController.contactBook = contactBook
        
        contactBook.cloudKitExchange.subscribeForPushNotifications()
        contactBook.sync()
        
        return true
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        let task = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
        contactBook.sync { _ in
            UIApplication.shared.endBackgroundTask(task)
        }
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        contactBook.sync()
    }
    
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable : Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        log.trace("Received push notification")
        let preVersion = contactBook.currentVersion
        contactBook.sync { error in
            let versionChanged = self.contactBook.currentVersion != preVersion
            let success = error == nil
            completionHandler(versionChanged ? .newData : success ? .noData : .failed)
        }
    }
    
    func storeCurrentVersion() {
        UserDefaults.standard.set(self.contactBook.currentVersion.identifierString, forKey: self.storeVersionKey)
        UserDefaults.standard.synchronize()
    }

    func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController:UIViewController, onto primaryViewController:UIViewController) -> Bool {
        guard let navController = secondaryViewController as? UINavigationController else { return false }
        guard let contactController = navController.topViewController as? ContactViewController else { return false }
        if contactController.contactBook == nil { return true }
        return false
    }

}


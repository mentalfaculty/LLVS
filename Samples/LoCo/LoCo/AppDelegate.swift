//
//  AppDelegate.swift
//  LoCo
//
//  Created by Drew McCormack on 17/01/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit
import LLVS

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
        if let versionString = UserDefaults.standard.string(forKey: storeVersionKey) {
            versionIdentifier = .init(versionString)
            book = try! ContactBook(prevailingAt: versionIdentifier, loadingFrom: store)
        } else if let version = store.history.mostRecentHead?.identifier {
            versionIdentifier = version
            book = try! ContactBook(prevailingAt: version, loadingFrom: store)
        } else {
            book = try! ContactBook(creatingIn: store)
            versionIdentifier = book.currentVersion
        }
        UserDefaults.standard.set(versionIdentifier.identifierString, forKey: storeVersionKey)
        return book
    }()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        NotificationCenter.default.addObserver(forName: .contactBookVersionDidChange, object: contactBook, queue: nil) { notif in
            UserDefaults.standard.set(self.contactBook.currentVersion.identifierString, forKey: self.storeVersionKey)
        }
        
        let splitViewController = window!.rootViewController as! UISplitViewController
        let navigationController = splitViewController.viewControllers[splitViewController.viewControllers.count-1] as! UINavigationController
        navigationController.topViewController!.navigationItem.leftBarButtonItem = splitViewController.displayModeButtonItem
        splitViewController.delegate = self
        
        return true
    }

    func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController:UIViewController, onto primaryViewController:UIViewController) -> Bool {
        guard let secondaryAsNavController = secondaryViewController as? UINavigationController else { return false }
        guard let topAsDetailController = secondaryAsNavController.topViewController as? ContactViewController else { return false }
        if topAsDetailController.detailItem == nil {
            // Return true to indicate that we have handled the collapse by doing nothing; the secondary controller will be discarded.
            return true
        }
        return false
    }

}


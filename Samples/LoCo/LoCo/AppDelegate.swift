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
        if let versionString = UserDefaults.standard.string(forKey: storeVersionKey),
            let version = store.history.version(identifiedBy: .init(versionString)) {
            book = try! ContactBook(prevailingAt: version.identifier, loadingFrom: store)
            versionIdentifier = version.identifier
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
        let detailNavController = splitViewController.viewControllers.last as! UINavigationController
        detailNavController.topViewController!.navigationItem.leftBarButtonItem = splitViewController.displayModeButtonItem
        splitViewController.delegate = self
        
        let masterNavController = splitViewController.viewControllers.first as! UINavigationController
        let contactsController = masterNavController.topViewController as! ContactsViewController
        contactsController.contactBook = contactBook
        
        return true
    }

    func splitViewController(_ splitViewController: UISplitViewController, collapseSecondary secondaryViewController:UIViewController, onto primaryViewController:UIViewController) -> Bool {
        guard let navController = secondaryViewController as? UINavigationController else { return false }
        guard let contactController = navController.topViewController as? ContactViewController else { return false }
        if contactController.contactBook == nil { return true }
        return false
    }

}


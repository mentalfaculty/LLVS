//
//  SceneDelegate.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 05/06/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let scene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: scene)
            let appDelegate = UIApplication.shared.delegate as! AppDelegate
            let contactsView = ContactsView()
                .environmentObject(appDelegate.dataSource)
                .accentColor(.green)
            window.rootViewController = UIHostingController(rootView: contactsView)
            self.window = window
            window.makeKeyAndVisible()
        }
    }
    
    func sceneWillEnterForeground(_ scene: UIScene) {
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        appDelegate.dataSource.sync()
    }
    
}


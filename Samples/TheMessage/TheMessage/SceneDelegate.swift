//
//  SceneDelegate.swift
//  TheMessage
//
//  Created by Drew McCormack on 11/10/2019.
//  Copyright © 2019 Momenta B.V. All rights reserved.
//

import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        let appDelegate = UIApplication.shared.delegate as! AppDelegate
        let contentView = ContentView().environmentObject(appDelegate)
        if let windowScene = scene as? UIWindowScene {
            let window = UIWindow(windowScene: windowScene)
            window.rootViewController = UIHostingController(rootView: contentView)
            self.window = window
            window.makeKeyAndVisible()
        }
    }
    
}


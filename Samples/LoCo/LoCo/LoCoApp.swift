//
//  LoCoApp.swift
//  LoCo
//
//  Created by Drew McCormack on 04/03/2026.
//

import SwiftUI

@main
struct LoCoApp: App {
    @State private var store = ContactStore()

    var body: some Scene {
        WindowGroup {
            ContactsView()
                .environment(store)
        }
    }
}

//
//  ContentView.swift
//  TheMessage
//
//  Created by Drew McCormack on 11/10/2019.
//  Copyright © 2019 Momenta B.V. All rights reserved.
//

import SwiftUI

struct ContentView: View {
    
    @EnvironmentObject var appDelegate: AppDelegate
    
    @State var editedMessage: String = ""
    @State var isEditing = false
    
    var body: some View {
        HStack {
            if isEditing {
                TextField("The Message",
                    text: $editedMessage,
                    onCommit: {
                        if self.editedMessage != self.appDelegate.message {
                            self.appDelegate.post(message: self.editedMessage)
                        }
                        self.isEditing = false
                    })
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .multilineTextAlignment(.center)
            } else {
                Text(appDelegate.message)
                    .onTapGesture {
                        self.editedMessage = self.appDelegate.message
                        self.isEditing = true
                    }
            }
        }
    }
    
}


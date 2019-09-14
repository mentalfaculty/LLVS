//
//  ContentView.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 05/06/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI

struct ContentView : View {
    var body: some View {
        NavigationView {
            List(0..<5) { item in
                HStack {
                    Image("Placeholder")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(6.0)
                        .frame(width: 50, height: 50, alignment: .center)
                    VStack(alignment: .leading) {
                        Text("Main Title Here")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Subtitle")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationBarTitle(Text("Contacts"))
        }
    }
}

struct ContentViewPreview : PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

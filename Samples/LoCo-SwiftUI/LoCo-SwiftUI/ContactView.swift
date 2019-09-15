//
//  ContactView.swift
//  LoCo-SwiftUI
//
//  Created by Drew McCormack on 15/09/2019.
//  Copyright © 2019 The Mental Faculty B.V. All rights reserved.
//

import SwiftUI

struct ContactView: View {
    @EnvironmentObject var dataSource: ContactsDataSource

    var body: some View {
        VStack(alignment: .leading) {
            Text("Details").font(.largeTitle).padding(.bottom, 20)
            
            VStack(alignment: .leading, spacing: 5.0) {
                Text("English").font(.headline)
                Text(dataSource.selectedTranslation?.sourceText ?? "")
                    .foregroundColor(Color(white: 0.3))
                HStack {
                    if dataSource.selectedTranslation?.localizationNote.isEmpty == false {
                        Text(dataSource.selectedTranslation?.localizationNote ?? "").font(.footnote)
                        Spacer()
                    }
                }
            }.padding(.bottom, 40.0)

            VStack(alignment: .leading, spacing: 5.0) {
                Text("Translation (\(self.dataSource.selectedTranslation!.targetLanguage.rawValue))").font(.headline)
                MultilineTextView(text: self.dataSource.translationBinding(at: self.dataSource.selectedIndex).targetText)
                Picker("Status", selection: self.dataSource.translationBinding(at: self.dataSource.selectedIndex).statusRawValue) {
                    ForEach(self.dataSource.availableStatusesForSelectedTranslation) { t in
                        Text(t.description).tag(t.rawValue)
                    }
                }.pickerStyle(SegmentedPickerStyle())
            }.padding(.bottom, 40.0)

            VStack(alignment: .leading, spacing: 5.0) {
                Text("Comment from Translator").font(.headline)
                MultilineTextView(text: self.dataSource.translationBinding(at: dataSource.selectedIndex).comment.text)
            }.padding(.bottom, 40.0)
            
            Spacer()
        }
    }
}

struct ContactViewPreview: PreviewProvider {
    static var previews: some View {
        ContactView()
    }
}

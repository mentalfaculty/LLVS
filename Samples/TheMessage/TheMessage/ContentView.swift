import SwiftUI

struct ContentView: View {
    @Environment(MessageStore.self) var store
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 20) {
            Text(store.message)
                .font(.title2)
                .multilineTextAlignment(.center)
                .padding()

            HStack {
                TextField("New message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Post") {
                    guard !draft.isEmpty else { return }
                    store.post(message: draft)
                    draft = ""
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
        }
    }
}

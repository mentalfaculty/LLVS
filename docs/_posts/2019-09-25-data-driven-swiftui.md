---
layout: post
title: "Data Driven SwiftUI"
author: Drew McCormack
tags: [swiftui]
---

SwiftUI has set us all thinking about the future of development on Apple's platforms. It's a disruptive technology which will supersede a UI stack dating back more than 20 years to the pre-Mac OS X era. But while SwiftUI introduces bold new concepts in the UI, what about the rest of our Swift app? Can we disrupt that too? 

Here I'm going to show you how to build an app that...

1. Uses SwiftUI for views
2. Adopts immutable value types (structs) at every level, and immutable files on disk
3. Syncs seamlessly across devices, with no networking code
4. Has around 450 lines of code in total

## SwiftUI

Even with SwiftUI in constant flux, there is already plenty of great content around for learning  the new framework. I've spent several weeks working on side projects in an effort to 'kick the tires'; the tutorials and API descriptions others have compiled have been indispensable. And yet, I can't help feeling most of the code is clothed above the waist, and pantsless below. The king is only half dressed. There is an enormous, data-sized elephant in the SwiftUI room.

To be more concrete, SwiftUI examples typically rely heavily on the `@State` property wrapper. This is a convenient way to include some mutable state without having to think much about the controllers and data models which make up a real app. This is fully understandable, because the framework is new, and we are still fixated on how to handle animation, layout, and a multitude of other UI concerns. But recently, I've started to focus on the next step: How do you go from the tutorials and demos to real world, scalable apps? How do you build a SwiftUI app from the ground up?

## Structs Atop Classes

One of the most perplexing aspects of the current state of affairs is that we have a framework for UI based on value types — `View` structs — while being encouraged to use reference types at the model level. Model types are still typically represented by classes, and Apple's own solution for data storage, Core Data, is firmly established in the realm of reference types.

This feels upside down to me. If I were to choose to use value types in either model or view, I would be inclined to pick the model first. In fact, in the app [Agenda](https://agenda.com), we took exactly this approach: the model is made up of structs, and the view utilizes standard AppKit/UIKit types, _ie_, classes.

## Values All the Way Down

Of course, one choice need not exclude the other. Maybe the best solution is to use value types in both the view _and_ the model. It's this option I want to explore here by developing a basic contacts app with SwiftUI. But we'll take it a step further, not only using value types, but also adopting immutable data throughout, right down to the on disk storage.

![The LoCo App]({{site.baseurl}}/images/data-drive-swiftui/LoCo.png)


## LLVS

We'll use the [Low-Level Versioned Store (LLVS)](https://github.com/mentalfaculty/LLVS) for app storage, because it is based entirely on immutable files, and syncs automatically via CloudKit. The full source code for the sample app (LoCo) is [in the LLVS project](https://github.com/mentalfaculty/LLVS/tree/master/Samples/LoCo-SwiftUI/LoCo-SwiftUI).

The easiest way to think about LLVS is as Git for your app. The concepts are completely analogous: 

- They both maintain a full history of versions
- Data can be retrieved for any version
- Data can be stored to create a new version based on any earlier version
- History can be branched, and merged

LLVS has the added advantage that it abstracts away all sync and networking code, so building a syncing app is as easy as pulling from GitHub.

## Data Driven

Because LLVS has a full history of versions, and each version is immutable, our data handling becomes dramatically simpler. The state of the whole app can be derived from a single value: the current version. 

We can use the Combine framework to monitor changes to the current version, and propagate the changes through the data source class, and into the views. All of the SwiftUI views are literally a function of that one single value.

Here is the [relevant code](https://github.com/mentalfaculty/LLVS/blob/master/Samples/LoCo-SwiftUI/LoCo-SwiftUI/ContactsDataSource.swift) from the `ContactsDataStore` class:

```swift
final class ContactsDataSource: ObservableObject  {

    let storeCoordinator: StoreCoordinator

    private var contactsSubscriber: AnyCancellable?

    init(storeCoordinator: StoreCoordinator) {
        self.storeCoordinator = storeCoordinator
        contactsSubscriber = storeCoordinator.currentVersionSubject
            .receive(on: DispatchQueue.main)
            .map({ self.fetchedContacts(at: $0) })
            .assign(to: \.contacts, on: self)
    }
    
    ...
    
    @Published var contacts: [Contact] = []
```

The `StoreCoordinator` class is our interface to LLVS; it manages the store for us, tracking the current version, and merging changes from other devices. The class has a `currentVersionSubject`, which we can subscribe to. 

After shunting to the main queue, we use a Combine `map` to convert the current version into a list of contacts for that version. The method `fetchContacts` handles this, querying the `StoreCoordinator` for values stored in the current version, and unpacking the data using the `Codable` protocol to create an array of our model type, `Contact`.

After the current contacts are fetched they are assigned to the `contacts` property; because this is `@Published`, it triggers an update to the SwiftUI `View` types, reflecting the data for the user. All of this arises whenever the current version of the `StoreCoordinator` changes, whether due to a local edit, or new data from a remote device.

## The Views

The view code is quite standard SwiftUI. We create a list of contacts in `ContactsView`.

```swift
struct ContactsView : View {
    @EnvironmentObject var dataSource: ContactsDataSource
    
    ...
    
    var body: some View {
        NavigationView {
            List {
                ForEach(dataSource.contacts) { contact in
                    ContactCell(contactID: contact.id)
                        .environmentObject(self.dataSource)
                }
                ...
            }
        ...
```

The `ContactsDataSource` object is passed in here as an `@EnvironmentObject`, and the `contacts` property from the previous section is used to generate the list cells.

When the user taps a cell, a detail view is pushed onto the navigation stack, showing the details of the contact in a form.

```swift
struct ContactView: View {
    @EnvironmentObject var dataSource: ContactsDataSource
    var contactID: Contact.ID
    
    ...
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Name")) {
                    TextField("First Name", text: contact.person.firstName)
                    TextField("Last Name", text: contact.person.secondName)
                }
                Section(header: Text("Address")) {
                    TextField("Street Address", text: contact.address.streetAddress)
                    TextField("Postcode", text: contact.address.postCode)
                    TextField("City", text: contact.address.city)
                    TextField("Country", text: contact.address.country)
                }
            }
            .navigationBarTitle(Text("Contact"))
        }
    }
}
```

This is what it looks like to the user.

![Contact Detail View]({{site.baseurl}}/images/data-drive-swiftui/ContactDetails.png)


## Change Without Mutation

So far, we have no mechanism to change the contacts data. This is where it gets more interesting, because we are going to update the contacts without actually mutating any of our data.

Let's take the case of updating an existing contact. (Inserting and deleting are very similar.) We need a means to observe changes in the text fields of the `ContactView`. In SwiftUI, that usually means a binding. Here is the `contact` binding that we used to populate the form above.

```swift
    private var contact: Binding<Contact> {
        Binding<Contact>(
            get: { () -> Contact in
                self.dataSource.contact(withID: self.contactID)
            },
            set: { newContact in
                self.dataSource.update(newContact)
            }
        )
    }
```

Usually a binding would be a wrapper around a simple value, but, in this case, the getter fetches the contact from the `ContactsDataSource`, and the setter calls an `update` method passing the changed contact.

```swift
    func update(_ contact: Contact) {
        let change: Value.Change = .update(try! contact.encodeValue())
        try! storeCoordinator.save([change])
        sync()
    }
```

As you can see, the `update` method doesn't actually make any changes to the `contacts` array in `ContactsDataSource`, which is what you would probably expect it to do. Instead, it encodes the new value, and saves it straight into the LLVS store to create a new version.

Stop to think about that for a minute: we didn't actually mutate any of the data in our `ContactsDataSource`, or SwiftUI views. We simply created a new `Contact` value, and saved it straight to disk.


If we don't update the array of contacts in the data source class, how do edits end up on screen? Well, we saved the new value to the LLVS store, which causes the current version to change, and this induces the chain of observation we started with, updating the whole UI. The cycle is complete.

![The Data Cycle](/images/data-drive-swiftui/DataFlow.png)


## A Merge at Every Coal Face

Who cares? Why is this useful? Here is something you realize when implementing sync in a non-trivial app: whenever you have a mutable copy of the data, you have a merge problem. For example, imagine you fetch data from disk, and store it in a controller. What happens when new changes arrive from a different device? You have to merge those changes into the controller's data. And what happens when the user makes changes in the view? You have to merge those changes into the controller's copy of the data.

And the same applies to every level of the app. If you are working on a view class, you have to be careful to pull updates in from the controller, and merge them with any changes the user has just made. In short, there is a merge problem at every coal face. Any mutable copy of your data is another merge problem to solve.

The reason the solution above works so well is that there is no mutable copy of the data. The only mutation occurs in the data store when changing the current version. All merging occurs in this step, via the mechanisms provided by LLVS. In this particular example, we have opted for a simple "most recent value wins" merge policy, but we could make merging as sophisticated as needed. We do this in one place, rather than throughout the app for every mutable copy of the data.

## Early Adopters

It's still very early days for SwiftUI, but now is the time to start exploring new ways to build apps. Question your assumptions. The dam is ready to break.

In this post, we've seen how using a distributed store like LLVS can complement SwiftUI. You can build your whole app around immutable value types, and vastly simplify sync and data merging.


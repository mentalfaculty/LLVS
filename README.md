# Low-Level Versioned Store (LLVS)

_Author: Drew McCormack (@drewmccormack)_

## Introduction to LLVS

Ever wish it was as easy to move your app's data around as it is to push and pull your source code with a tool like Git? If so, read on.

### Why LLVS?

Application data is more decentralized than ever. It is rare to find it concentrated on a single device. Typically, a single user will have a multitude of devices, from phones to laptops and watches, and each device may have several independent processes running (eg today extension, sharing extension), each working with a copy of the data. How can you share all of this data, giving the user a consistent picture, without writing thousands of lines of custom code to handle each scenario?

Software developers faced a similar situation in the world of source control. They were faced with this question: How can multiple individuals all work together on the same source files across multiple computers? We all know how that played out. Advances in Source Control Management (SCM) led to systems like Git and GitHub.

These tools successfully solved the problem of decentralized collaboration, and it is odd that the same approach has not been applied to app data before. That's where LLVS comes in. It provides a basic framework for storing and moving data through the decentralized world in which our apps live.

### What is LLVS?

LLVS is best described as a _decentralized, versioned, key-value storage framework_. 

It works a bit like a traditional key-value store, in which you can insert data values for given unique keys. But LLVS adds to this several extra dimensions, namely, that when a set of values are stored, a new version is created in the store, and each version has an ancestry of other versions which you can trace back in time. Just as with Git, you can retrieve the values for any version at any time, determine the values that changed between any two versions, and merge together versions.

All of this would be great on its own, but if it were isolated to a single store, it still would not be very useful in our decentralized world. So LLVS can _send_ and _receive_ versions from other stores, in the same way that you _push_ and _pull_ from other repositories with Git.

If this still has you wondering what LLVS is about, here are a few other characterizations which may help you grok it. LLVS is...

- A decentralized, versioned, key-value storage framework
- An abstractive layer for handling the ancestry of a decentralized data set
- A Directed, Acyclic Graph (DAG) history of the data in your app
- A simple means to "sync up" data sets across devices, and in the cloud
- An append-only distributed store, with full versioned history

### What is LLVS _Not_?

At this point, you are probably trying to apply labels to LLVS; trying to categorize it in terms of what you are already acquainted with. Try to keep an open mind lest you miss important, atypical aspects of the framework. To help you in this direction, here is a list of things that LLVS is _not_:

- An Object Relational Modeling (ORM) framework
- A database
- A serialization framework
- A framework for developing web services

### Where Does it Fit In?

LLVS is an abstraction. It handles the history of a dataset, without needing to know what the data actually represents, how it is stored on disk, or even how it moves between devices. 

LLVS includes some classes to get you started. You can set up a basic store using the existing storage classes (eg file based), and distribute your data using an existing cloud service (eg CloudKit), but you could also choose to add support for your own store (eg SQLite) or cloud service (eg Firebase). And you are free to use any data format you like, including serialized Swift Codable values, JSON, and end-to-end encrypted formats.


## Installing

### Swift Package Manager (SPM) in Xcode 11 or later

The easiest way to get started with LLVS is using Xcode 11 or later, which supports the Swift Package Manager (SPM). 

1. To add LLVS, choose _File > Swift Packages > Add Package Dependency..._. 
2. Enter the LLVS repo URL: [https://github.com/mentalfaculty/LLVS](https://github.com/mentalfaculty/LLVS)
3. Now enter the minimum version you require (eg 0.3.0), and add the package. 
4. Select your project in the Xcode source list on the left.
5. Select your app target and go to the _General_ tab.
6. Add the frameworks you need to your app target in the _Frameworks, Libraries, and Embedded Content_ (_e.g._ LLVS, LLVSCloudKit).

### Swift Package Manager

If you aren't building with Xcode, you can instead add this to your SPM `Package.swift`. 

```
dependencies: [
    .package(url: "https://github.com/mentalfaculty/LLVS.git, from: "0.3.0")
]
```

### Manually with Xcode

To manually add LLVS to your Xcode project...

1. Download the source code or add the project as a submodule with Git.
2. Drag the _LLVS_ root folder into your own Xcode app project.
3. Select your project in the source list, and then your app's target.
4. Add the _LLVS_ framework in the _Frameworks, Libraries, and Embedded Content_ section of the _General_ tab.

### Trying it Out First

If you don't want to go to the trouble of installing the framework, but do want to test it out in practice, you can try out the LoCo sample app via Test Flight. Use the link below to add the app to Test Flight on your iOS device.

[https://testflight.apple.com/join/nMfzRxt4](https://testflight.apple.com/join/nMfzRxt4)


## Quick Start

This section gets you up and running as fast as possible with a iOS app that syncs via CloudKit. 

### The Message

We are going to walk through a project called 'TheMessage', which you can find in the _Samples_ directory. It's about the simplest app you can envisage, which is exactly why it is useful for our purposes. 

A single message is shown on the screen. The user can edit the message if they choose. The message is saved into an LLVS store, and syncs via the CloudKit public database to anyone else using the app. So the message is shared between all users, and can be updated by any of them — they all share the same LLVS distributed store.

### Setting Up the Project

Before we look at the code, let's walk through some aspects of setting up the project.

#### Creating the Xcode Project

TheMessage was generated as an Xcode project using the _Single View App_ template. We will be using SwiftUI for the view layer, so make sure that is checked.

#### Adding LLVS

With a project in place, we now need to add LLVS. You can use any of the approaches in the section on Installing above. 

The approach taken for the sample project was to drag the LLVS root folder into the Xcode project, and then add the frameworks to the target.

The frameworks we need for TheMessage are LLVS and LLVSCloudKit.

#### Adding CloudKit

Now that LLVS is in place, we need to setup CloudKit. 

1. Select TheMessage project in the source list.
2. Select the app target, and the the _Signing & Capabilities_ tab.
3. Press the + button, and add iCloud.
4. Check the CloudKit checkbox.
5. Add a container for the app. _E.g._ "iCloud.com.yourcompany.themessage"

### Add a Store Coordinator

Most of the source code resides directly in the _AppDelegate_ file. (Do not try this at home!) 

First, we have code to setup a `StoreCoordinator` object.

```swift
lazy var storeCoordinator: StoreCoordinator = {
    LLVS.log.level = .verbose
    let coordinator = try! StoreCoordinator()
    let container = CKContainer(identifier: "iCloud.com.mentalfaculty.themessage")
    let exchange = CloudKitExchange(with: coordinator.store, 
        storeIdentifier: "MainStore", 
        cloudDatabaseDescription: .publicDatabase(container))
    coordinator.exchange = exchange
    return coordinator
}()
```

A `StoreCoordinator` takes care of a lot of the mundane aspects of managing an LLVS store, such as tracking what version of the data your app is using, and merging data from other devices. It also makes saving and fetching data more convenient, so it is perfect for your first app.

In addition to creating the `StoreCoordinator`, the code above also sets up a `CloudKitExchange`, and attaches it to the coordinator. An `Exchange` is an object that can send and receive the store data; in this case, it is sending data to CloudKit so that other devices can add it to their local store, and receiving changes made by other devices from CloudKit.

### Store Some Data

The `AppDelegate` includes the data for the message shown on screen, as well as functions to fetch it from the store, and save it to the store.

```swift
let messageId = Value.ID("MESSAGE") // Id in the store
@Published var message: String = ""
```

The message has an identifier in LLVS, called a _value identifier_. Value identifiers are the _keys_ in the LLVS key-value store. They uniquely identify a value in the store.

As you can see, we declare a single fixed identifier for our message, of the type `Value.ID`. It is set to the string "MESSAGE", but the actual value is arbitrary. We need it to be the same on all devices, but it could be any string. As long as we end up with a single identifier, so that all users are updating the same message.

Storing data in LLVS is handled by the `post` function.

```swift
/// Update the message in the store, and sync it to the cloud
func post(message: String) {
    let data = message.data(using: .utf8)!
    let newValue = Value(id: messageId, data: data)
    try! storeCoordinator.save(updating: [newValue])
    sync()
}
```

LLVS stores `Value`s, which have an identifier (_ie_ key), and contain some data. So whatever data we use in our app needs to be converted into `Data` to store in `Value`s. In this case, where the message is just a `String`, this is trivial. In more advanced apps, you would likely use `Codable` types.

To save with the `StoreCoordinator`, we simply pass in an array of values we are updating. If needed, we could also pass values to insert and remove. (Note that updating will insert the value if the value is not yet in the store.)

After updating the value, there is a sync, to ensure the data is uploaded to CloudKit. This is discussed more below.

### Fetch Data

Fetching the message from the LLVS store is just as simple.

```swift
/// Fetch the message for the current version from the store
func fetchMessage() -> String? {
    guard let value = try? storeCoordinator.value(id: messageId) else { return nil }
    return String(data: value.data, encoding: .utf8)
}
```

The `value(id:)` func of `StoreCoordinator` will return a value if it exists in the store, and `nil` otherwise. The `fetchMessage` func uses this to try to get the message value, with the same message identifier that we use in the save. If it is found, the data is extracted from the value and converted into the message `String`; if not found, the function returns `nil`.

### Sync

Syncing with LLVS is also very simple.

```swift
func sync() {
    // Exchange with the cloud
    storeCoordinator.exchange { _ in
        // Merge branches to get the latest version
        self.storeCoordinator.merge()
    }
}
```

No networking code or complex CloudKit operations needed. Just call `exchange` to send and receive any changes with the cloud, and then call `merge` to resolve any changes made between devices.

### Ship It!

The rest of the code is generic SwiftUI, and won't be covered here. All up, The Message is less than 200 lines of code. Sure, it doesn't do very much, but as we have seen above, saving, fetching, and even syncing can be achieved in just a few lines.

If we were to distribute The Message via the App Store, we would first need go to the [CloudKit Dashboard](http://icloud.developer.apple.com) and make sure the development schema gets deployed to production. 


## Advanced: The `Store` Class

The Quick Start makes use of a class called `StoreCoordinator`, which simplifies using LLVS a lot. You can ignore many of the internal details, like versions, branching, and merging. This is a good way to begin using the framework, and for many apps will be all you need.

But LLVS has a lot more to offer. It gives you full access to the history of your data. You can fetch data for any version, compare changes between versions, and apply powerful merging algorithms to create new versions.

All of this is available via the core class of LLVS: `Store`. 

### Creating a Store

A `StoreCoordinator` wraps around a `Store`, which is accessible via the `store` property, but you can also completely ignore `StoreCoordinator` and use `Store` directly. `StoreCoordinator` is just a convenience — you can do it all with `Store`.

Creating a versioned store on a single device is as simple as passing in a directory URL.

```swift
let groupDir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.mycompany.myapp")!
let rootDir = groupDir.appendingPathComponent("MyStore")
let store = Store(rootDirectoryURL: rootStoreDirectory)
```

This code uses the app group container, which is useful if you want to share data with app extensions. (LLVS stores can be shared directly between multiple processes, such as the main app and a sharing extension.)

### Inserting Values

When you first create a store, you will probably want to add some initial data.

```swift
let v1 = Value(idString: "ABCDEF", data: "First Value".data(using: .utf8)!)
let firstVersion = try store.makeVersion(basedOnPredecessor: nil, inserting: [v1])
```

This code makes a new version in the store, inserting a new value. 

The argument for `basedOnPredecessor` is `nil`, which indicates this is the first version in the store — there are no predecessor versions. (For Git users, this is the same as an initial commit.) 

Usually, you would might have a number of values to insert, update, and remove. All of this can be handled in a single call to `makeVersion`. The version made applies to the whole store, not just the values being manipulated.

If you are using `StoreCoordinator`, it will take care of storing the new version that is created; if you are using `Store` directly, it is up to you to follow which version you consider to be the current version for your app's UI. Typically, you would store it somewhere (_eg_ a variable, a file, user defaults), so that it can be used in fetching data. 

### Updating Values

Storing subsequent values is very similar. The only difference is that you need to pass in the version upon which the changes are based, which is generally the current version being used by your app.

```swift
let v2 = Value(idString: "CDEFGH", data: "My second data".data(using: .utf8)!)
let secondVersion = try store.makeVersion(basedOnPredecessor: firstVersion.id, inserting: [v2])
```

The main difference here is that a non-nil predecessor is passed in when making the version. The predecessor is the identifier of the first version we created above, _ie_, `firstVersion.id`.

### Versions are Store-Wide

It is important to realize that versions apply to the store as a whole. They are global, and form a complete history of the store, just like they do in a system like Git. Once a value has been added, it remains in existence, until it is removed or updated in a future version.

### Fetching Data

Once we have data in the store, we can retrieve it again. With LLVS you need to indicate which version of the data you want, because the store includes a complete history of changes.

```swift
let value = try store.value(idString: "CDEFGH", atVersionWithIdString: secondVersion.id.stringValue)!
let fetchedString = String(data: value.data, encoding: .utf8)
```

Here we have fetched the second value we added above, and converted it back into a string. We passed in the second version identifier; if we had passed in the first version, `nil` would have been returned, because the value had not yet been added in that version.

What about the first value we added above? That was added before the second version, so it continues to exist in future versions. So we can fetch it in exactly the same way. 

```swift
let valueId = Value.ID("ABCDEF")
let value = try store.value(id: valueId, at: secondVersion.id)!
let fetchedString = String(data: value.data, encoding: .utf8)
```

We've used a slightly different `value` func for this call, which takes the value identifier instead of a string, but the end result is the same.

### Updating and Removing Values

Just as you can _insert_ new values, you can also _update_ existing values, and _remove_ them.

```swift
let updateData = "An update of my first data".data(using: .utf8)!
let updateValue = Value(idString: "ABCDEF", data: updateData)
let removeId = Value.ID("CDEFGH")
let thirdVersion = try store.makeVersion(basedOnPredecessor: secondVersion.id, 
    updating: [updateValue], removing: [removeId])
```

The third version is based on the second one. There are two changes: it updates the value for "ABCDEF" with new data, and removes the value for "CDEFGH". 

If we now attempted to fetch the value with identifier "CDEFGH", we get `nil`.

```swift
// This will be nil
let value = try store.value(id: Value.ID("CDEFGH"), at: thirdVersion.id)
```

### Branching

If the history of changes is _serial_ — one set of changes always based on the preceding — it is easy to work with your data. It gets more complex when _concurrent_ changes are made. If two versions are added at about the same time, you can end up with divergence of your data, and this will likely need to be merged at a later time.

An example of this is when a user makes changes on two different devices, with no interceding sync. Later, when the data does get transferred, the versions branch off, rather than appearing in a continuous ancestral line. This can even happen if you are not using sync; for example, if you have a sharing extension, and it adds a version while your main app is also adding a version.

### Predecessors, Successors, and Heads

The `Version` type forms the basis of the history tracking in LLVS. A version can have up to two _predecessor_  versions upon which it is based, and it can have zero or more _successors_.

A _head_ is a version that has no successors: there are no versions based off of the head version. They form the tips of branches; if you imagine the version history as a tree, with the bottom rooted at the initial version, the heads form the tips of branches at the top.

Heads are important, because they usually represent recent changes. Most of the time, your app will use a head as the current version, and will base new versions off of a head.

Heads are also important because, if there are more than one, they generally need to be merged together to create a single head version for the app to use.

### Navigating History

The `History` class is used to query the history of the store. For example, you can ask for the heads at any time like so...

```swift
var heads: Set<Version.Identifier>?
store.queryHistory { history in
    heads = history.headIdentifiers
}
```

The `queryHistory` function gets you access to the store's history object. You need to provide it with a block, which will be called synchronously. The reason the history is not vended as a simple property is to control access from different threads. Using the block allows access to the history to be serialized, so it can't change while you are querying it.

Once you have the `History` object, you can request the heads, but you can also retrieve any version you choose.

Getting the most recent head is also easy.

```swift
let version: Version? = store.mostRecentHead
```

The most recent head is a convenient version to use when starting up an extension, or syncing for the first time on a new device. In effect, you are saying "take me to the newest data".

### Merging

One of the strengths of LLVS is that it gives you a systematic way to resolve discrepancies between versions. If two devices each edit a particular value at about the same time, you can not only identify the _conflict_, but can merge the two disparate data values together into a new consistent version.

There are two types of merges in LLVS: two-way and three-way. Most of the time you will deal with three-way merges. A three way merge involves two versions — usually heads — and one so-called _common ancestor_. A common ancestor is a version that exists in the ancestry of each of the two versions being merged; it is a point in the history where the two versions were in agreement, before they diverged.

Merging in this way is much more powerful than the facilities you get from most data modelling frameworks, because you don't just know what the latest values are, you also know what they were in the past, so you can determine what has changed.

LLVS supports a second type of merge: two-way. This happens when more than one data set is added to the store that does not have any predecessors. Effectively, you have two initial versions. 

You can get started with merging quite easily. 

```swift
let arbiter = MostRecentChangeFavoringArbiter()
let newVersion = try! store.merge(currentVersionId, with: otherHeadId, resolvingWith: arbiter)
```

If it turns out that the version for `otherHeadId` is a descendent of the current version, this will not actually add a new version, but will just return the new head. (In Git terminology, it will _fast forward_.)

However, normally the two versions will be divergent, and will need a three-way merge. The merge method will search back through the history, and find a common ancestor. It will then determine the differences between the two new versions by comparing them to the common ancestor. These differences will be passed to a `MergeArbiter` object, whose task it is to resolve any conflicts.

In this instance, we have used a built-in arbiter class called `MostRecentChangeFavoringArbiter`. As the name suggests, it will choose the most recently changed value whenever there is a conflict.

In your app, you are more likely to create your own arbiter class, to merge your data in custom ways. You can also choose to handle certain specific cases, and pass more standard tasks off to one of the existing arbiter classes.


### Inside a MergeArbiter

You might be wondering what the internals of an arbiter class look like. It's typically a loop over the differences, treating each type of conflict. One of the simplest is `MostRecentBranchFavoringArbiter`, which will simply favor the branch that has the most recent timestamp. Here is the whole class.

```swift
public class MostRecentBranchFavoringArbiter: MergeArbiter {
    
    public init() {}
    
    public func changes(toResolve merge: Merge, in store: Store) throws -> [Value.Change] {
        let v = merge.versions
        let favoredBranch: Value.Fork.Branch = v.first.timestamp >= v.second.timestamp ? .first : .second
        let favoredVersion = favoredBranch == .first ? v.first : v.second
        var changes: [Value.Change] = []
        for (valueId, fork) in merge.forksByValueIdentifier {
            switch fork {
            case let .removedAndUpdated(removeBranch):
                if removeBranch == favoredBranch {
                    changes.append(.preserveRemoval(valueId))
                } else {
                    let value = try store.value(valueId, at: favoredVersion.id)!
                    changes.append(.preserve(value.reference!))
                }
            case .twiceInserted, .twiceUpdated:
                let value = try store.value(valueId, at: favoredVersion.id)!
                changes.append(.preserve(value.reference!))
            case .inserted, .removed, .updated, .twiceRemoved:
                break
            }
        }
        return changes
    }
}
```

The engine of this class is the loop over _forks_. A fork summarizes the changes made in each branch for a single value identifier. Forks can be non-conflicting, like _.inserted_, _.removed_, _.updated_, and _.twiceRemoved_. These types involve either a change on a single branch, or a change on both branches that can be considered equivalent (_eg_ removing the value on both branches).

Alternatively, a fork can be conflicting. At a minimum, the arbiter is required to return new changes for any forks that are conflicting. This is how they _resolve_ the conflicts in the merge. They can return a completely new change to resolve a conflicting fork, or they can _preserve_ an existing change. 

You can see in the code above that when data is inserted on each branch, or updated on each branch, the arbiter _preserves_ the value from the more recent branch. When a _.removedAndUpdated_ is encountered — one branch removing the value, and another applying an update — the arbiter again preserves whichever change was made on the most recent branch.

You need not worry much about arbiters when getting started. You can just choose one of the existing classes, and start with that. Later, as you need more control, you can think about developing your own custom class that conforms to the `MergeArbiter` protocol.


### Setting Up an Exchange

LLVS is a decentralized storage framework, so you need a way to move versions between stores. For this purpose, we use an _Exchange_. An Exchange is a class that can send and receive data with the goal of moving it to/from other stores. 

CloudKit is a good choice for transferring data on Apple platforms. The `CloudKitExchange` class can be used to move data between LLVS stores using CloudKit.

To get started, we create the exchange.

```swift
self.cloudKitExchange = CloudKitExchange(with: store, storeIdentifier: "MyStore", cloudDatabaseDescription: .privateDatabaseWithCustomZone(CKContainer.default(), zoneIdentifier: "MyZone"))
```

To retrieve new versions from the cloud, we simply call the `retrieve` func, which is asynchronous, with a completion callback.

```swift
self.cloudKitExchange.retrieve { result in
    switch result {
    case let .failure(error):
        // Handle failure
    case let .success(versionIds):
        // Handle success
    }
}
```

Sending new versions to the cloud is just as easy.

```swift
self.cloudKitExchange.send { result in
    switch result {
    case let .failure(error):
        // Handle failure
    case .success:
        // Handle success
    }
}
```

LLVS has no limit on how many exchanges you setup. You can setup several for a single store, effectively pushing and pulling data via different routes. 

Exchanges are also not limited to cloud services. You can write your own peer-to-peer class which conforms to the `Exchange` protocol. LLVS even includes `FileSystemExchange`, which is an exchange that works via a directory in the file system. This is very useful for testing your app without having to use the cloud.


## Learning More

The best way to see how LLVS works in practice is to look in the provided Samples. There are very simple examples like TheMessage, but also more advanced apps like Loco-SwiftUI, a contact book app.

There are also useful posts at the [LLVS Blog](https://mentalfaculty.github.io/LLVS/).


## How to Structure Your Data

If you are looking into the sample code, bear in mind that LLVS places no restrictions on what data you put into it. It is entirely up to you how you structure your app data. LLVS gives you a means to store and move the data around, and to track how it is changing, but the data itself is opaque to the framework.

Something to consider is the granularity of the data you put in each `Value`. You can go very fine grained, putting every single property of your model types into a separate `Value`, or you can go the other extreme and put all the data in a single `Value`. A good middle ground is to put each entity in the model (_eg_ struct or class) into a `Value`.

There are tradeoffs to each of these:

- The fine grained, property level approach...
    - Works well for merging, allowing each property to be merged independently
    - Leads to slower loading, because each property must be fetched separately
    - Results in many small files on disk, each containing a single property
- The whole store in one `Value` approach...
    - Can give fast loading, because only a single file is read
    - Could lead to large disk and cloud use, as each version will add a new file with all values
    - Will generally require manual merging of all data
- The one entity per `Value` approach...
    - Works reasonably well for merging, merging each entity independently
    - Loads faster than property level storage
    - Results in moderate file numbers, and loading times
    
    
Our advice for getting started is to use the _one entity per value_ approach — it's Goldilocks.

## Features of LLVS

Here are list of LLVS features, some of which may not be apparent from the description above.

- No lock in! Use multiple services to exchange data, and switch at will
- Includes a full history of changes
- Branch and merge history
- Determine what changed between two different versions
- Work with old versions of data
- Playback changes
- Revert commits for undo purposes
- Extend to any cloud storage
- Support pure peer-to-peer exchange
- Support end-to-end encryption
- Add support for any on-disk storage (_eg_ SQLite, CouchDB, flat file)
- Systematic 3-way merging of data
- Append only, so very robust. No mutable data
- Fully thread safe. Work from any thread, and switch at any time
- Multiprocess safe. Share the same store between processes (eg extensions)
- Can safely be added to syncing folders like Dropbox (unlike SQLite, for example)


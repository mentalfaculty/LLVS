# Low-Level Versioned Store (LLVS)

_Author: Drew McCormack (@drewmccormack)_

## Introduction to LLVS

Ever wish it was as easy to move your app's data around as it is to push and pull your source code with a tool like Git? If so, read on.

### Why LLVS?

Application data is more decentralized than ever. It is rare to find it concentrated on a single device. Typically, a single user will have a multitude of devices, from phones to laptops and watches, and each device may have several independent processes running (eg today extension, sharing extension), each working with a copy of the data. How can you share all this data, giving the user a consistent picture, without writing thousands of lines of custom code to handle each scenario?

Software developers faced a similar situation in the world of source control. They were faced with this question: How can multiple individuals all work together on the same source files across multiple computers? We all know how that played out. Advances in Source Control Management (SCM) led to systems like Git and GitHub.

These tools successfully solved the problem of decentralized collaboration, and it is odd that the same approach has not been applied to app data. That's where LLVS comes in. It provides a basic framework for storing and moving data through the decentralized world in which our apps live.

### What is LLVS?

LLVS is a new kind of beast, so it is somewhat difficult to explain where it fits in. A good start might be that it is a _decentralized, versioned, key-value storage framework_.

You can think of it a bit like a traditional key-value store, in which you can insert data values for given unique keys. But LLVS adds to this several extra dimensions, namely, that every time a value is stored, it gets assigned a version, and each version has an ancestry of other versions which you can trace back in time. Just as with Git, you can retrieve the values for any version you like, determine the differences between two versions, and merge together versions.

All of this would be great on its own, but if it were isolated in a single store, it still would not be very useful in our decentralized world. So LLVS can _send_ and _receive_ versions from other stores, in the same way that you _pull_ and _push_ from other repositories with Git.

If this still has you wondering what LLVS is about, here are a few other descriptions which may help you grok it. LLVS is...

- A decentralized, versioned, key-value storage framework
- An abstractive layer for handling the ancestry of a decentralized data set
- A Directed, Acyclic Graph (DAG) history of the data in your app
- A simple means to "sync up" data sets across devices, and in the cloud

### What is LLVS _Not_?

At this point, you are probably trying to apply labels to LLVS; trying to categorize it in terms of what you already know. I urge you to resist that, and to keep an open mind. To help you along, here are some things that LLVS certainly is not...

- An Object Relational Modeling (ORM) framework
- A database
- A serialization framework
- A framework for developing web services

### Where Does it Fit In?

LLVS is an abstraction. It handles the history of a dataset, without needing to know what the data actually represents, how it it stored on disk, or even how it moves between devices. 

LLVS includes some classes to get you started. You can set up a basic store using the existing storage classes (eg file based), and distribute your data using an existing cloud service (eg CloudKit), but you could also choose to add support for your own store or cloud service. And you are free to use any data format you like, including serialized Swift Codable values, JSON, and end-to-end encrypted formats.

## Some Simple Examples

### Creating a Store

### Storing Values
- Initial
- Subsequent

### Setting Up an Exchange

### Sending and Receiving

### Merging

## Installing

## Advantages of LLVS
- Full history of changes. 
    - You can fork and merge as much as you like.
    - You can diff two versions to get what changed
    - Checkout old versions
    - Playback changes
    - Revert commits for undo purposes
- No lock in
- Easy to extend to any cloud storage
- Can support pure peer-to-peer
- Can work with fully encrypted data
- Can add support for any on-disk storage you like. Sqlite, CouchDB, flat file, etc.
- Systematic 3-way merging of data. Use the built in arbiter, or create your own. You have full conrol.
- Extremely robust, because append only
- Multithreading is no problem, unlike ORMs
- Multiprocess is no problem. Great for extensions. No need to even send/receive (unless you prefer that)
- No risk of data conflicts. You can keep using your version until you are ready to merge. If other versions are added, they don't invalidate your data.

## FAQ

- Is there a version for Android?
    - No, but would love one
- Is there LLVS in the cloud?
    - No, but that would be awesome.

## Important Objectives

### Simple
- Just a simple key-value store, with a versioned history like Git
- No assumptions about what the values are. Could be anything from JSON to encrypted data and JPEG images.

### Very robust
- A crash should not render a store unusable. At worst, the most recent changes may be lost.
- LLVS should be resilient to all but deliberate tampering and disk level corruption.
- Corrupted SQLite databases caused by an unlucky crash during saving should be a thing of the past.

### Append Only
- Files in LLVS are immutable. No file should ever be updated once created.
- Merging two stores is equivalent to just taking the union of all files and directories.

### Versioned
- Works with versioned history.
- Can check out any version. Each version is a complete snapshot of the store.
- Can branch off into concurrent branches.
- Can merge branches, using powerful three-way merging.
- Can implement advanced features like undo, without losing changes introduced by sync.

### Concurrent
- Read/write from multiple threads/processes concurrently without corruption or locking

### Global
- Should be straightforward to sync a store with a server or via file system.
- Should be possible to put a store in a shared file system like Dropbox and sync that way.

### Programming Language, Operating System Agnostic
- Can create a store using any language, on any device, and with any operating system
- Can even author stores by hand if you really want to

### FilterMaping
- Support for basic mapes
- FilterMapes are versioned along with the values

# Low-Level Versioned Store (LLVS)

LLVS is the little store that could. It's a simple file based storage system, which is very robust, and supports a versioning system very similar to source control management systems such as Git.

## Important Objectives

### Simple
- Works with ubiquitous format (JSON)
- Only stores arrays, dictionaries and strings
- No types, model versioning, or migration included, but features to build these.

### Very robust
- It is inexcusable that a crash can render a store unreadable.
- LLVS should be resilient to all but deliberate tampering and disk level corruption.
- Corrupted SQLite databases caused by an unlucky crash during saving should be a thing of the past.

### Append Only
- Files in LLVS are immutable. No file should ever be updated once created.

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

### Fetching of Versioned Objects
- Can fetch a snapshot of data, given 

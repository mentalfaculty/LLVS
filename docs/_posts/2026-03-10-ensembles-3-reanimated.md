# Ensembles 3: Reanimated

*TLDR; I used [Claude Code](https://docs.anthropic.com/en/docs/agents-and-tools/claude-code/overview) to rewrite [Ensembles](https://ensembles.io) — my 13-year-old Objective-C sync framework — in Swift 6. It now supports SwiftData, has new backends, and is in beta.*

In 2013, I was struggling to ship cloud sync in my app [Mental Case](https://www.intua.net/mentalcase/). I had been using Apple's iCloud Core Data sync, and it was a disaster. Data would corrupt silently. Devices would diverge and never recover. I spent more time debugging Apple's sync than building my own app.

So I reverse engineered it. I dug into what Apple was doing under the hood, identified the problems, and built my own replacement. I called it Ensembles and pushed it to GitHub at [GOTO Aarhus](https://gotocon.com) later that year.

The core idea behind Ensembles is that sync doesn't need a central server. Each device keeps its own copy of the Core Data store. The framework monitors your saves, generates compact change logs, and merges in changes when they arrive from other devices. There's no server that understands your data model — each device is an equal peer.

In 2013, nobody had a word for this. It was just "sync". I released Ensembles as open source, and later a more capable commercial version (source available) called Ensembles 2, with CloudKit support, better memory usage, and additional backends.

Since then, the web community has given this approach a name: *local-first*. I attended the inaugural [Local-First Conf](https://www.localfirstconf.com) in Berlin in 2024 and gave a short talk about Ensembles — at that point more than 10 years old. It was good to see so much energy around ideas that Apple platform developers had been using for a long time. Having a word for something means you can have a conference about it, and push it forward.

## An old framework in a new world

The original Ensembles was written in Objective-C. It worked with Core Data. And it still worked fine — the code was solid and I was maintaining it. But the world had moved on. Apple introduced SwiftData. The community was adopting Swift 6 with strict concurrency. Nobody starts a new Objective-C project in 2026.

I was expecting a long, slow decline. Keep it compiling, fix the odd issue, watch it fade out.

## What if?

About a week ago, I decided to try something: use Claude Code to rewrite Ensembles in Swift 6.

Not a wrapper around the old code. A real rewrite: `async`/`await`, `Sendable` types, structured concurrency. New backends. And maybe — the stretch goal — SwiftData support alongside Core Data.

## A week later

The core Swift rewrite was compiling and passing tests after about a day of work. I was guiding Claude Code throughout — correcting mistakes, steering it away from bad decisions. It made plenty of them. But the existing architecture translated reasonably well to Swift, which helped.

One thing that made this feasible: Ensembles had extensive tests. Without those, I wouldn't have attempted it. When you're rewriting a sync framework — where bugs mean data loss — you need to know things actually work. The tests caught real problems in the generated code, and I'd fix them and run the suite again. Without that feedback loop, this would have been reckless rather than productive.

By the second day, I was adding backends. SwiftData support came together after that. The rest of the week was cleanup — licensing, documentation, more tests — and [Ensembles 3](https://github.com/mentalfaculty/Ensembles3) is now in beta.

## What Ensembles 3 is

For anyone who hasn't used the original: Ensembles is a peer-to-peer sync framework for Apple platforms. You add it to your app, point it at your Core Data or SwiftData store, choose a backend, and data syncs across devices. No server required.

The fundamental architecture hasn't changed. What's new:

- Pure Swift 6 with structured concurrency
- SwiftData support alongside Core Data
- More backends

## The AI in the room

I know a lot of people are angry about LLMs, and with good reason. I wrote a [bleak post](https://appdecentral.com/2025/01/30/welcome-to-the-machine/) in January about what they're doing to our industry and our world. I stand by every word.

But I want to be straightforward about what happened here. This rewrite would have taken months by hand — months I didn't have and probably wouldn't have committed. Ensembles was heading for retirement. That's the context for why I tried this approach.

I don't want to overstate this. I made the decisions throughout. I know the architecture inside out — I designed it. Claude Code needed constant guidance and made plenty of mistakes. It's not a story about AI replacing a developer. It's more mundane than that: a tool that sped up a particular kind of tedious work.

Whether that's a good thing probably depends on where you sit. In this specific case, an open source framework got an update it wasn't going to get any other way. Make of that what you will.

## Give it a try

Ensembles 3 is on [GitHub](https://github.com/mentalfaculty/Ensembles3). It's a beta, so expect rough edges. If you have a Core Data or SwiftData app and want local-first sync without running a server, take a look.

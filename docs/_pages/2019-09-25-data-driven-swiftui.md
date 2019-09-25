---
title: You're up and running!
---

Next you can update your site name, avatar and other options using the _config.yml file in the root of your repository (shown below).

![_config.yml]({{ site.baseurl }}/images/config.png)

The easiest way to make your first post is to edit this one. Go into /_posts/ and update the Hello World markdown file. For more instructions head over to the [Jekyll Now repository](https://github.com/barryclark/jekyll-now) on GitHub.


SwiftUI has set us all thinking about the future of development on Apple's platforms. It's a disruptive technology which will supersede a development stack dating back more than 20 years to the pre-Mac OS X era. It's disruptive to be sure, but is it disruptive enough? While we're at it, should we be pulling the plug on a few more of our mainstays?

Even with SwiftUI in constant flux, there is already plenty of great content around for learning  the new framework. I've spent several weeks working on side projects in an effort to 'kick the tires'; the tutorials and API descriptions others have compiled have been indespensible. And yet, I can't help feeling it's all code that is fully clothed above the waist, but pantless below. The king is only half dressed. There is a enormous, data-model-sized elephant in the SwiftUI room.

Most SwiftUI examples rely heavily on the `@State` property wrapper. This is a convenient way to include some mutable state without having to think much about the controllers and data models which make up the state of a real app. This is fully understandable, because the framework is so new, and we are still fixated with how to handle animation, layout, and a multitude of other UI concerns. But recently, I've started to focus on the next step: How do you go from the tutorials and demos to real world, scalable apps? How do you build a SwiftUI app from the ground up?

## Structs atop Classes

One of the most perplexing aspects of the situation as it stands is that we have a framework for UI which is built around value types — `View` structs — while being encouraged to use reference types for our model. Model types are still typically represented by classes, and Apple's own solution for data storage, Core Data, is firmly established in the realm of reference types.

This feels upside down to me. If I were to choose to use value types in either model or view, I would be inclined to pick the model first. In fact, in the app [Agenda](https://agenda.com), we took exactly this approach: the model is made up of value types, and the view utilizes standard AppKit/UIKit, _ie_, classes.

## Values All the Way Down

Of course, one need not exclude the other. Maybe the best solution is to use value types in both the view _and_ the model. It's this option I want to explore in the rest of the post. But I want to take it a step further, not only using value types throughout an app, but using immutable data throughout, right down to the on disk store.

```
for i in [.hi] {
}
```


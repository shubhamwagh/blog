---
date: 2026-08-30 12:00:00
description: I added comments and analytics to this blog. Then the comments silently vanished on every in-site click, and signing in could make them disappear entirely. The culprit was a JavaScript race condition between a deferred script and an inline one.
categories:
  - Homelab Journal
  - Blog
  - Meta
tags:
  - homelab
  - blog
  - javascript
  - debugging
  - giscus
  - mkdocs
comments: true
series: Building a Self-Hosted Homelab
---

# Why My Blog Comments Kept Disappearing (A JavaScript Race Condition)

I run this blog on [MkDocs Material](https://squidfunk.github.io/mkdocs-material/), built and served from the homelab itself. A while back I finally added the two things almost every blog eventually wants: reader comments (via [giscus](https://giscus.app), which turns a GitHub Discussion into a comment thread) and privacy-friendly analytics (self-hosted Umami). I wired them in, watched them work on a hard refresh, and moved on.

Then two things started bugging me. Comments would be there one minute and gone the next. And my analytics numbers looked suspiciously low. Neither failed loudly — they just quietly broke. This is the story of chasing both down and finding the same class of script-timing bug underneath.

<!-- more -->

## Symptom 1: comments vanish the moment you click

The first report came from a reader: they'd open a post from the homepage, read it, and there'd be no comment box. Refresh the page directly and it came back.

The pattern was the clue. Comments were missing *only* when you arrived via an in-site link, never on a hard reload.

MkDocs Material has a feature called **instant loading** (`navigation.instant`). Instead of a full page navigation, it fetches the next page and swaps the content in place, like a single-page app. That's great for speed — but it means scripts that ran on the initial load don't automatically run again. My giscus embed was a plain `<script>` tag that executed exactly once, on first paint. After an in-site click, the post content was swapped in, the old giscus iframe was thrown away, and nothing re-created it. Silently.

The fix is to hook Material's own lifecycle. Material exposes a tiny observable called `document$` that fires on every instant-navigation (and on the initial load). Subscribe to it, and rebuild the comments widget each time:

```html
<script>
  document$.subscribe(function () {
    var container = document.getElementById("__comments-container")
    if (!container) return
    container.innerHTML = ""   // wipe the previous post's iframe too
    var script = document.createElement("script")
    script.src = "https://giscus.app/client.js"
    script.setAttribute("data-repo", "shubhamwagh/blog")
    script.setAttribute("data-category", "Announcements")
    script.setAttribute("data-mapping", "pathname")
    script.setAttribute("data-theme", "preferred_color_scheme")
    script.async = true
    container.appendChild(script)
  })
</script>
```

Two sub-bugs bit me on the way to that version. First, the script has to live in its own container `<div>`, not nested inside the `<h2>` "Comments" heading — otherwise giscus's iframe lands *inside* the heading, which is structurally wrong. Second, removing only the old `<script src="...giscus...">` tag leaves its already-inserted `<iframe>` behind, so the previous page's stale frame just sits there. Clearing `container.innerHTML = ""` removes both.

## Symptom 2: the real root cause — a race on every hard load

I thought I was done. Then I tested a proper **hard reload** in a real browser (not just clicking around the site), and the comments were gone again — with no in-site navigation at all. And worse: signing in to comment (giscus does an OAuth round-trip that redirects back with `?giscus=<token>`) could make the box vanish at the exact moment it was needed.

The browser console told the story in five words:

```
Uncaught ReferenceError: document$ is not defined
```

Here's what was happening. That block above *uses* `document$`. But `document$` is defined by Material's own JavaScript **bundle** — and that bundle is loaded with `defer` (or as a module), which means it runs *after* the HTML is parsed, not during. My inline `<script>` runs at its position in the page, immediately, while the document is still being parsed. On a hard load, the order is a race: my script can run before Material's bundle has defined `document$`. Lose the race and the whole script throws and dies before it ever appends giscus. Comments never appear.

Why did a hard reload expose it but clicking around didn't? On an in-site navigation, Material's bundle is already loaded and `document$` already exists — the race only happens on the very first parse of a fresh page. And the OAuth callback is a fresh page load at the worst possible moment.

The fix is to stop *assuming* `document$` exists and poll for it:

```html
(function initComments() {
  if (typeof document$ === "undefined") {
    setTimeout(initComments, 50)   // bundle not ready yet; try again shortly
    return
  }
  document$.subscribe(function () {
    // build the widget (clear container, append giscus script)
  })
})()
```

Fifty milliseconds later Material's bundle has run, `document$` is defined, and the subscription registers. The race is gone.

## The analytics twin

The same class of bug had quietly broken my analytics too. Umami's tracking script was loaded with `data-auto-track="false"` and I was calling `umami.track()` manually — but only on the initial load, so in-site navigations weren't counted. Wrapping that call in a `DOMContentLoaded` listener that subscribes to `document$` fixed it the same way: every instant-navigation now fires a track, and `DOMContentLoaded` guarantees Material's deferred bundle has already run by the time the handler executes.

## An honest caveat

One part I have *not* fully closed: giscus is pointed at an "Announcements" discussion category, and giscus can't actually surface an Announcements-type category — it needs a plain "Discussion"-type category in the repo. Until that exists, the widget can still render blank even when everything else is wired correctly. Creating that category is a manual step in the GitHub repo that I still need to do; the code fix above is real and shipped, but the category config is the remaining half of the story. (On a post that's never received a comment, "Discussion not found" is expected and harmless — giscus lazily creates the thread on first submission.)

## What I took away

- **Deferred and module scripts run after parsing.** Inline scripts in `<head>` or early `<body>` can run before them. Order is not guaranteed — it's a race.
- **"It ran once" is not "it runs when needed."** Single-page-app-style navigation means you must subscribe to the framework's lifecycle, not assume a script re-executes.
- **Test a hard reload and the real auth/callback paths**, not just happy-path clicks. The bug lived exactly where my testing didn't.
- **Read your own rendered output.** Both of these failed silently — no error in my face until I opened the console on a real load.

If you self-host a MkDocs Material blog (or any instant-navigation site), the same two patterns — *subscribe to `document$`*, and *poll for it if it might not exist yet* — will save you an afternoon.

---

*This is part of the [Building a Self-Hosted Homelab](/hello-world/) series. The previous post, [How I Locked Down My Homelab Bot](/how-i-locked-down-my-homelab-bot/), is the other side of "things that broke and taught me something" — there it was cluster access, here it's the blog's own frontend. For how this blog reaches the public internet at all, see [How My Homelab Blog Got a Public URL Without Opening a Port](/how-my-homelab-blog-got-a-public-url-without-opening-a-port/).*

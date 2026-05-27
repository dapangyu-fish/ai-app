# App Store Compliance Notes

This document explains how MyApp's JSON-APP runtime works for reviewers,
operators, and contributors. It is not legal advice.

## Runtime Boundary

MyApp does not download or execute arbitrary native code. The iOS, Android,
desktop, and Web clients contain a precompiled Flutter runtime with a fixed set
of widgets, actions, game atoms, IM APIs, media APIs, storage helpers, and
network helpers.

Generated apps are JSON documents. A JSON-APP can describe:

- screen structure and layout;
- text, images, video, and other data assets;
- state variables and JsonLogic expressions;
- calls to precompiled, whitelisted runtime functions;
- package dependencies resolved by the registry.

A JSON-APP cannot add new Dart, Swift, Kotlin, JavaScript, native plugins,
system permissions, background services, or executable binaries. If a capability
is not already compiled into the client runtime, JSON cannot create it.

## AI-Generated Apps

The AI generation flow produces declarative JSON configuration, not executable
code. The backend validates generated JSON packages before publishing or
returning them to the client. The client then interprets the JSON inside the
same fixed runtime boundary described above.

Assets such as PNG, MP4, TMX/JSON map data, and package manifests are data files.
They may change an app's content, layout, or behavior inside the allowed DSL,
but they do not extend the native runtime.

If a JSON app opens a web page, it is treated as normal web content. It is not a
mechanism for adding native client capabilities or bypassing the compiled
runtime boundary.

## Marketplace And User Apps

The marketplace distributes JSON packages and asset references. Each package is
versioned, searchable, and removable. User-created JSON apps belong to their
authors; the project license for this repository does not automatically relicense
marketplace content.

## Reviewer Note Template

MyApp does not use dynamic executable code delivery. AI-generated apps are JSON
configuration files that describe UI layout and business logic. The client
renders them with precompiled Flutter widgets and a fixed whitelist of runtime
actions. JSON cannot add native APIs, plugins, permissions, or executable code.
All available capabilities are already present in the submitted client binary.

Suggested test flow:

1. Sign in.
2. Tap the floating AI button.
3. Ask the AI to generate a small app, for example: "Create a whack-a-mole game."
4. Open the returned JSON app and verify that it runs inside the MyApp runtime.

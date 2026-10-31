<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="Assets/Wordmark.png">
    <img src="Assets/Wordmark-light.png" alt="lit" height="84">
  </picture>
</p>

<p align="center"><b>Simple, honest photo editing for macOS.</b></p>

lit is a tiny photo editor: a download of under 1 MB that opens in a blink, with no catalogue
to import into and nothing to set up. Open a photo, adjust, export.

A camera rarely sees exactly what you saw. The sky was a little deeper, the shadows held more
detail, the light was warmer than the file remembers. lit is for those small tweaks that bring
a photo back to the moment, with a handful of basic controls and nothing more.

## Panoramas

Drop 2 to 9 overlapping photos on the window and lit stitches them into one, in a single row
or a few rows. A live preview shows the result as you go, and you can choose between
two projections. If you shot RAW + JPEG, lit quietly builds from the RAW files for the best
quality.

## What it does

A few simple sliders for light and colour, graduated filters you can drag across the sky,
and panoramas. That's the heart of it.

lit is made with landscape photographers in mind, and it deliberately doesn't have every
bell and whistle. Around the basics there are a few small, honest helpers: crop and
straighten, your camera's own lens corrections, and a dust speck tool for sensor spots.

## What it won't do

lit improves slightly on what came straight out of your camera. It doesn't change what was
there. No content-aware fill, no sky replacement, no auto-generated anything, no AI "looks".
Keeping it real is the point. Even the dust speck tool is deliberately dust-sized.

## Your privacy: nothing leaves your Mac

lit collects **zero** data. No analytics, no statistics, no crash reports, no accounts, no
"phoning home". It doesn't contain a single line of networking code, so it never connects to
the internet at all. Your photos and edits stay on your Mac, and the source code is right here
for anyone to check.

## Free and open source

lit is free and open source under the [MIT License](LICENSE). Use it, study it, change it,
share it, build your own version on top of it. Go nuts.

## Install

### [⬇ Download lit](https://github.com/sandeep-josyula/lit/releases/latest/download/LIT.zip)

**You'll need** a Mac with Apple silicon (M1 or newer) running macOS 14 Sonoma or later.

1. **Unzip** `LIT.zip` by double-clicking it.
2. **Drag LIT** into your **Applications** folder.
3. **Open LIT.** The first time, macOS will say it can't check LIT for malicious software
   and won't open it. That's expected: lit isn't registered with Apple yet (see below).
   To allow it, once:
   - Open **System Settings → Privacy & Security**.
   - Scroll down to *"LIT" was blocked to protect your Mac* and click **Open Anyway**.
   - Enter your password and click **Open**.

From then on LIT opens like any other app. Drop a photo on the window to start.

> **Why the warning?** Apple only lets apps open without it once the developer has paid for
> an Apple Developer ID and Apple has scanned ("notarized") the app. lit hasn't been through
> that yet. Only allow it if you got LIT from someone you trust.

**To remove lit**, drag it from Applications to the Trash. Your saved edits live in
`~/Library/Application Support/LIT` and can be deleted too. Your photos are never touched.

## Handy keys

| | |
|---|---|
| **E** · **G** · **C** · **D** | Edit · Gradient · Crop · Dust |
| **Z** or pinch | Zoom to 100% and back (space-drag to look around) |
| **\\** | Before / after |
| **B** | Black or white background |
| **J** | Show clipped highlights and shadows |
| **O** | Show where a gradient is strongest |
| **⌘E** | Export |
| **⇧⌘P** | Build a panorama |

On any slider: double-click to reset, hold ⌥ for fine control, or click the number to type.

---

<details>
<summary>For the curious</summary>

lit is written in Swift with Apple's Core Image; there are no other dependencies. RAW files
are decoded by Apple's RAW engine, then everything runs on the GPU in linear light. Sony lens
corrections come from the data the camera stores in each ARW. Panoramas are projected
(cylindrical or rectilinear), aligned with FFT phase correlation plus rotation refinement,
exposure-matched and blended. The code lives in `Sources/LitCore` (engine), `Sources/Lit`
(app) and `Sources/lit-cli` (a test tool).

Thanks to the [darktable](https://www.darktable.org) project, whose open documentation and
code showed how Sony stores lens corrections in ARW files. lit's implementation is its own.

**Build it yourself** (needs Xcode):

```sh
scripts/build-app.sh --install   # builds LIT.app and copies it to /Applications
```

**Share it** as the `LIT.zip` the steps above expect:

```sh
scripts/build-app.sh && ditto -c -k --keepParent build/LIT.app build/LIT.zip
```

</details>

## Need something?

lit stays small on purpose, but if there's a feature you really need, ask.
[Open a feature request](https://github.com/sandeep-josyula/lit/issues/new) and tell us how
you'd use it.

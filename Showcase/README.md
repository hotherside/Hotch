# Hotch showcase source

This is the 21.2-second showcase for Hotch 2.2.0 used at the top of the repository's README. It animates the app's own renders: the edge tab opens AI usage, Sessions and This Mac, an alert grows out of the tab, and Hotch moves to a pill, an orb and the Dock. The motion is composed in HyperFrames; it is not a screen recording.

The compositions use Hotch's native demo snapshots with fictional session names. `BRIEF.md`, `SPEC.md`, and `REVIEW.md` describe the intent and validation. No live account screenshots or session transcripts are included. The 2.1.3 version of this showcase is in the repository history.

## Refresh the UI renders

After a UI change, build the app and replace the parts in `assets/ui` from the repository root:

```sh
make app
build/Hotch.app/Contents/MacOS/Hotch --snapshot-parts build/parts --snapshot-dark
cp build/parts/{tab,tab-alert,rail-ai,rail-sessions,rail-mac,card-now,card-ai,card-sessions,card-mac,pill,pill-alert,orb,orb-alert,bottom,bottom-alert}.png Showcase/assets/ui/
```

If a part changes size, update its box and clip values in `compositions/`, then check the frames.

## Preview and render

Install Node.js, npm, and FFmpeg, then run commands from this directory:

```sh
npm run dev
npm run check
npx hyperframes@0.8.185 render -o renders/hotch-showcase.mp4 --fps 30 --quality delivery
```

The scripts pin HyperFrames to version `0.8.185`; the first run downloads it through npm, and rendering also needs its headless Chrome (`npx hyperframes@0.8.185 browser ensure`). The composition loads GSAP `3.14.2` from jsDelivr, so previewing and rendering require network access. Read `AGENTS.md` before changing compositions.

To produce the README media from the render (1280 px, 15 fps GIF, about 4 MB):

```sh
ffmpeg -i renders/hotch-showcase.mp4 -vf "fps=15,scale=1280:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -loop 0 ../docs/images/hotch-showcase.gif
ffmpeg -i renders/hotch-showcase.mp4 -c copy -movflags +faststart ../docs/media/hotch-showcase.mp4
```

Rendered videos, thumbnails, preview files, and local HyperFrames session state are excluded from Git. Source compositions and their input assets are retained here.

## Third-party assets

The bundled Bricolage Grotesque font is distributed under the SIL Open Font License in `assets/fonts/OFL.txt`. Its upstream source is [Bricolage Grotesque](https://github.com/ateliertriay/bricolage). The repository's MIT license does not replace the font's license. HyperFrames and the externally loaded GSAP library retain their respective upstream licenses.

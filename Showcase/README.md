# Hotch showcase source

The 26-second reel and the README GIF show the real app. `Hotch --demo-tour` runs the real anchors on demo data and plays a fixed sequence, `tools/record-tour.swift` records only Hotch's windows (no desktop, no other apps), and that recording is placed on a stand-in desktop and framed here with HyperFrames. A dark and a light take are recorded with the same timing, so the reel can sweep between them mid-motion.

Nothing in the footage is a mock-up of Hotch: the cards, tab, notch panel, alerts, pill, orb and Dock bar are the app drawing itself. The desktop (wallpaper, menu bar, terminal, Dock icons) is drawn in `plates/desktop.html`, and the notch is a stand-in for a 14" MacBook Pro's. The session names and figures are fictional.

## Rebuild the footage

From the repository root, with Node.js, npm and FFmpeg installed. The recorder needs Screen Recording permission for the terminal that runs it; leave the mouse alone while it records (about 55 seconds a take).

```sh
make app
swift tools/record-tour.swift build/Hotch.app/Contents/MacOS/Hotch build/tour-dark.mov --dark
swift tools/record-tour.swift build/Hotch.app/Contents/MacOS/Hotch build/tour-light.mov
```

Each take writes a `.log` beside it with every step's time and the windows' frames. Render the two desktop plates at 2x from `Showcase/plates/desktop.html` (add `?theme=light` for the light one) at 2560 x 1440, then place each take on its plate:

```sh
ffmpeg -loop 1 -framerate 60 -i plate-dark.png -i build/tour-dark.mov -filter_complex "[0]format=gbrap[bg];[1]fps=60,format=gbrap[fg];[bg][fg]overlay=shortest=1:format=auto,scale=3840:2160:flags=lanczos:out_color_matrix=bt709:out_range=tv,format=yuv420p" -c:v libx264 -crf 14 -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart Showcase/footage/desk-dark.mp4
```

Repeat for the light take, and save the plates as `Showcase/footage/plate-dark.jpg` and `plate-light.jpg` at 3840 x 2160. `Showcase/footage` is not in Git.

The timings in `index.html` follow the step times in the logs (see the comments there). If `DemoTour.swift` changes its steps, update the clip offsets and camera moves to match.

## Preview and render

```sh
cd Showcase
npm run check
npx hyperframes@0.8.185 render -o renders/hotch-reel.mp4 --fps 60 --quality delivery
```

The scripts pin HyperFrames to version `0.8.185`; rendering needs its headless Chrome (`npx hyperframes@0.8.185 browser ensure`). The composition loads GSAP `3.14.2` from jsDelivr, so previewing and rendering need network access. Read `AGENTS.md` before changing compositions.

README media from the render (the first 16 seconds as a 1080 px, 15 fps GIF, about 5 MB, and the whole reel):

```sh
ffmpeg -ss 1.2 -t 16.1 -i renders/hotch-reel.mp4 -vf "fps=15,scale=1080:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle" -loop 0 ../docs/marketing/video/hotch-reel.gif
ffmpeg -i renders/hotch-reel.mp4 -c copy -movflags +faststart ../docs/marketing/video/hotch-reel.mp4
```

## Stills

`stills/stills.html` crops the marketing stills from full-resolution frames of the takes (`Showcase/footage/frames`, each a take's frame placed on its plate at 5120 x 2880). Open it with `?shot=hero`, `split`, `notch`, `alert`, `homes` or `social` and render at 2x; the results live in `docs/marketing/stills` and `docs/marketing/social`.

## Fonts and third-party assets

Captions and titles use Inter, distributed under the SIL Open Font License (`assets/fonts/Inter-OFL.txt`, upstream [rsms/inter](https://github.com/rsms/inter)). Apple's SF Pro is licensed for interface mock-ups only, so it is not used for marketing type; the app's own interface in the footage is drawn by macOS as usual. The repository's MIT license does not replace the font's license. HyperFrames and the externally loaded GSAP library retain their own licenses.

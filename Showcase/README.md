# Hotch showcase source

This is the original 20.5-second showcase for Hotch 2.1.3, preserved for contributors who want to work on product videos. It depicts the earlier three-ring tab and does not represent the current 2.2.0 interface. The current app overview is in the repository's main README.

The compositions use Hotch's native demo snapshots with fictional session names. `BRIEF.md`, `SPEC.md`, and `REVIEW.md` describe the original intent and validation. No live account screenshots or session transcripts are included.

## Preview and render

Install Node.js and npm, then run commands from this directory:

```sh
npm run dev
npm run check
npm run render
```

The scripts pin HyperFrames to version `0.8.185`; the first run downloads it through npm. The composition loads GSAP `3.14.2` from jsDelivr, so previewing and rendering require network access. Read `AGENTS.md` before changing compositions.

Rendered videos, thumbnails, preview files, and local HyperFrames session state are excluded from Git. Source compositions and their input assets are retained here.

## Third-party assets

The bundled Bricolage Grotesque font is distributed under the SIL Open Font License in `assets/fonts/OFL.txt`. Its upstream source is [Bricolage Grotesque](https://github.com/ateliertriay/bricolage). The repository's MIT license does not replace the font's license. HyperFrames and the externally loaded GSAP library retain their respective upstream licenses.

# Review: Hotch showcase

## Creative calls

- One continuous desktop at 2x, so every piece of Hotch shows at the size it reads in the app.
  All Hotch UI is the app's own render (`Hotch --snapshot-parts --snapshot-dark`), sample data
  with neutral session names. The Dock tiles and the menu bar are plain stand-ins; the menu bar's
  status item redraws Hotch's glyph.
- The card hangs from a fixed top beside the tab and resizes downward, the way 2.2.0 attaches it.
  Resting on a readout opens that readout's section (the app's dwell behaviour), so the walk opens
  on AI, then clicks the Sessions readout and the card's Mac tab to show both ways to switch.
- Captions carry the story because a GIF has no sound. The homes beat uses a rolling last word.
- The end card redraws the app icon's companion curve and warm signal from `HotchIcon.swift`.
- Not built: a cut that shows the session's app coming forward after the alert click (no real
  screen of that app to show), the Now, Focus and Clipboard sections (the README's native tour
  covers them), and the Notch and menu bar homes.

## What was measured, what was only looked at

- `check`: 0 errors. Kept warnings: `film_silent` (a GIF carries no sound, by design);
  `timeline_track_too_dense` (six captions on one track in the walk scene, readable as is).
  Menu bar text is 26 px at 2x and marked `data-layout-ignore` as texture.
- Looked at frames 1.9, 2.3, 3.4, 5.0, 5.06, 6.0, 7.6, 9.62, 10.4, 11.2, 14.0, 15.6, 16.0, 17.4
  and 20.4, and at GIF frames 7.6 and 15.0 at 1280 px.
- Not checked: the GIF on a phone.

## Weakest shot

The alert click at 10.75 s: the bubble retracts and the caption says what happens, but nothing on
screen shows the session's app coming forward. With a real screenshot of that moment it would land.

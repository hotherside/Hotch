# Review: Hotch showcase

## Creative calls

- One continuous desktop at 2x, so every piece of Hotch shows at the size it reads in the app.
  All Hotch UI is the app's own render (`Hotch --snapshot-parts --snapshot-dark`), sample data
  with neutral session names. The Dock tiles and the menu bar are plain stand-ins, not Hotch.
- The card is split into card and rail renders so it resizes against a fixed rail the way the
  app does, with the app's blur-fade on the content.
- Hover the memory ring opens This Mac (the app's ring-to-section behaviour), then Sessions, then AI.
- Captions carry the story because a GIF has no sound. The homes beat uses a rolling last word.
- Not built: a cut that shows the session's app coming forward after the alert click (no real
  screen of that app to show), and the menu bar home.

## What was measured, what was only looked at

- `check`: 0 errors. Kept warnings: `film_silent` (a GIF carries no sound, by design);
  `timeline_track_too_dense` (five captions on one track in the walk scene, readable as is).
  Menu bar text is 26 px at 2x and marked `data-layout-ignore` as texture.
- Looked at frames 0.5, 2.2, 3.6, 5.08, 6.0, 8.35, 9.9, 13.8, 15.0, 16.3, 19.6 and 20.08.
- Not checked: real-time feel at full speed beyond the render, and the GIF on a phone.

## Weakest shot

The alert click at 9.95 s: the bubble retracts and the caption says what happens, but nothing on
screen shows the session's app coming forward. With a real screenshot of that moment it would land.

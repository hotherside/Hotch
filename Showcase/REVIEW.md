# Review: Hotch reel

## Creative calls

- Real motion over imitation: the card's spring, page changes, alert bubbles, the notch panel and
  the homes are the app's own animation, recorded with `--demo-tour`. Only the cursor and camera
  are added, and the cursor lands where the tour acts at the moment it acts.
- Two takes with the same timing (within about 30 ms) make the light and dark sweep possible
  across a live card, rather than a crossfade between stills.
- The desktop is drawn, not photographed: no Apple hardware, a stand-in notch, a neutral Dock with
  Hotch first. Apple's product images are licensed for App Store apps only.
- Inter Display instead of SF Pro, whose licence covers interface mock-ups, not marketing type.

## What was measured, what was only looked at

- `check`: 0 errors. Kept warnings: `film_silent` (no licensed music yet);
  `nested_structure_needs_subcomposition` (captions stay in the root so one clock drives camera,
  sweep and cursor). Contrast 7/7 WCAG AA.
- Looked at snapshots at 1.0, 2.9, 3.4, 4.2, 6.6, 10.1, 11.6, 13.45, 14.4, 17.0, 22.3, 25.65, 29.6,
  35.2, 40.6, 43.6, 47.0, 48.6, 48.7, 49.4 and 51.6 s, and at frames 7.0, 13.5 and 29.8 s of the
  rendered MP4.
- Not checked: the reel with music, and the GIF on a phone.

## Weakest shot

The alert click at 24.75 s still ends with the bubble retracting and no app coming forward,
because the tour does not switch apps. A cut to the terminal would land it.

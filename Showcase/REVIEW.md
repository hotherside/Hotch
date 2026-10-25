# Review: Hotch reel

## Creative calls

- Real motion over imitation: the card's spring, page changes, alert bubbles, the notch panel and
  the homes are the app's own animation, recorded with `--demo-tour`. Only the cursor and camera
  are added, and the cursor lands where the tour acts at the moment it acts.
- Snappy over complete: 26 s, one headline per beat, about two seconds a feature. Idle frames are
  cut where only the tab or an open card is on screen. The notch alert and Focus are left out.
- Two takes with the same timing (within about 30 ms) make the light and dark sweep possible
  across a live card, rather than a crossfade between stills.
- The desktop is drawn, not photographed: no Apple hardware, a stand-in notch, a neutral Dock with
  Hotch first. Apple's product images are licensed for App Store apps only.
- Inter Display instead of SF Pro, whose licence covers interface mock-ups, not marketing type.

## What was measured, what was only looked at

- `check`: 0 errors. Kept warnings: `film_silent` (no licensed music yet);
  `nested_structure_needs_subcomposition` (captions stay in the root so one clock drives camera,
  sweep and cursor). Contrast 7/7 WCAG AA.
- Looked at snapshots at 0, 1.6, 2.9, 5.9, 7.8, 10.2, 12.8, 14.3, 15.6, 18.2, 19.9, 21.6, 22.7
  and 25.0 s.
- Not checked: the reel with music, and the GIF on a phone.

## Weakest shot

The alert click at 13.9 s cuts away to the notch before anything answers it. A cut to the terminal
coming forward would land it.

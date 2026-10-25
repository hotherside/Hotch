GOAL:    A visitor watching the GIF once knows what Hotch is: a tab on the screen edge that opens into
         AI limits, sessions and Mac health, taps you when an agent needs you, and can live elsewhere.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps. Delivered as MP4 and as a 1280 x 720 GIF at 15 fps that loops.
TIME:    21.2 s x 30 = 636 frames. Silent (a GIF carries no sound).
LOOK:    Medium: a Mac desktop seen at 2x (1 pt = 2 px), the real Hotch renders in dark appearance.
         Ground: solid #2B2533 with two radial washes, orange rgba(242,140,77,0.38) at 24% 74%
         r 34%, teal rgba(64,191,217,0.26) at 80% 26% r 30%, navy rgba(34,42,68,0.85) at 0% 0% r 60%.
         Menu bar 48 px, rgba(12,10,20,0.40), text #F4F2FA 26 px, Hotch's status item (curve, amber dot, 63%).
         Ink #F4F2FA. Accent #F5A524 (Hotch's "needs you" amber), only on caption highlights.
         Display: Bricolage Grotesque 720, captions 76 px / 1.04, tracking -0.02em, max 2 lines, left x 150.
         Card glass #1C1C1C at 98%, radius 36 px. Shadows: 0 30 64 rgba(0,0,0,0.5) on UI only.
OBJECTS: The tab (three readouts: Claude, sessions, Focus), the tab with a readout selected, the card
         (AI, Sessions, Mac) hanging from a fixed top beside the tab, the alert bubble, the pill, the orb,
         the Dock-side bar with its label, a macOS arrow cursor (black with white outline), a plain Dock
         of blank tiles. All Hotch UI is the app's own render.
MOTION:  Enter expo.out (card 0.44 s scale 0.94 -> 1 from its top-right, captions 0.18 s); moves
         power2.inOut (cursor 0.4-0.8 s); exits power3.in at 50-60% of the entrance; card resize
         expo.out 0.42 s with the top fixed (the app's attachment); section content: out 0.10 s blur 4 px,
         in 0.18 s blur 4 -> 0, y 6 -> 0. Click: cursor 1 -> 0.86 -> 1 in 0.16 s.
SHOTS:   0.0-2.75  Desktop, tab resting. Caption "Hotch lives on the edge of your screen." per word.
                   Cursor enters from bottom 1.1, rests on the Claude readout 1.9.
         2.1-4.8   After the dwell the card opens on AI. Caption "Rest on a readout to open it."
         4.45-7.0  Cursor clicks the Sessions readout (4.9). Caption "Every agent session, live."
         6.0-9.05  Cursor clicks Mac in the card's tab bar (6.6). Caption "And how your Mac is holding up."
         8.65-9.2  Cursor leaves, card closes back into the tab.
         9.4-11.0  The alert bubble grows out of the tab. Caption "An agent needs you."
         10.2-13.2 Cursor clicks the bubble (10.75), it retracts. Caption "Click it to jump to that session."
         13.0-17.9 Tab leaves; "Or keep it / as a pill." pill, pill speaking; roll "as an orb." orb, orb
                   speaking; roll "by the Dock." Dock bar rises with the Dock, label pops above it.
         17.6-21.2 Ground floods to #1A1620, the companion curve draws and the warm signal lands, "Hotch"
                   wipes in, line "AI limits, live sessions and your Mac." holds. Loops to the first frame.
BANNED:  invented product UI; click rings; floating or breathing loops; titles that drift after landing;
         every element fading and sliding up; glow; corner labels; the logo docked in a corner; chips.
QA:      2.3 card opening; 3.4 AI card landed; 5.06 Sessions swap; 7.6 Mac card; 9.62 bubble mid-grow;
         11.2 bubble retracted; 14.0 pill; 16.0 orb speaking; 17.4 Dock and label; 20.4 end card.

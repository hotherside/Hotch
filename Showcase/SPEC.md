GOAL:    A friend watching the GIF once knows what Hotch is: a tab on the screen edge that opens into
         AI limits, sessions and Mac health, taps you when a session needs you, and can live elsewhere.
OUTPUT:  HyperFrames, 1920 x 1080, 30 fps. Delivered as MP4 and as a 960 x 540 GIF that loops.
TIME:    20.5 s x 30 = 615 frames. Silent (a GIF carries no sound).
LOOK:    Medium: a Mac desktop seen at 2x (1 pt = 2 px), the real Hotch renders in dark appearance.
         Ground: solid #2B2533 with two radial washes, orange rgba(242,140,77,0.38) at 24% 74%
         r 34%, teal rgba(64,191,217,0.26) at 80% 26% r 30%, navy rgba(34,42,68,0.85) at 0% 0% r 60%.
         Menu bar 48 px, rgba(12,10,20,0.40), text #F4F2FA 26 px.
         Ink #F4F2FA. Accent #F5A524 (Hotch's "needs you" amber), only on the rolling word and the glyph fill.
         Display: Bricolage Grotesque 720, captions 76 px / 1.04, tracking -0.02em, max 2 lines, left x 150.
         Card glass #1C1C1C at 98%, radius 36 px. Shadows: 0 28 48 rgba(0,0,0,0.45) on UI only.
OBJECTS: The tab (tapered, three rings), the expanded rail (section icons), the card (Mac, Sessions, AI),
         the alert bubble, the pill, the orb, the Dock-side bar with its label, a macOS arrow cursor
         (58 px, black with white outline), a plain Dock of blank tiles. All Hotch UI is the app's own render.
MOTION:  Enter expo.out (card 0.40 s, captions 0.18 s); moves power2.inOut (cursor 0.45-0.8 s);
         exits power3.in at 50-60% of the entrance; card resize expo.out 0.42 s (the app uses a spring);
         section content: out 0.10 s blur 4 px, in 0.18 s blur 4 -> 0, y 6 -> 0. Click: cursor 1 -> 0.86 -> 1 in 0.16 s.
SHOTS:   0.0-2.6   Desktop, tab resting. Caption "Hotch lives on the edge of your screen." per word.
                   Cursor enters from bottom left 1.1, lands on the memory ring 1.9.
         2.0-5.6   Hover opens the card on This Mac: tab -> rail, card widens out of the rail.
                   Caption "Hover a ring to open its section."
         4.2-7.4   Cursor clicks Sessions (4.2) then AI (6.0); the card resizes against the fixed rail.
                   Caption "Switch sections from the rail."
         7.4-7.9   Cursor leaves, card closes back into the tab.
         7.9-10.0  The alert bubble grows out of the tab. Caption "Alerts grow out of the tab."
         9.3-12.4  Cursor clicks the bubble (9.85), it retracts. Caption "Click it to jump to that session."
         12.3-17.2 Tab leaves; "Or keep it / as a pill." pill, pill speaking; roll "as an orb." orb, orb
                   speaking; roll "by the Dock." Dock bar rises with the Dock, label pops above it.
         16.9-20.5 Ground floods to #1A1620, glyph draws and fills amber, "Hotch" wipes in, line
                   "AI limits, live sessions and your Mac." holds 2.2 s. Loops to the first frame.
BANNED:  invented product UI; click rings; floating or breathing loops; titles that drift after landing;
         every element fading and sliding up; glow; corner labels; the logo docked in a corner; chips.
QA:      2.4 card opening mid-way; 3.5 Mac card landed; 4.35 resize mid-flight; 8.2 bubble mid-grow;
         13.6 pill speaking; 15.9 Dock and label; 19.5 end card.

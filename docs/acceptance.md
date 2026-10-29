# Playability gates

The owner's current order is windowed play first, then immersive play, with
DualSense and PSVR2 Sense both required. Hand controls are optional and come
last. A build, synthetic input test or simulator screenshot is component
evidence; physical gameplay remains a separate gate.

1. **Windowed visionOS:** load the real campaign, move and look, interact,
   jump, fire both portals, pause, save and reload, and run past the previous
   two-minute hang. Verify audio and sustained frame pacing on the headset.
   Prove normal DualSense and both PSVR2 Sense halves, including disconnect
   and reconnect. Preserve existing saves and other installed apps.
2. **Window ↔ immersive:** keep the same engine process, map, player and save
   state. Keep the window visible until the immersive renderer has a valid
   game frame. Return to a live window before retiring immersive presentation.
   Cancelled/failed transitions must leave one usable presentation and one
   active input session. Check repeated transitions and app suspension.
3. **Immersive:** accept actual left/right eye views, head translation and
   rotation, stable scale, asymmetric projections and tracked Sense aim/grip.
   Verify movement, both portal shots, crossing wall/floor portals, clipping,
   menus, pause and sustained frame pacing on physical Vision Pro.
4. **iPad/iPhone:** use the fork's native iOS runtime, verify game input,
   audio, touch/gamepad, saves and sustained play on each device family.
5. **Optional hands, after controllers:** assess left index–thumb pinch plus
   left arm displacement as a joystick; right index–thumb pinch for primary
   fire; right middle–thumb pinch for secondary fire; left middle–thumb pinch
   for jump. Require distinct gestures, neutral/release on tracking loss and
   practical reliability while moving. Omit the feature if it cannot meet
   that bar. No hand gesture is a prerequisite for controller play.
6. **Final polish:** add an original Portal-themed app icon after the gameplay
   and input gates, using blue/orange portals and a test-chamber visual theme.
   Prepare the appropriate icon assets for visionOS and iPad/iPhone.

Campaign/content mods and multiplayer keep their original compatibility
goals, but Steam authentication, matchmaking and Workshop are not supplied
by the inherited offline mobile stub.

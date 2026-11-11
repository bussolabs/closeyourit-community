# Coworker office

This extends the existing office canvas using the approved image concept.
The surrounding application chrome and server-rendered details remain unchanged.
Room floors use canvas parquet or tile textures with world-sized repeats and distinct per-room light/dark palettes.
Furniture, kitchen shelves, lounge upholstery, cafe fittings, and garden details dress the scene.
Scene spheres and small boxes share cached geometry; each mascot shares its own sphere geometry.
Mascot scale `0.85` intentionally preserves proportions relative to the furniture.
Soft PCF shadows use radius `3`, with 2048px maps above 900px viewport width and 1024px otherwise; pixel ratio is capped at `1.5`.
Window light patches and lamps follow the theme; fabric uses bump maps and ceramic clones use roughness `0.2` with environment reflections.

The campus sits on continuous countryside instead of a display plinth. Hills and distant trees
surround a road connected to the west entrance. Terrain extends as the view moves.
The park and countryside now use the same continuous grass surface, with a repeating grain texture
and gently varied vertex colors. The separate rectangular park lawn has been removed.
Shrubs, stones, flowers and grass tufts form perimeter pockets and larger countryside clusters;
road reflectors line the approach. Protected ground keeps paths and room footprints clear.

## Ownership

- `world.js`: deterministic hills, flat campus and road corridors, and instanced distant trees.
  A fixed 9×9 grid of 64-unit chunks follows the view focus. Departing chunks release geometry.
  `OFFICE_APPROACH` reserves a route for future arrivals/departures; lifecycle animations are not connected.
  The current Puck controller has no destroy action.
- `details.js`: furniture-scale stationery, mail, photographs, headphones, pastries and seven
  interactive secrets. Each reaction lasts 3.2 seconds, then returns to its resting pose.
- `rooms.js`: archive, observatory and workshop geometry, built only for room IDs supplied by Rails;
  shared paths connect these north wings to the existing campus.
- `scene.js`: room geometry, furniture, lighting, camera, decorative routes,
  picking, browser preference synchronization, and WebGL resource cleanup.
- `mascots.js`: twenty procedural Three.js characters, IDs `01` through `20`,
  based on the gallery identities in `public/coworkers/mascots`.
- `garden.js`: five pond fish, three birds continuously flying, landing, perching,
  and departing over a 32-second cycle, two squirrels, and reactive cafe umbrellas.
- `atmosphere.js`: translucent water above the fish, animated surface normals,
  expanding ripples, and a procedural cubemap for ambient reflections, not live scene reflections.
- `batching.js`: repeated static meshes become `InstancedMesh` batches, preserving world transforms
  and children while excluding transparent materials and animated subtrees. Scene cleanup explicitly disposes instances.
- `../controllers/coworker_office_controller.js`: lazy scene loading, selection,
  reset, discovery messages, fallback, and connection lifecycle.
- `app/views/member/coworker_office/`: real Puck data and accessible detail controls.

## Data and identity

The server supplies Puck IDs, names, detail cards, and activity state.
`busy` still means the newest run is active (queued or running).
Busy Puckies remain at their desks; idle walking is decorative, not telemetry.
Mascots blink, gesture while working, greet, turn smoothly, and face the pond during nearby stops.
The first six work seats have chairs; selected park routes include a bench stop, and cafe stops include a coffee gesture.
Routes use directional offsets up to 0.46 world units and wait when approaching another Puck within 0.85 units.
These are local spacing rules, not general pathfinding or a guarantee of collision-free movement.
Fish gather toward a Puck within 5 units of the pond center; squirrels pause and face Puckies within 2.8 units.
All seating, gestures, routes, and wildlife responses are decorative, not activity telemetry.
Vegetation and open umbrellas sway gently; these gestures and wind effects are decorative.

Mascot choice uses the gallery's existing localStorage key:
`coworkers:mascot:{organization_id}:{account_id}:{puck_id}`.
Missing, invalid, or inaccessible stored choices default to `01`.
`coworker-mascot:change` updates the current page; `storage` synchronizes tabs.
Changing a mascot replaces its geometry without changing activity or selection.
One umbrella stays open; others open within 3.6 world units of a Puck and close
when all Puckies are beyond 4.6 units, with smooth transitions and hysteresis.

## Conditional rooms

`Coworkers::Office::Rooms` receives only Puckies from `visible.coworker_puckies`.
The workshop connection query is restricted to those Puck IDs and reads only IDs, never credentials.

- Archive: at least one visible Puck has the saved `researcher@version` preset.
- Observatory: at least one visible Puck has `watch_every_minutes` enabled.
- Workshop: at least one visible Puck has a connected app.

Names and instructions never infer a role. There is no separate research-enabled flag in the current
model: the archive reflects the saved Researcher role, not permission to perform research.
Reload the office after changing configuration. The Special rooms disclosure explains all three
conditions and disables view buttons for inactive rooms. Active buttons frame the corresponding wing.

## Discoveries

Seven objects can be selected in the scene or through keyboard-accessible buttons under Little secrets:
a reception cat waves, a meeting-room paper plane flies, a lounge arcade lights up, a cafe tin reveals
a golden star, a garden snail moves, the server robot turns its head, and a coordination-room book
reveals a brass key. Selecting one frames it and announces a localized message through a status region.
These are decorative reactions; they do not unlock permissions or perform Puck actions.
Reduced motion shows a static revealed pose instead of continuous movement.

## Viewing and accessibility

The desktop camera frames the grounds; portrait mobile starts closer to the Puckies.
Orbit controls support pan and pinch zoom; reset restores the starting view.
Selection frames the Puck at zoom `2.5`; optional follow stops when an orbit interaction starts.
Three presets frame the office, park, or cafe. Lighting defaults to the device local wall clock, refreshed every second and after tab resume.
Art-directed dawn runs 05:00–08:00, daylight 08:00–16:00, dusk 16:00–20:00, and night 20:00–05:00.
Transitions interpolate smoothly; these are fixed local hours, not astronomical sunrise/sunset.
Day/evening overrides remain available; Local time restores automatic lighting.
The document's `dark` class updates scene colors and lighting live.
`prefers-reduced-motion` updates live, suppressing walking, bobbing, arm motion,
LED blinking, and selection pulsing. It freezes fish, squirrels, vegetation, and water animation,
hides birds and ripples, restores open eyes and neutral arms, and stops umbrella sway.
Umbrella opening and closing become immediate.
Camera framing becomes immediate and continuous follow is suspended under reduced motion.
The existing buttons and detail cards remain available outside the canvas.

## Verification and limits

Run `mise exec -- node --test test/javascript/coworker_*_test.mjs`.
The 26 Node tests cover gallery geometry and picking, expressions, wildlife and umbrellas,
world coverage and recycling, protected landscaping, daylight continuity, special-room activation
and bounds, and all seven discovery reactions, reduced motion and resource cleanup.

Run `bundle exec rspec spec/models/coworkers/office/rooms_spec.rb` for the four standalone Ruby examples.
They cover zero/one/multiple configurations, saved role versions, unrelated connection IDs and disabling.
The request specs additionally cover server-rendered activation and account privacy, but were not run
because database preparation was blocked earlier in this session. No destructive setup was retried.
Node tests validate geometry and behavior, not visual fidelity; rendered appearance needs browser review.

These are real-time procedural interpretations of the approved characters,
not offline plush renders. Materials and silhouettes approximate the references.

Daylight tests cover local hours, continuous boundaries and midnight over every second of a day.

World tests cover level campus/access routes, distant coverage, bounded chunk recycling, terrain heights, and disposal.
The orthographic camera sits farther back without changing scale; fog hides distant terrain.
Ground-plane panning preserves camera height and prevents foreground clipping at low orbit angles.

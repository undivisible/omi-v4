# Design references

What Omi's surface is pulling from, and which decision each one is behind.
Kept short on purpose: a reference that is not load-bearing is decoration.

## The palette

**Sanzo Wada, *A Dictionary of Color Combinations* (配色事典, 1933).**
Already the source — `omi_wa_palette.dart` carries six real plates by number
(166 dawn, 190 ember, 139 indigo, 207 moss, 232 lacquer, 151 harbour). Two
things about Wada matter beyond the hex values:

- The combinations are *named*, not sampled. Grenadine Pink into Naples Yellow
  into Deep Slate Green is a stated relationship, which is why lifting one stop
  out of a plate and using it alone looks wrong.
- They were printed on paper in daylight. Every plate is pulled toward the
  app's own floor (`deepened()`) before it is used, because this is a dark
  room. A plate used at its printed values reads washed out on a black screen.

**Jun'ichirō Tanizaki, *In Praise of Shadows* (陰翳礼讃, 1933).** The argument
for why the dark surface is the default and not a theme: lacquer, gold leaf and
ink were made for low light, and their beauty is in what the darkness withholds.
It is the reasoning behind `bokashi()` — a graded wash rather than a flat fill —
and behind the radial well the cold open puts under the dots so cream reads on
pale ground without lighting the whole field.

**Kenya Hara, *White* (白), and the MUJI art direction.** Emptiness as content
rather than absence — 間 (*ma*). Directly behind removing the conversations
heading and subtitle: the section already *is* what it is, and a label above it
is the designer explaining their own layout.

## The mark, and marks that behave like personas

**The Paramount cold open.** The user's own reference and the shape of
`omi_cold_open.dart`: a field of fixed stars, elements arriving from the
periphery, one settle, hand over. The lesson we got wrong the first time is that
the hand-over has to land on the *real* object — a mark that resolves at screen
centre and then cuts to a mark somewhere else is two animations, not one.

**Saul Bass title sequences** (*Vertigo*, *Anatomy of a Murder*). Geometric
motion that resolves into a mark, and stops. Bass never loops. The idle showcase
performing one lap and returning to rest is this; the old rotation that ran
until interrupted was not.

**The Google Assistant four dots.** The closest prior art to what the eight
Omi dots are doing — a small number of identical shapes that carry state by
rearranging rather than by changing colour or adding a spinner. Worth studying
for what it refuses to do: the dots never leave their lane, and they never
perform while the user is reading.

**Disney's twelve principles, specifically slow in / slow out and
follow-through.** Behind `Curves.easeOutBack` on the converge: each dot
overshoots its rest radius and settles back, which is what makes eight circles
read as objects with mass instead of positions being assigned.

## The layout

**Josef Müller-Brockmann, *Grid Systems in Graphic Design*.** The single
reading column (`_readingColumnMaxWidth`) and the refusal to fill the window
width because the window is wide.

**Dieter Rams' ten principles**, and in particular *as little design as
possible*. The test we keep failing and re-passing: every chrome element on the
hub has to justify itself against the content it displaces. The settings button
came off conversations and memory under this rule.

## Motion, and when not to have any

**Apple HIG, Motion and Accessibility.** `MediaQuery.disableAnimations` is
honoured everywhere the mark animates (`debugOmiOrbStatic` is the test-side
equivalent). A cold open that cannot be skipped is a cold open that will be
hated on the fiftieth launch, which is why tapping it finishes it.

## The mathematics

**The Tusi couple** — a circle rolling inside a circle of twice the radius,
where every point on the rolling circle traces a straight line. It is a
degenerate hypocycloid, and it is the reason the dots can travel along diameters
without anything appearing to drive them.

**Pendulum wave demonstrations.** Detuned periods across a row, so the set
falls out of phase into apparent chaos and back into alignment on a known beat.
`tusiPendulum` is this laid onto the Tusi lanes; the lap length is chosen so the
lattice resynchronises exactly at turn 1, which is what lets the cold open blend
in and out of it without a jump.

# Bring Back Spawner Blocking

![Bring Back Spawner Blocking](thumbnail.png)

A Factorio 2.1 mod that brings back the classic "wall the nest in with
pipes" strategy: surround a biter/spitter spawner tightly enough and it
can never spawn a unit, full stop.

## Why

Factorio 2.1 broke this in two ways:

1. **The acid cloud.** A spawner that can't find a place to spawn now fires
   off a damaging acid cloud instead of just sitting there blocked.
2. **Tighter spawning range.** `spawning_radius` and `spawning_spacing` were
   both reduced, letting biters squeeze into gaps that used to be too
   cramped for them - so old wall-off patterns stopped working even before
   the acid cloud got involved.

This mod removes the acid cloud entirely and tunes `spawning_radius` /
`spawning_spacing` back up (to 4 / 3) so two rings of pipes around a
spawner reliably blocks it again, the same density as the original manual
"one pipe, skip, skip" wall-off pattern - not a fully solid fill.

## The planner tool

Manually placing two rings of pipes around every nest gets old fast, so
the mod also adds a selection tool in the spirit of the Mining Patch
Planner / Deconstruction Planner:

- **ALT+S** (or the shortcut bar button) gives you the tool.
- **Drag** it over an area: any enemy spawner caught in the selection gets
  a sparse grid of pipe ghosts placed around it, spaced exactly
  `spawning_spacing` tiles apart out to `spawning_radius`.
- **Shift-drag** (reverse select) removes pipe ghosts this tool placed.
- **Ctrl+Z** undoes a whole drag at once, same as the vanilla blueprint
  paste - placements are filed into your own undo queue via
  `surface.create_entity`'s `player`/`undo_index` parameters.

### Force build

While the tool is selected, a small panel appears on the left with a
**Force build** toggle (on by default - same name as vanilla's own build
mode). When it's on, anything in the way of a pipe ghost - trees, rocks,
existing buildings - gets marked for deconstruction and the ghost is
placed anyway, the same way a forced blueprint paste works. Tiles blocked
purely by terrain (water, cliffs) are left alone either way, since there's
nothing there to deconstruct and forcing an unbuildable ghost onto deep
water isn't useful.

## Lockdown

Some Factorio updates changed how the engine picks spawn positions enough
that a fully-walled nest could still leak a unit through a corner gap
between pipes, even with the values above. To get back to "fully walled
in means fully silent," this mod also tracks each spawner the planner
tool has touched: once at least one pipe from its pattern is actually
built, the mod takes the spawner's spawning over directly instead of
trusting the engine's own check.

- **Fully walled** (every position in the pattern has a real pipe): the
  spawner is locked down completely, same as the classic strategy always
  promised.
- **Partially walled** (one or more positions are missing or got
  destroyed): units leak out specifically through the gap, on roughly the
  spawner's normal timer - breaking the wall opens a hole right there,
  rather than freeing the whole nest.
- **Untouched** (the tool was used on it but nothing was ever built): left
  completely vanilla.

## Compatibility

Reads `spawning_radius`/`spawning_spacing` live from the spawner prototype
at runtime, so the planner tool stays correct even if those values get
tuned again later or overridden by another mod.

## License

MIT - see [LICENSE](LICENSE).

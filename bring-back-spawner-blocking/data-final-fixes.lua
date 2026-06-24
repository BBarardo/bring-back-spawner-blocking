-- Reverts two related Factorio 2.1 changes to biter/spitter spawners that,
-- together, broke the classic "wall the nest in with pipes" strategy:
--
-- 1) spawn_blocked_trigger (new in 2.1): emits a damaging acid cloud when the
--    spawner can't find a valid spawn location. We remove it entirely.
--
-- 2) Reduced spawning range / increased spawning precision (2.1 changelog).
--    Confirmed via factorio-data diff (2.0.77 -> 2.1.7):
--      spawning_radius:  10  -> 2.0   (how far units can spawn from the spawner)
--      spawning_spacing: 3   -> 1.0   (minimum free space required between units)
--
--    Tuning (per in-game testing): radius 4 / spacing 3 reproduces the old
--    2.0.77 wall-off density minus one ring - two rings of pipes around the
--    spawner block it reliably without needing a fully solid fill.

if data.raw["unit-spawner"] then
  for _, spawner in pairs(data.raw["unit-spawner"]) do
    spawner.spawn_blocked_trigger = nil
    spawner.spawning_radius = 4
    spawner.spawning_spacing = 3
  end
end

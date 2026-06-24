-- Factorio 2.1 made enemy spawners emit a damaging acid cloud whenever they
-- can't find a valid spot to spawn a unit. That's the first half of why the
-- classic "wall the nest in with pipes" strategy stopped working - even a
-- nest that's fully boxed in now lashes out instead of just sitting there
-- helpless. Remove it.

if data.raw["unit-spawner"] then
  for _, spawner in pairs(data.raw["unit-spawner"]) do
    spawner.spawn_blocked_trigger = nil
  end
end

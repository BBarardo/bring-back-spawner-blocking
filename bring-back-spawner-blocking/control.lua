-- Spawner Blocker Planner
--
-- Drag the "spawner-blocker-planner" selection tool (default keybind ALT+S
-- to get one in your cursor) over an area. Any enemy spawner caught in the
-- selection gets a sparse grid of pipe ghosts placed around it, spaced
-- exactly spawning_spacing tiles apart, out to spawning_radius - the same
-- density as the classic manual "sim, nao, nao" wall-off pattern, not a
-- solid fill of every tile.
--
-- Shift-drag (reverse select) over an area removes pipe ghosts that this
-- tool placed. The engine's undo (ctrl+z) does not track entities created
-- via the scripting API, so this is the supported way to walk back a
-- placement made with this tool.

local TOOL_NAME = "spawner-blocker-planner"
local BLOCKER_ENTITY = "pipe"

--- Surrounds a single spawner with a sparse grid of pipe ghosts, spaced
-- spawning_spacing tiles apart, out to spawning_radius.
-- @return number of ghosts placed
local function block_spawner(force, spawner)
  if not (spawner and spawner.valid) then return 0 end

  local surface = spawner.surface
  local bbox = spawner.bounding_box

  -- Read straight from the prototype so this always matches whatever
  -- spawning_radius/spawning_spacing the "Bring Back Spawner Blocking"
  -- data-final-fixes.lua has set, even if those get tuned again later.
  local radius = spawner.prototype.spawning_radius or 4
  local spacing = spawner.prototype.spawning_spacing or 3
  if spacing < 1 then spacing = 1 end

  local rings = math.max(1, math.ceil(radius / spacing))

  -- Tile-center aligned point nearest the spawner's own center, so the
  -- grid lines up the same way the old manual pattern did (one lattice
  -- point sits on the spawner's own center tile, which is unbuildable -
  -- that's expected and matches the classic pattern).
  local base_x = math.floor(spawner.position.x) + 0.5
  local base_y = math.floor(spawner.position.y) + 0.5

  local placed = 0

  for i = -rings, rings do
    for j = -rings, rings do
      local pos = {x = base_x + i * spacing, y = base_y + j * spacing}

      local inside_spawner =
        pos.x > bbox.left_top.x and pos.x < bbox.right_bottom.x and
        pos.y > bbox.left_top.y and pos.y < bbox.right_bottom.y

      if not inside_spawner then
        if surface.can_place_entity({name = BLOCKER_ENTITY, position = pos, force = force}) then
          surface.create_entity({
            name = "entity-ghost",
            inner_name = BLOCKER_ENTITY,
            position = pos,
            force = force,
            expires = false
          })
          placed = placed + 1
        end
      end
    end
  end

  return placed
end

local function on_area_selected(event)
  if event.item ~= TOOL_NAME then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local spawners_done = 0
  local ghosts_placed = 0

  for _, entity in pairs(event.entities or {}) do
    if entity.valid and entity.type == "unit-spawner" then
      local placed = block_spawner(player.force, entity)
      ghosts_placed = ghosts_placed + placed
      spawners_done = spawners_done + 1
    end
  end

  if spawners_done > 0 then
    player.print({"", "[Spawner Blocker] ", tostring(spawners_done), " spawner(s) surrounded, ",
      tostring(ghosts_placed), " pipe ghost(s) placed."})
  else
    player.print("[Spawner Blocker] No enemy spawners found in that selection.")
  end
end

local function on_area_reverse_selected(event)
  if event.item ~= TOOL_NAME then return end

  local removed = 0

  for _, entity in pairs(event.entities or {}) do
    if entity.valid and entity.type == "entity-ghost" and entity.ghost_name == BLOCKER_ENTITY then
      entity.destroy()
      removed = removed + 1
    end
  end

  local player = game.get_player(event.player_index)
  if player then
    if removed > 0 then
      player.print({"", "[Spawner Blocker] Removed ", tostring(removed), " pipe ghost(s)."})
    else
      player.print("[Spawner Blocker] No pipe ghosts found in that selection.")
    end
  end
end

script.on_event(defines.events.on_player_selected_area, on_area_selected)
script.on_event(defines.events.on_player_alt_selected_area, on_area_selected)
script.on_event(defines.events.on_player_reverse_selected_area, on_area_reverse_selected)

-- Spawner Blocker Planner
--
-- Drag the "spawner-blocker-planner" selection tool (default keybind ALT+S,
-- or the shortcut bar button) over an area. Any enemy spawner caught in the
-- selection gets a sparse grid of pipe ghosts placed around it, spaced
-- exactly spawning_spacing tiles apart, out to spawning_radius - the same
-- density as the classic manual "sim, nao, nao" wall-off pattern, not a
-- solid fill of every tile.
--
-- Placement is force-pasted like a blueprint: if something is already
-- sitting on a spot we want to put a pipe ghost on, we mark it for
-- deconstruction (the same as the vanilla "X" you'd get from a forced
-- blueprint paste) and place the ghost anyway, instead of silently skipping
-- that tile.
--
-- Ghosts are created with `player` and `undo_index` set on
-- surface.create_entity, which is what actually files them into the
-- player's normal undo queue - ctrl+z undoes a whole drag in one go, same
-- as Mining Patch Planner.
--
-- Shift-drag (reverse select) over an area also removes pipe ghosts that
-- this tool placed, as a longer-lived alternative to ctrl+z.

local TOOL_NAME = "spawner-blocker-planner"
local BLOCKER_ENTITY = "pipe"

--- Clears whatever is currently occupying `pos` (if anything), the same way
-- a forced blueprint paste would, so a pipe ghost can still go down there.
local function force_clear(force, player, surface, pos)
  local blockers = surface.find_entities_filtered({position = pos, radius = 0.4})
  for _, e in pairs(blockers) do
    if e.valid and e.type ~= "entity-ghost" and e.type ~= "unit-spawner"
       and e.type ~= "resource" and e.type ~= "character"
       and (not e.to_be_deconstructed or not e.to_be_deconstructed()) then
      pcall(function() e.order_deconstruction(force, player) end)
    end
  end
end

--- Surrounds a single spawner with a sparse grid of pipe ghosts, spaced
-- spawning_spacing tiles apart, out to spawning_radius. Force-pastes over
-- anything in the way and threads everything into one undo action.
-- @return number of ghosts placed, updated undo_index
local function block_spawner(player, force, spawner, undo_index)
  if not (spawner and spawner.valid) then return 0, undo_index end

  local surface = spawner.surface
  local bbox = spawner.bounding_box

  local radius = spawner.prototype.spawning_radius or 4
  local spacing = spawner.prototype.spawning_spacing or 3
  if spacing < 1 then spacing = 1 end

  local rings = math.max(1, math.ceil(radius / spacing))

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
        -- create_entity does not check entity collision for ghosts by
        -- default - it'll happily place one on top of whatever's there.
        -- can_place_entity (no special build_check_type) is only used here
        -- to tell "blocked by a real entity" apart from "blocked by terrain
        -- the entity could never go on anyway" (water, out of the map...).
        local free = surface.can_place_entity({name = BLOCKER_ENTITY, position = pos, force = force})
        local should_place = free

        if not free then
          force_clear(force, player, surface, pos)
          should_place = true
        end

        if should_place then
          local result = surface.create_entity({
            name = "entity-ghost",
            inner_name = BLOCKER_ENTITY,
            position = pos,
            force = force,
            player = player,
            raise_built = true,
            expires = false,
            undo_index = undo_index
          })

          if result then
            placed = placed + 1
            -- First successful placement opens a new undo item (index 0 ->
            -- becomes index 1 on the stack). Every placement after that
            -- reuses index 1 so the whole drag undoes as a single action.
            if undo_index == 0 then undo_index = 1 end
          end
        end
      end
    end
  end

  return placed, undo_index
end

local function on_area_selected(event)
  if event.item ~= TOOL_NAME then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local spawners_done = 0
  local ghosts_placed = 0
  local undo_index = 0

  for _, entity in pairs(event.entities or {}) do
    if entity.valid and entity.type == "unit-spawner" then
      local placed
      placed, undo_index = block_spawner(player, player.force, entity, undo_index)
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

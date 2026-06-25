-- Spawner Blocker Planner
--
-- Drag the "spawner-blocker-planner" selection tool (default keybind ALT+S,
-- or the shortcut bar button) over an area. Any enemy spawner caught in the
-- selection gets a sparse grid of pipe ghosts placed around it, spaced
-- exactly spawning_spacing tiles apart, out to spawning_radius - the same
-- density as the classic manual "one pipe, skip, skip" wall-off pattern,
-- not a solid fill of every tile.
--
-- Force build (toggle in the left-side panel shown while the tool is
-- selected, on by default - same name as vanilla's own build mode): if
-- something is already sitting where a pipe ghost wants to go, mark it for
-- deconstruction and place the ghost anyway, the same way a forced
-- blueprint paste works.
--
-- Ghosts are created with `player` and `undo_index` set on
-- surface.create_entity, which is what actually files them into the
-- player's normal undo queue - ctrl+z undoes a whole drag in one go, same
-- as Mining Patch Planner.
--
-- Shift-drag (reverse select) over an area also removes pipe ghosts that
-- this tool placed, as a longer-lived alternative to ctrl+z.
--
-- Lockdown: a later Factorio update changed how the engine finds spawn
-- positions enough that units could squeeze through walls that used to be
-- airtight, even with spawning_radius/spawning_spacing tuned back up. To
-- get back to "fully walled in means fully silent", once a spawner has at
-- least one real pipe built from its pattern, this mod intercepts
-- on_entity_spawned and immediately destroys any unit produced by a fully
-- walled spawner (every pattern position occupied). If the wall has gaps,
-- spawned units are left alive - a hole in the wall lets things through.

local TOOL_NAME = "spawner-blocker-planner"
local BLOCKER_ENTITY = "pipe"
local GUI_FRAME_NAME = "spawner-blocker-gui"
local CHECKBOX_NAME = "spawner-blocker-force-build-checkbox"
local SWEEP_INTERVAL = 300

-- How many rings of pipe positions to place OUTSIDE each spawner's bbox.
-- Both Nauvis spawner types are 5×5 but biters have a larger effective
-- spawn zone and need one extra ring.  Unknown spawner types fall back to 2.
local OUTSIDE_RINGS = {
  ["biter-spawner"]   = 3,
  ["spitter-spawner"] = 2,
}

local function get_force_build(player_index)
  local value = storage.force_build and storage.force_build[player_index]
  if value == nil then return false end
  return value
end

local function set_force_build(player_index, value)
  storage.force_build = storage.force_build or {}
  storage.force_build[player_index] = value
end

--- Marks whatever real entity is occupying `pos` for deconstruction, the
-- same way a forced blueprint paste would, so a pipe ghost can still go
-- down there.
--
-- Deliberately does NOT count terrain-only obstructions (water, cliffs,
-- space) as something to "clear" - there's no entity to deconstruct in
-- those cases, and forcing a pipe ghost onto e.g. deep water would just
-- leave a ghost that can never actually be built without landfill. Force
-- build is meant for clearing trees, rocks, and existing buildings out of
-- the way, not for terraforming.
-- @return true if a real, removable obstruction was found and marked
local function force_clear(force, player, surface, pos)
  local cleared_something = false
  local blockers = surface.find_entities_filtered({position = pos, radius = 0.4})
  for _, e in pairs(blockers) do
    if e.valid and e.type ~= "entity-ghost" and e.type ~= "unit-spawner"
       and e.type ~= "resource" and e.type ~= "character" and e.type ~= "cliff"
       and e.name ~= BLOCKER_ENTITY then
      if not (e.to_be_deconstructed and e.to_be_deconstructed()) then
        pcall(function() e.order_deconstruction(force, player) end)
      end
      if e.valid and e.to_be_deconstructed and e.to_be_deconstructed() then
        cleared_something = true
      end
    end
  end
  return cleared_something
end

--- The full list of grid candidate positions around `spawner` that the
-- wall pattern needs to occupy, spaced spawning_spacing tiles apart out to
-- spawning_radius, excluding points inside the spawner's own bounding box.
-- Shared by the planner tool (which places ghosts here) and the lockdown
-- code (which checks whether these points are actually built).
local function compute_grid_positions(spawner)
  local bbox = spawner.bounding_box
  local radius = spawner.prototype.spawning_radius or 4
  local spacing = spawner.prototype.spawning_spacing or 3
  if spacing < 1 then spacing = 1 end

  -- Use the actual bbox centre so the grid aligns with the spawner's
  -- physical footprint regardless of how Factorio rounds entity positions.
  local base_x = (bbox.left_top.x + bbox.right_bottom.x) / 2
  local base_y = (bbox.left_top.y + bbox.right_bottom.y) / 2

  -- rings_inside: how many grid steps fit inside the spawner's bbox (these
  -- positions are always excluded because a pipe can't go inside the spawner).
  -- outside: how many rings to place OUTSIDE the bbox; varies by spawner type
  -- so that the pattern matches the effective spawn zone without excess.
  local half_w = (bbox.right_bottom.x - bbox.left_top.x) / 2
  local half_h = (bbox.right_bottom.y - bbox.left_top.y) / 2
  local rings_inside = math.floor(math.max(half_w, half_h) / spacing)
  local outside = OUTSIDE_RINGS[spawner.name] or math.max(2, math.ceil(radius / spacing))
  local rings = rings_inside + outside

  local positions = {}
  for i = -rings, rings do
    for j = -rings, rings do
      local pos = {x = base_x + i * spacing, y = base_y + j * spacing}
      local inside_spawner =
        pos.x > bbox.left_top.x and pos.x < bbox.right_bottom.x and
        pos.y > bbox.left_top.y and pos.y < bbox.right_bottom.y
      if not inside_spawner then
        positions[#positions + 1] = pos
      end
    end
  end
  return positions
end

--- A position counts as "held" by the wall if a pipe can't be placed
-- there - either because a real entity already occupies it, or because
-- the terrain itself blocks it (water, cliffs). A bare ghost does NOT
-- count as held - the player has to actually build it.
local function position_is_held(surface, pos, force)
  return not surface.can_place_entity({name = BLOCKER_ENTITY, position = pos, force = force})
end

--- Re-evaluates one tracked spawner: recomputes which of its pattern
-- positions are actually held.
--
-- Management only engages once at least one position is held by a real
-- pipe - a nest the player selected with the tool but never actually
-- built anything around is left completely untouched, vanilla behaviour
-- and all. Once management is engaged, on_entity_spawned destroys any
-- unit the spawner produces when there are no gaps; if gaps remain the
-- units are left alive.
-- @return false if the spawner is no longer valid and should be dropped
local function refresh_spawner_lock(data)
  local spawner = data.spawner
  if not (spawner and spawner.valid) then return false end

  local held = 0
  local gaps = {}
  for _, pos in ipairs(data.positions) do
    if position_is_held(spawner.surface, pos, spawner.force) then
      held = held + 1
    else
      gaps[#gaps + 1] = pos
    end
  end

  data.gaps = gaps
  data.managed = held > 0

  return true
end

local function register_tracked_spawner(spawner, positions)
  storage.tracked_spawners = storage.tracked_spawners or {}
  local data = storage.tracked_spawners[spawner.unit_number] or {
    spawner = spawner,
  }
  data.spawner = spawner
  data.positions = positions
  -- Pre-compute the squared reach so refresh_nearby_tracked_spawners can
  -- compare distances without a sqrt and without under-shooting for large
  -- patterns (e.g. biter ring 5 is at distance 5 from centre; the old
  -- spawning_radius+2 fallback of 4 would have missed it).
  local cx, cy = spawner.position.x, spawner.position.y
  local max_d2 = 0
  for _, pos in ipairs(positions) do
    local d2 = (cx - pos.x)^2 + (cy - pos.y)^2
    if d2 > max_d2 then max_d2 = d2 end
  end
  data.reach_sq = max_d2 + 4  -- +4 ≈ 2-tile buffer
  storage.tracked_spawners[spawner.unit_number] = data
  refresh_spawner_lock(data)
end

--- Finds any tracked spawner with a pattern position within reach of
-- `pos`, for event-driven rechecks when a pipe near a nest is built or
-- removed. Cheap as long as the number of tracked spawners stays small,
-- which it should for a single base.
local function refresh_nearby_tracked_spawners(surface, pos)
  if not storage.tracked_spawners then return end
  for unit_number, data in pairs(storage.tracked_spawners) do
    if data.spawner and data.spawner.valid and data.spawner.surface == surface then
      local dx = data.spawner.position.x - pos.x
      local dy = data.spawner.position.y - pos.y
      if dx * dx + dy * dy <= (data.reach_sq or 36) then
        refresh_spawner_lock(data)
      end
    else
      storage.tracked_spawners[unit_number] = nil
    end
  end
end

--- When a managed spawner produces a unit and every wall position is held,
-- destroy the unit immediately - the wall is airtight so nothing gets out.
-- If the wall has gaps, the unit lives; the gap is the leak.
local function on_entity_spawned(event)
  if not storage.tracked_spawners then return end
  local spawner = event.spawner
  if not (spawner and spawner.valid) then return end
  local data = storage.tracked_spawners[spawner.unit_number]
  if not (data and data.managed) then return end
  if data.gaps and #data.gaps == 0 then
    local entity = event.entity
    if entity and entity.valid then entity.destroy() end
  end
end

--- Surrounds a single spawner with a sparse grid of pipe ghosts, spaced
-- spawning_spacing tiles apart, out to spawning_radius. Force-pastes over
-- anything in the way and threads everything into one undo action. Also
-- registers the spawner for lockdown management (see refresh_spawner_lock).
-- @return number of ghosts placed, updated undo_index
local function block_spawner(player, force, spawner, undo_index, force_build)
  if not (spawner and spawner.valid) then return 0, undo_index end

  local surface = spawner.surface
  local positions = compute_grid_positions(spawner)
  local placed = 0

  for _, pos in ipairs(positions) do
    -- create_entity does not check entity collision for ghosts by
    -- default - it'll happily place one on top of whatever's there.
    -- can_place_entity (no special build_check_type) is only used here
    -- to tell "blocked by a real entity" apart from "blocked by terrain
    -- the entity could never go on anyway" (water, out of the map...).
    local free = surface.can_place_entity({name = BLOCKER_ENTITY, position = pos, force = force})
    local should_place = free

    if not free and force_build then
      -- Only force the ghost down if there was an actual entity to
      -- clear out of the way - skip tiles that are blocked by terrain
      -- alone (water, cliffs), same as if force build were off.
      if force_clear(force, player, surface, pos) then
        should_place = true
      end
    end

    -- Don't stack a second ghost on top of an existing one. Ghosts have no
    -- collision so can_place_entity returns true even when one is already
    -- there; we need an explicit check.
    if should_place and surface.find_entities_filtered({
        type = "entity-ghost", ghost_name = BLOCKER_ENTITY,
        position = pos, radius = 0.5})[1] then
      should_place = false
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

  register_tracked_spawner(spawner, positions)

  return placed, undo_index
end

local function on_area_selected(event)
  if event.item ~= TOOL_NAME then return end

  local player = game.get_player(event.player_index)
  if not player then return end

  local force_build = get_force_build(player.index)

  local spawners_done = 0
  local ghosts_placed = 0
  local undo_index = 0

  for _, entity in pairs(event.entities or {}) do
    if entity.valid and entity.type == "unit-spawner" then
      local placed
      placed, undo_index = block_spawner(player, player.force, entity, undo_index, force_build)
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
  local affected_surface = nil
  local affected_positions = {}

  for _, entity in pairs(event.entities or {}) do
    if entity.valid and entity.type == "entity-ghost" and entity.ghost_name == BLOCKER_ENTITY then
      affected_surface = entity.surface
      affected_positions[#affected_positions + 1] = entity.position
      entity.destroy()
      removed = removed + 1
    end
  end

  if affected_surface then
    for _, pos in ipairs(affected_positions) do
      refresh_nearby_tracked_spawners(affected_surface, pos)
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

-- Left-side settings panel, shown while the spawner-blocker-planner tool is
-- in the player's cursor, same spot Mining Patch Planner puts its own panel.
local function destroy_gui(player)
  local existing = player.gui.left[GUI_FRAME_NAME]
  if existing then existing.destroy() end
end

local function build_gui(player)
  if player.gui.left[GUI_FRAME_NAME] then return end

  local frame = player.gui.left.add({
    type = "frame",
    name = GUI_FRAME_NAME,
    direction = "vertical",
    caption = "Spawner Blocker"
  })

  frame.add({
    type = "checkbox",
    name = CHECKBOX_NAME,
    caption = "Force build",
    tooltip = "Mark anything in the way for deconstruction and place the pipe ghost anyway, like a forced blueprint paste.",
    state = get_force_build(player.index)
  })
end

local function on_cursor_stack_changed(event)
  local player = game.get_player(event.player_index)
  if not player then return end

  local stack = player.cursor_stack
  if stack and stack.valid_for_read and stack.name == TOOL_NAME then
    build_gui(player)
  else
    destroy_gui(player)
  end
end

local function on_gui_checked_state_changed(event)
  local element = event.element
  if element and element.valid and element.name == CHECKBOX_NAME then
    set_force_build(event.player_index, element.state)
  end
end

--- A real pipe was built (or revived from a ghost) near a tracked
-- spawner - recheck its lock state immediately rather than waiting for
-- the next sweep.
local function on_entity_built(event)
  local entity = event.entity or event.created_entity
  if not (entity and entity.valid and entity.name == BLOCKER_ENTITY) then return end
  refresh_nearby_tracked_spawners(entity.surface, entity.position)
end

--- A real pipe near a tracked spawner was mined, destroyed, or otherwise
-- removed - same idea, but this is the direction that can open a leak.
local function on_entity_removed(event)
  local entity = event.entity
  if not (entity and entity.valid and entity.name == BLOCKER_ENTITY) then return end
  refresh_nearby_tracked_spawners(entity.surface, entity.position)
end

--- Safety-net sweep, in case some build/mine event was missed (mods
-- removing entities silently, biters chewing through a pipe, etc.).
local function sweep_tracked_spawners()
  if not storage.tracked_spawners then return end
  for unit_number, data in pairs(storage.tracked_spawners) do
    if not refresh_spawner_lock(data) then
      storage.tracked_spawners[unit_number] = nil
    end
  end
end

script.on_event(defines.events.on_player_selected_area, on_area_selected)
script.on_event(defines.events.on_player_alt_selected_area, on_area_selected)
script.on_event(defines.events.on_player_reverse_selected_area, on_area_reverse_selected)
script.on_event(defines.events.on_player_cursor_stack_changed, on_cursor_stack_changed)
script.on_event(defines.events.on_gui_checked_state_changed, on_gui_checked_state_changed)

script.on_event(defines.events.on_built_entity, on_entity_built)
script.on_event(defines.events.on_robot_built_entity, on_entity_built)
script.on_event(defines.events.script_raised_built, on_entity_built)
script.on_event(defines.events.script_raised_revive, on_entity_built)

script.on_event(defines.events.on_player_mined_entity, on_entity_removed)
script.on_event(defines.events.on_robot_mined_entity, on_entity_removed)
script.on_event(defines.events.on_entity_died, on_entity_removed)
script.on_event(defines.events.script_raised_destroy, on_entity_removed)

script.on_event(defines.events.on_entity_spawned, on_entity_spawned)

script.on_nth_tick(SWEEP_INTERVAL, sweep_tracked_spawners)

--- Returns true if `pos` has a real pipe or a pipe ghost placed there.
-- Used for auto-discovery: we want to detect intentional player placement,
-- not terrain/cliffs that happen to block pipe placement.
local function has_pipe_or_ghost(surface, pos)
  return surface.find_entities_filtered({
      name = BLOCKER_ENTITY, position = pos, radius = 0.5})[1] ~= nil
    or surface.find_entities_filtered({
      type = "entity-ghost", ghost_name = BLOCKER_ENTITY,
      position = pos, radius = 0.5})[1] ~= nil
end

--- Kill all units and worms belonging to / near a fully-locked spawner.
local function clear_locked_spawner(data)
  local spawner = data.spawner
  if not (spawner and spawner.valid) then return end
  if not (data.managed and data.gaps and #data.gaps == 0) then return end
  for _, unit in pairs(spawner.units or {}) do
    if unit.valid then unit.destroy() end
  end
  local pos  = spawner.position
  local surf = spawner.surface
  local frc  = spawner.force
  for _, e in pairs(surf.find_entities_filtered({
      position = pos, radius = 50, force = frc, type = "unit"})) do
    if e.valid then e.destroy() end
  end
  for _, e in pairs(surf.find_entities_filtered({
      position = pos, radius = 50, force = frc, type = "turret"})) do
    if e.valid then e.destroy() end
  end
end

--- Runs on every game-ready event (save load or mod update).
-- Phase 1 – auto-discover: scan every loaded spawner on every surface.
--   If it has at least one real pipe or ghost from our pattern, add it to
--   tracking. This handles saves made before the tool was ever used on those
--   spawners (storage.tracked_spawners empty) as well as pipes placed
--   manually without the tool.
-- Phase 2 – recompute + refresh: for every tracked spawner (discovered or
--   pre-existing), recompute grid positions from the current prototype so
--   stale data from old mod versions is discarded, then refresh managed/gaps.
-- Phase 3 – clean up: for each fully-locked spawner, destroy all owned
--   units wherever they have roamed and worms within 50 tiles.
local function on_game_ready()
  storage.tracked_spawners = storage.tracked_spawners or {}

  -- Phase 1: auto-discover
  for _, surface in pairs(game.surfaces) do
    for _, spawner in pairs(surface.find_entities_filtered({type = "unit-spawner"})) do
      if spawner.valid and not storage.tracked_spawners[spawner.unit_number] then
        local positions = compute_grid_positions(spawner)
        for _, pos in ipairs(positions) do
          if has_pipe_or_ghost(surface, pos) then
            storage.tracked_spawners[spawner.unit_number] = {
              spawner    = spawner,
              positions  = positions,
            }
            break
          end
        end
      end
    end
  end

  -- Phase 2 + 3: recompute, refresh, clear
  for unit_number, data in pairs(storage.tracked_spawners) do
    local spawner = data.spawner
    if not (spawner and spawner.valid) then
      storage.tracked_spawners[unit_number] = nil
    else
      data.positions = compute_grid_positions(spawner)
      local cx, cy = spawner.position.x, spawner.position.y
      local max_d2 = 0
      for _, pos in ipairs(data.positions) do
        local d2 = (cx - pos.x)^2 + (cy - pos.y)^2
        if d2 > max_d2 then max_d2 = d2 end
      end
      data.reach_sq = max_d2 + 4
      refresh_spawner_lock(data)
      clear_locked_spawner(data)
    end
  end
end

-- on_configuration_changed fires when the mod version changes (update).
-- Game state is fully accessible here so we call on_game_ready directly.
script.on_configuration_changed(on_game_ready)

-- on_load fires on every save load but the game object is not yet
-- accessible. Register a one-shot on_tick to run on_game_ready on the
-- very first tick after load, when the world is fully available.
-- No early-return guard here: Phase 1 handles the case where
-- tracked_spawners is empty by scanning all surfaces for pattern pipes.
script.on_load(function()
  script.on_event(defines.events.on_tick, function()
    on_game_ready()
    script.on_event(defines.events.on_tick, nil)
  end)
end)

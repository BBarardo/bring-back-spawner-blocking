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
-- least one real pipe built from its pattern, this mod takes over and
-- disables the spawner's own spawning directly (spawner.active = false)
-- instead of trusting the engine's own collision check. As long as every
-- position in the pattern has a real pipe, nothing spawns. If a position
-- is missing or gets destroyed, units leak out specifically through that
-- gap, on roughly the spawner's normal spawn timer - a hole in the wall
-- lets things through right there, not everywhere.

local TOOL_NAME = "spawner-blocker-planner"
local BLOCKER_ENTITY = "pipe"
local GUI_FRAME_NAME = "spawner-blocker-gui"
local CHECKBOX_NAME = "spawner-blocker-force-build-checkbox"
local LEAK_CHECK_INTERVAL = 30
local SWEEP_INTERVAL = 300

local function get_force_build(player_index)
  local value = storage.force_build and storage.force_build[player_index]
  if value == nil then return true end
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
       and e.type ~= "resource" and e.type ~= "character" and e.type ~= "cliff" then
      if not (e.to_be_deconstructed and e.to_be_deconstructed()) then
        pcall(function() e.order_deconstruction(force, player) end)
      end
      if e.to_be_deconstructed and e.to_be_deconstructed() then
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
  local rings = math.max(1, math.ceil(radius / spacing))

  local base_x = math.floor(spawner.position.x) + 0.5
  local base_y = math.floor(spawner.position.y) + 0.5

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

--- Picks which unit a spawner's lockdown leak should spawn: always the
-- weakest unit in the spawner's own result_units (falls back to
-- small-biter/small-spitter by name). A broken wall lets the small stuff
-- trickle through - it doesn't hand the spawner a free behemoth.
local function pick_leak_unit(spawner)
  local result_units = spawner.prototype.result_units
  if result_units and result_units[1] and result_units[1][1] then
    return result_units[1][1]
  end
  if spawner.name == "spitter-spawner" then return "small-spitter" end
  return "small-biter"
end

--- Roughly the spawner's own spawning_cooldown, scaled by the force's
-- current evolution factor (faster as evolution climbs, same idea as the
-- vanilla prototype). This is an approximation of the engine's internal
-- scheduling, not a faithful reimplementation of it.
local function leak_cooldown_ticks(spawner)
  local cd = spawner.prototype.spawning_cooldown or {360, 150}
  local evo = 0
  pcall(function() evo = spawner.force.get_evolution_factor(spawner.surface) end)
  local ticks = cd[1] + (cd[2] - cd[1]) * evo
  return math.max(30, math.floor(ticks))
end

--- Re-evaluates one tracked spawner: recomputes which of its pattern
-- positions are actually held, and sets spawner.active accordingly.
--
-- Management only engages once at least one position is held by a real
-- pipe - a nest the player selected with the tool but never actually
-- built anything around is left completely untouched, vanilla behaviour
-- and all. Once management is engaged, the spawner's own spawning is
-- always switched off (spawner.active = false); if there are still gaps,
-- leak_tracked_spawners() lets units through specifically there.
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

  if data.managed then
    spawner.active = false
  elseif spawner.active == false then
    -- Never actually built anything (or tore it all back down) - hand
    -- spawning back to the engine instead of leaving it stuck off.
    spawner.active = true
  end

  return true
end

local function register_tracked_spawner(spawner, positions)
  storage.tracked_spawners = storage.tracked_spawners or {}
  local data = storage.tracked_spawners[spawner.unit_number] or {
    spawner = spawner,
    next_leak_tick = 0
  }
  data.spawner = spawner
  data.positions = positions
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
      local reach = (data.spawner.prototype.spawning_radius or 4) + 2
      if dx * dx + dy * dy <= reach * reach then
        refresh_spawner_lock(data)
      end
    else
      storage.tracked_spawners[unit_number] = nil
    end
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

--- Periodically lets a managed spawner's blocked units "leak" through
-- whatever gaps its pattern currently has, on roughly its own spawn
-- timer. A spawner with zero gaps never reaches the spawn call below -
-- it's fully locked down with nothing to leak.
local function leak_tracked_spawners(event)
  if not storage.tracked_spawners then return end

  for unit_number, data in pairs(storage.tracked_spawners) do
    local spawner = data.spawner
    if not (spawner and spawner.valid) then
      storage.tracked_spawners[unit_number] = nil
    elseif data.managed and data.gaps and #data.gaps > 0 then
      if event.tick >= (data.next_leak_tick or 0) then
        local pos = data.gaps[math.random(#data.gaps)]
        local unit_name = pick_leak_unit(spawner)
        pcall(function()
          if spawner.surface.can_place_entity({name = unit_name, position = pos, force = spawner.force}) then
            spawner.surface.create_entity({name = unit_name, position = pos, force = spawner.force})
          end
        end)
        data.next_leak_tick = event.tick + leak_cooldown_ticks(spawner)
      end
    end
  end
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

script.on_nth_tick(LEAK_CHECK_INTERVAL, leak_tracked_spawners)
script.on_nth_tick(SWEEP_INTERVAL, sweep_tracked_spawners)

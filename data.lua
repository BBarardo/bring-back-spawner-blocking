-- Adds a selection tool, similar in spirit to the Mining Patch Planner /
-- Deconstruction Planner: drag it over an area and it finds enemy spawners,
-- then drops a sparse grid of pipe ghosts around them to block spawning.
--
-- Normal select / alt select: place blocker ghosts.
-- Reverse select (shift+drag): remove blocker ghosts placed by this tool,
-- since the engine's own undo (ctrl+z) does not track scripted ghost
-- placement - Mining Patch Planner has this exact limitation too, which is
-- why it ships its own undo button instead of using ctrl+z.

data:extend({
  {
    type = "selection-tool",
    name = "spawner-blocker-planner",
    icon = "__base__/graphics/icons/pipe.png",
    icon_size = 64,
    flags = {"spawnable", "only-in-cursor", "not-stackable"},
    subgroup = "tool",
    order = "z[spawner-blocker-planner]",
    stack_size = 1,
    select =
    {
      border_color = {145, 0, 200},
      count_button_color = {145, 0, 200},
      cursor_box_type = "copy",
      mode = {"any-entity"},
      entity_type_filters = {"unit-spawner"},
      entity_filter_mode = "whitelist",
      started_sound = { filename = "__core__/sound/deconstruct-select-start.ogg" },
      ended_sound = { filename = "__core__/sound/deconstruct-select-end.ogg" }
    },
    alt_select =
    {
      border_color = {145, 0, 200},
      count_button_color = {145, 0, 200},
      cursor_box_type = "copy",
      mode = {"any-entity"},
      entity_type_filters = {"unit-spawner"},
      entity_filter_mode = "whitelist",
      started_sound = { filename = "__core__/sound/deconstruct-select-start.ogg" },
      ended_sound = { filename = "__core__/sound/deconstruct-select-end.ogg" }
    },
    reverse_select =
    {
      border_color = {200, 30, 30},
      count_button_color = {200, 30, 30},
      cursor_box_type = "not-allowed",
      mode = {"entity-ghost"},
      entity_filters = {"pipe"},
      entity_filter_mode = "whitelist",
      started_sound = { filename = "__core__/sound/deconstruct-select-start.ogg" },
      ended_sound = { filename = "__core__/sound/deconstruct-select-end.ogg" }
    }
  },
  {
    -- Press the keybind to spawn the tool straight into your cursor,
    -- same way ALT+B/ALT+U/ALT+D give you the vanilla planners.
    type = "custom-input",
    name = "give-spawner-blocker-planner",
    key_sequence = "ALT + S",
    consuming = "game-only",
    item_to_spawn = "spawner-blocker-planner",
    action = "spawn-item"
  },
  {
    -- Bottom-left shortcut bar button, same spot Mining Patch Planner puts
    -- its own button. Reuses the base game's pipe icon since we don't have
    -- custom artwork - same trick the item icon above already uses.
    type = "shortcut",
    name = "spawner-blocker-planner-shortcut",
    icon = "__base__/graphics/icons/pipe.png",
    icon_size = 64,
    small_icon = "__base__/graphics/icons/pipe.png",
    small_icon_size = 64,
    order = "b[blueprints]-z[spawner-blocker-planner]",
    action = "spawn-item",
    item_to_spawn = "spawner-blocker-planner",
    style = "blue",
    associated_control_input = "give-spawner-blocker-planner"
  }
})

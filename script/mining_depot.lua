local mining_drone = require("script/mining_drone")
local depot_update_rate = 60
local mining_depot = {}
local depot_metatable = {__index = mining_depot}
local depot_range = 40
local max_spawn_per_update = 10

local script_data =
{
  depots = {},
  path_requests = {},
  global_taken = {},
  depot_highlights = {}
}

local get_product_amount = function(entity, randomize_ore)

  if entity.type == "item-entity" then
    return entity.stack.count
  end

  if entity.type == "resource" then
    local amount = (entity.prototype.mineable_properties.products[1].amount or entity.prototype.mineable_properties.products[1].amount_min) * 5
    if randomize_ore then return math.random(amount - 2, amount + 3) end
    return amount
  end

  return (entity.prototype.mineable_properties.products[1].amount or entity.prototype.mineable_properties.products[1].amount_min)

end

local names = require("shared")

local offsets =
{
  [defines.direction.north] = {0, -3},
  [defines.direction.south] = {0, 3},
  [defines.direction.east] = {3, 0},
  [defines.direction.west] = {-3, 0},
}

function mining_depot.new(entity)

  local depot =
  {
    entity = entity,
    drones = {},
    potential = {},
    estimated_count = 0,
    path_requests = {},
    item = nil
  }

  setmetatable(depot, depot_metatable)

  rendering.draw_sprite
  {
    sprite = "caution-sprite",
    surface = entity.surface,
    scale = 0.5,
    render_layer = "decorative",
    target = entity,
    target_offset = offsets[entity.direction]
  }

  local unit_number = entity.unit_number
  local depots = script_data.depots
  local bucket = depots[unit_number % depot_update_rate]
  if not bucket then
    bucket = {}
    depots[unit_number % depot_update_rate] = bucket
  end
  bucket[unit_number] = depot

  entity.active = false

  return depot
end

local on_built_entity = function(event)
  local entity = event.entity or event.created_entity
  if not (entity and entity.valid) then return end

  if entity.name ~= names.mining_depot then return end

  mining_depot.new(entity)

end

function mining_depot:get_spawn_position()
  local offset = offsets[self.entity.direction]
  local position = self.entity.position
  position.x = position.x + offset[1]
  position.y = position.y + offset[2]
  return position
end

function mining_depot:spawn_drone()
  local entity = self.entity
  if not entity.surface.can_place_entity{name = names.drone_name, position = self:get_spawn_position()} then return end
  local unit = entity.surface.create_entity{name = names.drone_name, position = self:get_spawn_position(), force = entity.force}
  if not unit then return end

  unit.orientation = (entity.direction / 8)
  unit.ai_settings.do_separation = false
  unit.speed = unit.prototype.speed * (1 + (math.random() - 0.5) / 3)

  --self:get_drone_inventory().remove({name = names.drone_name, count = 1})


  local drone = mining_drone.new(unit)
  self.drones[unit.unit_number] = drone

  drone:set_depot(self)

  self:update_sticker()
  return drone
end

function mining_depot:update_sticker()


  if self.rendering then
    rendering.destroy(self.rendering)
  end

  if not self:get_desired_item() then return end

  self.rendering = rendering.draw_text
  {
    surface = self.entity.surface,
    target = self.entity,
    text = self:get_active_drone_count().."/"..self:get_drone_item_count(),
    only_in_alt_mode = true,
    forces = {self.entity.force},
    color = {r = 1, g = 1, b = 1},
    alignment = "center",
    scale = 1.5
  }


end

function mining_depot:desired_item_changed()
  self.item = self:get_desired_item()
  self:find_potential_items()
  for k, drone in pairs(self.drones) do
    drone:cancel_command()
  end
end

function mining_depot:add_no_items_alert(string)

  for k, player in pairs (self.entity.force.connected_players) do
    player.add_custom_alert(self.entity, {type = "item", name = self.entity.name}, "Mining depot out of mining targets.", true)
  end
  rendering.draw_sprite
  {
    surface = self.entity.surface,
    target = self.entity,
    sprite = "utility/warning_icon",
    forces = {self.entity.force},
    time_to_live = 30,
    target_offset = {0, -0.5},
    render_layer = "entity-info-icon-above"
  }
end

function mining_depot:add_spawn_blocked_alert(string)

  for k, player in pairs (self.entity.force.connected_players) do
    player.add_custom_alert(self.entity, {type = "item", name = self.entity.name}, "Mining depot spawn blocked.", true)
  end
  rendering.draw_sprite
  {
    surface = self.entity.surface,
    target = self.entity,
    sprite = "utility/warning_icon",
    forces = {self.entity.force},
    time_to_live = 30,
    target_offset = offsets[self.entity.direction],
    x_scale = 0.5,
    y_scale = 0.5,
    render_layer = "entity-info-icon-above"
  }
end

function mining_depot:update()
  local entity = self.entity
  if not (entity and entity.valid) then return end

  local item = self:get_desired_item()
  if item ~= self.item then
    self:desired_item_changed()
  end

  if not item then return end

  if not next(self.potential) then
    --Nothing to mine, nothing to do...
    if not self.had_rescan then
      self.had_rescan = true
      self:find_potential_items()
      return
    end
    self:add_no_items_alert()
    return
  end

  if self:is_spawn_blocked() then
    self:add_spawn_blocked_alert()
    return
  end

  self:adopt_idle_drones()

  self:update_sticker()


  if self:is_full() then
    return
  end



  local count = self:get_drone_item_count() - self:get_active_drone_count()
  local output_space = self:get_output_space()
  --game.print(serpent.line{output_space = output_space, count = count, estimated = self.estimated_count})
  if count > 0 then

    for k = 1, (math.min(count, max_spawn_per_update)) do

      if output_space - self.estimated_count <= 0 then break end

      local entity = self:find_entity_to_mine()
      if not entity then return end

      self:attempt_to_mine(entity)

    end

  end

  if count < 0 then

    for k = count, 0, 1 do
      local index, drone = next(self.drones)
      if drone then
        drone:cancel_command(true)
      end
    end
  end

end

function mining_depot:adopt_idle_drones()

  local idle_drones = mining_drone.get_idle_drones()
  if not next(idle_drones) then return end

  local space = self:get_drone_item_count() - self:get_active_drone_count()

  if space < 1 then return end

  for unit_number, drone in pairs (idle_drones) do
    self:take_drone(drone)
    drone:return_to_depot()
    idle_drones[unit_number] = nil
    space = space - 1
    if space < 1 then break end
  end

end

function mining_depot:get_drone_item_count()
  local inventory = self:get_drone_inventory()
  if #inventory == 0 then return 0 end
  local stack = self:get_drone_inventory()[1]
  return stack.valid_for_read and stack.count or 0
end

function mining_depot:get_can_spawn_count()
  return self:get_drone_item_count() - self:get_active_drone_count()
end

function mining_depot:is_spawn_blocked()
  return not self.entity.surface.can_place_entity{name = names.drone_name, position = self:get_spawn_position()}
end

function mining_depot:attempt_to_mine(entity)

  --Will make a path request, and if it passes, send a drone to go mine it.

  local prototype = game.entity_prototypes[names.drone_name]
  local path_request_id = self.entity.surface.request_path
  {
    bounding_box = prototype.collision_box,
    collision_mask = prototype.collision_mask,
    start = self:get_spawn_position(),
    goal = entity.position,
    force = self.entity.force,
    radius = (entity.get_radius() * 2) + 1,
    can_open_gates = true,
    pathfind_flags = {cache = false, low_priority = false}
  }

  script_data.path_requests[path_request_id] = self
  self.path_requests[path_request_id] = entity

  local product_amount = get_product_amount(entity)

  self.estimated_count = self.estimated_count + product_amount

end

function mining_depot:can_spawn_drone()
  return not self:is_spawn_blocked() and self.get_drone_item_count() > self:get_active_drone_count()
end

local unique_index = function(entity)
  local unit_number = entity.unit_number
  if unit_number then return unit_number end
  local position = entity.position
  return entity.surface.index.."_"..position.x.."_"..position.y
end

local insert = table.insert
local get_entities_for_products = function(item)
  local names = {}
  for name, prototype in pairs(game.entity_prototypes) do
    local properties = prototype.mineable_properties
    if properties.minable and properties.products then
      for k, product in pairs (properties.products) do
        if product.name == item then
          insert(names, name)
          break
        end
      end
    end
  end
  return names
end

local directions =
{
  [defines.direction.north] = {0, -(depot_range + 2.5)},
  [defines.direction.south] = {0, (depot_range + 2.5)},
  [defines.direction.east] = {(depot_range + 2.5), 0},
  [defines.direction.west] = {-(depot_range + 2.5), 0},
}

local get_depot_area = function(entity)
  local origin = entity.position
  local direction = directions[entity.direction]
  origin.x = origin.x + direction[1]
  origin.y = origin.y + direction[2]
  return util.area(origin, depot_range)
end

function mining_depot:get_area()
  return get_depot_area(self.entity)
end

function mining_depot:find_potential_items()
  local potential = {}
  local unique_index = unique_index
  local item = self.item
  for k, entity in pairs(self.entity.surface.find_entities_filtered{area = self:get_area(), name = get_entities_for_products(item)}) do
    potential[unique_index(entity)] = entity
  end
  for k, entity in pairs(self.entity.surface.find_entities_filtered{area = self:get_area(), type = "item-entity"}) do
    if entity.stack.name == item then
      potential[unique_index(entity)] = entity
    end
  end

  self.potential = potential

end

function mining_depot:find_entities_to_mine()

  if not next(self.potential) then return end

  local taken = script_data.global_taken
  local eligible_entities = {}

  for unit_number, entity in pairs (self.potential) do
    if not entity.valid then
      self.potential[unit_number] = nil
    elseif not taken[unit_number] then
      eligible_entities[unit_number] = entity
    end
  end

  return eligible_entities

end

function mining_depot:find_entity_to_mine()

  local entities = self:find_entities_to_mine()
  if not next(entities) then
    return
  end

  local closest = self.entity.surface.get_closest(self.entity.position, entities)
  local index = unique_index(closest)

  script_data.global_taken[index] = true

  return closest

end

function mining_depot:remove_drone(drone, remove_item)

  if remove_item then
    self:get_drone_inventory().remove{name = names.drone_name, count = 1}
  end

  if drone.estimated_count then
    self.estimated_count = self.estimated_count - drone.estimated_count
    drone.estimated_count = nil
  end

  local mining_target = drone.mining_target
  if mining_target and mining_target.valid then
    self:add_mining_target(mining_target)
  end
  drone.mining_target = nil

  self.drones[drone.entity.unit_number] = nil
  self:update_sticker()
end

--self.potential[drone.desired_item][unique_index(target)] = target

function mining_depot:order_drone(drone, entity)

  local product_amount = get_product_amount(entity, true)
  self.estimated_count = self.estimated_count + product_amount
  drone.estimated_count = product_amount
  drone:mine_entity(entity, product_amount)

end

function mining_depot:handle_order_request(drone)

  if not (drone.mining_target and drone.mining_target.valid) then
    self:return_drone(drone)
    return
  end

  if self:is_full() or self:get_active_drone_count() > self:get_drone_item_count() then
    self:return_drone(drone)
    return
  end

  self:order_drone(drone, drone.mining_target)

end

function mining_depot:get_output_inventory()
  return self.entity.get_output_inventory()
end

function mining_depot:get_drone_inventory()
  return self.entity.get_inventory(defines.inventory.assembling_machine_input)
end

function mining_depot:get_desired_item()
  local recipe = self.entity.get_recipe()
  if not recipe then return end
  return recipe.products[1].name
end

function mining_depot:get_output_space()
  local inventory = self:get_output_inventory()
  local item = self:get_desired_item()
  if not item then return 0 end
  local prototype = game.item_prototypes[item]
  return (prototype.stack_size * (#inventory - 2)) - inventory.get_item_count(item)
end

function mining_depot:is_full()
  return (self:get_output_space() - self.estimated_count) <= 0
end

function mining_depot:handle_path_request_finished(event)
  local entity = self.path_requests[event.id]
  if not (entity and entity.valid) then return end
  self.path_requests[event.id] = nil

  local product_amount = get_product_amount(entity)

  self.estimated_count = self.estimated_count - product_amount

  if not event.path then
    --we can't reach it, don't spawn any miners.
    self:add_mining_target(entity)
    self.potential[unique_index(entity)] = nil
    game.print("HUH")
    return
  end




  local drone = self:spawn_drone()
  self:order_drone(drone, entity)

end

function mining_depot:return_drone(drone)
  self:remove_drone(drone)
  drone:remove_from_list()
  drone.entity.destroy()
  self:update_sticker()
end

function mining_depot:add_mining_target(entity)
  script_data.global_taken[unique_index(entity)] = nil
end

function mining_depot:remove_from_list()
  local unit_number = self.entity.unit_number
  script_data.depots[unit_number % depot_update_rate][unit_number] = nil
end

function mining_depot:handle_depot_deletion()
  for unit_number, drone in pairs (self.drones) do
    --self:remove_drone(drone)
    drone:cancel_command(true)
  end
end

function mining_depot:take_drone(drone)
  self.drones[drone.entity.unit_number] = drone
  drone:set_depot(self)

  drone:say("Assigned to a new depot!")
  if drone:is_returning_to_depot() then
    drone:return_to_depot()
  end
end

function mining_depot:get_all_depots()
  local depots = {}
  for k, bucket in pairs (script_data.depots) do
    for unit_number, depot in pairs (bucket) do
      if not depot.entity.valid then
        error("HI idk if I should happen")
        --depot:handle_depot_deletion(unit_number)
        bucket[unit_number] = nil
      else
        depots[unit_number] = depot
      end
    end
  end
  return depots
end

function mining_depot:get_active_drone_count()
  return table_size(self.drones)
end

function mining_depot:can_accept_drone()
  return self:get_drone_item_count() > self:get_active_drone_count()
end

local on_tick = function(event)
  local bucket = script_data.depots[event.tick % depot_update_rate]
  if bucket then
    for unit_number, depot in pairs (bucket) do
      if not (depot.entity.valid) then
        bucket[unit_number] = nil
      else
        depot:update()
      end
    end
  end
end

local on_script_path_request_finished = function(event)
  --game.print(event.tick.." - "..event.id)
  local depot = script_data.path_requests[event.id]
  if not depot then return end
  script_data.path_requests[event.id] = nil
  depot:handle_path_request_finished(event)
end

local on_entity_removed = function(event)
  local entity = event.entity
  if not (entity and entity.valid) then
    return
  end
  local unit_number = entity.unit_number
  if not unit_number then return end

  local bucket = script_data.depots[unit_number % depot_update_rate]
  if not bucket then return end
  local depot = bucket[unit_number]
  if not depot then return end
  depot:handle_depot_deletion(unit_number)

end

local on_selected_entity_changed = function(event)
  local player = game.get_player(event.player_index)

  local highlight = script_data.depot_highlights[event.player_index]
  if highlight then
    rendering.destroy(highlight)
    script_data.depot_highlights[event.player_index] = nil
  end

  local entity = player.selected
  if not (entity and entity.valid) then return end

  if entity.name ~= names.mining_depot then return end

  local area = get_depot_area(entity)
  script_data.depot_highlights[event.player_index] = rendering.draw_rectangle
  {
    surface = entity.surface,
    players = {player},
    filled = true,
    color = {r = 0, g = 0.1, b = 0, a = 0.1},
    draw_on_ground = true,
    target = entity,
    only_in_alt_mode = false,
    left_top = area[1],
    right_bottom = area[2]
  }




end

local lib = {}

lib.events =
{
  [defines.events.on_built_entity] = on_built_entity,
  [defines.events.on_robot_built_entity] = on_built_entity,
  [defines.events.script_raised_revive] = on_built_entity,
  [defines.events.script_raised_built] = on_built_entity,

  [defines.events.on_script_path_request_finished] = on_script_path_request_finished,

  [defines.events.on_player_mined_entity] = on_entity_removed,
  [defines.events.on_robot_mined_entity] = on_entity_removed,

  [defines.events.on_entity_died] = on_entity_removed,
  [defines.events.script_raised_destroy] = on_entity_removed,

  [defines.events.on_tick] = on_tick,

  [defines.events.on_selected_entity_changed] = on_selected_entity_changed,

}

lib.on_init = function()
  global.mining_depot = global.mining_depot or script_data
end

lib.on_load = function()
  script_data = global.mining_depot or script_data
  for k, bucket in pairs (script_data.depots) do
    for unit_number, depot in pairs (bucket) do
      setmetatable(depot, depot_metatable)
    end
  end
end

return lib
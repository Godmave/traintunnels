local floor = math.floor
local bxor = bit32.bxor
local rshift = bit32.rshift
local band = bit32.band

local inventory_types = {}
do
    local map = {}
    for _, inventory_type in pairs(defines.inventory) do
        map[inventory_type] = true
    end
    for t in pairs(map) do
        inventory_types[#inventory_types + 1] = t
    end
    table.sort(inventory_types)
end
local function serialize_equipment_grid(grid)
    local names, xs, ys = {}, {}, {}

    local position = {0,0}
    local width, height = grid.width, grid.height
    local processed = {}
    for y = 0, height - 1 do
        for x = 0, width - 1 do
            local base = (y + 1) * width + x + 1
            if not processed[base] then
                position[1], position[2] = x, y
                local equipment = grid.get(position)
                if equipment ~= nil then
                    local shape = equipment.shape
                    for j = 0, shape.height - 1 do
                        for i = 0, shape.width - 1 do
                            processed[base + j * width + i] = true
                        end
                    end

                    local idx = #names + 1
                    names[idx] = equipment.name
                    xs[idx] = x
                    ys[idx] = y
                end
            end
        end
    end
    return {
        names = names,
        xs = xs,
        ys = ys,
    }
end
local function serialize_inventory(inventory)
    local filters

    local bar
    if inventory.hasbar() then
        bar = inventory.getbar()
    end

    if inventory.supports_filters() then
        filters = {}
        for i = 1, #inventory do
            filters[i] = inventory.get_filter(i)
        end
    end
    local item_names, item_counts, item_durabilities,
    item_ammos, item_exports, item_labels, item_grids
    = {}, {}, {}, {}, {}, {}, {}

    for i = 1, #inventory do
        local slot = inventory[i]
        if slot.valid_for_read then
            if slot.is_item_with_inventory then
                print("sending items with inventory is not allowed")
            elseif slot.is_blueprint or slot.is_blueprint_book
                    or slot.is_deconstruction_item or slot.is_item_with_tags then
                local success, export = pcall(slot.export_stack)
                if not success then
                    print("failed to export item")
                else
                    item_exports[i] = export
                end
            else
                item_names[i] = slot.name
                item_counts[i] = slot.count
                local durability = slot.durability
                if durability ~= nil then
                    item_durabilities[i] = durability
                end
                if slot.type == "ammo" then
                    item_ammos[i] = slot.ammo
                end
                if slot.is_item_with_label then
                    item_labels[i] = {
                        label = slot.label,
                        label_color = slot.label_color,
                        allow_manual_label_change = slot.allow_manual_label_change,
                    }
                end

                local grid = slot.grid
                if grid then
                    item_grids[i] = serialize_equipment_grid(grid)
                end
            end
        end
    end

    return {
        bar = bar,
        filters = filters,
        item_names = item_names,
        item_counts = item_counts,
        item_durabilities = item_durabilities,
        item_ammos = item_ammos,
        item_exports = item_exports,
        item_labels = item_labels,
        item_grids = item_grids,
    }
end
local function deserialize_grid(grid, data)
    grid.clear()
    local names, xs, ys = data.names, data.xs, data.ys
    for i = 1, #names do
        grid.put({
            name = names[i],
            position = {xs[i], ys[i]}
        })
    end
end
local function deserialize_inventory(inventory, data)
    local item_names, item_counts, item_durabilities,
    item_ammos, item_exports, item_labels, item_grids
    = data.item_names, data.item_counts, data.item_durabilities,
    data.item_ammos, data.item_exports, data.item_labels, data.item_grids

    if inventory.hasbar() then
        inventory.setbar(data.bar)
    end

    for idx, name in pairs(item_names) do
        local slot = inventory[idx]
        slot.set_stack({
            name = name,
            count = item_counts[idx]
        })
        if item_durabilities[idx] ~= nil then
            slot.durability = item_durabilities[idx]
        end
        if item_ammos[idx] ~= nil then
            slot.ammo = item_ammos[idx]
        end
        local label = item_labels[idx]
        if label then
            slot.label = label.label
            slot.label_color = label.label_color
            slot.allow_manual_label_change = label.allow_manual_label_change
        end

        local grid = item_grids[idx]
        if grid then
            deserialize_grid(slot.grid, grid)
        end
    end
    for idx, str in pairs(item_exports) do
        inventory[idx].import_stack(str)
    end
    if data.filters then
        for idx, filter in pairs(data.filters) do
            inventory.set_filter(idx, filter)
        end
    end
end

local function teleportCarriage(trainToObserve, carriageIndex, sourceStop, targetStop, distance)
    local carriage = trainToObserve.carriages[tonumber(carriageIndex)]

    local is_flipped = floor(carriage.orientation * 4 + 0.5)
    is_flipped = bxor(rshift(sourceStop.direction, 2), rshift(is_flipped, 1))

    local inventories = {}
    for _, inventory_type in pairs(inventory_types) do
        local inventory = carriage.get_inventory(inventory_type)
        if inventory then
            inventories[inventory_type] = serialize_inventory(inventory)
        end
    end

    local fluids
    do
        local fluidbox = carriage.fluidbox
        if #fluidbox > 0 then
            fluids = {}
            for i = 1, #fluidbox do
                fluids[i] = fluidbox[i]
            end
        end
    end

    local data = {
        driver = carriage.get_driver(),
        name = carriage.name,
        color = carriage.color,
        health = carriage.health,
        is_flipped = 1-is_flipped,
        inventories = inventories,
        fluids = fluids,
        energy = carriage.energy,
        currently_burning = carriage.burner and carriage.burner.currently_burning and carriage.burner.currently_burning.name,
        remaining_burning_fuel = carriage.burner and carriage.burner.remaining_burning_fuel
    }

    local rotation
    if band(targetStop.direction, 2) == 0 then
        rotation = { 1, 0, 0, 1 }
    else
        rotation = { 0, -1, 1, 0 }
    end
    if band(targetStop.direction, 4) == 4 then
        for i = 1, 4 do rotation[i] = -rotation[i] end
    end

    local ox, oy = -2, distance
    ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

    local sp = targetStop.position
    local entity = game.surfaces[targetStop.surface.index].create_entity{
        name = data.name,
        force = game.forces.player,
        position = {x=sp.x + ox, y=sp.y + oy},
        direction = (targetStop.direction + data.is_flipped * 4) % 8
    }

    if entity == nil then
        ox, oy = -2, distance - 1
        ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

        entity = game.surfaces[targetStop.surface.index].create_entity{
            name = data.name,
            force = game.forces.player,
            position = {x=sp.x + ox, y=sp.y + oy},
            direction = (targetStop.direction + data.is_flipped * 4) % 8
        }
    end

    if entity == nil then
        ox, oy = -2, distance - 2
        ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

        entity = game.surfaces[targetStop.surface.index].create_entity{
            name = data.name,
            force = game.forces.player,
            position = {x=sp.x + ox, y=sp.y + oy},
            direction = (targetStop.direction + data.is_flipped * 4) % 8
        }
    end

    -- ft(carriage, data.direction)

    if entity ~= nil then
        entity.connect_rolling_stock(defines.rail_direction.front)
        entity.connect_rolling_stock(defines.rail_direction.back)
        if data.driver ~= nil then
            local driver = carriage.get_driver().player.index;
            if entity.surface.index ~= data.driver.surface.index then
                game.players[driver].teleport(game.players[driver].position, entity.surface.index)
            end
            entity.set_driver(game.players[driver])
        end

        if data.color then
            entity.color = data.color
        end

        if data.health then
            entity.health = data.health
        end

        for inventory_id, inventory_data in pairs(data.inventories) do
            deserialize_inventory(entity.get_inventory(inventory_id), inventory_data)
        end

        if data.fluids then
            local fluidbox = entity.fluidbox
            for i = 1, #data.fluids do
                fluidbox[i] = data.fluids[i]
            end
        end

        if data.energy > 0 then
            entity.energy = data.energy
            if entity.burner then
                entity.burner.currently_burning = data.currently_burning
                entity.burner.remaining_burning_fuel = data.remaining_burning_fuel
            end
        end

        entity.train.schedule = trainToObserve.schedule

        local train = carriage.train
        local trainId = carriage.train.id
        carriage.destroy()
        script.raise_event(defines.events.script_raised_destroy, {train=train, trainId=trainId})

        --trainToObserve.carriages[tonumber(carriageIndex)] = entity
    else
        -- game.print("cant teleport")
        return false
    end

    return entity
end

return {
    inventory_types = inventory_types,
    serialize_inventory = serialize_inventory,
    deserialize_inventory = deserialize_inventory,
    teleportCarriage = teleportCarriage
}
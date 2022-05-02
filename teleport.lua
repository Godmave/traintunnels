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


local function teleportCarriage(trainToObserve, carriageIndex, sourceStop, targetStop, distance)
    local carriage = trainToObserve.carriages[tonumber(carriageIndex)]

    local is_flipped = (math.abs(carriage.orientation - sourceStop.orientation) > 0.25) and 1 or 0

    -- game.print(serpent.line{cindex=carriage.unit_number,carriage=carriage.orientation, sourceStop=sourceStop.orientation,is_flipped=is_flipped})

    local inventories = {}
    local grid = saveRestoreLib.saveGrid(carriage.grid)
    for _, inventory_type in pairs(inventory_types) do
        local inventory = carriage.get_inventory(inventory_type)
        if inventory then
            inventories[inventory_type] = saveRestoreLib.saveInventoryStacks(inventory)
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
        grid = grid,
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
        snap_to_train_stop = false,
        position = {x=(sp.x + ox), y=sp.y + oy},
        direction = (targetStop.direction + data.is_flipped * 4) % 8
    }

    if(entity and math.abs(carriage.orientation - entity.orientation) > 0.25) then
        entity.destroy()
        entity = game.surfaces[targetStop.surface.index].create_entity{
            name = data.name,
            force = game.forces.player,
            snap_to_train_stop = false,
            position = {x=(sp.x + ox), y=sp.y + oy},
            direction = (targetStop.direction + (1-data.is_flipped) * 4) % 8
        }
    end

    if entity ~= nil then
        if data.driver ~= nil then
            local driver = carriage.get_driver()
            if(driver.is_player()) then
                driver = driver.index
            else
                driver = driver.player.index
            end
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
            saveRestoreLib.insertInventoryStacks(entity.get_inventory(inventory_id), inventory_data)
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

        if data.grid and entity.grid then
            saveRestoreLib.restoreGrid(entity.grid, data.grid)
        end

        --- For compatibility with https://mods.factorio.com/mod/VehicleWagon2 ---
        if remote.interfaces["VehicleWagon2"] then
            wagon_data = remote.call("VehicleWagon2", "get_wagon_data", carriage)
            remote.call("VehicleWagon2", "set_wagon_data", entity, wagon_data)
        end

        entity.train.schedule = trainToObserve.schedule

        carriage.destroy()
    else
        return false
    end

    return entity
end

return {
    inventory_types = inventory_types,
    teleportCarriage = teleportCarriage
}
local inspect = require("inspect")
local teleport = require("teleport")

require("mod-gui")
require("quadTree")

local insert = table.insert
local remove = table.remove
local sqrt = math.sqrt
local abs = math.abs
local pow = math.pow
local find = string.find
local gsub = string.gsub
local next = next

--[[
todo:
- fix switch from manual supertrains to automatic. atm it behaves automatic but is not
--]]

global.superTrains = {}
global.trainTunnels = {}
global.trainTunnelsRailLookup = {} -- [surface] => quadtree:rail.pos => traintunnel
global.trainTunnelsStopLookup = {} -- stopId => traintunnel

local ftCache = {}
local function ft(anchor, text, row)
    row = row or 0
    local cacheKey = anchor.unit_number .. ':' .. row

    if ftCache[cacheKey] then
        if ftCache[cacheKey].valid then
            ftCache[cacheKey].destroy()
        end
        ftCache[cacheKey] = nil
    end

    ftCache[cacheKey] = anchor.surface.create_entity{name = "flying-text", position = {anchor.position.x,anchor.position.y-0.5*row}, text = text, color = {r=1,g=0,b=0}}
end


local function entity_distance(a, b)
    if a.position.x == b.position.x then
        return abs(a.position.y - b.position.y)
    elseif a.position.y == b.position.y then
        return abs(a.position.x - b.position.x)
    end
    return sqrt(pow(abs(a.position.x - b.position.x), 2) + pow(abs(a.position.y - b.position.y),2))
end
local function train_frontfartheraway(carriage, to_stop)
    if #carriage.train.carriages == 1 then
        if carriage.type == "locomotive" then
            return abs(carriage.orientation - to_stop.orientation) > 0.25
        else
            return abs(carriage.orientation - to_stop.orientation) > 0.25
        end
    else
        return entity_distance(carriage.train.front_stock, to_stop) > entity_distance(carriage.train.back_stock, to_stop)
    end
end
local function tryToDisolveSupertrain(superTrainIndex)
    local superTrain = global.superTrains[superTrainIndex]
    local hasPlayer = (superTrain.player_index and superTrain.player_index > 0)
    local isInPieces = table_size(superTrain.trains) > 1

    if isInPieces then
        return false
    elseif not superTrain.auto then
        if hasPlayer then
            return false
        else
            global.superTrains[superTrainIndex] = nil
        end
    else
        -- no known case if this
        global.superTrains[superTrainIndex] = nil
    end

    return true
end


script.on_event(defines.events.on_tick, function(event)
    global.distances = global.distances or {}

    if #global.superTrains > 0 then
        for _, trainToObserve in pairs(global.superTrains) do
            if trainToObserve.controlTrain and trainToObserve.controlTrain.valid then
                if trainToObserve.auto then
                    if not trainToObserve.controlTrain.manual_mode then
                        if trainToObserve.arrivingTunnel then
                            trainToObserve.controlTrain.manual_mode = true
                            trainToObserve.controlTrain.speed = trainToObserve.speed
                            trainToObserve.controlTrain.manual_mode = false
                        end
                    else
                        trainToObserve.auto = false
                    end
                end

                trainToObserve.speed = trainToObserve.controlTrain.speed
                if trainToObserve.speed == 0 then
                    if not (trainToObserve.checkWhenStopped and tryToDisolveSupertrain(_)) then
                        if table_size(trainToObserve.trains) > 1 then
                            for _st, subTrain in pairs(trainToObserve.trains) do
                                if subTrain.valid then
                                    subTrain.speed = 0
                                end
                            end
                        end
                    end
                else
                    -- todo: in 0.17 we should be able to only do this when the schedule changes via a newly introduced event
                    trainToObserve.schedule = trainToObserve.controlTrain.schedule

                    if trainToObserve.carriagesChanged then
                        trainToObserve.carriages =  {}
                    end

                    if next(trainToObserve.carriages) == nil then
                        for _st, subTrain in pairs(trainToObserve.trains) do
                            if subTrain.valid then
                                trainToObserve.carriages[#trainToObserve.carriages+1] = subTrain.front_stock
                                if subTrain.front_stock.unit_number ~= subTrain.back_stock.unit_number then
                                    trainToObserve.carriages[#trainToObserve.carriages+1] = subTrain.back_stock
                                end
                            end
                        end
                        trainToObserve.carriagesChanged = false
                    end

                    if not trainToObserve.auto then
                        for _c=1,#trainToObserve.carriages do
                            local carriage = trainToObserve.carriages[_c]
                            if carriage.valid then
                                local driver = carriage.get_driver()
                                if driver and driver.player.index == trainToObserve.player_index then
                                    trainToObserve.rs = carriage.train.riding_state
                                end
                            end
                        end
                    end

                    local trainSpeedSet = {}

                    for _c=1,#trainToObserve.carriages do
                        local carriage = trainToObserve.carriages[_c]
                        if carriage.valid and carriage.train.valid and trainToObserve.controlTrain.valid then
                            local carriageTeleported = false
                            local previousSpeed = carriage.speed
                            local compare_rail

                            if #carriage.train.carriages > 1 then
                                if carriage.train.back_stock == carriage then
                                    compare_rail = carriage.train.back_rail
                                else
                                    compare_rail = carriage.train.front_rail
                                end
                            else
                                if carriage.speed < 0 then
                                    compare_rail = carriage.train.back_rail
                                else
                                    compare_rail = carriage.train.front_rail
                                end
                            end


                            if trainToObserve.trainSpeedMulti[carriage.train.id] == nil then
                                if (trainToObserve.speed * carriage.train.speed) < 0 then
                                    trainToObserve.trainSpeedMulti[carriage.train.id] = -1
                                else
                                    trainToObserve.trainSpeedMulti[carriage.train.id] = 1
                                end
                            end


                            local cposition = carriage.position
                            local range = {
                                x = cposition.x - 4,
                                y = cposition.y - 4,
                                w = 8,
                                h = 8
                            }
                            local carriageSurface = carriage.surface.name
                            local tunnels = global.trainTunnelsRailLookup[carriageSurface]:getObjectsInRange(range)
                            local carriagetrain = carriage.train

                            for _=1,#tunnels do
                                local tunnel = global.trainTunnels[ tunnels[_]['tunnel']]
                                local from_rail, to_rail, from_stop, to_stop

                                if carriageSurface == tunnel.from_surface then
                                    from_rail = tunnel.from_rail
                                    to_rail = tunnel.to_rail
                                    from_stop = tunnel.from_stop
                                    to_stop = tunnel.to_stop
                                else
                                    from_rail = tunnel.to_rail
                                    to_rail = tunnel.from_rail
                                    from_stop = tunnel.to_stop
                                    to_stop = tunnel.from_stop
                                end

                                local carriage_unit_number = carriage.unit_number

                                if (compare_rail.position.x == from_rail.position.x or compare_rail.position.y == from_rail.position.y) then
                                    local cacheKey = carriage_unit_number..':'..from_rail.unit_number
                                    local lastDistance = global.distances[cacheKey]
                                    local distance = entity_distance(carriage, from_rail)

                                    if lastDistance ~= nil and lastDistance > distance and distance < (trainToObserve.auto and 4 or 3+abs(trainToObserve.speed)) then
                                        global.distances[cacheKey] = nil
                                        local driver
                                        if not trainToObserve.auto then
                                            driver = carriage.get_driver()
                                        end

                                        local isControl = ((trainToObserve.auto or not trainToObserve.player_index) and carriagetrain == trainToObserve.controlTrain) or (driver and driver.player.index == trainToObserve.player_index)

                                        local connectedCarriage
                                        if #carriagetrain.carriages > 1 then

                                            for _=1,#carriagetrain.carriages do
                                                local c = carriagetrain.carriages[_]
                                                if c.unit_number == carriage_unit_number then
                                                    if _ == 1 then
                                                        connectedCarriage = carriagetrain.carriages[_+1]
                                                    else
                                                        connectedCarriage = carriagetrain.carriages[_-1]
                                                    end
                                                end
                                            end
                                        end

                                        local pre = {
                                            speedMulti = trainToObserve.trainSpeedMulti[carriagetrain.id],
                                            speed = carriagetrain.speed,
                                            frontFartherAwayThanBack = train_frontfartheraway(carriage, from_stop)
                                        }



                                        -- TELEPORT
                                        if not teleport.teleportCarriage(trainToObserve, _c, from_stop, to_stop) then
                                            log("unable to teleport")
                                            goto carriagedone
                                        end

                                        carriage = trainToObserve.carriages[_c]
                                        carriagetrain = carriage.train
                                        trainToObserve.trains[carriagetrain.id] = carriagetrain
                                        --

                                        if connectedCarriage then
                                            if (pre.speed * connectedCarriage.train.speed) < 0 then
                                                trainToObserve.trainSpeedMulti[connectedCarriage.train.id] = pre.speedMulti * -1
                                            else
                                                trainToObserve.trainSpeedMulti[connectedCarriage.train.id] = pre.speedMulti
                                            end
                                        end

                                        if train_frontfartheraway(carriage, to_stop) == pre.frontFartherAwayThanBack then
                                            trainToObserve.trainSpeedMulti[carriagetrain.id] = pre.speedMulti * -1
                                        else
                                            trainToObserve.trainSpeedMulti[carriagetrain.id] = pre.speedMulti
                                        end

                                        if #carriagetrain.carriages == 1 then
                                            carriagetrain.speed = pre.speed * trainToObserve.trainSpeedMulti[carriagetrain.id]
                                        end



                                        if isControl then
                                            if trainToObserve.controlTrainId ~= carriagetrain.id then
                                                -- this should not happen, but does in auto
                                                trainToObserve.controlTrain = carriagetrain
                                                trainToObserve.controlTrainId = carriagetrain.id
                                            end

                                            if trainToObserve.auto then
                                                local schedule = trainToObserve.controlTrain.schedule
                                                schedule.current = schedule.current % #schedule.records + 1
                                                trainToObserve.controlTrain.schedule = schedule

                                                trainToObserve.controlTrain.manual_mode = false
                                            end


                                            if carriagetrain.speed ~= 0 then
                                                trainToObserve.speed = carriagetrain.speed
                                            end

                                            if trainToObserve.trainSpeedMulti[carriagetrain.id] ~= 1 then
                                                trainToObserve.speed = carriagetrain.speed
                                                for ___ in pairs(trainToObserve.trainSpeedMulti) do
                                                    trainToObserve.trainSpeedMulti[___] = -trainToObserve.trainSpeedMulti[___]
                                                end
                                            end
                                        elseif table_size(trainToObserve.trainSpeedMulti) == 1 then
                                            trainToObserve.trainSpeedMulti[carriagetrain.id] = 1
                                            trainToObserve.speed = carriagetrain.speed
                                        end

                                        carriageTeleported = true
                                        trainToObserve.carriagesChanged = true
                                        goto carriagedone
                                    end

                                    global.distances[cacheKey] = distance
                                end
                            end

                            ::carriagedone::

                            local carriageTrainId = carriagetrain.id

                            if not trainSpeedSet[carriageTrainId] and carriage.valid and carriagetrain.valid then
                                if carriageTrainId ~= trainToObserve.controlTrainId then
                                    carriagetrain.speed = trainToObserve.speed * trainToObserve.trainSpeedMulti[carriageTrainId] * trainToObserve.trainSpeedMulti[trainToObserve.controlTrainId]
                                elseif carriageTeleported then
                                    if trainToObserve.auto == false
                                            or (
                                            trainToObserve.controlTrain.state ~= defines.train_state.arrive_signal
                                                    and  trainToObserve.controlTrain.state ~= defines.train_state.wait_signal
                                                    and  trainToObserve.controlTrain.state ~= defines.train_state.no_path
                                                    and  trainToObserve.controlTrain.state ~= defines.train_state.no_schedule
                                                    and  trainToObserve.controlTrain.state ~= defines.train_state.path_lost
                                    ) then
                                        if carriagetrain.speed < 0 then
                                            carriagetrain.speed = abs(previousSpeed) * -1
                                        else
                                            carriagetrain.speed = abs(previousSpeed)
                                        end
                                    end

                                    if trainToObserve.auto then
                                        trainToObserve.controlTrain.manual_mode = false
                                    end
                                end

                                trainSpeedSet[carriageTrainId] = true
                            end
                        else
                            trainToObserve.carriages[_c] = nil
                        end
                    end

                    if trainToObserve.rs ~= nil and trainToObserve.player_index then
                        game.players[trainToObserve.player_index].riding_state = trainToObserve.rs
                        trainToObserve.rs = nil
                    end
                end

                if next(trainToObserve.trains) ~= nil then
                    if trainToObserve.auto or (trainToObserve.player_index and #trainToObserve.passengers > 0) then
                        if table_size(trainToObserve.trains) > 1 then
                            local idle_riding_state = {
                                acceleration = defines.riding.acceleration.nothing,
                                direction = defines.riding.direction.straight
                            }

                            local player_riding_state
                            if trainToObserve.player_index then
                                player_riding_state = game.players[trainToObserve.player_index].riding_state
                            end

                            for _st, subTrain in pairs(trainToObserve.trains) do
                                if subTrain.valid then
                                    for _c=1, #subTrain.carriages do
                                        local driver = subTrain.carriages[_c].get_driver()
                                        if driver and (trainToObserve.auto or driver.player.index ~= trainToObserve.player_index) then
                                            if trainToObserve.auto then
                                                driver.riding_state = idle_riding_state
                                            elseif player_riding_state then
                                                driver.riding_state = player_riding_state
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            else
                global.superTrains[_] = nil
            end
        end
    end
end)

local function tunnelPrefix(name)
    local prefix = '<T>'
    return prefix .. string.gsub(name, '^<T>', "")
end

local function updateTunnelName(entity)
    -- make sure the tunnel is prefixed with <T>
    entity.backer_name = tunnelPrefix(entity.backer_name)

    -- and that both ends have the same name
    local tunnel = global.trainTunnelsStopLookup[entity.unit_number]
    if tunnel then
        global.trainTunnels[tunnel].from_stop.backer_name = entity.backer_name
        global.trainTunnels[tunnel].to_stop.backer_name = entity.backer_name
    end
end

local function addTunnel(tunnel)
    local rail_position
    local uniqueId = tunnel.from_stop.unit_number .. ':' .. tunnel.to_stop.unit_number

    tunnel.to_stop.backer_name = tunnelPrefix(tunnel.from_stop.backer_name)
    tunnel.from_stop.backer_name = tunnelPrefix(tunnel.from_stop.backer_name)

    -- store the tunnel itself
    global.trainTunnels[uniqueId] = tunnel

    -- store lookup for upper entrance
    if global.trainTunnelsRailLookup[tunnel.from_surface] == nil then
        global.trainTunnelsRailLookup[tunnel.from_surface] = QuadTree:new()
    end

    rail_position = tunnel.from_rail.position
    global.trainTunnelsRailLookup[tunnel.from_surface]:addObject({
        x = rail_position.x,
        y = rail_position.y,
        width = 1,
        height = 1,
        tunnel = uniqueId
    })

    -- store lookup for lower entrance
    if global.trainTunnelsRailLookup[tunnel.to_surface] == nil then
        global.trainTunnelsRailLookup[tunnel.to_surface] = QuadTree:new()
    end
    rail_position = tunnel.to_rail.position
    global.trainTunnelsRailLookup[tunnel.to_surface]:addObject({
        x = rail_position.x,
        y = rail_position.y,
        width = 1,
        height = 1,
        tunnel = uniqueId
    })

    -- store stop lookups for auto-trains
    global.trainTunnelsStopLookup[tunnel.from_stop.unit_number] = uniqueId
    global.trainTunnelsStopLookup[tunnel.to_stop.unit_number] = uniqueId
end
local function removeTunnel(tunnel)
    local rail_position
    local uniqueId = tunnel.from_stop.unit_number .. ':' .. tunnel.to_stop.unit_number

    global.trainTunnels[uniqueId] = nil

    rail_position = tunnel.from_rail.position
    if global.trainTunnelsRailLookup[tunnel.from_surface] then
        global.trainTunnelsRailLookup[tunnel.from_surface]:removeObject({
            x = rail_position.x,
            y = rail_position.y,
            width = 1,
            height = 1,
            tunnel = uniqueId

        })

    end

    rail_position = tunnel.to_rail.position
    if global.trainTunnelsRailLookup[tunnel.to_surface] then
        global.trainTunnelsRailLookup[tunnel.to_surface]:removeObject({
            x = rail_position.x,
            y = rail_position.y,
            width = 1,
            height = 1,
            tunnel = uniqueId

        })
    end

    global.trainTunnelsStopLookup[tunnel.from_stop.unit_number] = nil
    global.trainTunnelsStopLookup[tunnel.to_stop.unit_number] = nil
end
local function ensureSurfaceByName(surfaceName)
    if game.surfaces[surfaceName] then
        return game.surfaces[surfaceName]
    end

    local autoplace_controls, tile_settings
    for control in pairs(game.autoplace_control_prototypes) do
        if control:find("dirt") then
            autoplace_controls = control
        end
    end

    if autoplace_controls then
        autoplace_controls = {
            [autoplace_controls] = {
                frequency = "very-low",
                size = "very-high",
            }
        }
    else
        tile_settings = {
            ["sand-1"] = {
                frequency = "very-low",
                size = "very-high",
            }
        }
    end

    local newSurface = game.create_surface(surfaceName, {
        starting_area = "none",
        water = "none",
        cliff_settings = { cliff_elevation_0 = 1024 },
        default_enable_all_autoplace_controls = false,
        autoplace_controls = autoplace_controls,
        autoplace_settings = {
            decorative = { treat_missing_as_default = false },
            entity = { treat_missing_as_default = false },
            tile = { treat_missing_as_default = false, settings = tile_settings },
        },
    })

    newSurface.daytime = 0.5
    newSurface.freeze_daytime = 1
    newSurface.peaceful_mode = 1


    for _, entity in pairs(newSurface.find_entities_filtered({ type = 'resource'})) do
        entity.destroy()
    end

    return newSurface
end
local function getSurfaceBelow(surface)
    local surfaceBelow
    if surface.name == "nauvis" then
        surfaceBelow = "underground_1"
    elseif find(surface.name, 'underground_',1,true) then
        local level = gsub(surface.name, 'underground%_', "")
        surfaceBelow = "underground_" .. (level + 1)
    end

    return ensureSurfaceByName(surfaceBelow)
end

local lowerTunnelStructures = {
    [1] = {-4, 6,"traintunnelup"},
    [2] = {-2, 0,"straight-rail"},
    [3] = {-2, 2,"straight-rail"},
    [4] = {-2, 4,"straight-rail"},
    [5] = {-2, 6,"straight-rail", true},
    [6] = {-2, 8,"straight-rail"}
}
local upperTunnelStructures = {
    [1] = { 0, 0,"traintunnel"},
    [2] = {-2,-2,"straight-rail"},
    [3] = {-2, 0,"straight-rail", true},
    [4] = {-2, 2,"straight-rail"},
    [5] = {-2, 4,"straight-rail"},
    [6] = {-2, 6,"straight-rail"},
}


local function removeTunnelDown(entity)
    local s = entity.surface
    local p = entity.position
    local d = entity.direction

    local ts = getSurfaceBelow(entity.surface)

    local tunnelId = global.trainTunnelsStopLookup[entity.unit_number]
    if tunnelId ~= nil then
        removeTunnel(global.trainTunnels[tunnelId])
    end

    local rotation
    if bit32.band(d, 2) == 0 then
        rotation = { 1, 0, 0, 1 }
    else
        rotation = { 0, -1, 1, 0 }
    end
    if bit32.band(d, 4) == 4 then
        for i = 1, 4 do rotation[i] = -rotation[i] end
    end

    for _, structure in ipairs(upperTunnelStructures) do
        if structure[3] ~= "straight-rail" then
            local ox, oy = structure[1], structure[2]
            ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

            local e = s.find_entity(structure[3], {x = p.x+ox, y = p.y+oy})
            if e and e.valid then
                e.destroy()
            end

        end
    end
    for _, structure in ipairs(lowerTunnelStructures) do
        if structure[3] ~= "straight-rail" then
            local ox, oy = structure[1], structure[2]
            ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

            local e = ts.find_entity(structure[3], {x = p.x+ox, y = p.y+oy})
            if e and e.valid then
                e.destroy()
            end
        end
    end
end
local function findOrPlaceEntity(surfaceName, entityDefinition)
    local surface = game.surfaces[surfaceName]

    if not surface.is_chunk_generated(entityDefinition.position) then
        surface.request_to_generate_chunks(entityDefinition.position, 1)
        surface.force_generate_chunk_requests()
    end

    if not surface.can_place_entity(entityDefinition) then
        local entityAtPosition = surface.find_entity(entityDefinition.name, entityDefinition.position)
        if entityAtPosition and entityAtPosition.valid then
            return entityAtPosition
        end
    else
        return surface.create_entity(entityDefinition)
    end
end
local function createTunnelDown(entity, player_index)
    local s = entity.surface.name
    local p = entity.position
    local d = entity.direction

    local rotation
    if bit32.band(d, 2) == 0 then
        rotation = { 1, 0, 0, 1 }
    else
        rotation = { 0, -1, 1, 0 }
    end
    if bit32.band(d, 4) == 4 then
        for i = 1, 4 do rotation[i] = -rotation[i] end
    end


    local tunnel = {
        from_surface = entity.surface.name,
        from_stop = 0,
        from_rail = 0,
        to_surface = 0,
        to_stop = 0,
        to_rail = 0,
    }

    tunnel.to_surface = getSurfaceBelow(entity.surface).name

    local tobeCreated, lastCreated

    for _, structure in ipairs(upperTunnelStructures) do
        local ox, oy = structure[1], structure[2]
        ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

        tobeCreated = {
            name = structure[3],
            force = game.forces.player,
            position = {x=p.x+ox, y=p.y+oy},
            direction = d
        }

        lastCreated = findOrPlaceEntity(tunnel.from_surface, tobeCreated)

        if lastCreated and structure[3] == "traintunnel" then
            tunnel.from_stop = lastCreated
        end
        if lastCreated and structure[4] == true then
            tunnel.from_rail = lastCreated
        end
    end

    for _, structure in ipairs(lowerTunnelStructures) do
        local ox, oy = structure[1], structure[2]
        ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

        tobeCreated = {
            name = structure[3],
            force = game.forces.player,
            position = {x=p.x+ox, y=p.y+oy},
            direction = (d + 4) % 8
        }

        lastCreated = findOrPlaceEntity(tunnel.to_surface, tobeCreated)

        if lastCreated and structure[3] == "traintunnelup" then
            tunnel.to_stop = lastCreated
        end
        if lastCreated and structure[4] == true then
            tunnel.to_rail = lastCreated
        end
    end

    local valid = true
    for _ in pairs(tunnel) do
        if tunnel[_] == 0 then
            valid = false;
            break
        end
    end

    if not valid then
        removeTunnelDown(entity)
        game.players[player_index].insert{name = "traintunnel", count=1}
    else
        addTunnel(tunnel)
    end
end



script.on_event(defines.events.on_built_entity, function(event)
    if event.created_entity.name == "traintunnel" then
        createTunnelDown(event.created_entity, event.player_index)
    end
end)

script.on_event(defines.events.on_robot_built_entity, function(event)
    if event.created_entity.name == "traintunnel" then
        createTunnelDown(event.created_entity, event.player_index)
    end
end)

script.on_event(defines.events.on_player_mined_entity, function(event)
    if event.entity.name == "traintunnel" then
        removeTunnelDown(event.entity)
    end
end)

script.on_event(defines.events.on_robot_mined_entity, function(event)
    if event.entity.name == "traintunnel" then
        removeTunnelDown(event.entity)
    end
end)


script.on_event(defines.events.on_player_driving_changed_state, function(event)
    if event.entity ~= nil and event.entity.train ~= nil then
        if game.players[event.player_index].driving then
            local jumped = false
            local train = event.entity.train
            for _, superTrain in ipairs(global.superTrains) do
                if superTrain.player_index == event.player_index then
                    global.superTrains[_].driverTrain = train
                    global.superTrains[_].driverTrainId = train.id

                    if not superTrain.auto then
                        global.superTrains[_].controlTrain = train
                        global.superTrains[_].controlTrainId = train.id

                        -- todo: teleport this player to the controlTrain so he can not hijack the subtrain
                    end
                    jumped = true
                    break
                end
            end

            if not jumped then
                local superTrain
                for _, st in pairs(global.superTrains) do
                    if st.trains[event.entity.train.id] then
                        superTrain = st
                        global.superTrains[_] = nil
                        break
                    end
                end

                if superTrain == nil then
                    superTrain = {
                        player_index = event.player_index,
                        passengers = {},
                        driverTrain = train,
                        driverTrainId = train.id,
                        controlTrain = train,
                        controlTrainId = train.id,
                        trains = {},
                        trainSpeedMulti = {},
                        carriages = {}
                    }
                    superTrain.trains[train.id] = train
                else
                    if not superTrain.player_index then
                        superTrain.player_index = event.player_index
                        superTrain.driverTrain = train
                        superTrain.driverTrainId = train.id

                        if not superTrain.auto then
                            superTrain.controlTrain = train
                            superTrain.controlTrainId = train.id
                        end
                    else
                        superTrain.passengers = superTrain.passengers or {}
                        insert(superTrain.passengers, event.player_index)
                    end

                end
                insert(global.superTrains, superTrain)
            end

        else
            for _, superTrain in ipairs(global.superTrains) do
                if superTrain.player_index == event.player_index then
                    local hasPassengers = superTrain.passengers and (next(superTrain.passengers) ~= nil)
                    if table_size(superTrain.trains) == 1 and not superTrain.auto and not hasPassengers then
                        -- supertrain consists of only one train, resolve
                        if superTrain.speed == 0 then
                            global.superTrains[_] = nil
                        else
                            global.superTrains[_].checkWhenStopped = true
                            global.superTrains[_].player_index = nil
                        end
                    else
                        -- supertrain is split into parts or has passengers
                        if hasPassengers then
                            global.superTrains[_].player_index = remove(superTrain.passengers, 1)

                            -- find train this new driver is sitting in
                            -- and set it to control and/or driver train
                            for _st, subTrain in pairs(superTrain.trains) do
                                if subTrain.valid then
                                    for _c=1, #subTrain.carriages do
                                        local driver = subTrain.carriages[_c].get_driver()
                                        if driver and driver.player.index ~= global.superTrains[_].player_index then

                                            global.superTrains[_].driverTrain = subTrain
                                            global.superTrains[_].driverTrainId = subTrain.id
                                            if superTrain.auto then
                                                global.superTrains[_].controlTrain = subTrain
                                                global.superTrains[_].controlTrainId = subTrain.id
                                            end

                                            break
                                        end
                                    end
                                end
                            end

                        else
                            global.superTrains[_].player_index = nil
                        end
                    end
                    break
                else
                    -- not the current driver, just remove him from the passengers
                    for _, p in pairs(superTrain.passengers) do
                        if p == event.player_index then
                            superTrain.passengers[_] = nil
                            break
                        end
                    end
                end
            end
        end
    end
end)

script.on_event(defines.events.on_train_changed_state, function (event)
    local train = event.train
    local trainState = event.train.state

    local superTrain, superTrainIndex
    for _, st in pairs(global.superTrains) do
        if st.trains[train.id] then
            superTrain = st
            superTrainIndex = _
            break
        end
    end

    local hasMomentum = false
    local hasPlayer = false
    local isInPieces = false
    local isDisolvable = true

    if superTrain then
        superTrain.arrivingTunnel = false

        hasMomentum = (superTrain.speed ~= 0)
        hasPlayer = (superTrain.player_index and superTrain.player_index > 0)
        isInPieces = table_size(superTrain.trains) > 1

        isDisolvable = not hasPlayer and not isInPieces
    end

    if superTrainIndex and trainState == defines.train_state.on_the_path  then
        if train.id ~= superTrain.controlTrainId then
            superTrain.controlTrain = train
            superTrain.controlTrainId = train.id
            superTrain.auto = true
        else
            superTrain.auto = true
        end
        -- Normal state -- following the path.
        if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil return end
    elseif trainState == defines.train_state.path_lost then
        -- Had path and lost it -- must stop.
        if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil return end
    elseif trainState == defines.train_state.no_schedule then
        -- Doesn't have anywhere to go.
        if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil return end
    elseif trainState == defines.train_state.no_path then
        -- Has no path and is stopped.
        if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil return end
    elseif trainState == defines.train_state.arrive_signal then
        -- Braking before a rail signal.
        if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil return end
    elseif trainState == defines.train_state.wait_signal then
        -- Waiting at a signal.
        if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil return end
    elseif trainState == defines.train_state.arrive_station then
        -- Braking before a station.
        local entryStation = train.schedule.records[train.schedule.current].station
        if find(entryStation, '<T',1, true) then
            if superTrain == nil then
                superTrain = {
                    auto = true,
                    controlTrain = train,
                    controlTrainId = train.id,
                    speed = train.speed,
                    trains = {},
                    trainSpeedMulti = {},
                    carriages = {},
                    passengers = {}
                }
                superTrain.trains[train.id] = train
            else
                superTrain.auto = true
            end
            superTrain.arrivingTunnel = true
        else
            if superTrain ~= nil then
                superTrain.arrivingTunnel = false
            end
        end
    elseif trainState == defines.train_state.wait_station then
        -- Waiting at a station.
        if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil return end
    elseif trainState == defines.train_state.manual_control_stop or trainState == trainState == defines.train_state.manual_control then
        -- Switched to manual control and has to stop.
        -- Can move if user explicitly sits in and rides the train.

        if superTrain then
            if hasPlayer then
                if superTrain.controlTrainId ~= superTrain.driverTrainId then
                    superTrain.controlTrain = superTrain.driverTrain
                    superTrain.controlTrainId = superTrain.driverTrainId
                end

                superTrain.auto = false
            elseif hasMomentum then
                superTrain.checkWhenStopped = true
            else
                return
            end
        end
    end

    if superTrain then
        if superTrainIndex then
            global.superTrains[superTrainIndex] = superTrain
        else
            insert(global.superTrains, superTrain)
        end
    end

    return
end)

script.on_event(defines.events.on_train_created, function (event)
    for _, superTrain in pairs(global.superTrains) do
        if event.old_train_id_1 ~= nil and superTrain.trains[event.old_train_id_1] ~= nil then
            superTrain.trains[event.old_train_id_1] = nil
            superTrain.trains[event.train.id] = event.train

            if superTrain.trainSpeedMulti[event.old_train_id_1] ~= nil then
                superTrain.trainSpeedMulti[event.train.id] = superTrain.trainSpeedMulti[event.old_train_id_1]
                superTrain.trainSpeedMulti[event.old_train_id_1] = nil
            end

        end
        if event.old_train_id_2 ~= nil and superTrain.trains[event.old_train_id_2] ~= nil then
            superTrain.trains[event.old_train_id_2] = nil
            superTrain.trains[event.train.id] = event.train

            if superTrain.trainSpeedMulti[event.old_train_id_2] ~= nil then
                superTrain.trainSpeedMulti[event.train.id] = superTrain.trainSpeedMulti[event.old_train_id_2]
                superTrain.trainSpeedMulti[event.old_train_id_2] = nil
            end
        end

        if event.old_train_id_1 == superTrain.controlTrainId or event.old_train_id_2 == superTrain.controlTrainId then
            superTrain.controlTrain = event.train
            superTrain.controlTrainId = event.train.id
        end
        if event.old_train_id_1 == superTrain.driverTrainId or event.old_train_id_2 == superTrain.driverTrainId then
            superTrain.driverTrain = event.train
            superTrain.driverTrainId = event.train.id
        end

        global.superTrains[_] = superTrain
    end
end)
script.on_event(defines.events.script_raised_destroy, function (event)
    local train = event.train
    local trainId = event.trainId

    if train and trainId and not train.valid then
        for _, superTrain in pairs(global.superTrains) do
            if superTrain.trains[trainId] then
                superTrain.trains[trainId] = nil
                superTrain.trainSpeedMulti[trainId] = nil

                global.superTrains[_] = superTrain
            end
        end
    end

end)


script.on_event(defines.events.on_entity_renamed, function (event)
    if not event then return end
    local entity = event.entity
    if entity and entity.valid and entity.type == "train-stop" and (entity.name == "traintunnel" or entity.name=="traintunnelup") then
        if not event.by_script then
            updateTunnelName(event.entity)
        end
    end
end)



local checkplayerleft = function (event)
    local player_index = event.player_index

    for _, superTrain in pairs(global.superTrains) do
        if superTrain.player_index == player_index then
            superTrain.player_index = nil
            superTrain.checkWhenStopped = true
            goto found
        end
        for i=1, #superTrain.passengers do

            if superTrain.passengers[i] == player_index then
                remove(superTrain.passengers, i)
                goto found -- can not be in more than one train at the same time
            end
        end
    end
    ::found::
end

script.on_event(defines.events.on_player_left_game, checkplayerleft)
script.on_event(defines.events.on_player_removed, checkplayerleft)



script.on_event("raillayer-toggle-editor-view", function()
    game.print("here might be a raillayer event in the future")
end)

script.on_load(function()
    for surface in pairs(global.trainTunnelsRailLookup) do
        setmetatable(global.trainTunnelsRailLookup[surface], QuadTree)
        global.trainTunnelsRailLookup[surface]:remeta()
    end
end)

remote.add_interface("trainTunnels", {
    clearTrains = function()
        global.superTrains = {}
    end,
    listTrains = function()
        game.print(inspect(global.superTrains))
    end
})

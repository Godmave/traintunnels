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
todo: fix all the cases of decoupling and hopefully remove the need to slow down trains
todo: fix transition between manual_mode and auto. move driver to previous controlLoco on auto->manual
todo: fix/replace the quadtree implementation ...
todo: mod configuration. resources on underground, diggy, max underground level
todo: editing trains that are partially in tunnels causes problems
TODO: split mod. only one underground surface, but with "raillayer" and blueprint support
--]]

global.superTrains = {}
global.trainTunnels = {}
global.trainTunnelsRailLookup = {} -- [surface] => quadtree:rail.pos => traintunnelId
global.trainTunnelsStopLookup = {} -- stopId => traintunnelId
global.trainUIs = {}

local ftCache = {}
local function ft(anchor, text, row)
    row = row or 0
    local cacheKey = anchor.unit_number .. ':' .. row

    if ftCache[cacheKey] then
        if ftCache[cacheKey] then
            rendering.set_text(ftCache[cacheKey], text)
        end
    else
        ftCache[cacheKey] = rendering.draw_text{target=anchor, text=text, surface=anchor.surface, color={r = 1, g = 0, b = 0, a = 0.5}, target_offset={0,-1 * row}}
    end

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
        return abs(carriage.orientation - to_stop.orientation) > 0.25
    else
        return entity_distance(carriage.train.front_stock, to_stop) > entity_distance(carriage.train.back_stock, to_stop)
    end
end
local function tryToDisolveSupertrain(superTrainIndex)
    local superTrain = global.superTrains[superTrainIndex]
    if superTrain == nil then
        return
    end
    local hasPlayer = (superTrain.player_index and superTrain.player_index > 0)
    local isInPieces = table_size(superTrain.trains) > 1
    local hasMomentum = (superTrain.speed ~= 0)

    if isInPieces then
        return false
    elseif not superTrain.auto then
        if hasPlayer or hasMomentum then
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
local function getSurfaceAbove(surface)
    local surfaceAbove
    if surface.name == "nauvis" then
        surfaceAbove = "nauvis" -- should cause invalid
    elseif find(surface.name, 'underground_',1,true) then
        local level = gsub(surface.name, 'underground%_', "")
        if level == 1 then
            surfaceAbove = "nauvis"
        else
            surfaceAbove = "underground_" .. (level - 1)
        end
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
local function removeTunnelUp(entity)
    local tunnelId = global.trainTunnelsStopLookup[entity.unit_number]
    removeTunnelDown(global.trainTunnels[tunnelId].from_stop)
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

local findPlayerInMovers = function(train, player_index)
    local foundInLoco
    local frontMovers = train.locomotives.front_movers

    if frontMovers then
        for _, loco in ipairs(frontMovers) do
            local driver = loco.get_driver()
            if driver and driver.player.index == player_index then
                foundInLoco = loco
                break
            end
        end
    end

    if not foundInLoco then
        local backMovers = train.locomotives.back_movers
        if backMovers then
            for _, loco in ipairs(backMovers) do
                local driver = loco.get_driver()
                if driver and driver.player.index == player_index then
                    foundInLoco = loco
                    break
                end
            end
        end
    end

    if not foundInLoco then
        if frontMovers and frontMovers[1] then
            frontMovers[1].set_driver(game.players[player_index])
        else
            -- game.print("no loco, no supertrain")
        end

        -- will get called by the set_driver event. so exit here even if there was a loco
        return -1
    end

    return foundInLoco
end


script.on_event(defines.events.on_tick, function(event)
    global.distances = global.distances or {}

    if #global.superTrains > 0 and table_size(global.trainTunnelsRailLookup) > 0 then
        for trainToObserveId, trainToObserve in pairs(global.superTrains) do

            if not trainToObserve.controlLoco then
                trainToObserve.controlLoco = trainToObserve.controlTrain.locomotives.front_movers[1]
                if trainToObserve.controlLoco.speed == nil or trainToObserve.controlLoco.speed < 0 then
                    trainToObserve.controlLoco = trainToObserve.controlTrain.locomotives.back_movers[1]
                end
            elseif trainToObserve.controlLoco.valid and trainToObserve.controlLoco.train.valid then
                trainToObserve.controlTrain = trainToObserve.controlLoco.train
                trainToObserve.controlTrainId = trainToObserve.controlLoco.train.id
            end

            if not (trainToObserve.controlLoco and trainToObserve.controlLoco.valid) then
                global.superTrains[trainToObserveId] = nil
                goto trainDone
            end

            -- debug
            --[[
            if trainToObserve.controlLoco.valid then
                for _, t in pairs(trainToObserve.trains) do
                    if trainToObserve.trains[_].valid then
                        for __, c in pairs(trainToObserve.trains[_].carriages) do
                            if c.unit_number == trainToObserve.controlLoco.unit_number then
                                c.color = {r=0,g=1,b=0}
                            else
                                c.color = {r=1,g=0,b=0}
                            end

                            ft(c, math.floor(c.speed * 1000) / 1000, 10)
                        end
                    end
                end
            end
            --]]

            if trainToObserve.controlLoco.train and trainToObserve.controlLoco.train.valid then
                if trainToObserve.auto then
                    if not trainToObserve.controlLoco.train.manual_mode then
                        if trainToObserve.arrivingTunnel then
                            trainToObserve.controlLoco.train.manual_mode = true
                            trainToObserve.controlLoco.train.speed = trainToObserve.speed
                            trainToObserve.controlLoco.train.manual_mode = false
                        end
                    else
                        trainToObserve.auto = false
                    end
                elseif trainToObserve.player_index then
                    trainToObserve.rs = game.players[trainToObserve.player_index].riding_state
                end

                trainToObserve.speed = trainToObserve.controlLoco.train.speed

                -- faster speeds are prone to mis-teleport if any part of the train is not "straight"
                local maxSpeed = 0.8
                if trainToObserve.speed > maxSpeed then
                    trainToObserve.speed = maxSpeed
                    trainToObserve.controlLoco.train.speed = trainToObserve.speed
                elseif trainToObserve.speed < -maxSpeed then
                    trainToObserve.speed = -maxSpeed
                    trainToObserve.controlLoco.train.speed = trainToObserve.speed
                end

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
                    trainToObserve.schedule = trainToObserve.controlLoco.train.schedule

                    if trainToObserve.carriagesChanged then
                        trainToObserve.carriages =  {}
                    end

                    -- expensive, but prevents most colliding subtrains from breaking the supertrain
                    -- need a better way to detect (persisting) collisions
                    for _st, subTrain in pairs(trainToObserve.trains) do
                        if subTrain.valid then
                            if abs(trainToObserve.speed) > 0.1 then
                                if abs(subTrain.speed) < (abs(trainToObserve.speed) / 2) then
                                    game.print("STOP IT!")
                                    for _, t in pairs(trainToObserve.trains) do
                                        -- t.manual_mode = true
                                        if t.speed < 0 then
                                            t.speed = -0
                                        else
                                            t.speed = 0
                                        end
                                    end
                                    goto trainDone
                                end
                            end
                        end
                    end
                    --

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

                    local carriageTeleported = false

                    for _c=1,#trainToObserve.carriages do
                        local carriage = trainToObserve.carriages[_c]
                        if carriage and carriage.valid then
                            if trainToObserve.cooldown and trainToObserve.cooldown[carriage.unit_number] then
                                trainToObserve.cooldown[carriage.unit_number] = trainToObserve.cooldown[carriage.unit_number] - 1
                                if trainToObserve.cooldown[carriage.unit_number] == 0 then
                                    trainToObserve.cooldown[carriage.unit_number] = nil
                                end
                            else
                                if carriage and carriage.valid and carriage.train.valid and trainToObserve.controlLoco.valid then
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
                                        x = cposition.x - 6,
                                        y = cposition.y - 6,
                                        w = 12,
                                        h = 12
                                    }
                                    local carriageSurface = carriage.surface.name
                                    local tunnels = global.trainTunnelsRailLookup[carriageSurface] and global.trainTunnelsRailLookup[carriageSurface]:getObjectsInRange(range) or {}
                                    local carriagetrain = carriage.train
                                    local isControl = false

                                    for _t=1,#tunnels do
                                        local tunnel = global.trainTunnels[ tunnels[_t]['tunnel']]
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
                                            local distance = entity_distance(carriage, from_stop)

                                            -- ft(carriage, math.floor(distance * 1000) / 1000, 9)

                                            -- ft(carriage, lastDistance and lastDistance or "none", 1)
                                            -- ft(carriage, distance, 2)

                                            if lastDistance ~= nil and lastDistance >= distance and distance - abs(carriage.speed) < 4 then
                                                global.distances[cacheKey] = nil

                                                isControl = trainToObserve.controlLoco.unit_number == carriage.unit_number

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
                                                trainToObserve.teleportDiff = trainToObserve.teleportDiff or {}
                                                if not (trainToObserve.teleportDiff[to_stop.unit_number] and trainToObserve.teleportDiff[to_stop.unit_number].tick > event.tick-20) then
                                                    trainToObserve.teleportDiff[to_stop.unit_number] = {diff=0.2, tick=event.tick}
                                                end


                                                local previousDistance = entity_distance(carriage, from_stop)
                                                local previousSpeed = carriage.speed

                                                local bla = distance + trainToObserve.teleportDiff[to_stop.unit_number].diff

                                                local entity = teleport.teleportCarriage(trainToObserve, _c, from_stop, to_stop, distance + trainToObserve.teleportDiff[to_stop.unit_number].diff)
                                                if entity == false then
                                                    game.print("unable to teleport")
                                                    carriage.color = {r=0, g=0, b=1}
                                                    for _, t in pairs(trainToObserve.trains) do
                                                        t.manual_mode = true
                                                        t.speed = 0
                                                    end
                                                    return
                                                    -- goto carriagedone
                                                end

                                                global.lastTeleportTick = global.lastTeleportTick or event.tick
                                                local newDistance = entity_distance(entity, to_stop)
                                                trainToObserve.teleportDiff[to_stop.unit_number] = {tick=event.tick, diff=(newDistance - distance - 0.4)}
                                                if trainToObserve.teleportDiff[to_stop.unit_number].diff < 0 then
                                                   trainToObserve.teleportDiff[to_stop.unit_number] = {diff=0, tick=event.tick}
                                                end

--                                                ft(entity, "distance after: " .. math.floor(newDistance * 1000) / 1000, 2)
--                                                ft(entity, "distance before: " .. math.floor(previousDistance * 1000) / 1000, 3)
--                                                ft(entity, "speed after: " .. math.floor(entity.speed * 1000) / 1000, 4)
--                                                ft(entity, "speed before: " .. math.floor(previousSpeed * 1000) / 1000, 5)
--                                                ft(entity, "teleport tick diff: " .. math.floor((event.tick - global.lastTeleportTick) * 1000) / 1000, 6)
--                                                ft(entity, "teleport difference: " .. math.floor(trainToObserve.teleportDiff[to_stop.unit_number].diff * 1000) / 1000, 7)
--                                                ft(entity, "teleport distance: " .. math.floor(bla * 1000) / 1000, 8)

                                                global.lastTeleportTick = event.tick

                                                trainToObserve.carriages[_c] = entity

                                                carriage = trainToObserve.carriages[_c]
                                                carriagetrain = carriage.train
                                                trainToObserve.trains[carriagetrain.id] = carriagetrain

                                                trainToObserve.cooldown = trainToObserve.cooldown or {}
                                                trainToObserve.cooldown[carriage.unit_number] = 10
                                                --

                                                if isControl then
                                                    if next(global.trainUIs) ~= nil then
                                                        for _, entityNumber in pairs(global.trainUIs) do
                                                            if  carriage_unit_number == entityNumber then
                                                                game.players[_].opened = carriage
                                                            end
                                                        end
                                                    end
                                                end

                                                if connectedCarriage then
                                                    if (pre.speed * connectedCarriage.train.speed) < 0 then
                                                        trainToObserve.trainSpeedMulti[connectedCarriage.train.id] = pre.speedMulti * -1
                                                    else
                                                        trainToObserve.trainSpeedMulti[connectedCarriage.train.id] = pre.speedMulti * 1
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
                                                    trainToObserve.controlLoco = carriage
                                                    trainToObserve.controlTrain = carriagetrain
                                                    trainToObserve.controlTrainId = carriagetrain.id

                                                    -- todo this might break in cases
                                                    if trainToObserve.driverTrainId ~= nil and trainToObserve.driverTrainId ~= carriagetrain.id then
                                                        trainToObserve.driverTrain = carriagetrain
                                                        trainToObserve.driverTrainId = carriagetrain.id
                                                    end

                                                    if trainToObserve.auto then
                                                        local schedule = trainToObserve.controlLoco.train.schedule
                                                        schedule.current = schedule.current % #schedule.records + 1
                                                        trainToObserve.controlLoco.train.schedule = schedule
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
                                else
                                    trainToObserve.carriages[_c] = nil
                                    trainToObserve.carriagesChanged = true
                                end
                            end
                        else
                            trainToObserve.carriagesChanged = true
                        end
                    end

                    if next(trainToObserve.trains) ~= nil then
                        if carriageTeleported then
                            trainToObserve.controlLoco.train.manual_mode = true

                            if trainToObserve.controlLoco.train.speed * trainToObserve.speed < 0 then
                                trainToObserve.speed = trainToObserve.controlLoco.train.speed
                                trainToObserve.trainSpeedMulti[trainToObserve.controlLoco.train.id] = 1
                            end

                            for _, t in pairs(trainToObserve.trains) do
                                if _ ~= trainToObserve.controlLoco.train.id then
                                    if (trainToObserve.trainSpeedMulti[_] * t.speed * trainToObserve.speed) < 0 then
                                        trainToObserve.trainSpeedMulti[_] = -trainToObserve.trainSpeedMulti[_]
                                    end
                                end
                            end
                        end

                        for _, t in pairs(trainToObserve.trains) do
                            --pcall(function()
                            t.speed = trainToObserve.speed * trainToObserve.trainSpeedMulti[t.id]
                            if _ ~= trainToObserve.controlLoco.train.id then
                                t.schedule = nil
                            end
                            -- end)
                        end

                        if trainToObserve.auto and trainToObserve.controlLoco.train.manual_mode then
                            trainToObserve.controlLoco.train.manual_mode = false
                        end

                        if trainToObserve.rs ~= nil and trainToObserve.player_index then
                            game.players[trainToObserve.player_index].riding_state = trainToObserve.rs
                            trainToObserve.rs = nil
                        end

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
                end
            else
                global.superTrains[trainToObserveId] = nil
            end

            ::trainDone::
        end
    end
end)

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
    if event.entity.valid and event.entity.name == "traintunnel" then
        removeTunnelDown(event.entity)
    end
    if event.entity.valid and event.entity.name == "traintunnelup" then
        removeTunnelUp(event.entity)
    end
end)

script.on_event(defines.events.on_robot_mined_entity, function(event)
    if event.entity.name == "traintunnel" then
        removeTunnelDown(event.entity)
    end
    if event.entity.name == "traintunnelup" then
        removeTunnelUp(event.entity)
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
                    local foundInLoco = findPlayerInMovers(train, event.player_index)
                    if foundInLoco == -1 then
                        -- player got moved to another loco
                        return
                    end

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
                    if train.manual_mode then
                        superTrain.controlLoco = foundInLoco
                    else
                        superTrain.auto = true
                    end
                    superTrain.trains[train.id] = train
                else
                    if not superTrain.player_index then
                        superTrain.player_index = event.player_index


                        if not superTrain.auto then
                            local foundInLoco = findPlayerInMovers(train, event.player_index)
                            if foundInLoco == -1 then
                                -- player got moved to another loco
                                return
                            end

                            superTrain.controlLoco = foundInLoco
                            superTrain.driverTrain = foundInLoco.train
                            superTrain.driverTrainId = foundInLoco.train.id

                            if superTrain.trainSpeedMulti[foundInLoco.train.id] and superTrain.trainSpeedMulti[foundInLoco.train.id] < 0 then
                                for _, t in pairs(superTrain.trains) do
                                    superTrain.trainSpeedMulti[_] = -superTrain.trainSpeedMulti[_]
                                end
                            end
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
                    superTrain.player_index = nil
                    if not superTrain.auto then
                        tryToDisolveSupertrain(_)
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
        local schedule = train.schedule
        local currentRecord = schedule.records[train.schedule.current]
        local entryStation = currentRecord.station
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

            superTrain.controlLoco = nil

            superTrain.arrivingTunnel = true

            if currentRecord.wait_conditions and currentRecord.wait_conditions[1] and currentRecord.wait_conditions[1].type ~= "circuit" then
                currentRecord.wait_conditions[1] = {
                    type = "circuit",
                    compare_type = "and",
                    condition = {
                        comparator = "=",
                        first_signal = {type="virtual", name="signal-T"},
                        second_signal = {type="virtual", name="signal-T"}
                    }
                }
                train.schedule = schedule
            end
        else
            if superTrain ~= nil then
                superTrain.arrivingTunnel = false
            end
        end
    elseif trainState == defines.train_state.wait_station then
        -- Waiting at a station.
    elseif trainState == defines.train_state.manual_control_stop or trainState == defines.train_state.manual_control then
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
                if superTrainIndex and isDisolvable then global.superTrains[superTrainIndex] = nil end
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
            superTrain.carriagesChanged = true

            if superTrain.trainSpeedMulti[event.old_train_id_1] ~= nil then
                superTrain.trainSpeedMulti[event.train.id] = superTrain.trainSpeedMulti[event.old_train_id_1]
                superTrain.trainSpeedMulti[event.old_train_id_1] = nil
            end

        end
        if event.old_train_id_2 ~= nil and superTrain.trains[event.old_train_id_2] ~= nil then
            superTrain.trains[event.old_train_id_2] = nil
            superTrain.trains[event.train.id] = event.train
            superTrain.carriagesChanged = true

            if superTrain.trainSpeedMulti[event.old_train_id_2] ~= nil then
                superTrain.trainSpeedMulti[event.train.id] = superTrain.trainSpeedMulti[event.old_train_id_2]
                superTrain.trainSpeedMulti[event.old_train_id_2] = nil
            end
        end

        if event.old_train_id_1 == superTrain.controlTrainId or event.old_train_id_2 == superTrain.controlTrainId then
            superTrain.controlTrain = event.train
            superTrain.controlTrainId = event.train.id
        end
        if superTrain.driverTrainId ~= nil and (event.old_train_id_1 == superTrain.driverTrainId or event.old_train_id_2 == superTrain.driverTrainId) then
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
script.on_event(defines.events.on_player_left_game, checkplayerleft)
script.on_event(defines.events.on_player_removed, checkplayerleft)
script.on_event(defines.events.on_gui_opened, function(event)
    local entity = event.entity
    if not entity or (entity.type ~= "locomotive" and entity.type ~= "cargo-wagon" and entity.type ~= "fluid-wagon" and entity.type ~= "artillery-wagon") then
        return
    end

    local player_index = event.player_index

    global.trainUIs = global.trainUIs or {}
    global.trainUIs[player_index] = entity.unit_number
end)
script.on_event(defines.events.on_gui_closed, function (event)
    local entity = event.entity
    if not entity or (entity.type ~= "locomotive" and entity.type ~= "cargo-wagon" and entity.type ~= "fluid-wagon" and entity.type ~= "artillery-wagon") then
        return
    end

    local player_index = event.player_index
    if global.trainUIs and global.trainUIs[player_index] then
        global.trainUIs[player_index] = nil
    end
end)
script.on_event("raillayer-toggle-editor-view", function()
    game.print("here might be a raillayer event in the future")
end)
script.on_load(function()
    for surface in pairs(global.trainTunnelsRailLookup) do
        setmetatable(global.trainTunnelsRailLookup[surface], QuadTree)
        global.trainTunnelsRailLookup[surface]:remeta()
    end
end)


-- debug stuff
remote.add_interface("trainTunnels", {
    clearTrains = function()
        global.superTrains = {}
    end,
    listTrains = function()
        game.print(serpent.line(global.superTrains))
    end,
    listTunnels = function()
        for _, t in pairs(global.trainTunnels) do
            game.print(_)
        end
    end,
    quad = function()
        log(inspect(global.trainTunnelsRailLookup))
    end,
    requad = function()
        global.trainTunnelsRailLookup = {}
        for _, t in pairs(global.trainTunnels) do
            addTunnel(t)
        end
    end
})

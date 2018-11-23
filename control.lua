require("mod-gui")
local teleport = require("teleport")

--[[
reminder:
- store tunnels by chunks, so a faster lookup and exclusion of non-hits can be carriagedone
- take auto-trains of the superTrains when they are in one peace and not approaching a station
- fix switch from manual supertrains to automatic. atm it behaves automatic but is not
- teleport passengers and drivers to the controltrain, so they can't hijack subtrains in manual_mode
--]]

global.superTrains = {}


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
    return math.sqrt(math.pow(math.abs(a.position.x - b.position.x), 2) + math.pow(math.abs(a.position.y - b.position.y),2))
end

local function train_frontfartheraway(carriage, to_stop)
    if #carriage.train.carriages == 1 then
        if carriage.type == "locomotive" then
            return math.abs(carriage.orientation - to_stop.orientation) > 0.25
        else
            return math.abs(carriage.orientation - to_stop.orientation) > 0.25
        end
    else
        return entity_distance(carriage.train.front_stock, to_stop) > entity_distance(carriage.train.back_stock, to_stop)
    end
end


-- todo: make this work and use it on supertrains with tryToDisolveSupertrain==true
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
            game.print("supertrain stopped in one piece in manual, disolving")
            global.superTrains[superTrainIndex] = nil
        end
    else
        -- no known case if this
        game.print("supertrain stopped in one piece in manual, disolving")
        global.superTrains[superTrainIndex] = nil
    end

    return true
end


script.on_event(defines.events.on_tick, function(event)
    local lastTrainId = 0

    global.superTrains = global.superTrains or {}
    global.distances = global.distances or {}

    if #global.superTrains > 0 then
        local gui
        local guitable

        for _, trainToObserve in pairs(global.superTrains) do
            if trainToObserve.controlTrain and trainToObserve.controlTrain.valid then
                trainToObserve.schedule = trainToObserve.controlTrain.schedule
                if trainToObserve.auto then
                    if not trainToObserve.controlTrain.manual_mode then
                        if trainToObserve.controlTrain.state == defines.train_state.arrive_station then
                            trainToObserve.controlTrain.manual_mode = true
                            trainToObserve.controlTrain.speed = trainToObserve.speed
                            trainToObserve.controlTrain.manual_mode = false
                        end
                    else
                        trainToObserve.auto = false
                    end

                    -- [[
                    if global.gui and global.gui[1] then
                        gui = global.gui[1].gui
                        gui.clear()

                        guitable = gui.add{type="table", column_count=2}
                        guitable.add{type="label", caption="AUTO"}
                        guitable.add{type="label", caption=trainToObserve.controlTrain.id}
                    end
                    --]]
                end

                trainToObserve.speed = trainToObserve.controlTrain.speed
                if trainToObserve.speed == 0 then
                    if not (trainToObserve.checkWhenStopped and tryToDisolveSupertrain(_)) then
                        for _st, subTrain in pairs(trainToObserve.trains) do
                            if subTrain.valid then
                                subTrain.speed = 0
                            end
                        end

                    end
                    goto traindone
                end

                -- [[
                if trainToObserve.player_index and global.gui[trainToObserve.player_index] and not trainToObserve.auto then
                    gui = global.gui[trainToObserve.player_index].gui
                    gui.clear()

                    guitable = gui.add{type="table", column_count=2}

                    guitable.add{type="label", caption="Player-Index"}
                    guitable.add{type="label", caption=trainToObserve.player_index}
                    guitable.add{type="label", caption="Number of Subtrains"}
                    guitable.add{type="label", caption=table_size(trainToObserve.trains)}
                end
                --]]

                trainToObserve.carriages =  {}
                -- trainToObserve.trainSpeedMulti = trainToObserve.trainSpeedMulti or {}

                for _st, subTrain in pairs(trainToObserve.trains) do
                    if subTrain.valid then
                        table.insert(trainToObserve.carriages, subTrain.front_stock)
                        if subTrain.front_stock.unit_number ~= subTrain.back_stock.unit_number then
                            table.insert(trainToObserve.carriages, subTrain.back_stock)
                        end
                    end
                end

                if not trainToObserve.auto then
                    trainToObserve.riding_state = trainToObserve.controlTrain.riding_state
                    for _c, carriage in pairs(trainToObserve.carriages) do
                        if carriage.valid then
                            if carriage.get_driver() then
                                trainToObserve.rs = carriage.train.riding_state
                            end
                        end
                    end
                end

                local trainSpeedSet = {}

                for _c, carriage in pairs(trainToObserve.carriages) do
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

                        for _, tunnel in pairs(global.tunnels) do
                            for _, railPair in pairs(tunnel.railPairs) do
                                local from_rail, to_rail, from_stop, to_stop


                                if carriage.surface.name ~= "tunnelsurface" then
                                    from_rail = railPair[1]
                                    to_rail = railPair[2]
                                    from_stop = tunnel.stopPairs[_][1]
                                    to_stop = tunnel.stopPairs[_][2]
                                else
                                    from_rail = railPair[2]
                                    to_rail = railPair[1]
                                    from_stop = tunnel.stopPairs[_][2]
                                    to_stop = tunnel.stopPairs[_][1]
                                end

                                local cacheKey = carriage.unit_number..':'..from_rail.unit_number
                                local lastDistance = global.distances[cacheKey]
                                local distance = entity_distance(carriage, from_rail)

                                if (compare_rail.position.x == from_rail.position.x or compare_rail.position.y == from_rail.position.y) and lastDistance ~= nil and lastDistance > distance and distance < (trainToObserve.auto and 4 or 3+math.abs(trainToObserve.speed)) then
                                    global.distances[cacheKey] = nil
                                    local isControl = ((trainToObserve.auto or not trainToObserve.player_index) and carriage.train == trainToObserve.controlTrain) or (not trainToObserve.auto and carriage.get_driver())

                                    local connectedCarriage
                                    if #carriage.train.carriages > 1 then
                                        for _, c in pairs(carriage.train.carriages) do
                                            if c.unit_number == carriage.unit_number then
                                                if _ == 1 then
                                                    connectedCarriage = carriage.train.carriages[_+1]
                                                else
                                                    connectedCarriage = carriage.train.carriages[_-1]
                                                end
                                            end
                                        end
                                    end

                                    local pre = {
                                         speedMulti = trainToObserve.trainSpeedMulti[carriage.train.id],
                                         speed = carriage.train.speed,
                                         frontFartherAwayThanBack = train_frontfartheraway(carriage, from_stop)
                                    }



                                    -- TELEPORT
                                    if not teleport.teleportCarriage(trainToObserve, _c, from_stop, to_stop) then
                                        game.print("unable to teleport")
                                        goto carriagedone
                                    end
                                    carriage = trainToObserve.carriages[_c]
                                    trainToObserve.trains[carriage.train.id] = carriage.train
                                    --

                                    if connectedCarriage and (pre.speed * connectedCarriage.train.speed) < 0 then
                                        trainToObserve.trainSpeedMulti[connectedCarriage.train.id] = pre.speedMulti * -1
                                    elseif connectedCarriage then
                                        trainToObserve.trainSpeedMulti[connectedCarriage.train.id] = pre.speedMulti
                                    end


                                    if train_frontfartheraway(carriage, to_stop) == pre.frontFartherAwayThanBack then
                                        trainToObserve.trainSpeedMulti[carriage.train.id] = pre.speedMulti * -1
                                    else
                                        trainToObserve.trainSpeedMulti[carriage.train.id] = pre.speedMulti
                                    end

                                    if #carriage.train.carriages == 1 then
                                        carriage.train.speed = pre.speed * trainToObserve.trainSpeedMulti[carriage.train.id]
                                    end



                                    if isControl then
                                        -- game.print("incontrol clause")

                                        if trainToObserve.controlTrainId ~= carriage.train.id then
                                            -- this should not happen, but does in auto
                                            -- game.print("wrong control train id")
                                            trainToObserve.controlTrain = carriage.train
                                            trainToObserve.controlTrainId = carriage.train.id
                                        end

                                        if trainToObserve.auto then
                                            local schedule = trainToObserve.controlTrain.schedule
                                            schedule.current = schedule.current % #schedule.records + 1
                                            trainToObserve.controlTrain.schedule = schedule

                                            trainToObserve.controlTrain.manual_mode = false
                                        end


                                        if carriage.train.speed ~= 0 then
                                            trainToObserve.speed = carriage.train.speed
                                        end

                                        if trainToObserve.trainSpeedMulti[carriage.train.id] ~= 1 then
                                            trainToObserve.speed = carriage.train.speed
                                            for ___ in pairs(trainToObserve.trainSpeedMulti) do
                                                    trainToObserve.trainSpeedMulti[___] = -trainToObserve.trainSpeedMulti[___]
                                            end
                                        end
                                    elseif table_size(trainToObserve.trainSpeedMulti) == 1 then
                                        trainToObserve.trainSpeedMulti[carriage.train.id] = 1
                                        trainToObserve.speed = carriage.train.speed
                                    end

                                    carriageTeleported = true
                                    goto carriagedone
                                end

                                global.distances[cacheKey] = distance
                            end
                        end

                        ::carriagedone::

                        local carriageTrainId = carriage.train.id

                        if not trainSpeedSet[carriageTrainId] and carriage.valid and carriage.train.valid then
                            if carriageTrainId ~= trainToObserve.controlTrainId then
                                carriage.train.speed = trainToObserve.speed * trainToObserve.trainSpeedMulti[carriageTrainId] * trainToObserve.trainSpeedMulti[trainToObserve.controlTrainId]
                            elseif carriageTeleported then
                                if trainToObserve.auto == false
                                or (
                                        trainToObserve.controlTrain.state ~= defines.train_state.arrive_signal
                                        and  trainToObserve.controlTrain.state ~= defines.train_state.wait_signal
                                        and  trainToObserve.controlTrain.state ~= defines.train_state.no_path
                                        and  trainToObserve.controlTrain.state ~= defines.train_state.no_schedule
                                        and  trainToObserve.controlTrain.state ~= defines.train_state.path_lost
                                ) then
                                    if carriage.train.speed < 0 then
                                        carriage.train.speed = math.abs(previousSpeed) * -1
                                    else
                                        carriage.train.speed = math.abs(previousSpeed)
                                    end
                                end

                                if trainToObserve.auto then
                                    trainToObserve.controlTrain.manual_mode = false
                                end
                            end

                            trainSpeedSet[carriageTrainId] = true
                        end

                        --ft(carriage, "control-speed: " .. trainToObserve.speed)
                        --ft(carriage, "set speed: " .. carriage.speed, 2)
                        --ft(carriage, carriage == carriage.train.front_stock and "front" or "back", 3)
                        --ft(carriage, carriage.orientation, 4)

                        -- [[
                        if gui and gui.valid and guitable and guitable.valid and carriage.valid and lastTrainId ~= carriage.train.id then
                            lastTrainId = carriage.train.id

                            guitable.add{type="label", caption="Train-Id"}
                            guitable.add{type="label", caption=carriage.train.id}

                            guitable.add{type="label", caption="Is control"}
                            guitable.add{type="label", caption=carriage.train.id == trainToObserve.controlTrainId}

                            guitable.add{type="label", caption="Stock-Orientation"}
                            guitable.add{type="label", caption=carriage.train.front_stock.orientation}
                            guitable.add{type="label", caption="Rail-Orientation"}
                            guitable.add{type="label", caption=carriage.train.front_rail.orientation}

                            guitable.add{type="label", caption="Train-Speed"}
                            guitable.add{type="label", caption=carriage.train.speed}

                            guitable.add{type="label", caption="Speed-Multi"}
                            guitable.add{type="label", caption=trainToObserve.trainSpeedMulti[carriage.train.id]}

                            guitable.add{type="label", caption="#Carriages"}
                            guitable.add{type="label", caption=#carriage.train.carriages}
                        end
                        --]]
                    else
                        trainToObserve.carriages[_c] = nil
                    end
                end




                if trainToObserve.rs ~= nil and trainToObserve.player_index then
                    game.players[trainToObserve.player_index].riding_state = trainToObserve.rs
                    trainToObserve.rs = nil
                end

            end

            ::traindone::

            if trainToObserve.auto or trainToObserve.player_index then
                local idle_riding_state = {
                    acceleration = defines.riding.acceleration.nothing,
                    direction = defines.riding.direction.straight
                }
                for _st, subTrain in pairs(trainToObserve.trains) do
                    if subTrain.valid and (trainToObserve.auto or trainToObserve.player_index) then
                        for _c, c in pairs(subTrain.carriages) do
                            local driver = c.get_driver()
                            if driver and (trainToObserve.auto or driver.player.index ~= trainToObserve.player_index) then
                                driver.riding_state = idle_riding_state
                            end
                        end

                    end
                end
            end
        end
    end
end)

local function debugGUI(player_index, showIt)
    if global.gui == nil then
        global.gui = {}
    end

    -- showIt = false

    if global.gui[player_index] then
        global.gui[player_index].gui.destroy()
        global.gui[player_index] = nil

        if showIt == false then
            return
        end
    end

    if showIt == false then return end

    local player = game.players[player_index]

    global.gui[player_index] = {}
    global.gui[player_index].gui = player.gui.left.add{type = 'frame', name = 'traintunnel-debug-gui', direction = 'vertical', caption = 'Traintunnel-Debug'}
end




local lowerTunnelStructures = {
    [1] = {-4, 4,"traintunnelup"},
    [2] = {-2,-8,"straight-rail"},
    [3] = {-2,-6,"straight-rail"},
    [4] = {-2,-4,"straight-rail"},
    [5] = {-2,-2,"straight-rail"},
    [6] = {-2, 0,"straight-rail"},
    [7] = {-2, 2,"straight-rail"},
    [8] = {-2, 4,"straight-rail", true},
    [9] = {-2, 6,"straight-rail"}
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
    game.print("tunnel removal")

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

    for _, structure in ipairs(upperTunnelStructures) do
        if structure[3] ~= "straight-rail" then
            local ox, oy = structure[1], structure[2]
            ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

            local e = game.surfaces[s].find_entity(structure[3], {x = p.x+ox, y = p.y+oy})
            if e and e.valid then
                e.destroy()
            end

        end
    end
    for _, structure in ipairs(lowerTunnelStructures) do
        if structure[3] ~= "straight-rail" then
            local ox, oy = structure[1], structure[2]
            ox, oy = rotation[1] * ox + rotation[2] * oy, rotation[3] * ox + rotation[4] * oy

            local e = game.surfaces['tunnelsurface'].find_entity(structure[3], {x = p.x+ox, y = p.y+oy})
            if e and e.valid then
                e.destroy()
            end
        end
    end
end
local function findOrPlaceEntity(surface, entityDefinition)
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
    game.print("tunnel creation")

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


    -- todo: determine which surface is 1 down and make sure it exists. then put it into to_surface

    local tunnel = {
        from_surface = entity.surface,
        from_stop = 0,
        from_rail = 0,
        to_surface = 0,
        to_stop = 0,
        to_rail = 0,
    }

    tunnel.to_surface = game.surfaces['tunnelsurface']

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

        lastCreated = findOrPlaceEntity(game.surfaces[s], tobeCreated)

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
        lastCreated = findOrPlaceEntity(game.surfaces['tunnelsurface'], tobeCreated)

        if lastCreated and structure[3] == "traintunnelup" then
            tunnel.to_stop = lastCreated
        end
        if lastCreated and structure[4] == true then
            tunnel.to_rail = lastCreated
        end
    end

    game.print(serpent.line(tunnel))

    local valid = true
    for _ in pairs(tunnel) do
        if tunnel[_] == 0 then
            valid = false;
            break
        end
    end

    if not valid then
        game.print("invalid")
        removeTunnelDown(entity)
        game.players[player_index].insert{name = "traintunnel", count=1}
    else

        -- todo: add tunnel to data structure with lookups and stuff
        global.traintunnels = global.traintunnels or {}

    end
end



script.on_event(defines.events.on_built_entity, function(event)
    if event.created_entity.name == "traintunnel" then
        createTunnelDown(event.created_entity, event.player_index)
    end
end)

script.on_event(defines.events.on_player_mined_entity, function(event)
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
                    -- game.print("new supertrain: " .. train.id)
                    superTrain = {
                        player_index = event.player_index,
                        controlTrain = train,
                        controlTrainId = train.id,
                        driverTrain = train,
                        driverTrainId = train.id,
                        trains = {},
                        trainSpeedMulti = {}
                    }
                    superTrain.trains[train.id] = train
                else
                    superTrain.player_index = event.player_index

                    superTrain.driverTrain = train
                    superTrain.driverTrainId = train.id


                    if not superTrain.auto then
                        superTrain.controlTrain = train
                        superTrain.controlTrainId = train.id
                    end
                end
                table.insert(global.superTrains, superTrain)

                debugGUI(event.player_index, true)
            end

        else
            for _, superTrain in ipairs(global.superTrains) do
                if superTrain.player_index == event.player_index then
                    if table_size(superTrain.trains) == 1 and not superTrain.auto then
                        -- supertrain consists of only one train, resolve
                        if superTrain.speed == 0 then
                            global.superTrains[_] = nil
                        else
                            global.superTrains[_].checkWhenStopped = true
                            global.superTrains[_].player_index = nil
                        end
                    else
                        -- supertrain is split into parts
                        global.superTrains[_].player_index = nil
                    end
                    debugGUI(event.player_index, false)
                    break
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
        if string.find(entryStation, '<T',1, true) then
            if superTrain == nil then
                -- game.print("new auto supertrain created")
                superTrain = {
                    auto = true,
                    controlTrain = train,
                    controlTrainId = train.id,
                    speed = train.speed,
                    trains = {},
                    trainSpeedMulti = {}
                }
                superTrain.trains[train.id] = train
            else
                superTrain.auto = true
            end
            debugGUI(1, true)
        end
    elseif trainState == defines.train_state.wait_station then
        -- Waiting at a station.
    elseif trainState == defines.train_state.manual_control_stop or trainState == trainState == defines.train_state.manual_control then
        -- Switched to manual control and has to stop.
        -- Can move if user explicitly sits in and rides the train.

        if superTrain then
            if hasPlayer then
                if superTrain.controlTrainId ~= superTrain.driverTrainId then
                    superTrain.controlTrain = superTrain.driverTrain
                    superTrain.controlTrainId = superTrain.driverTrainId
                end

                -- game.print("supertrain handed over to player")
                superTrain.auto = false
            elseif hasMomentum then
                -- game.print("todo: try to resolve when stopped")
                superTrain.checkWhenStopped = true
            else
                -- game.print("manual train resolved")
                return
            end
        end
    end

    if superTrain then
        if superTrainIndex then
            global.superTrains[superTrainIndex] = superTrain
        else
            table.insert(global.superTrains, superTrain)
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




remote.add_interface("trainTunnels", {
    newTunnel = function()
        global.tunnels = global.tunnels or {}
        local tunnel = {
            railPairs = {},
            stopPairs = {}
        }
        table.insert(global.tunnels, tunnel)

        return #global.tunnels
    end,
    clearTunnels = function()
        global.tunnels = {}
    end,
    removeTunnel = function(tunnelId)
        global.tunnels[tunnelId] = nil
    end,
    setSurfaceRail = function(tunnelId, index, railEntity)
        local tunnel = global.tunnels[tonumber(tunnelId)]
        tunnel.railPairs[index] = {railEntity}
        global.tunnels[tonumber(tunnelId)] = tunnel
    end,
    setSurfaceStop = function(tunnelId, index, stopEntity)
        global.tunnels[tonumber(tunnelId)].stopPairs[index] = {stopEntity}
    end,
    setTunnelRail = function(tunnelId, index, railEntity)
        global.tunnels[tonumber(tunnelId)].railPairs[index][2] = railEntity
    end,
    setTunnelStop = function(tunnelId, index, stopEntity)
        global.tunnels[tonumber(tunnelId)].stopPairs[index][2] = stopEntity
    end,

    debugTunnel = function(tunnelId)
        if tunnelId == nil then
            game.print(serpent.line(global.tunnels))
        else
            local tunnel =global.tunnels[tonumber(tunnelId)]
            game.print("Surface-Rail: " .. tunnel.railPairs[1][1].position.x .. ":" .. tunnel.railPairs[1][1].position.y)
            game.print("Tunnel-Rail: " .. tunnel.railPairs[1][2].position.x .. ":" .. tunnel.railPairs[1][2].position.y)
        end
    end
})

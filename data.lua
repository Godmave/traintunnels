require "util"

local empty_sprite =
{
    filename = "__core__/graphics/empty.png",
    width = 1,
    height = 1,
    frame_count = 1
}

--add collision mask to curved rails
local defaultRailMask = {"object-layer", "item-layer", "floor-layer", "water-tile"}
for railName,_ in pairs(data.raw["curved-rail"]) do
    if not data.raw["curved-rail"][railName].collision_mask then
        data.raw["curved-rail"][railName].collision_mask = defaultRailMask
    end
    table.insert(data.raw["curved-rail"][railName].collision_mask, "layer-13")
end





local traintunnel = util.table.deepcopy(data.raw['train-stop']["train-stop"])
traintunnel.name = "traintunnel"
traintunnel.minable.result = "traintunnel"
traintunnel.localised_name = {"item-name.traintunnel"}
traintunnel.localised_description = {"item-description.traintunnel"}

traintunnel.selection_box = {{-4, -6}, {0, 6}}
traintunnel.collision_box = {{-4, -6}, {0, 6}}
traintunnel.collision_mask = {"layer-13", "player-layer"}

traintunnel.light1 = nil
traintunnel.light2 = nil
traintunnel.rail_overlay_animations = nil

traintunnel.max_health = 10000

-- [[
traintunnel.animations  = {
    east = {
        layers = {
            {
                filename = "__traintunnels__/graphics/placeholders/E.png",
                frame_count = 1,
                height = 256,
                line_length = 1,
                priority = "high",
                scale = 0.9,
                shift = {1,-3},
                width = 512,
            }
        }
    },
    north = empty_sprite,
    south = {
        layers = {
            {
                filename = "__traintunnels__/graphics/placeholders/S.png",
                frame_count = 1,
                y = 412,
                height = 100,
                hr_version = nil,
                line_length = 1,
                priority = "high",
                scale = 1,
                shift = {3,6},
                width = 256
            }
        }
    },
    west = {layers = {{
        filename = "__traintunnels__/graphics/placeholders/W.png",
        frame_count = 1,
        height = 83,
        hr_version = nil,
        line_length = 1,
        priority = "high",
        scale = 0.9,
        shift = {1,3.49},
        width = 512,
        y = 173
    }}}
}
traintunnel.top_animations = {
    east = empty_sprite,
    north = {
        layers = {
            {
                filename = "__traintunnels__/graphics/placeholders/N.png",
                frame_count = 1,
                height = 512,
                hr_version =nil,
                line_length = 1,
                priority = "high",
                scale = 1,
                shift = {-1,0},
                width = 256
            }
        }
    },
    south = {
        layers = {
            {
                filename = "__traintunnels__/graphics/placeholders/S.png",
                frame_count = 1,
                height = 412,
                hr_version = nil,
                line_length = 1,
                priority = "high",
                scale = 1,
                shift = {3,-2},
                width = 256
            }
        }
    },
    west = {layers = {{
        filename = "__traintunnels__/graphics/placeholders/W.png",
        frame_count = 1,
        height = 173,
        hr_version = nil,
        line_length = 1,
        priority = "high",
        scale = 0.9,
        shift = {1,0},
        width = 512,
    }}}
}
-- ]]

local traintunnelup = util.table.deepcopy(traintunnel)
traintunnelup.name = "traintunnelup"
traintunnelup.minable.result = "traintunnel"
traintunnelup.localised_name = {"item-name.traintunnelup"}
traintunnelup.localised_description = {"item-description.traintunnelup"}



-- [[
data:extend {
    {
        type = "custom-input",
        name = "raillayer-toggle-editor-view",
        key_sequence = "CONTROL + R",
    },
    {
        type = "custom-input",
        name = "trainteleport-entertunnel",
        key_sequence = "RETURN",
    }
}
--]]

data:extend {
    traintunnel,
    traintunnelup,
    {
        type = "recipe",
        name = "traintunnel",
        enabled = true,
        ingredients = {
            { "steel-plate", 200 },
            { "concrete", 200 },
            { "small-lamp", 10 },
        },
        energy_required = 30,
        result = "traintunnel",
        requester_paste_multiplier = 1
    },
    {
        type = "recipe",
        name = "traintunneldown",
        enabled = true,
        ingredients = {
            { "traintunnelup", 1 }
        },
        energy_required = 5,
        result = "traintunnel",
        requester_paste_multiplier = 1
    },
    {
        type = "recipe",
        name = "traintunnelup",
        enabled = true,
        ingredients = {
            { "traintunnel", 1 }
        },
        energy_required = 5,
        result = "traintunnelup",
        requester_paste_multiplier = 1
    },
    {
        type = "item",
        name = "traintunnel",
        icon = "__base__/graphics/icons/train-stop.png",
        icon_size = 32,
        flags = {},
        subgroup = "transport",
        order = "a[train-system]-c[traintunnel]",
        place_result = "traintunnel",
        stack_size = 1
    },
    {
        type = "item",
        name = "traintunnelup",
        icon = "__base__/graphics/icons/train-stop.png",
        icon_size = 32,
        flags = {},
        subgroup = "transport",
        order = "a[train-system]-c[traintunnelup]",
        place_result = "traintunnelup",
        stack_size = 1
    }
}

data.raw['tile']['landfill']["autoplace"] = {}

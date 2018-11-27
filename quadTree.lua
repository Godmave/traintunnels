MAX_OBJECTS_PER_QUAD = 4

QuadTree = {
    name = "QuadTree",
    __index = QuadTree
}

local insert = table.insert
local floor = math.floor

function QuadTree:new(_left, _top, _width, _height)
    _left = _left or -1048575
    _top = _top or -1048575
    _width = _width or 2*1048575
    _height = _height or 2*1048575

    local options = {
        x   = _left,
        y    = _top,
        w  = _width,
        h = _height,
        children = nil,
        count = 0,
        objects = {}
    }

    setmetatable(options, self)
    self.__index = self

    return options
end

function QuadTree:subdivide()
    local x = self.x
    local y = self.y
    local w = floor(self.w / 2)
    local h = floor(self.h / 2)

    self.children = {
        ["NW"] = QuadTree:new(x    , y    , w, h),
        ["NE"] = QuadTree:new(x + w, y    , w, h),
        ["SE"] = QuadTree:new(x    , y + h, w, h),
        ["SW"] = QuadTree:new(x + w, y + h, w, h)
    }

    for _, o in pairs(self.objects) do
        for c in pairs(self.children) do
            self.children[c]:addObject(o)
        end
    end

    self.objects = {}
    self.count = 0
end

function QuadTree:check(object, func, x, y)
    local oleft   = x or object.x
    local otop    = y or object.y
    local oright  = object.w and (oleft + object.w - 1) or oleft
    local obottom = object.h and (otop + object.h - 1) or otop

    local left   = self.x
    local top    = self.y
    local right  = left + self.w - 1
    local bottom = top  + self.h - 1

    if oright < left or obottom < top or oleft > right or otop > bottom then
        return false
    else
        if not self.children then
            func(self)
        else
            for c in pairs(self.children) do
                self.children[c]:check(object, func, x, y)
            end
        end
    end
end

function QuadTree:addObject(object)
    local function add(tree)
        if tree.count == MAX_OBJECTS_PER_QUAD then
            tree:subdivide()
        end

        if tree.children then
            for i,child in pairs(tree.children) do
                child:addObject(object)
            end
        else
            insert(tree.objects, object)
            tree.count = tree.count + 1
        end
    end


    self:check(object, add)
end

function QuadTree:removeObject(object)
    local function remove(tree)
        for _, o in pairs(tree.objects) do
            if o['x'] == object['x'] and o['y'] == object['y'] then
                tree.objects[_] = nil
                tree.count = self.count - 1
                break
            end
        end
    end

    self:check(object, remove)
end

function QuadTree:getObjectsInRange(range)
    local near = {}
    if not self.children then
        for i,o in pairs(self.objects) do
            if o.x >= range.x and o.x <= range.x+range.w and o.y >= range.y and o.y <= range.y+range.h then
                near[#near+1] =  o
            end
        end
    else
        local quads = {}
        local function add (child) insert(quads, child) end
        self:check(range, add)

        for _,q in pairs(quads) do
            for i,o in pairs(q.objects) do
                if o.x >= range.x and o.x <= range.x+range.w and o.y >= range.y and o.y <= range.y+range.h then
                    near[#near+1] =  o
                end
            end
        end
    end

    return near
end

function QuadTree:remeta()
    if self.children then
        for _, sq in pairs(self.children) do
            setmetatable(self.children[_], QuadTree)
            self.children[_]:remeta()
        end
    end
end

QuadTree:new()
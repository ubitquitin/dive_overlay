-- Create and track a pool of ShapeInstances
--
-- I was experiencing HUGE performance hiccups after creating and destroying
-- thousands of ShapeInstances while running around the world and new() ing
-- whenever a new tile entered the radius, whenever I turned off the plugin.
-- It seemed like the plugin API was not GCing as it went. Since we have a rough
-- upper bound of the number of tiles we would ever render (21x21 or 441-ish),
-- reusing the same ShapeInstance from a pool seemed to alleviate the issues

local M = {}

local Pool = {}
Pool.__index = Pool

-- Creates an empty pool whose instances can be shared/reused
function M.new(prefix)
    return setmetatable({
        -- a string prefix to include on the ShapeInstance names
        -- Ie, arrow:125, tile:72
        prefix = prefix,
        -- auto-incrementing ID / how many tiles are in the pool, simply so we
        -- can give each tile a unique name
        count = 0,
        -- a list of tiles we are safe to re-use
        free = {}
    }, Pool)
end

-- Takes a hidden instance from the pool, or creates a new one.
-- Returns nil if the client refuses to create one.
function Pool:take()
    -- if a free tile is available, use it
    local free = self.free
    while #free > 0 do
        local instance = table.remove(free)
        if instance.isValid then return instance end
    end

    -- create a new ShapeInstance if we had none lying around
    self.count = self.count + 1
    local name = self.prefix .. self.count
    local instance = ShapeList.CreateInstance(name) or ShapeList.GetInstance(name)
    if not instance then return nil end

    -- set a few sane defaults on our newly created shape
    instance.ignoreDepth = true
    instance.lineWidth = 3
    instance.visible = false
    return instance
end

-- Hides an instance and returns it to the pool. Invalid instances are dropped.
function Pool:release(instance)
    if instance and instance.isValid then
        instance.visible = false
        self.free[#self.free + 1] = instance
    end
end

return M

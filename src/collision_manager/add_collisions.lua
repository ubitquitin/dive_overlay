-- Add collision inferred from visible Locs and documented exceptions.
-- Shape heuristics are experimental: do not silently broaden them.
local M = {}
local CENTER = 1
local specialCases = require("src/collision_manager/special_cases")
local function key(a,b,c) return string.format('%d_%d_%d',a,b,c) end

-- door rotation mapping
local WALL_BY_ROTATION = {
    [0] = 2,  -- West
    [1] = 4,  -- North
    [2] = 8,  -- East
    [3] = 16  -- South
}

local LWALL_BY_ROTATION = {
    [0] = 2 | 4,   -- West + North = 6
    [1] = 4 | 8,   -- North + East = 12
    [2] = 8 | 16,  -- East + South = 24
    [3] = 16 | 2   -- South + West = 18
}
local CARDINAL = 2 | 4 | 8 | 16

-- Return only the collision a *visible* dynamic Loc contributes.
-- For shapes 1/3 and decorative/roof shapes we deliberately add nothing.
function M.addedCollisionMask(loc)
    -- If the location is hidden or it does not block walks then dont add collision mask
    if loc.hidden ~= false or (loc.block ~= 1 and loc.block ~= 2) then
        return 0
    end
    local shape = loc.shape
    -- If the location is 0 (door) then return the mapped block direction (not central blocking)
    if shape == 0 then
        if loc.rotation == nil then return 0 end
        return WALL_BY_ROTATION[loc.rotation % 4] or 0
    -- If the location is 2 (L-shape) then return the mapped block direction
    elseif shape == 2 then
        if loc.rotation == nil then return 0 end
        return WALL_BY_ROTATION[loc.rotation % 4] or 0
    -- For ground decoration, enforce that blockWalk = 1
    elseif (shape == 22 and loc.block == 1) then
        return CENTER

    -- Otherwise return central blocking for the respective remaining shapes
    elseif shape == 9 or shape == 10 or shape == 11 then
        return CENTER
    end

    return 0
end


-- Apply dynamic directional edges after stale static flags are cleared.
-- Updates the static collision mask with our computed dynamic mask
function M.addVisibleWallEdges(locs, effectiveByTile)
    for _,loc in ipairs(locs) do
        -- apply the shape based collision mask update
        local mask = M.addedCollisionMask(loc)
        -- update the final collision mapping if the collision is nonzero
        -- effectiveByTile updates the object passed in from the collisionManager.
        if (mask & CARDINAL) ~= 0 then
            local k = key(loc.x, loc.z, loc.plane)
            if effectiveByTile[k] ~= nil then
                effectiveByTile[k] = effectiveByTile[k] | mask
            end
        end
    end
end


-- Edge case collision addition. Objects with blockwalk=0 but that do block.
-- Mark the occupied footprint of a visible, explicitly server-blocking Loc.
-- Entity width/length are already world-oriented, as in the Loc inspector.
function M.applyServerBlockingLocs(locs, effectiveByTile)
    for _,loc in ipairs(locs) do
        -- If the loc id is in our list of exceptions, set rule to true
        local rule = specialCases.serverBlockingLocs[loc.id]
        -- If there is an exception loc (regardless of if it's hidden)
        -- add center blocking to all tiles it occupies.
        --if rule and loc.hidden == false then
        if rule then
            local width = math.max(1, math.floor(loc.width or 1))
            local length = math.max(1, math.floor(loc.length or 1))
            if not rule.footprint then width, length = 1, 1 end
            for dx = 0, width - 1 do
                for dz = 0, length - 1 do
                    local k = key(loc.x + dx, loc.z + dz, loc.plane)
                    if effectiveByTile[k] ~= nil then
                        effectiveByTile[k] = effectiveByTile[k] | CENTER
                    end
                end
            end
        end
    end
end


return M

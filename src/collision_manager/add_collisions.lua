-- Add collision inferred from visible Locs and documented exceptions.
-- Shape heuristics are experimental: do not silently broaden them.
local M = {}
local CENTER = 1
local blockedLocs = require("data/blocking_locs")
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
    -- Hidden Locs never contribute dynamic collision additions.
    if loc.hidden ~= false then
        return 0
    end

    -- A Loc may block movement according to either the live API
    -- or the cached blocks_movement property.
    local liveBlocking = loc.block == 1 or loc.block == 2
    -- If the live state and cached param of the loc both dont say blocking
    -- then don't add any collision.
    if not liveBlocking and not blockedLocs.contains(loc.id) then 
        return 0
    end

    local shape = loc.shape
    -- Directional collision resolution:
    -- If the location is 0 (door) then return the mapped block direction (not central blocking)
    if shape == 0 then
        if loc.rotation == nil then return 0 end
        return WALL_BY_ROTATION[loc.rotation % 4] or 0

    -- If the location is 2 (L-shape) then return the mapped block direction
    elseif shape == 2 then
        if loc.rotation == nil then return 0 end
        return LWALL_BY_ROTATION[loc.rotation % 4] or 0

    -- For ground decoration, enforce that blockWalk = 1
    elseif (shape == 22 and loc.block == 1) then
        return CENTER

    -- Scenery shapes
    elseif shape == 9 or shape == 10 or shape == 11 then
        -- Scenery MultiLocs with blockWalk = 2 may inherit nonblocking collision behaviour from their parent.
        if loc.block == 2 and loc.isMultiLoc == true and loc.parentBlock == 0 then return 0 end
        -- Scenery shapes add collision
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


return M

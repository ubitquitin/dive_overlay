-- ============================================================================
-- REMOVE COLLISIONS
-- ============================================================================
-- Adjust static collision flags using the current state of nearby Locs.
--
-- Static collision maps may contain blocking flags that no longer match
-- the live game world. For example, an object may be hidden, or a door
-- may have changed state.
--
-- This module identifies certain cases where static blocking should be
-- removed. It does not modify the underlying packed collision maps.
--
-- The collision manager calls effectiveFlags() for each nearby tile,
-- then applies additional collision rules from add_collisions.lua.
--
-- NOTE: These are heuristics, not a complete reconstruction of the
-- game's collision system. Directional collision removal is restricted
-- to the shape and rotation of qualifying hidden Locs to avoid removing
-- unrelated static collision. See README for limitations.
-- ============================================================================

local M = {}
-- Bit 0 represents blocking at the center of a tile.
local CENTER = 1
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

-- Reuse the addition module's shape-based collision classification to
-- determine whether a visible Loc contributes CENTER blocking.
local addCollisions = require("src/collision_manager/add_collisions")

-- Helper function to calculate the directional collision from a loc Entity
-- based on the shape and rotation of the loc
local function staleDirectionalMask(loc)
    if loc.rotation == nil then
        return 0
    end

    local rotation = loc.rotation % 4

    if loc.shape == 0 then
        return WALL_BY_ROTATION[rotation] or 0

    elseif loc.shape == 2 then
        return LWALL_BY_ROTATION[rotation] or 0
    end

    return 0
end


-- ============================================================================
-- 1. PAIRED LOC STATE DETECTION
-- ============================================================================

-- Check whether a Loc has a nearby counterpart with the same name,
-- on the same plane, but with the opposite hidden state.
--
-- This supports the existing heuristic for paired door/object states,
-- where one Loc representation may become hidden while another becomes
-- visible as the object changes state.
--
-- A matching counterpart must:
--   * Be a different Loc record.
--   * Have the same nonempty name and plane.
--   * Have blockWalk == 2.
--   * Have a different hidden state.
--   * Be within one tile on both coordinate axes.
--
-- Returns true when such a counterpart exists.
local function sameNameOppositeHidden(a, locs)
    if a.name == nil or a.name == "" then
        return false
    end
    for _,b in ipairs(locs) do
        if b ~= a and b.plane == a.plane and b.name == a.name
            and b.block == 2 and b.hidden ~= a.hidden
            and math.abs(b.x-a.x) <= 1 and math.abs(b.z-a.z) <= 1 then
            return true
        end
    end
    return false
end


-- Remove stale static collision based on the current state of nearby Locs.
--
-- rawFlags:      Original static collision flags for this tile.
-- footprintLocs: Locs occupying this tile, including multi-tile objects.
-- originLocs:    Locs originating on this tile.
-- nearbyLocs:    All nearby Locs, used to detect paired object states.
--
-- CENTER blocking is handled separately from directional blocking:
-- CENTER can be cleared independently, while stale directional
-- collision is removed selectively based on Loc shape and rotation.
-- Unrelated directional and corner flags are preserved.
function M.effectiveFlags(rawFlags, footprintLocs, originLocs, nearbyLocs)

    -- hiddenLoc tells us if there is stale CENTER blocking to be removed
    -- visibleCenter tells us if we will be adding in center blocking again later
    -- This prevents a redundant collision removal before adding back again
    local hiddenLoc, visibleCenter = false, false

    for _, loc in ipairs(footprintLocs) do
        if loc.hidden == true and (loc.isActive == true or loc.block == 1) then
            hiddenLoc = true
        elseif (addCollisions.addedCollisionMask(loc) & CENTER) ~= 0 then
            visibleCenter = true
        end
    end

    local effective = rawFlags

    -- Case 1: Static tile has CENTER blocking.
    -- Remove CENTER if a qualifying Loc is hidden and no visible Loc
    -- still requires it. Preserve directional and corner flags.
    if (rawFlags & CENTER) ~= 0 then
        if hiddenLoc and not visibleCenter then
            effective = effective & (~CENTER)
        end

    -- Case 2: Static tile has directional/corner blocking but no CENTER.
    -- Clear static blocking when an origin Loc indicates it is stale
    -- TODO: Elseif -> if; in the rare case that a tile has both central and directional collision.
    elseif rawFlags ~= 0 then
        for _, loc in ipairs(originLocs) do
            if loc.isActive == true and loc.hidden == true then
                -- if the loc is active, hidden and is blockWalk = 1 (hidden blocking loc)
                -- or blockWalk = 2 with an opposite-hidden same-name counterpart (how doors work)
                -- then mark the loc as stale.
                local stale = (
                    loc.block == 1
                    or (
                        loc.block == 2
                        and sameNameOppositeHidden(loc, nearbyLocs)
                    )
                )
                -- if the loc is stale, get the mask and NOT it to remove collision 
                -- ONLY in the cached direction (the direction it used to block)
                if stale then
                    local mask = staleDirectionalMask(loc)

                    effective = effective & (~mask)
                end
            end
        end
    end

    -- Restore CENTER if an overlapping visible Loc currently blocks the tile.
    if visibleCenter then
        effective = effective | CENTER
    end

    return effective
end


return M

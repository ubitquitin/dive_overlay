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
-- game's collision system. The existing non-wall blockWalk=0 clearing
-- behavior is intentionally preserved. See README for limitations.
-- ============================================================================

local M = {}
-- Bit 0 represents blocking at the center of a tile.
local CENTER = 1

-- Reuse the addition module's shape-based collision classification to
-- determine whether a visible Loc contributes CENTER blocking.
local addCollisions = require("src/collision_manager/add_collisions")


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
    if a.name == "" then return false end
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
-- CENTER can be cleared independently, while stale directional-only
-- collision is cleared entirely when a matching Loc state is found.
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
    -- Clear static blocking when an origin Loc indicates it is stale:
    --   - Visible nonblocking Loc (blockWalk = 0)
    --   - Hidden blocking Loc (blockWalk = 1)
    --   - blockWalk = 2 Loc with an opposite-hidden same-name counterpart
    elseif rawFlags ~= 0 then
        for _, loc in ipairs(originLocs) do
            if loc.isActive == true and (
                (loc.block == 0 and loc.hidden == false)
                or (loc.hidden == true and loc.block == 1)
                or (loc.block == 2 and sameNameOppositeHidden(loc, nearbyLocs)) -- Doors
            ) then
                effective = 0
                break
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

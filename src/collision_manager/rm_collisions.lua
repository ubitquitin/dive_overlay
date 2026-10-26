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


-- ============================================================================
-- 2. STATIC COLLISION FLAG REMOVAL
-- ============================================================================

-- Calculate a tile's effective collision flags after applying removal
-- heuristics based on the current state of nearby Locs.
--
-- Parameters:
--   rawFlags      Static collision bitmask for the destination tile.
--   footprintLocs Locs whose footprints overlap this tile.
--   originLocs    Locs whose origin coordinates match this tile.
--   nearbyLocs    All nearby Locs, used to identify paired states.
--
-- The function handles two main cases:
--
--   A. Static CENTER blocking:
--      Clear CENTER when a qualifying hidden Loc exists and no visible
--      CENTER-blocking Loc overlaps the tile.
--
--   B. Static directional blocking without CENTER:
--      Clear the entire bitmask when one of the existing Loc-state
--      heuristics indicates that the static blocking is stale.
--
-- Visible CENTER blocking is then restored when appropriate.
--
-- Returns the adjusted collision bitmask. A return value of 0 means
-- no blocking flags remain after these rules are applied.
function M.effectiveFlags(rawFlags, footprintLocs, originLocs, nearbyLocs)
    -- ------------------------------------------------------------
    -- Step 1: Inspect Locs occupying the tile's footprint.
    -- ------------------------------------------------------------
    local hiddenLoc, visibleCenter = false, false
    for _,loc in ipairs(footprintLocs) do
        -- A hidden Loc may indicate that static CENTER collision is stale.
        -- Only count it when its configuration is active or blockWalk == 1.
        if loc.hidden == true and (loc.isActive == true or loc.block == 1) then
            hiddenLoc = true
        
        -- Otherwise, check whether this Loc contributes CENTER blocking
        -- according to the shape/visibility rules in add_collisions.lua.
        --
        -- Bitwise AND isolates the CENTER bit from the returned mask.
        elseif (addCollisions.addedCollisionMask(loc) & CENTER) ~= 0 then
            visibleCenter = true
        end
    end

    -- Begin with the original static collision flags.
    local effective = rawFlags

    -- ------------------------------------------------------------
    -- Step 2A: Handle tiles with static CENTER blocking.
    -- ------------------------------------------------------------
     if (rawFlags & CENTER) ~= 0 then

        -- Remove only CENTER when a qualifying hidden Loc is present
        -- and no visible Loc contributes CENTER blocking.
        --
        -- Bitwise AND with ~CENTER clears bit 0 while preserving
        -- any directional wall or corner flags.
        if hiddenLoc and not visibleCenter then
            effective = effective & (~CENTER)
        end

    -- ------------------------------------------------------------
    -- Step 2B: Handle directional-only static blocking.
    -- ------------------------------------------------------------
    elseif rawFlags ~= 0 then

        -- This branch only runs when static flags are nonzero but
        -- CENTER is absent. These flags represent directional or
        -- corner blocking rather than central tile occupancy.
        --
        -- Inspect Locs originating on this tile for evidence that
        -- the original static collision no longer applies.
        for _,loc in ipairs(originLocs) do

            -- Case 1: A visible nonblocking Loc (blockWalk == 0).
            --
            -- Preserve the existing heuristic that treats this as
            -- evidence for clearing stale static directional flags.
            --
            -- Case 2: A hidden Loc with blockWalk == 1.
            --
            -- Treat its hidden state as evidence that the static
            -- directional blocking should no longer apply.
            --
            -- Case 3: A blockWalk == 2 Loc with a nearby same-name
            -- counterpart in the opposite hidden state.
            --
            -- This supports paired door/object state transitions.
            if (loc.block == 0 and loc.hidden == false)
                or (loc.hidden == true and loc.block == 1)
                or (loc.block == 2 and sameNameOppositeHidden(loc, nearbyLocs)) then

                -- Unlike CENTER removal, this clears the entire
                -- static directional bitmask for the tile.
                effective = 0
                break
            end
        end
    end

    -- ------------------------------------------------------------
    -- Step 3: Preserve observed visible CENTER blocking.
    -- ------------------------------------------------------------

    -- Add CENTER when a visible overlapping Loc contributes it.
    --
    -- Bitwise OR adds CENTER without removing any other flags.
    -- This can restore CENTER even if the static tile lacked it.
    if visibleCenter then effective = effective | CENTER end

    return effective
end


return M

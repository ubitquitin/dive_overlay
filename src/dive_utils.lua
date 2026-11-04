-- Dive path simulation and straight-line Surge/Escape projection.
local M = {}
local collisionManager = require("src/collision_manager/collision_manager")
local RADIUS = 10 -- Dive/surge distance
local DEFAULT_ESCAPE = 7 -- Default escape distance
local MAINHAND_SLOT = 4 -- Position of mainhand slot in Worn Equipment API
local RANGE_PARAM_ID = 13 -- Item parameter used to derive Escape distance for equipped weapons

-- Utility for getting the sign of a value
local function sign(n)
    if n > 0 then return 1 end
    if n < 0 then return -1 end
    return 0
end

-- Returns the dynamic collision override flags from the collision manager
-- These flags will update the underlying cached collision state when calculating diveability
local getCollisionFlags = collisionManager.getFlags

-- Collision Data translations from bitmasks to meaningful collision states.
local CENTER, WEST, NORTH, EAST, SOUTH = 1, 2, 4, 8, 16
local NW, NE, SE, SW = 32, 64, 128, 256

-- Returns true if any of the specified collision flags are set.
-- Collision flags are stored as bits within a single integer.
-- The bitwise AND (&) isolates the requested flags.
-- A nonzero result means at least one requested flag is present.
-- Returns false if the collision value is nil.
local function flagged(value, mask)
    return value ~= nil and (value & mask) ~= 0
end

-- Helper function to check if a neighboring tile is reachable according to the collision data.
-- Cardinal movement checks cardinal wall bits only.
-- Diagonals must pass both orthogonal routes through the neighboring tiles.
local canStep
canStep = function(x, z, nx, nz, plane)
    local from = getCollisionFlags(x, z, plane)
    local to = getCollisionFlags(nx, nz, plane)
    if from == nil or to == nil then return false end
    -- Edge case - if we are in a center blocked tile, we cannot leave it
    if flagged(from, CENTER) or flagged(to, CENTER) then return false end

    local dx, dz = nx - x, nz - z
    -- Moving East: Check the East boundary of our current tile and the West boundary of our destination tile.
    if dx == 1 and dz == 0 then
        return not flagged(from, EAST)
           and not flagged(to, WEST)
    -- Moving West: Check the West boundary of our current tile and the East boundary of our destination tile.
    elseif dx == -1 and dz == 0 then
        return not flagged(from, WEST)
           and not flagged(to, EAST)
    -- Moving North: Check the North boundary of our current tile and the South boundary of our destination tile.
    elseif dx == 0 and dz == 1 then
        return not flagged(from, NORTH)
           and not flagged(to, SOUTH)
    -- Moving South: Check the South boundary of our current tile and the North boundary of our destination tile.
    elseif dx == 0 and dz == -1 then
        return not flagged(from, SOUTH)
           and not flagged(to, NORTH)
    -- Diagonal Movement Check: Get the ordinal direction based on the dx, dz magnitudes
    elseif math.abs(dx) == 1 and math.abs(dz) == 1 then
        local cornerFrom, cornerTo
        if dx == 1 and dz == 1 then cornerFrom, cornerTo = NE, SW
        elseif dx == -1 and dz == 1 then cornerFrom, cornerTo = NW, SE
        elseif dx == 1 and dz == -1 then cornerFrom, cornerTo = SE, NW
        else cornerFrom, cornerTo = SW, NE end
        if flagged(from, cornerFrom) or flagged(to, cornerTo) then return false end
        -- Check if we can step cardinally in X, cardinally in Z, and ordinally in X and Z
        -- If we cannot step from nx,z to nx,nz AND x,nz to nx,nz, then we would be wall clipping.
        -- So we must check all 4 are true for valid tile walk diagonally.
        return canStep(x, z, nx, z, plane)
           and canStep(nx, z, nx, nz, plane)
           and canStep(x, z, x, nz, plane)
           and canStep(x, nz, nx, nz, plane)
    end
    return false
end


-- Function for determining whether or not a candidate tile can be reached with Dive.
-- At every step, attempt:
-- 1. Diagonal toward target
-- 2. E/W toward target
-- 3. N/S toward target
-- Move one tile, then repeat the priority checks.
-- Stop once the tile is reached or we can no longer move towards the candidate.
function M.isDiveable(startX, startZ, targetX, targetZ, plane)
    local dx, dz = targetX - startX, targetZ - startZ
    if math.max(math.abs(dx), math.abs(dz)) > RADIUS then
        return false
    end
    local start = getCollisionFlags(startX, startZ, plane)
    local dest = getCollisionFlags(targetX, targetZ, plane)
    if start == nil or dest == nil
        or flagged(start, CENTER)
        or flagged(dest, CENTER) then
        return false
    end
    local x, z = startX, startZ
    while x ~= targetX or z ~= targetZ do
        local sx = sign(targetX - x)
        local sz = sign(targetZ - z)
        -- Priority 1: Diagonal
        if sx ~= 0 and sz ~= 0
            and canStep(x, z, x + sx, z + sz, plane) then
            x = x + sx
            z = z + sz
        -- Priority 2: Horizontal (E/W)
        elseif sx ~= 0
            and canStep(x, z, x + sx, z, plane) then
            x = x + sx
        -- Priority 3: Vertical (N/S)
        elseif sz ~= 0
            and canStep(x, z, x, z + sz, plane) then
            z = z + sz
        else
            -- No valid step toward the target
            return false
        end
    end
    return true
end


-- Converts the player's compass-facing angle into a tile direction (dx, dz)
-- for projecting Surge and Escape destinations.
--
-- In main.lua, the player's effective facing direction is obtained from
-- dive_direction.lua and passed into compassVector(). The resulting (dx, dz)
-- is then passed to active_tiles.traceLine(), which checks tiles in that
-- direction up to the ability's maximum range.
--
-- For example, facing Northeast (45 degrees) returns (1, 1).
-- traceLine() then examines (x+1, z+1), (x+2, z+2), etc.
--
-- The lookup table contains the 8 compass directions, ordered clockwise
-- from North. Each entry specifies how X and Z change for one tile of
-- movement in that direction.
local compass = {
    {0, 1},    -- North
    {1, 1},    -- Northeast
    {1, 0},    -- East
    {1, -1},   -- Southeast
    {0, -1},   -- South
    {-1, -1},  -- Southwest
    {-1, 0},   -- West
    {-1, 1}    -- Northwest
}

-- Rounds the input angle to the nearest 45-degree compass direction
-- and returns its corresponding (dx, dz) tile offsets.
--
-- Adding 22.5 degrees shifts the boundaries so angles round to the
-- nearest compass direction rather than always rounding down.
-- Modulo 360 handles angle wrapping, while modulo 8 and +1 produce
-- a valid Lua table index (1 through 8).
function M.compassVector(degrees)
    local sector = math.floor(((degrees % 360) + 22.5) / 45) % 8 + 1
    return compass[sector][1], compass[sector][2]
end


-- Determines Escape's maximum distance based on the equipped main-hand weapon.
--
-- The default Escape distance is 7 tiles. A ranged weapon may modify this
-- distance, so we inspect the main-hand item's combat-style parameter.
--
-- MAINHAND_SLOT = 4 identifies the main-hand equipment slot.
-- RANGE_PARAM_ID = 13 identifies the item parameter used for this calculation.
--
-- If the equipment API is unavailable, the item has no relevant parameter,
-- or an error occurs, use the default distance.
function M.getEscapeDistance()

    -- pcall prevents an equipment/API error from crashing the plugin.
    -- 'ok' indicates whether the function executed successfully.
    -- 'result' contains the returned parameter value, or nil.
    local ok, result = pcall(function()

        -- Access the player's worn equipment inventory.
        local worn = Inventory.Find(config.Inv.WORN)
        if not worn or not worn.isValid then return nil end

        -- Retrieve the equipped main-hand item.
        local slot = worn:GetSlot(MAINHAND_SLOT)
        if not slot or not slot.obj then return nil end

        -- Look up the item parameter used to determine the weapon's range.
        local rangeParam = config.Param.FromID(RANGE_PARAM_ID)

        -- Return nil if the item does not expose this parameter.
        if not rangeParam or not slot.obj:HasParam(rangeParam) then
            return nil
        end

        -- Read and convert the parameter value to a number.
        return tonumber(slot.obj:GetParamValue(rangeParam))
    end)

    -- Fall back to the standard Escape distance if lookup fails.
    if not ok or result == nil then
        return DEFAULT_ESCAPE
    end

    -- Convert the item parameter into Escape distance.
    -- Subtract 1, then constrain the result to a minimum of 3 and maximum of 8.
    return math.max(3, math.min(8, result - 1))
end


return M

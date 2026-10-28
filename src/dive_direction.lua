-- Dive direction tracking.
-- Called once per Draw frame by main.lua.
-- Public API:
--   update(tileX, tileZ, plane, gameFacing, cooldowns) -> compass degrees or nil
--   directionForOffset(dx, dz) -> compass degrees or nil
--   getDirection() -> last effective compass direction
--   clear() -> reset all tracking state
-- Compass degrees: 0=N, 45=NE, 90=E, ..., 315=NW.
--
-- Why this module exists:
-- PlayerEntity.facing does not reliably update after Dive. We detect Dive using
-- a cooldown change and infer its final facing from the displacement between
-- the Dive's starting tile and the player's current tile. Surge and Escape are
-- recognized so their movement does not get mistaken for ordinary walking.
--
-- The cooldown values passed by main.lua correspond to:
--   diveEnd = 6961, surge = 8670, escape = 8666.
--
-- Timing below is measured in game ticks.

local M = {}

-- Translate the game's facing convention into compass degrees.
local FACING_OFFSET_DEGREES = 180
local LONG_MOVE_DISTANCE = 9


local N, NE, E, SE, S, SW, W, NW, X =
    0, 45, 90, 135, 180, 225, 270, 315, false

-- Empirical Dive-facing lookup for every destination offset within +/-10 tiles.
-- Row 1 is dz=+10 (north), row 21 is dz=-10 (south).
-- Column 1 is dx=-10 (west), column 21 is dx=+10 (east).
-- The center cell represents no movement and deliberately contains false.
local diveGrid = {
    { NW, NW, NW, NW, NW, N,  N,  N,  N,  N,  N, N,  N,  N,  N,  NE, NE, NE, NE, NE, NE },
    { NW, NW, NW, NW, NW, NW, N,  N,  N,  N,  N, N,  N,  N,  NE, NE, NE, NE, NE, NE, NE },
    { NW, NW, NW, NW, NW, NW, NW, N,  N,  N,  N, N,  N,  NE, NE, NE, NE, NE, NE, NE, NE },
    { NW, NW, NW, NW, NW, NW, NW, NW, N,  N,  N, N,  NE, NE, NE, NE, NE, NE, NE, NE, NE },
    { NW, NW, NW, NW, NW, NW, NW, NW, NW, N,  N, N,  NE, NE, NE, NE, NE, NE, NE, NE, NE },
    { NW, NW, NW, NW, NW, NW, NW, NW, NW, N,  N, N,  NE, NE, NE, NE, NE, NE, NE, NE, NE },
    { W,  W,  NW, NW, NW, NW, NW, NW, NW, NW, N, NE, NE, NE, NE, NE, NE, NE, NE, E,  E },
    { W,  W,  W,  NW, NW, NW, NW, NW, NW, NW, N, NE, NE, NE, NE, NE, NE, NE, E,  E,  E },
    { W,  W,  W,  W,  W,  NW, NW, NW, NW, NW, N, NE, NE, NE, NE, NE, E,  E,  E,  E,  E },
    { W,  W,  W,  W,  W,  W,  W,  W,  NW, NW, N, NE, NE, E,  E,  E,  E,  E,  E,  E,  E },
    { W,  W,  W,  W,  W,  W,  W,  W,  W,  W,  X, E,  E,  E,  E,  E,  E,  E,  E,  E,  E },
    { W,  W,  W,  W,  W,  W,  W,  W,  SW, SW, S, SE, SE, E,  E,  E,  E,  E,  E,  E,  E },
    { W,  W,  W,  W,  W,  SW, SW, SW, SW, SW, S, SE, SE, SE, SE, SE, E,  E,  E,  E,  E },
    { W,  W,  W,  SW, SW, SW, SW, SW, SW, SW, S, SE, SE, SE, SE, SE, SE, SE, E,  E,  E },
    { W,  W,  SW, SW, SW, SW, SW, SW, SW, SW, S, SE, SE, SE, SE, SE, SE, SE, SE, E,  E },
    { SW, SW, SW, SW, SW, SW, SW, SW, SW, S,  S, S,  SE, SE, SE, SE, SE, SE, SE, SE, SE },
    { SW, SW, SW, SW, SW, SW, SW, SW, SW, S,  S, S,  SE, SE, SE, SE, SE, SE, SE, SE, SE },
    { SW, SW, SW, SW, SW, SW, SW, SW, S,  S,  S, S,  S,  SE, SE, SE, SE, SE, SE, SE, SE },
    { SW, SW, SW, SW, SW, SW, SW, S,  S,  S,  S, S,  S,  S,  SE, SE, SE, SE, SE, SE, SE },
    { SW, SW, SW, SW, SW, SW, S,  S,  S,  S,  S, S,  S,  S,  S,  SE, SE, SE, SE, SE, SE },
    { SW, SW, SW, SW, SW, S,  S,  S,  S,  S,  S, S,  S,  S,  S,  S,  SE, SE, SE, SE, SE }
}

-- Look up the facing that Dive produces for a relative tile offset.
-- The lookup is only defined for integer offsets inside the 21x21 grid.
function M.directionForOffset(dx, dz)
    if type(dx) ~= "number" or type(dz) ~= "number" then
        return nil
    end

    if dx ~= math.floor(dx) or dz ~= math.floor(dz) then
        return nil
    end

    -- Diving while running in the same direction can push the tick's offset
    -- past the edge, where directions are broad enough that it rarely matters.
    dx = math.max(-10, math.min(10, dx))
    dz = math.max(-10, math.min(10, dz))

    if dx == 0 and dz == 0 then
        return nil
    end

    -- Convert signed offsets to Lua's 1-based row/column indices.
    local angle = diveGrid[11 - dz][11 + dx]
    return type(angle) == "number" and angle or nil
end

-- Apply Offset to the PlayerEntity.facing variable (I found this to be rotated 180 degrees?)
local function gameCompass(facing)
    if type(facing) ~= "number" then return nil end
    return (facing + FACING_OFFSET_DEGREES) % 360
end


-- A changed numeric cooldown value is our signal that an ability activated.
-- Missing/non-numeric reads do not count as changes.
local function changed(now, before, key)
    return type(now[key]) == "number"
        and type(before[key]) == "number"
        and now[key] ~= before[key]
end

-- Utility for extracting cooldown states into a new dictionary
local function copyCooldowns(c)
    return {
        diveEnd = c.diveEnd,
        surge = c.surge,
        escape = c.escape
    }
end

local function gridDistance(dx, dz)
    return math.max(math.abs(dx), math.abs(dz))
end

-- Persistent state between Draw frames:
-- lastX/Z/Plane: position from the previous successful update.
-- lastCooldowns: most recent numeric readings for cooldown-change detection.
-- effective:     direction currently displayed by the overlay.
local lastX, lastZ, lastPlane
local lastCooldowns
local effective
-- Last direction produced by Dive. Unlike activeDive, this stays set after
-- Dive movement ends, until the player turns or starts moving normally.
local diveOverride
-- Previous game-reported facing, used to detect an actual change.
local lastGameFacing

-- For movements >= 9 tiles, our surge/dive/escape cooldown signals lag behind
-- 1 server logic tick. This extra state allows us to report the correct
-- diveOverride for those cases
local lastDX, lastDZ = 0, 0
local jumpPending = false

function M.clear()
    lastX, lastZ, lastPlane = nil, nil, nil
    lastCooldowns = nil
    effective = nil
    jumpPending = false
    diveOverride = nil
    lastGameFacing = nil
end

function M.getDirection()
    return effective
end

-- given 2 tiles next to each other, return the 'angle' you will be at
-- when walking from one to the next based on their x,z offsets from each other
local COMPASS = {
    --  x movement, then Z movement
    [0] = { [1] = 0, [-1] = 180 },
    [1] = { [1] = 45, [0] = 90, [-1] = 135 },
    [-1] = { [1] = 315, [0] = 270, [-1] = 225 },
}

local function sign(n)
    return n > 0 and 1 or (n < 0 and -1 or 0)
end

local function isDiagonalStep(dx, dz)
    return math.abs(dx) == 1 and math.abs(dz) == 1
end

-- The only split forms seen in testing: SE as E-then-S, NW as N-then-W.
local function isSplitDiagonal(a, mid, b)
    local fx, fz = mid.x - a.x, mid.z - a.z
    local sx, sz = b.x - mid.x, b.z - mid.z
    return (fx == 1 and fz == 0 and sx == 0 and sz == -1) -- E then S
        or (fx == 0 and fz == 1 and sx == -1 and sz == 0) -- N then W
end

-- Compass direction the player will be facing at the end of this tick's
-- movement, from coordGrid (where they are) and route (the next few tiles).
--
-- Route quirks this handles:
--   * S/W/SW moves start the route with the current tile; it's skipped.
--   * SE and NW diagonals are always split into two entries (SE: E then S,
--     NW: N then W). NE and SW diagonals are a single entry.
--   * Running into a split diagonal after a straight step (SSE, SEE, NNW,
--     WNW) can end a tick on the half-step, leaving one straight step that
--     is really the rest of the diagonal. `previous` (last tick's result)
--     is used to recognise that case.
--   * Walking around the NE corner of an obstacle (E then S, or N then W)
--     gives exactly the same route as a split diagonal. On the first tick
--     there's no way to tell them apart, so it wrongly predicts the diagonal.
--     On the next tick the player is standing on the corner tile, and
--     facingTarget shows the real straight direction, so that tick is right.
--
-- dev note: this sucked. I am still stumped as to why the route information is
-- asymmetrical and why all of these workarounds were needed, but I'm happy enough
-- with the end results outside of the 1 known mis-prediction,
local function routeCompass(player, previous)
    local here = player.coordGrid
    if not here then return nil end
    local route = player.route or {}

    -- Path: current tile, then the route without consecutive duplicates
    local path = { here }
    for _, c in ipairs(route) do
        local last = path[#path]
        if c.x ~= last.x or c.z ~= last.z then
            path[#path + 1] = c
        end
    end

    local n = #path
    if n < 2 then return nil end

    -- escape (and only escape?) sets your route which this method was
    -- interpreting as you walking backwards (and thus changing your angle)
    -- This tries to detect it based on distance and return early
    -- note: this will show the wrong facing angle if you escape exactly 1 tile
    -- for 1 tick (skill issue)
    local first = path[2]
    if gridDistance(first.x - here.x, first.z - here.z) > 1 then
        return nil
    end

    -- Last real step: a single diagonal entry, a split diagonal across the
    -- last two entries, or a straight step
    local last, prev = path[n], path[n - 1]
    local dx, dz = last.x - prev.x, last.z - prev.z
    if not isDiagonalStep(dx, dz) and n >= 3
        and isSplitDiagonal(path[n - 2], prev, last) then
        dx, dz = last.x - path[n - 2].x, last.z - path[n - 2].z
    end
    local result = COMPASS[sign(dx)][sign(dz)]

    -- Landed on the half-step of last tick's SE/NW diagonal: the route is a
    -- single straight entry (no leading current tile) finishing that diagonal
    local onHalfStep = #route == 1
        and ((result == 180 and previous == 135)
            or (result == 270 and previous == 315))
    if onHalfStep then
        -- Corner turn vs half-step of a split diagonal: same route shape.
        -- By this tick facingTarget reflects the step actually being taken.
        local target = (player.facingTarget + 180) % 360
        target = math.floor(target / 45 + 0.5) * 45 % 360
        if target == result then
            return result -- corner: really walking straight now
        end
        return previous -- half-step: still finishing the diagonal
    end

    return result
end

-- Update the displayed direction on each ServerLogic Tick
--
-- Normal movement: use PlayerEntity.facing immediately, without waiting
-- for the character to stop walking or running.
--
-- Dive: calculate direction from the Dive start tile and the diveGrid.
-- Keep that result in diveOverride even after Dive tracking ends. This is
-- needed because PlayerEntity.facing may still report the OLD direction.
--
-- Clear the override when PlayerEntity.facing actually changes, OR when a
-- new ordinary movement begins after the Dive movement has finished.
-- Surge and Escape never use the Dive grid.
function M.update(player, cooldowns)
    local grid = player and player.coordGrid
    if not grid then
        return effective
    end

    local x, z, plane = grid.x, grid.z, grid.level
    local facing = player.facing
    local routeFacing = routeCompass(player, effective)

    cooldowns = cooldowns or {}
    local currentFacing = gameCompass(facing)
    local facingChanged = currentFacing ~= nil and lastGameFacing ~= nil
        and currentFacing ~= lastGameFacing

    -- Establish baseline observations on startup or when changing planes.
    if lastX == nil or plane ~= lastPlane then
        lastX, lastZ, lastPlane = x, z, plane
        lastDX, lastDZ = 0, 0
        jumpPending = false
        lastCooldowns = copyCooldowns(cooldowns)
        effective = currentFacing
        lastGameFacing = currentFacing
        diveOverride = nil
        return effective
    end

    -- A cooldown VALUE change is used as the activation signal. This is
    -- intentionally distinct from checking whether an ability is available.
    local dive = changed(cooldowns, lastCooldowns, "diveEnd")
    local surge = changed(cooldowns, lastCooldowns, "surge")
    local escape = changed(cooldowns, lastCooldowns, "escape")
    local ability = dive or surge or escape

    -- Keep the previous valid value if a cooldown temporarily reads nil.
    for _, key in ipairs({ "diveEnd", "surge", "escape" }) do
        if type(cooldowns[key]) == "number" then
            lastCooldowns[key] = cooldowns[key]
        end
    end

    local dx, dz = x - lastX, z - lastZ
    local moved = dx ~= 0 or dz ~= 0

    if gridDistance(dx, dz) >= LONG_MOVE_DISTANCE and not ability then
        -- Long move with no signal yet: probably Dive or Surge, whose cooldown
        -- change arrives next tick. Either way, the dive lookup of the offset
        -- gives the right facing (a surge goes straight along the facing), so
        -- show it now; next tick's signal confirms or corrects it.
        jumpPending = true
        effective = M.directionForOffset(dx, dz) or effective
    else
        local hadJump = jumpPending
        jumpPending = false

        if hadJump and not ability then
            -- Last tick's long move wasn't an ability (teleport, shortcut...).
            diveOverride = nil
        elseif diveOverride ~= nil and not surge
            and (facingChanged or moved or routeFacing ~= nil) then
            -- Walking or turning clears the override. Surge doesn't: it keeps
            -- the player's facing.
            diveOverride = nil
        end

        if dive then
            -- After a frozen long move, the Dive's movement was last tick.
            if hadJump then
                diveOverride = M.directionForOffset(lastDX, lastDZ)
            else
                diveOverride = M.directionForOffset(dx, dz)
            end
        end

        if diveOverride ~= nil then
            -- After Dive: do NOT restore stale game-facing.
            effective = diveOverride
        elseif routeFacing ~= nil then
            -- Walking/running: the route leads the character model's turn
            -- animation, so prefer it over PlayerEntity.facing.
            effective = routeFacing
        elseif currentFacing ~= nil then
            -- Standing still or turning in place.
            effective = currentFacing
        end
    end

    -- A nil reading does not erase the last valid game-facing observation.
    if currentFacing ~= nil then lastGameFacing = currentFacing end
    lastX, lastZ, lastPlane = x, z, plane
    lastDX, lastDZ = dx, dz
    return effective
end

M.clear()
return M

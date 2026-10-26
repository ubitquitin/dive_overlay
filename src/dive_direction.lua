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
-- Timing below is measured in Draw callbacks (FRAMES), not game ticks.

local M = {}

-- Translate the game's facing convention into compass degrees.
local FACING_OFFSET_DEGREES = 180

-- Frames without movement before treating a movement sequence as settled.
local SETTLE_FRAMES = 3
-- Minimum frames since the last movement before ordinary movement can restore
-- PlayerEntity.facing; this gives late cooldown changes time to arrive.
local COOLDOWN_GRACE_FRAMES = 5
-- Expire a detected Surge/Escape if no movement follows its cooldown change.
local ABILITY_WAIT_FRAMES = 30
-- Continue inferring Dive facing after the last position change to accommodate
-- intermediate Dive positions. This is NOT a permanent direction lock.
local DIVE_TRACKING_FRAMES = 12

local N, NE, E, SE, S, SW, W, NW =
    0, 45, 90, 135, 180, 225, 270, 315

-- Empirical Dive-facing lookup for every destination offset within +/-10 tiles.
-- Row 1 is dz=+10 (north), row 21 is dz=-10 (south).
-- Column 1 is dx=-10 (west), column 21 is dx=+10 (east).
-- The center cell represents no movement and deliberately contains false.
local diveGrid = {
    {NW,NW,NW,NW,NW,N, N, N, N, N, N, N, N, N, N, NE,NE,NE,NE,NE,NE},
    {NW,NW,NW,NW,NW,NW,N, N, N, N, N, N, N, N, NE,NE,NE,NE,NE,NE,NE},
    {NW,NW,NW,NW,NW,NW,NW,N, N, N, N, N, N, NE,NE,NE,NE,NE,NE,NE,NE},
    {NW,NW,NW,NW,NW,NW,NW,NW,N, N, N, N, NE,NE,NE,NE,NE,NE,NE,NE,NE},
    {NW,NW,NW,NW,NW,NW,NW,NW,NW,N, N, N, NE,NE,NE,NE,NE,NE,NE,NE,NE},
    {NW,NW,NW,NW,NW,NW,NW,NW,NW,N, N, N, NE,NE,NE,NE,NE,NE,NE,NE,NE},
    {W, W, NW,NW,NW,NW,NW,NW,NW,NW,N, NE,NE,NE,NE,NE,NE,NE,NE,E, E},
    {W, W, W, NW,NW,NW,NW,NW,NW,NW,N, NE,NE,NE,NE,NE,NE,NE,E, E, E},
    {W, W, W, W, W, NW,NW,NW,NW,NW,N, NE,NE,NE,NE,NE,E, E, E, E, E},
    {W, W, W, W, W, W, W, W, NW,NW,N, NE,NE,E, E, E, E, E, E, E, E},
    {W, W, W, W, W, W, W, W, W, W, false, E, E, E, E, E, E, E, E, E, E},
    {W, W, W, W, W, W, W, W, SW,SW,S, SE,SE,E, E, E, E, E, E, E, E},
    {W, W, W, W, W, SW,SW,SW,SW,SW,S, SE,SE,SE,SE,SE,E, E, E, E, E},
    {W, W, W, SW,SW,SW,SW,SW,SW,SW,S, SE,SE,SE,SE,SE,SE,SE,E, E, E},
    {W, W, SW,SW,SW,SW,SW,SW,SW,SW,S, SE,SE,SE,SE,SE,SE,SE,SE,E, E},
    {SW,SW,SW,SW,SW,SW,SW,SW,SW,S, S, S, SE,SE,SE,SE,SE,SE,SE,SE,SE},
    {SW,SW,SW,SW,SW,SW,SW,SW,SW,S, S, S, SE,SE,SE,SE,SE,SE,SE,SE,SE},
    {SW,SW,SW,SW,SW,SW,SW,SW,S, S, S, S, S, SE,SE,SE,SE,SE,SE,SE,SE},
    {SW,SW,SW,SW,SW,SW,SW,S, S, S, S, S, S, S, SE,SE,SE,SE,SE,SE,SE},
    {SW,SW,SW,SW,SW,SW,S, S, S, S, S, S, S, S, S, SE,SE,SE,SE,SE,SE},
    {SW,SW,SW,SW,SW,S, S, S, S, S, S, S, S, S, S, S, SE,SE,SE,SE,SE}
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

    if math.abs(dx) > 10 or math.abs(dz) > 10 then
        return nil -- TODO: Handle attempted destinations outside Dive range.
    end

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

-- Persistent state between Draw frames:
-- frame:         count of processed Draw callbacks since clear().
-- lastX/Z/Plane: position from the previous successful update.
-- lastCooldowns: most recent numeric readings for cooldown-change detection.
-- effective:     direction currently displayed by the overlay.
-- pending:       recently detected ability, with its starting tile and trigger
--                frame; needed because cooldowns and movement may arrive apart.
-- motion:        a sequence of position changes, with its original tile and
--                last movement frame; ordinary walking also creates motion.
-- activeDive:    Dive-specific sequence whose ORIGINAL start tile must be kept
--                while the player moves through intermediate Dive positions.
local frame
local lastX, lastZ, lastPlane
local lastCooldowns
local effective
local pending
local motion
local activeDive
-- Last direction produced by Dive. Unlike activeDive, this stays set after
-- Dive movement ends, until the player turns or starts moving normally.
local diveOverride
-- Previous game-reported facing, used to detect an actual change.
local lastGameFacing

function M.clear()
    frame = 0
    lastX, lastZ, lastPlane = nil, nil, nil
    lastCooldowns = nil
    effective = nil
    pending = nil
    motion = nil
    activeDive = nil
    diveOverride = nil
    lastGameFacing = nil
end

function M.getDirection()
    return effective
end

-- Update the displayed direction on each Draw callback.
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
--
-- Timers below count Draw callbacks, not server ticks (600 ms).
function M.update(x, z, plane, facing, cooldowns)
    -- Invalid position: retain the last known facing and don't advance state.
    if type(x) ~= "number" or type(z) ~= "number" then
        return effective
    end

    cooldowns = cooldowns or {}
    frame = frame + 1
    local currentFacing = gameCompass(facing)
    local facingChanged = currentFacing ~= nil and lastGameFacing ~= nil
        and currentFacing ~= lastGameFacing

    -- Establish baseline observations on startup or when changing planes.
    if lastX == nil or plane ~= lastPlane then
        lastX, lastZ, lastPlane = x, z, plane
        lastCooldowns = copyCooldowns(cooldowns)
        effective = currentFacing
        lastGameFacing = currentFacing
        diveOverride = nil
        pending = nil
        motion = nil
        activeDive = nil
        return effective
    end

    -- A cooldown VALUE change is used as the activation signal. This is
    -- intentionally distinct from checking whether an ability is available.
    local dive = changed(cooldowns, lastCooldowns, "diveEnd")
    local surge = changed(cooldowns, lastCooldowns, "surge")
    local escape = changed(cooldowns, lastCooldowns, "escape")

    -- Keep the previous valid value if a cooldown temporarily reads nil.
    for _, key in ipairs({"diveEnd", "surge", "escape"}) do
        if type(cooldowns[key]) == "number" then
            lastCooldowns[key] = cooldowns[key]
        end
    end

    local moved = x ~= lastX or z ~= lastZ

    -- Track consecutive position updates as one movement sequence.
    -- Its starting tile matters if a cooldown change is reported after the
    -- first movement frame, or if Dive moves through intermediate tiles.
    if moved then
        if not motion then
            motion = {
                startX = lastX,
                startZ = lastZ,
                lastMoveFrame = frame
            }
        end
        motion.lastMoveFrame = frame
    end

    if dive or surge or escape then
        -- Preserve existing priority if multiple cooldowns change together.
        local kind = dive and "dive"
            or (surge and "surge" or "escape")

        -- Prefer the movement sequence's original tile; otherwise use the
        -- position immediately before the cooldown changed.
        local sx = motion and motion.startX or lastX
        local sz = motion and motion.startZ or lastZ

        pending = {
            kind = kind,
            startX = sx,
            startZ = sz,
            triggerFrame = frame
        }

        if kind == "dive" then
            -- A new Dive replaces any override left by an earlier Dive.
            diveOverride = nil
            activeDive = {
                startX = sx,
                startZ = sz,
                lastMoveFrame = frame
            }
        else
            -- Surge/Escape do not use the Dive direction lookup.
            activeDive = nil
        end
    end

    -- If a Dive has stopped changing tiles for a few frames, consider its
    -- movement finished. Do not erase its saved direction.
    -- This separation lets a subsequent WALK clear the override without
    -- accidentally treating intermediate Dive tiles as ordinary walking.
    if activeDive and not moved
        and frame - activeDive.lastMoveFrame >= SETTLE_FRAMES then
        activeDive = nil
        pending = nil
        motion = nil
    end

    if activeDive then
        -- The game can report intermediate tiles during Dive. Always compare
        -- against the ORIGINAL start tile, not the previous frame's tile.
        if moved then
            activeDive.lastMoveFrame = frame
        end
        local dx = x - activeDive.startX
        local dz = z - activeDive.startZ
        local direction = M.directionForOffset(dx, dz)
        if direction ~= nil then
            diveOverride = direction
            effective = direction
        end

        -- Safety timeout if a Dive remains active unusually long.
        -- The override remains saved even after tracking is stopped.
        if frame - pending.triggerFrame >= DIVE_TRACKING_FRAMES then
            activeDive = nil
            pending = nil
            motion = nil
        end
    else
        -- A change in the game's facing means the player actually turned.
        -- A new tile movement after Dive is also sufficient: the game's
        -- facing can remain numerically unchanged even when walking resumes.
        if diveOverride ~= nil and (facingChanged or moved) then
            diveOverride = nil
        end

        if diveOverride ~= nil then
            -- Still standing after Dive: do NOT restore stale game-facing.
            effective = diveOverride
        elseif currentFacing ~= nil then
            -- Normal walking/running or a new turn: update every frame.
            effective = currentFacing
        end

        -- Keep the original non-Dive ability bookkeeping. It does not delay
        -- reading game-facing while the player is running.
        if motion and frame - motion.lastMoveFrame >= SETTLE_FRAMES then
            if pending then
                pending = nil
                motion = nil
            elseif frame - motion.lastMoveFrame >= COOLDOWN_GRACE_FRAMES then
                motion = nil
            end
        end
    end

    -- Cooldown may arrive before movement. Drop a pending non-Dive ability
    -- after waiting long enough with no tracked movement.
    if pending and not activeDive and not motion
        and frame - pending.triggerFrame >= ABILITY_WAIT_FRAMES then
        pending = nil
    end

    -- Compare game-facing with the previous frame, not with the Dive angle.
    -- A nil reading does not erase the last valid game-facing observation.
    if currentFacing ~= nil then lastGameFacing = currentFacing end
    lastX, lastZ, lastPlane = x, z, plane
    return effective
end

M.clear()
return M

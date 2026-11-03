-- Dive Overlay entry point.
-- Each frame: update collision data -> determine effective facing ->
-- filter candidate Dive tiles -> evaluate reachability ->
-- apply perimeter filtering -> render overlays.
local RADIUS = 10
local SURGE_RANGE = 10
local DIVE_COOLDOWN_END_PLAYERVAR_ID = 6961
local SURGE_COOLDOWN_END_PLAYERVAR_ID = 8670
local ESC_COOLDOWN_END_PLAYERVAR_ID = 983
local DIVE_CURSOR_ID = 157
local BLADED_DIVE_CURSOR_ID = 42

-- Whether the cursor currently displays the Dive sprite.
local isDiveCursor = false

local collisionManager = require("src/collision_manager/collision_manager")
local diveDirection = require("src/dive_direction")
local diveUtils = require("src/dive_utils")
local uiUtils = require("src/ui_utils")

-- Read a player var safely: a missing var must not abort drawing.
local function vp(id)
    local ok, value = pcall(function()
        local configVar = var.VarPlayer.FromID(id)
        return configVar and configVar.value
    end)
    if ok then return tonumber(value) end
    return nil
end

-- Populate the native Plugin Hub settings layer when opened.
Event.SettingsLayerReady.Subscribe("diveOverlaySettings", function(event)
    uiUtils.buildSettings(event.component)
end)


-- MiniMenu entries are ordered from lowest to highest priority.
-- The last entry controls the cursor when the menu is closed.
Event.MiniMenuReady.Subscribe("diveCursorCheck", function(event)
    isDiveCursor = false

    local entries = event.miniMenu.entries
    local entry = entries[#entries]

    if not entry or not entry.cursorID or entry.cursorID < 0 then
        return
    end

    if entry.cursorID == BLADED_DIVE_CURSOR_ID or entry.cursorID == DIVE_CURSOR_ID then
        isDiveCursor = true
    end
end)


-- shift as much calculation as we can into the tick so we only have to pay
-- for it once every 600ms. This is still a noticable frame hitch and could use
-- more optimization
local reach = { tiles = {}, x = nil, z = nil, level = nil, facing = nil }
local function doTick()
    local self = PlayerList.Self()
    if self == nil then
        diveDirection.clear()
        return
    end

    -- routeEnd feels like a shortcut to 'where you will be next tick'
    -- which feels more accurate to what your dive is going to base on
    local coordGrid = self.routeEnd or self.coordGrid

    -- First, detect region changes and prepare procedural mapping state.
    collisionManager.updateRegionState(
        coordGrid.x, coordGrid.z, coordGrid.level
    )

    -- Then, reconstruct effective collision flags from nearby game objects.
    collisionManager.rebuildCollisionOverrides(coordGrid, RADIUS * 2)

    local tiles = {}
    for ox = -RADIUS, RADIUS do
        for oz = -RADIUS, RADIUS do
            if (ox ~= 0 or oz ~= 0)
                and diveUtils.isDiveable(
                    coordGrid.x, coordGrid.z,
                    coordGrid.x + ox, coordGrid.z + oz, coordGrid.level
                ) then
                tiles[ox .. "," .. oz] = true
            end
        end
    end

    -- Update the effective facing direction once per game tick.
    -- This handles ordinary movement, Dive overrides, and ability cooldowns.
    local effectiveFacing = diveDirection.update(
        self,
        {
            diveEnd = vp(DIVE_COOLDOWN_END_PLAYERVAR_ID),
            surge = vp(SURGE_COOLDOWN_END_PLAYERVAR_ID),
            escape = vp(ESC_COOLDOWN_END_PLAYERVAR_ID)
        }
    )

    -- Swap in one go so Draw never sees a half-built set
    reach = { tiles = tiles, x = coordGrid.x, z = coordGrid.z, level = coordGrid.level, facing = effectiveFacing }
end

Event.ServerLogic.Subscribe("updateCollision", doTick)

-- Creates an event that runs every frame for drawing valid Dive tiles.
Event.Draw.Subscribe("bladedDiveTiles", function(drawEvent)
    local self = PlayerList.Self()
    if self == nil then
        diveDirection.clear()
        return
    end
    if reach.x == nil then return end
    local playerTileX, playerTileZ, plane, effectiveFacing = reach.x, reach.z, reach.level, reach.facing


    local forward, backward = {}, {}
    local facingX, facingZ
    if type(effectiveFacing) == "number" then
        local dx, dz = diveUtils.compassVector(effectiveFacing)
        forward = diveUtils.traceStraightLine(playerTileX, playerTileZ, dx, dz, plane, SURGE_RANGE)
        backward = diveUtils.traceStraightLine(playerTileX, playerTileZ, -dx, -dz, plane,
            diveUtils.getEscapeDistance())
        if uiUtils.settings.hideBehind then
            facingX, facingZ = dx, dz
        end
    end

    -- Apply the Hide Behind filter to the tick's diveable set
    local reachable = {}
    for key in pairs(reach.tiles) do
        local ox, oz = key:match("^(-?%d+),(-?%d+)$")
        ox, oz = tonumber(ox), tonumber(oz)
        if uiUtils.isTileInFront(ox, oz, facingX, facingZ) then
            reachable[key] = true
        end
    end

    local perimeter = uiUtils.settings.diveMode == "perimeter" and uiUtils.outerPerimeter(reachable) or nil

    -- Hover tile: the Dive destination under the cursor while the Dive cursor is active.
    local hoverPath = {}
    local hoverOX, hoverOZ
    if isDiveCursor and not MiniMenu.IsOpen() then
        -- Get mouse hover direction
        local diveResult = uiUtils.getHoveredDivePosition(
            playerTileX, playerTileZ
        )
        -- if an angle was returned, find the furthest tile in that
        -- direction
        if diveResult.angle then
            -- turn our angle into tile offsets
            local dx, dz = diveUtils.compassVector(diveResult.angle)

            -- Search backwards for the furthest valid Dive destination.
            for dist = RADIUS, 1, -1 do
                local ox, oz = dx * dist, dz * dist
                if reachable[ox .. "," .. oz] then
                    hoverPath[ox .. "," .. oz] = true
                    hoverOX, hoverOZ = ox, oz
                    break
                end
            end
        else
            if diveResult.tile then
                -- translate player coordinates back to offset coordinates
                local ox, oz = diveResult.tile.x - playerTileX, diveResult.tile.z - playerTileZ
                hoverPath[ox .. "," .. oz] = true
                hoverOX, hoverOZ = ox, oz
            end
        end
    end


    -- show where you would surge after you dive
    local useDiveSurgePreview = uiUtils.settings.surgeFollowsHover and isDiveCursor
    local surgePreview = {}
    if (useDiveSurgePreview
            and hoverOX
            and reachable[hoverOX .. "," .. hoverOZ]
            -- should we require surge to be on for this to be on?
            -- should we allow both to be on at the same time?
            and uiUtils.settings.showSurge
        ) then
        local facing = diveDirection.directionForOffset(hoverOX, hoverOZ)
        if facing then
            local dx, dz = diveUtils.compassVector(facing)
            surgePreview = diveUtils.traceStraightLine(
                playerTileX + hoverOX, playerTileZ + hoverOZ, dx, dz, plane, SURGE_RANGE)
        end
    end

    -- the surge line in front of the player currently hides if we decide to
    -- show one at the current dive cursor instead
    local showPlayerSurgePreview = uiUtils.settings.showSurge and not useDiveSurgePreview

    -- Draw Tiles based on forward, backward, reachable sets and visual toggles
    for ox = -RADIUS, RADIUS do
        for oz = -RADIUS, RADIUS do
            local tx, tz = playerTileX + ox, playerTileZ + oz
            local key = tx .. "," .. tz
            local hoverVisible = uiUtils.settings.showHover
                and reachable[ox .. "," .. oz] and hoverPath[ox .. "," .. oz]
            local diveVisible = reachable[ox .. "," .. oz]
                and (
                    uiUtils.settings.diveMode == "all" or
                    (perimeter ~= nil and perimeter[ox .. "," .. oz])
                )
            if hoverVisible then
                uiUtils.drawTile(tx, tz, plane, uiUtils.hoverRGBA)
            elseif surgePreview[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.surgeRGBA)
            elseif showPlayerSurgePreview and forward[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.surgeRGBA)
            elseif uiUtils.settings.showEscape and backward[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.escapeRGBA)
            elseif diveVisible then
                uiUtils.drawTile(tx, tz, plane, uiUtils.diveRGBA)
            end
            if uiUtils.settings.showArrows and (diveVisible or hoverVisible) then
                local angle = diveDirection.directionForOffset(ox, oz)
                if angle ~= nil then uiUtils.drawDirectionArrow(tx, tz, plane, angle) end
            end
        end
    end

    -- draw surge preview outside of radius
    for key in pairs(surgePreview) do
        local tx, tz = key:match("^(-?%d+),(-?%d+)$")
        tx, tz = tonumber(tx), tonumber(tz)
        if math.abs(tx - playerTileX) > RADIUS or math.abs(tz - playerTileZ) > RADIUS then
            uiUtils.drawTile(tx, tz, plane, uiUtils.surgeRGBA)
        end
    end
end)

-- If a new region is created or deleted trigger a re-detection of procedurally generated areas.
local regionCreatedSubscribed = false
local regionUpdatedSubscribed = false
if Event.RegionCreated and Event.RegionCreated.Subscribe then
    regionCreatedSubscribed = pcall(function()
        Event.RegionCreated.Subscribe('diveCollisionRegionCreated', function()
            collisionManager.invalidateRegion()
        end)
    end)
end
if Event.RegionUpdated and Event.RegionUpdated.Subscribe then
    regionUpdatedSubscribed = pcall(function()
        Event.RegionUpdated.Subscribe('diveCollisionRegionUpdated', function()
            collisionManager.invalidateRegionUpdate()
        end)
    end)
end

-- Shutdown function
function PluginShutdown()
    uiUtils.saveSettings()

    Event.SettingsLayerReady.Unsubscribe("diveOverlaySettings")
    Event.Draw.Unsubscribe('bladedDiveTiles')
    Event.MiniMenuReady.Unsubscribe("diveCursorCheck")
    Event.ServerLogic.Unsubscribe("updateCollision")
    if regionCreatedSubscribed and Event.RegionCreated.Unsubscribe then
        Event.RegionCreated.Unsubscribe('diveCollisionRegionCreated')
    end
    if regionUpdatedSubscribed and Event.RegionUpdated.Unsubscribe then
        Event.RegionUpdated.Unsubscribe('diveCollisionRegionUpdated')
    end
end

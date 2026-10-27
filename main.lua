-- Dive Overlay entry point.
-- Each frame: update collision data -> determine effective facing ->
-- filter candidate Dive tiles -> evaluate reachability ->
-- apply perimeter filtering -> render overlays.
local TILE_SIZE = 512
local RADIUS = 10
local SURGE_RANGE = 10
local DIVE_COOLDOWN_END_PLAYERVAR_ID = 6961
local SURGE_COOLDOWN_END_PLAYERVAR_ID = 8670
local ESC_COOLDOWN_END_PLAYERVAR_ID = 8666
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

-- Calls CreateUI() to create the prettyUI Window
uiUtils.start()


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


-- Creates an event that runs every frame for drawing valid Dive tiles.
Event.Draw.Subscribe("bladedDiveTiles", function(drawEvent)
    local self = PlayerList.Self()
    if self == nil then
        diveDirection.clear()
        return
    end

    -- Get player and grid information
    local pos = self.position
    local playerTileX = math.floor(pos.x / TILE_SIZE)
    local playerTileZ = math.floor(pos.z / TILE_SIZE)
    local grid = self.coordGrid
    local plane = grid and grid.level
    if plane == nil then
        diveDirection.clear()
        return
    end

    -- Fetch the static collision data
    collisionManager.update(playerTileX, playerTileZ, plane)
    -- Update static collision data with dynamic collision data heuristics from locEntities
    collisionManager.updateLocs(grid, RADIUS + 2)

    -- Calculate effective player direction using playerEntity.facing OR
    -- diveDirection utilities if the player has just used a movement ability.
    local effectiveFacing = diveDirection.update(
        playerTileX, playerTileZ, plane, self.facing,
        { diveEnd = vp(DIVE_COOLDOWN_END_PLAYERVAR_ID), surge = vp(SURGE_COOLDOWN_END_PLAYERVAR_ID), escape = vp(ESC_COOLDOWN_END_PLAYERVAR_ID) }
    )

    -- Get tiles directly in front and directly behind player based on effective Direction.
    -- These tiles will be used for surge and dive highlighting.
    local forward, backward = {}, {}
    if type(effectiveFacing) == "number" then
        local dx, dz = diveUtils.compassVector(effectiveFacing)
        forward = diveUtils.traceStraightLine(playerTileX, playerTileZ, dx, dz, plane, SURGE_RANGE)
        backward = diveUtils.traceStraightLine(playerTileX, playerTileZ, -dx, -dz, plane, diveUtils.getEscapeDistance())
    end

    -- Get the player's effective facing as a compass direction vector.
    -- This is used by ui_utils.lua to filter Dive tiles behind the player.
    -- We use the same effective facing already calculated for Surge/Escape.
    local facingX, facingZ
    if uiUtils.settings.hideBehind and type(effectiveFacing) == "number" then
        facingX, facingZ = diveUtils.compassVector(effectiveFacing)
    end

    -- Find all reachable Dive tiles within the 10-tile radius.
    -- Apply the Hide Behind display filter before checking reachability.
    local reachable = {}

    -- Get all Diveable tiles
    for ox = -RADIUS, RADIUS do
        for oz = -RADIUS, RADIUS do
            if (ox ~= 0 or oz ~= 0)
                and uiUtils.isTileInFront(ox, oz, facingX, facingZ)
                and diveUtils.isDiveable(
                    playerTileX, playerTileZ,
                    playerTileX + ox, playerTileZ + oz, plane
                ) then
                reachable[ox .. "," .. oz] = true
            end
        end
    end

    -- Define perimeter tile set only for perimeter mode.
    local perimeter = uiUtils.settings.diveMode == "perimeter" and uiUtils.outerPerimeter(reachable) or nil

    -- Hover mode: only show a destination while the Dive cursor is active.
    local hoverPath = {}
    if uiUtils.settings.diveMode == "hover" then
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
                        -- break if you only want the last tile
                        break
                    end
                end
            else
                if diveResult.tile then
                    -- translate player coordinates back to offset coordinates
                    local ox, oz = diveResult.tile.x - playerTileX, diveResult.tile.z - playerTileZ
                    hoverPath[ox .. "," .. oz] = true
                end
            end
        end
    end

    -- Draw Tiles based on forward, backward, reachable sets and visual toggles
    for ox = -RADIUS, RADIUS do
        for oz = -RADIUS, RADIUS do
            local tx, tz = playerTileX + ox, playerTileZ + oz
            local key = tx .. "," .. tz
            local diveVisible = reachable[ox .. "," .. oz]
                and (
                    uiUtils.settings.diveMode == "all" or
                    (perimeter ~= nil and perimeter[ox .. "," .. oz]) or
                    (hoverPath ~= nil and hoverPath[ox .. "," .. oz])
                )
            if uiUtils.settings.showSurge and forward[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.surgeRGBA)
            elseif uiUtils.settings.showEscape and backward[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.escapeRGBA)
            elseif diveVisible then
                uiUtils.drawTile(tx, tz, plane, uiUtils.diveRGBA)
            end
            if uiUtils.settings.showArrows and diveVisible then
                local angle = diveDirection.directionForOffset(ox, oz)
                if angle ~= nil then uiUtils.drawDirectionArrow(tx, tz, plane, angle) end
            end
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
    uiUtils.shutdown()
    Event.Draw.Unsubscribe('bladedDiveTiles')
    Event.MiniMenuReady.Unsubscribe("diveCursorCheck")
    if regionCreatedSubscribed and Event.RegionCreated.Unsubscribe then
        Event.RegionCreated.Unsubscribe('diveCollisionRegionCreated')
    end
    if regionUpdatedSubscribed and Event.RegionUpdated.Unsubscribe then
        Event.RegionUpdated.Unsubscribe('diveCollisionRegionUpdated')
    end
end

-- Dive Overlay entry point.
-- Each tick: update collision data if changed -> determine effective facing ->
-- filter candidate Dive tiles -> render overlays.

-- Constants
local RADIUS = 10 -- Dive radius (tiles)
local SURGE_RANGE = 10 -- surge range (tiles)
local DIVE_COOLDOWN_END_PLAYERVAR_ID = 6961 -- Dive Cooldown playervar for player direction update
local SURGE_COOLDOWN_END_PLAYERVAR_ID = 8670 -- Surge Cooldown playervar for player direction update
local ESC_COOLDOWN_END_PLAYERVAR_ID = 983 -- Escape Cooldown playervar for player direction update
local DIVE_CURSOR_ID = 157 -- Dive Cursor Sprite ID for hover tile rendering when dive active
local BLADED_DIVE_CURSOR_ID = 42 -- Bladed Dive Cursor Sprite ID for hover tile rendering when dive active

-- Whether the cursor currently displays the Dive sprite.
local isDiveCursor = false

-- Required utils
local collisionManager = require("src/collision_manager/collision_manager")
local diveDirection = require("src/dive_direction")
local diveUtils = require("src/dive_utils")
local persist = require("src/settings/persist")
local settingsUi = require("src/settings/ui")
local geometry = require("src/tile/geometry")
local instanceDraw = require("src/tile/instance_draw")
local directDraw = require("src/tile/direct_draw")
local activeTiles = require("src/active_tiles")
local debouncer = require("src/debouncer")

local settings = persist.settings

-- Utility function to read a player var safely: a missing var must not abort drawing.
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
    settingsUi.buildSettings(event.component)
end)

-- Runs debounced calls, such as settings changes from sliders.
Event.Logic.Subscribe("diveOverlayDebounce", debouncer.onLogic)


-- MiniMenu entries are ordered from lowest to highest priority.
-- The last entry controls the cursor when the menu is closed.
-- Checks whether or not the cursor is a dive sprite
Event.MiniMenuReady.Subscribe("diveCursorCheck", function(event)
    isDiveCursor = false

    local entries = event.miniMenu.entries
    local entry = entries[#entries]

    -- handle empty cases
    if not entry or not entry.cursorID or entry.cursorID < 0 then
        return
    end

    -- check if cursor is either of the valid Dive sprites
    if entry.cursorID == BLADED_DIVE_CURSOR_ID or entry.cursorID == DIVE_CURSOR_ID then
        isDiveCursor = true
    end
end)


-- Player position and direction from the last tick.
local reach = { x = nil, z = nil, level = nil, facing = nil }

-- This function is called once per Runescape gametick.
-- It calculates the player's location, fetches static cached collision data for all map chunks (64x64)
-- that intersect the 20 tile radius of the player, and dynamic collision data from LocType entities within
-- the 20 tile radius.
-- It then creates a mask of diveable tiles (var tiles) by applying the dive algorithm to the collision data
-- for each tile in the radius. Finally, it calculates player direction by either polling the player facing
-- or if dive was used, referencing the empirical dive direction grid in dive_direction.lua.
local function doTick()
    -- Get player self
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

    -- Update the effective facing direction once per game tick.
    -- This handles ordinary movement, Dive overrides, and ability cooldowns.
    -- We pass in the cooldown playervars to identify if we should simply trust PlayerType.facing
    -- or if we should reference the empirical dive direction grid (dive doesnt update PlayerType.facing)
    local effectiveFacing = diveDirection.update(
        self,
        {
            diveEnd = vp(DIVE_COOLDOWN_END_PLAYERVAR_ID),
            surge = vp(SURGE_COOLDOWN_END_PLAYERVAR_ID),
            escape = vp(ESC_COOLDOWN_END_PLAYERVAR_ID)
        }
    )

    -- Whether the Hide Behind filter applies this tick.
    local hideBehind = settings.hideBehind and type(effectiveFacing) == "number"

    -- Re-centre the active tiles on the player before writing this tick's data.
    activeTiles.sync(coordGrid)

    -- For each tile in the 21x21 area around the player, calculate
    -- if dive can reach the tile, and if the tile is behind the player
    for _, tile in pairs(activeTiles.tiles) do
        tile.isDiveable = (tile.ox ~= 0 or tile.oz ~= 0)
            and diveUtils.isDiveable(
                coordGrid.x, coordGrid.z,
                tile.coord.x, tile.coord.z, coordGrid.level
            )
        tile.isBehind = hideBehind and not diveUtils.isTileInFront(tile, effectiveFacing)
        tile.perimeterEdges = nil
    end

    -- Mark the outermost reachable tiles and which of their sides face outward.
    local mode = settings.diveMode
    if mode == "perimeter" or mode == "edges" then
        activeTiles.applyPerimeter()
    end

    -- Save off necessary data to data structure.
    reach = { x = coordGrid.x, z = coordGrid.z, level = coordGrid.level, facing = effectiveFacing }
end


-- Subscribe the doTick function to run on server logic event (every tick)
Event.ServerLogic.Subscribe("updateCollision", doTick)


-- Creates an event that runs every frame for drawing valid Dive tiles.
Event.Draw.Subscribe("bladedDiveTiles", function(drawEvent)
    -- Get self
    local self = PlayerList.Self()
    if self == nil then
        diveDirection.clear()
        activeTiles.hideAll()
        return
    end
    if reach.x == nil then return end

    -- unpack necessary player renders from data structure
    local playerTileX, playerTileZ, plane, effectiveFacing = reach.x, reach.z, reach.level, reach.facing


    -- activeTiles.traceLine traces a straight line given a dynamic range
    -- (Surge range being 10 tiles, Escape range depending on weapon attack range)
    -- This block of code takes the player facing direction, and calculates the surge and
    -- escape tiles (forward and backward).
    local forward, backward = {}, {}
    if type(effectiveFacing) == "number" then
        local dx, dz = diveUtils.compassVector(effectiveFacing)
        forward = activeTiles.traceLine(playerTileX, playerTileZ, dx, dz, SURGE_RANGE)
        backward = activeTiles.traceLine(playerTileX, playerTileZ, -dx, -dz,
            diveUtils.getEscapeDistance())
    end

    -- Grab the dive tile render mode from plugin settings
    local mode = settings.diveMode
    -- edgesMode renders only the outer edges of the tile and no fill
    local edgesMode = mode == "edges"

    -- Hover tile: the Dive destination under the cursor while the Dive cursor is active.
    -- This block of code calculates the angle and tile to fill when in "Hover mode".
    -- "Hover mode" highlights the tile your cursor is on, and shows you the direction
    -- your character will be facing if you dive there.

    -- We set hoverTile to the tile to be highlighted (Just the hovered tile or max distance tile)
    local hoverTile
    if isDiveCursor and not MiniMenu.IsOpen() then
        -- Get mouse hover direction
        -- getHoveredDivePosition() returns an angle when the player's cursor is out of the
        -- 21x21 dive range. Else, it returns a specific dive tile coord.
        local diveResult = diveDirection.getHoveredDivePosition(
            playerTileX, playerTileZ
        )
        -- if an angle was returned, find the furthest reachable tile in that direction
        if diveResult.angle then
            -- turn our angle into tile offsets
            local dx, dz = diveUtils.compassVector(diveResult.angle)

            -- Search backwards for the furthest valid Dive destination.
            for dist = RADIUS, 1, -1 do
                local tile = activeTiles.byOffset[dx * dist][dz * dist]
                if activeTiles.isReachable(tile) then
                    hoverTile = tile
                    break
                end
            end
        else
            -- If a tile was returned, the player is hovering within the 21x21 dive radius
            if diveResult.tile then
                hoverTile = activeTiles.tiles[diveResult.tile:ToPacked()]
            end
        end
    end


    -- show where you would surge after you dive
    local useDiveSurgePreview = settings.surgeFollowsHover and isDiveCursor
    local surgePreview, surgePreviewOutside = {}, {}
    if (useDiveSurgePreview
            and hoverTile
            and activeTiles.isReachable(hoverTile)
            -- should we require surge to be on for this to be on?
            -- should we allow both to be on at the same time?
            and settings.showSurge
        ) then
        local facing = hoverTile.facing
        if facing then
            local dx, dz = diveUtils.compassVector(facing)
            surgePreview, surgePreviewOutside = activeTiles.traceLine(
                hoverTile.coord.x, hoverTile.coord.z, dx, dz, SURGE_RANGE)
        end
    end

    -- the surge line in front of the player currently hides if we decide to
    -- show one at the current dive cursor instead
    local showPlayerSurgePreview = settings.showSurge and not useDiveSurgePreview

    -- Draw Tiles based on forward, backward, reachable sets and visual toggles
    for _, tile in pairs(activeTiles.tiles) do
        local reachable = activeTiles.isReachable(tile)
        local hoverVisible = settings.showHover
            and reachable and tile == hoverTile
        local diveVisible = reachable
            and (
                mode == "all"
                or (mode == "perimeter" and tile.perimeterEdges ~= nil)
            )
        -- Flag for whether to draw arrows
        -- Arrows can render on perimeter tiles even in edges-only mode.
        local diveArrowVisible = diveVisible
            or (edgesMode and tile.perimeterEdges ~= nil)

        local colour
        local shape = geometry.TILE_FULL
        if hoverVisible then
            -- Render hover tile
            colour = settings.hoverColour
        elseif surgePreview[tile] then
            -- render Surge
            colour = settings.surgeColour
        elseif showPlayerSurgePreview and forward[tile] then
            -- render Surge preview
            colour = settings.surgeColour
        elseif settings.showEscape and backward[tile] then
            -- render Escape
            colour = settings.escapeColour
        elseif diveVisible then
            -- render dive tiles
            colour = settings.diveColour
        elseif edgesMode and tile.perimeterEdges ~= nil then
            -- render only the edges bordering the exterior flood-fill region
            colour = settings.diveColour
            shape = tile.perimeterEdges
        end

        instanceDraw.setTile(tile, colour, shape)

        -- render directional arrows
        instanceDraw.setTileArrow(tile,
            settings.showArrows and (diveArrowVisible or hoverVisible))
    end

    -- draw surge preview outside of radius
    for _, point in ipairs(surgePreviewOutside) do
        directDraw.drawTile(point.x, point.z, plane, settings.surgeColour)
    end
end)

-- Create event hookds for RegionCreated and Region Updated
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
-- Unsubscribe from all created events, and save user UI settings to PersistentDB
function PluginShutdown()
    debouncer.flush()
    persist.saveSettings()
    settingsUi.destroy()

    Event.SettingsLayerReady.Unsubscribe("diveOverlaySettings")
    Event.Logic.Unsubscribe("diveOverlayDebounce")
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

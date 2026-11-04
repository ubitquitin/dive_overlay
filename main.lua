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
local uiUtils = require("src/ui_utils")

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
    uiUtils.buildSettings(event.component)
end)


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


-- Data structure to store info on reachable tiles and player direction.
local reach = { tiles = {}, x = nil, z = nil, level = nil, facing = nil }

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

    -- For each tile in the 21x21 area around the player, calculate if diveable
    -- This creates a mask of diveable tiles in the local var.
    -- isDiveable applies the dive algorithm (coded in diveUtils).
    -- It references the collisionManager's current collision data state when doing so.
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

    -- Save off necessary data to data structure.
    -- Swap in one go so Draw never sees a half-built set
    reach = { tiles = tiles, x = coordGrid.x, z = coordGrid.z, level = coordGrid.level, facing = effectiveFacing }
end


-- Subscribe the doTick function to run on server logic event (every tick)
Event.ServerLogic.Subscribe("updateCollision", doTick)


-- Creates an event that runs every frame for drawing valid Dive tiles.
Event.Draw.Subscribe("bladedDiveTiles", function(drawEvent)
    -- Get self
    local self = PlayerList.Self()
    if self == nil then
        diveDirection.clear()
        return
    end
    if reach.x == nil then return end

    -- unpack necessary player renders from data structure
    local playerTileX, playerTileZ, plane, effectiveFacing = reach.x, reach.z, reach.level, reach.facing


    -- diveUtils.traceStraightLine draws a straight line given a dynamic range 
    -- (Surge range being 10 tiles, Escape range depending on weapon attack range)
    -- This block of code takes the player facing direction, and calculates the surge and
    -- escape tiles (forward and backward).
    -- If hidebehind mode is on, tiles behind the player aren't drawn.
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

    -- Grab the dive tile render mode from plugin settings
    local mode = uiUtils.settings.diveMode
    -- edgesMode renders only the outer edges of the tile and no fill
    local edgesMode = mode == "edges"

    -- local variables to capture the outer perimeter of diveable tiles
    local perimeter, exterior

    -- If the render mode is perimeter or outer edge only apply floodFill
    -- to calculate only the outermost set of diveable tiles.
    -- Perimeter holds the tiles, exterior holds the outer edges
    if mode == "perimeter" or edgesMode then
        perimeter, exterior = uiUtils.outerPerimeter(reachable)
    end

    -- Hover tile: the Dive destination under the cursor while the Dive cursor is active.
    -- This block of code calculates the angle and tile to fill when in "Hover mode".
    -- "Hover mode" highlights the tile your cursor is on, and shows you the direction 
    -- your character will be facing if you dive there.

    -- We populate hoverPath with the set of tiles to be highlighted (Just the hovered tile or max distance tile)
    -- We populate hoverOx and hoverOz with the player position if they dove to the hovered tile.
    local hoverPath = {}
    local hoverOX, hoverOZ
    if isDiveCursor and not MiniMenu.IsOpen() then
        -- Get mouse hover direction
        -- getHoveredDivePosition() returns an angle when the player's cursor is out of the
        -- 21x21 dive range. Else, it returns a specific dive tile coord.
        local diveResult = uiUtils.getHoveredDivePosition(
            playerTileX, playerTileZ
        )
        -- if an angle was returned, find the furthest reachable tile in that direction
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
            -- If a tile was returned, the player is hovering within the 21x21 dive radius
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
            -- Flag for whether to draw hover tile
            local hoverVisible = uiUtils.settings.showHover
                and reachable[ox .. "," .. oz] and hoverPath[ox .. "," .. oz]
            -- Flag for whether to draw dive tiles
            local diveVisible = reachable[ox .. "," .. oz]
                and (
                    mode == "all"
                    or (mode == "perimeter"
                        and perimeter ~= nil
                        and perimeter[ox .. "," .. oz])
                )
            -- Flag for whether to draw arrows
            -- Arrows can render on perimeter tiles even in edges-only mode.
            local diveArrowVisible = diveVisible
                or (
                    edgesMode
                    and perimeter ~= nil
                    and perimeter[ox .. "," .. oz]
                )

            -- Render hover tile
            if hoverVisible then
                uiUtils.drawTile(tx, tz, plane, uiUtils.hoverRGBA)
            -- render Surge
            elseif surgePreview[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.surgeRGBA)
            -- render Surge preview
            elseif showPlayerSurgePreview and forward[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.surgeRGBA)
            -- render Escape
            elseif uiUtils.settings.showEscape and backward[key] then
                uiUtils.drawTile(tx, tz, plane, uiUtils.escapeRGBA)
            -- render dive tiles
            elseif diveVisible then
                uiUtils.drawTile(tx, tz, plane, uiUtils.diveRGBA)
            end
            -- render directional arrows
            if uiUtils.settings.showArrows and (diveArrowVisible or hoverVisible) then
                local angle = diveDirection.directionForOffset(ox, oz)
                if angle ~= nil then uiUtils.drawDirectionArrow(tx, tz, plane, angle) end
            end
            -- Draw only the edges bordering the exterior flood-fill region.
            if edgesMode and perimeter[ox .. "," .. oz] then
                uiUtils.drawPerimeterEdges(
                    tx, tz, plane, ox, oz, exterior
                )
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

-- User-facing settings, UI controls, tile rendering, and display filters.
-- Movement and collision decisions deliberately live in other modules.

local debouncer = require("src/debouncer")
local diveUtils = require("src/dive_utils")

local M = {}
local TILE_SIZE = 512
local GROUND_OFFSET = 30

-- UI state; original default colours retained.
local SETTINGS_KEY = "diveOverlaySettings"

local DEFAULT_SETTINGS = {
    diveMode = "all",
    showSurge = true,
    showEscape = true,
    showArrows = false,
    hideBehind = false,
    showHover = true,
    surgeFollowsHover = false,
    diveColour = 0xEBC946FF,
    hoverColour = 0xD70E34FF,
    surgeColour = 0x1266DFFF,
    escapeColour = 0x008000FF,
    edgeOpacity = 29, -- Edge alpha as a percentage of the color picker's alpha
    fillOpacity = 6, -- Fill alpha as a percentage of the color picker's alpha
}

local function loadSettings()
    local saved = PersistentDB:GetStructuredData(SETTINGS_KEY)
    local settings = {}

    for key, default in pairs(DEFAULT_SETTINGS) do
        local value
        if type(saved) == "table" then value = saved[key] end

        if key:match("Colour$") then
            if type(value) == "string"
                and value:match("^%x%x%x%x%x%x%x%x$") then
                value = tonumber(value, 16)
            else
                value = default
            end
        elseif type(value) ~= type(default) then
            value = default
        end

        settings[key] = value
    end

    -- Validate the selected mode.
    if settings.diveMode ~= "all"
        and settings.diveMode ~= "perimeter"
        and settings.diveMode ~= "edges"
        and settings.diveMode ~= "none" then
        settings.diveMode = "all"
    end

    settings.edgeOpacity = math.max(0, math.min(100, settings.edgeOpacity))
    settings.fillOpacity = math.max(0, math.min(100, settings.fillOpacity))

    return settings
end

M.settings = loadSettings()

function M.saveSettings()
    local saved = {}

    for key, value in pairs(M.settings) do
        if key:match("Colour$") then
            saved[key] = string.format("%08X", value)
        else
            saved[key] = value
        end
    end

    PersistentDB:SetStructuredData(SETTINGS_KEY, saved)
end

-- Restores every setting to its default and persists the result.
function M.resetSettings()
    debouncer.cancel("edgeOpacity")
    debouncer.cancel("fillOpacity")

    for key, default in pairs(DEFAULT_SETTINGS) do
        M.settings[key] = default
    end

    M.refreshColours()
    M.saveSettings()
end

-- Helper function that takes the hex input from color pickers and
-- converts it into RGBA values, which are passed directly to drawTile.
--
-- The first four vertices form the tile outline and retain the selected
-- colour and opacity. The last four form the tile fill, whose opacity
-- is reduced to 27% of the selected value so the terrain remains visible.
--
-- The RGB channels are preserved for both the outline and fill.
local function colours(colour)
    -- Picker uses RRGGBBAA. Keep solid outlines and translucent fills.
    local rgb = colour & 0xFFFFFF00
    local alpha = colour & 0xFF

    local edgeAlpha = math.floor(
        alpha * M.settings.edgeOpacity / 100 + 0.5
    )
    local fillAlpha = math.floor(
        alpha * M.settings.fillOpacity / 100 + 0.5
    )

    local edge = rgb | edgeAlpha
    local fill = rgb | fillAlpha

    return {
        edge, edge, edge, edge,
        fill, fill, fill, fill
    }
end

-- Rebuild all overlay colours after opacity changes.
function M.refreshColours()
    M.diveRGBA = colours(M.settings.diveColour)
    M.hoverRGBA = colours(M.settings.hoverColour)
    M.surgeRGBA = colours(M.settings.surgeColour)
    M.escapeRGBA = colours(M.settings.escapeColour)
end

M.refreshColours()

-- Update opacity immediately and persist the selection.
function M.setOpacity(key, value)
    if key ~= "edgeOpacity" and key ~= "fillOpacity" then
        return
    end

    if type(value) ~= "number" then return end

    M.settings[key] = math.max(0, math.min(100, value))

    M.refreshColours()
    M.saveSettings()
end

-- Updates a tile colour and its corresponding drawing vertex colours.
-- Saves the color choice into the settings persistentDB
function M.setColour(kind, value)
    local settingKey = kind .. "Colour"
    local rgbaKey = kind .. "RGBA"

    if M.settings[settingKey] == nil then return end
    if type(value) ~= "number" then return end

    M.settings[settingKey] = value
    M[rgbaKey] = colours(value)

    M.saveSettings()
end

-- Function that is called when the user clicks the open settings button in the plugin settings UI
-- constructs a pretty UI window with toggles for dive overlays, modes and tile color pickers
function M.openSettings()
    -- initialize the prettyUI window
    local uiWindow

    -- creates the prettyUI window
    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    uiWindow = prettyui.Window.new(parent, {
        title = "Dive Overlay Settings",
        x = 800,
        y = 200,
        width = 330,
        height = uiMinimized and 140 or 415,
        resizable = true,
        minWidth = 280,
        minHeight = 140,
        scrollable = true,
    })
    -- Adds the section for Dive Tile Mode
    uiWindow:AddTitle("Dive tiles")
    uiWindow:AddRadioButton({
        { text = "All diveable tiles",   value = "all" },
        { text = "Outer perimeter only", value = "perimeter" },
        { text = "Perimeter edges only", value = "edges" },
        { text = "None",                 value = "none" },
    }, {
        selectedValue = M.settings.diveMode,
        onChange = function(_, value)
            M.settings.diveMode = value
            M.saveSettings()
        end,
    })
    uiWindow:AddCheckboxButton({
        { text = "Hover tile", value = "hover", selected = M.settings.showHover },
    }, {
        onChange = function(_, _, changed, selected)
            if changed ~= "hover" then return end
            M.settings.showHover = selected
            M.saveSettings()
        end,
    })

    -- Adds the section for Overlay tile options
    uiWindow:AddTitle("Overlays")
    uiWindow:AddCheckboxButton({
        { text = "Surge tiles",              value = "surge",             selected = M.settings.showSurge },
        { text = "Escape tiles",             value = "escape",            selected = M.settings.showEscape },
        { text = "Dive facing arrows",       value = "arrows",            selected = M.settings.showArrows },
        { text = "Hide dive tiles behind",   value = "behind",            selected = M.settings.hideBehind },
        { text = "Surge follows Hover Tile", value = "surgeFollowsHover", selected = M.settings.surgeFollowsHover },
    }, {
        onChange = function(_, _, changed, selected)
            if changed == "surge" then
                M.settings.showSurge = selected
            elseif changed == "escape" then
                M.settings.showEscape = selected
            elseif changed == "arrows" then
                M.settings.showArrows = selected
            elseif changed == "behind" then
                M.settings.hideBehind = selected
            elseif changed == "surgeFollowsHover" then
                M.settings.surgeFollowsHover = selected
            else
                return
            end

            M.saveSettings()
        end,
    })
    uiWindow:AddTitle("Tile opacity")

    uiWindow:AddText("Edge opacity (%)")
    uiWindow:AddSlider({
        min = 0,
        max = 100,
        step = 1,
        value = M.settings.edgeOpacity,
        onChange = function(_, value)
            debouncer.debounce("edgeOpacity", 0.2, function()
                M.setOpacity("edgeOpacity", value)
            end)
        end,
    })

    uiWindow:AddText("Fill opacity (%)")
    uiWindow:AddSlider({
        min = 0,
        max = 100,
        step = 1,
        value = M.settings.fillOpacity,
        onChange = function(_, value)
            debouncer.debounce("fillOpacity", 0.2, function()
                M.setOpacity("fillOpacity", value)
            end)
        end,
    })

    -- Adds the section for tile color pickers
    uiWindow:AddTitle("Tile colours")
    uiWindow:AddText("Dive")
    uiWindow:AddColourPicker({
        value = M.settings.diveColour,
        alphaSlider = true,
        windowTitle = "Dive tile colour",
        onChange = function(_, value)
            M.setColour("dive", value)
        end,
    })
    uiWindow:AddText("Hover")
    uiWindow:AddColourPicker({
        value = M.settings.hoverColour,
        alphaSlider = true,
        windowTitle = "Hover tile colour",
        onChange = function(_, value)
            M.setColour("hover", value)
        end,
    })
    uiWindow:AddText("Surge")
    uiWindow:AddColourPicker({
        value = M.settings.surgeColour,
        alphaSlider = true,
        windowTitle = "Surge tile colour",
        onChange = function(_, value)
            M.setColour("surge", value)
        end,
    })
    uiWindow:AddText("Escape")
    uiWindow:AddColourPicker({
        value = M.settings.escapeColour,
        alphaSlider = true,
        windowTitle = "Escape tile colour",
        onChange = function(_, value)
            M.setColour("escape", value)
        end,
    })
end

-- Builds the UI in the actual Jagex Plugin Settings UI.
-- Right now this is just a button that opens up the PrettyUI window when clicked
function M.buildSettings(parent)
    local button = ui.Button.new(parent)
    button.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    button.label = "Open Settings"
    button:SetPos(12, 20)
    button:SetSize(200, 36)

    button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        M.openSettings()
    end)
end

-- Vertex indices used by ShapeList.Draw when rendering a tile.
-- 'lines' connects the first four vertices into a square outline.
-- 'tris' connects the last four vertices into two triangles for the fill.
local lines = { 0, 1, 1, 2, 2, 3, 3, 0 }
local tris = { 4, 5, 6, 4, 6, 7 }


-- Retrieves the terrain height at a specific world position and plane.
-- Based on https://github.com/PrettyRS/tilemarkers/blob/main/src/draw.lua
--
-- Used by tileCorners() and createArrowInstance() to position overlay
-- graphics above the actual ground instead of using the player's height.
-- Returns nil if the terrain height is unavailable or the API fails.
local function groundHeight(plane, worldX, worldZ)
    if not World or not World.GetGroundHeight then return nil end
    local ok, height, available = pcall(World.GetGroundHeight, plane, worldX, worldZ)
    if not ok or available ~= true or type(height) ~= "number" then return nil end
    return height
end

-- Constructs the eight vertices used to draw a tile overlay.
--
-- Based on https://github.com/PrettyRS/tilemarkers/blob/main/src/draw.lua
--
-- RuneScape tile coordinates are converted into world positions using
-- TILE_SIZE (512 world units per tile). We sample the terrain height
-- independently at each of the tile's four corners so the overlay
-- follows sloped or uneven ground.
--
-- Returns eight vertices relative to the tile's center:
--   1-4: Corners of the square outline (SW, SE, NE, NW).
--   5-8: Corners of the filled square (SW, SE, NE, NW).
--
-- GROUND_OFFSET raises the overlay slightly above the terrain.
-- The outline is raised one additional unit above the fill.
-- Sampling stops just inside the tile boundary to avoid accidentally
-- reading terrain from a neighboring tile.
--
-- Returns nil if any of the four terrain heights are unavailable.
local function tileCorners(x, z, plane)
    local x0, z0 = x * TILE_SIZE, z * TILE_SIZE
    local x1, z1 = x0 + TILE_SIZE - 1, z0 + TILE_SIZE - 1
    local sw = groundHeight(plane, x0, z0)
    local se = groundHeight(plane, x1, z0)
    local ne = groundHeight(plane, x1, z1)
    local nw = groundHeight(plane, x0, z1)
    if not (sw and se and ne and nw) then return nil end
    local bias = GROUND_OFFSET
    local outlineBias = bias + 1
    return {
        Vector3.new(-250, sw + outlineBias, -250),
        Vector3.new(250, se + outlineBias, -250),
        Vector3.new(250, ne + outlineBias, 250),
        Vector3.new(-250, nw + outlineBias, 250),
        Vector3.new(-250, sw + bias, -250),
        Vector3.new(250, se + bias, -250),
        Vector3.new(250, ne + bias, 250),
        Vector3.new(-250, nw + bias, 250),
    }
end


-- Draws a coloured tile overlay at the specified world tile coordinate.
--
-- Based on https://github.com/PrettyRS/tilemarkers/blob/main/src/draw.lua
--
-- main.lua calls this for tiles that should be highlighted as reachable
-- by Dive, Surge, or Escape, passing the corresponding colour array.
--
-- tileCorners() generates terrain-following geometry, and ShapeList.Draw
-- renders its outline and translucent fill at the tile's world position.
function M.drawTile(x, z, plane, colors)
    local shapePositions = tileCorners(x, z, plane)
    if not shapePositions then return end
    ShapeList.Draw {
        shapePositions = shapePositions,
        shapeRGBA = colors,
        shapeLines = lines,
        shapeTris = tris,
        translation = Vector3.new(x * TILE_SIZE + TILE_SIZE / 2, 0, z * TILE_SIZE + TILE_SIZE / 2),
        ignoreDepth = true,
        lineWidth = 3
    }
end

-- TILE INSTANCES
-- Rendering for active tile records (see active_tiles.lua). Each record
-- gets an instance the first time it is shown, kept until active_tiles
-- drops the record. Its shape data is white with the edge and fill
-- opacity as vertex alpha; instance.colour supplies the colour.
--
-- Instances released by dropped records go back to a pool and are reused
-- for tiles entering range. This keeps the number of instances the plugin
-- creates bounded, which keeps the client's cleanup on unload fast.
local tilePool, arrowPool = {}, {}
local instanceCount = 0

-- Takes a hidden instance from the pool, or creates a new one.
local function takeInstance(pool, prefix)
    while #pool > 0 do
        local instance = table.remove(pool)
        if instance.isValid then return instance end
    end

    instanceCount = instanceCount + 1
    local name = prefix .. instanceCount
    local instance = ShapeList.CreateInstance(name) or ShapeList.GetInstance(name)
    if not instance then return nil end
    instance.ignoreDepth = true
    instance.lineWidth = 3
    instance.visible = false
    return instance
end

-- Hides an instance and returns it to the pool. Invalid instances are dropped.
local function releaseInstance(pool, instance)
    if instance and instance.isValid then
        instance.visible = false
        pool[#pool + 1] = instance
    end
end

-- Tile shapes are a bitmask of outline edges plus the fill.
-- Edge bits follow the outline vertex order: S (SW->SE), E, N, W.
local EDGE_LINES = { { 0, 1 }, { 1, 2 }, { 2, 3 }, { 3, 0 } }
local TILE_FILL = 16
M.TILE_FULL = 15 | TILE_FILL

-- Builds a tile's shape data from its tileCorners: the outline edges in
-- the shape's mask, plus the fill triangles if it has the fill bit. Vertex
-- colours are white with the edge or fill opacity as alpha, which
-- instance.colour is multiplied against.
local function tileShapeData(corners, shape, edgeOpacity, fillOpacity)
    local edge = 0xFFFFFF00 | math.floor(255 * edgeOpacity / 100 + 0.5)
    local fill = 0xFFFFFF00 | math.floor(255 * fillOpacity / 100 + 0.5)

    local shapeLines = {}
    for i, line in ipairs(EDGE_LINES) do
        if shape & (1 << (i - 1)) ~= 0 then
            shapeLines[#shapeLines + 1] = line[1]
            shapeLines[#shapeLines + 1] = line[2]
        end
    end

    local data = ShapeData.new()
    data.positions = corners
    data.rgba = { edge, edge, edge, edge, fill, fill, fill, fill }
    data.lines = shapeLines
    data.tris = (shape & TILE_FILL ~= 0) and tris or {}
    return data
end

-- Gives the tile an instance from the pool, placed at the tile. Its shape
-- data is set in setTile, since the tile's shape starts unset. Returns
-- false if the ground height isn't available yet, so the caller can retry
-- on a later frame.
local function createTileInstance(tile)
    local coord = tile.coord
    tile.corners = tile.corners or tileCorners(coord.x, coord.z, coord.level)
    if not tile.corners then return false end

    local instance = takeInstance(tilePool, "diveTile:")
    if not instance then return false end

    instance.translation = Vector3.new(coord.x * TILE_SIZE + TILE_SIZE / 2, 0, coord.z * TILE_SIZE + TILE_SIZE / 2)
    tile.instance = instance
    return true
end

-- Shows the instance in the given colour, or hides it when colour is nil.
-- Returns the colour so the tile can remember what was applied.
local function applyColour(instance, current, colour)
    if current == colour then return current end
    instance.visible = colour ~= nil
    if colour ~= nil then instance.colour = colour end
    return colour
end

-- Dive facing arrow pointing north (compass 0). Each arrow instance is
-- rotated to the direction the player would face after Diving to its tile.
local arrowData
local function arrowShapeData()
    if arrowData then return arrowData end
    local len, wing = 165, 85
    arrowData = ShapeData.new()
    arrowData.positions = {
        Vector3.new(0, 0, -len * 0.38),
        Vector3.new(0, 0, len * 0.62),
        Vector3.new(wing, 0, len * 0.18),
        Vector3.new(0, 0, len * 0.62),
        Vector3.new(-wing, 0, len * 0.18),
    }
    arrowData.rgba = { 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF }
    arrowData.lines = { 0, 1, 2, 3, 3, 4 }
    return arrowData
end

-- Converts compass degrees into the instance's yaw rotation.
local function arrowRotation(angle)
    return Vector3.new(angle, 0, 0)
end

-- The arrow sits above the terrain at the tile's centre.
local function createArrowInstance(tile)
    local coord = tile.coord
    local centreX = coord.x * TILE_SIZE + TILE_SIZE / 2
    local centreZ = coord.z * TILE_SIZE + TILE_SIZE / 2
    local y = groundHeight(coord.level, centreX, centreZ)
    if not y then return nil end

    -- Pooled arrows already have the arrow shape; new ones need it set once.
    local instance = takeInstance(arrowPool, "diveArrow:")
    if not instance then return nil end
    if not instance.hasData and not instance:SetShapeData(arrowShapeData()) then
        releaseInstance(arrowPool, instance)
        return nil
    end

    instance.translation = Vector3.new(centreX, y + 125, centreZ)
    return instance
end

-- Returns the tile's instances to the pool. Called when active_tiles drops
-- the record.
function M.releaseTile(tile)
    releaseInstance(tilePool, tile.instance)
    releaseInstance(arrowPool, tile.arrow)
    tile.instance, tile.arrow = nil, nil
end

-- Hides the tile and its arrow.
function M.hideTile(tile)
    M.setTile(tile, nil)
    M.setTileArrow(tile, false)
end

-- Shows the tile in the given RRGGBBAA picker colour and shape (M.TILE_FULL
-- or an edge mask from tile.perimeterEdges), or hides it when colour is nil.
-- The shape data is rebuilt when the shape or the edge or fill opacity
-- setting differs from what it was built with; the instance is otherwise
-- only touched when its colour changes.
function M.setTile(tile, colour, shape)
    -- The client can invalidate instances on its own; take a new one if so.
    if tile.instance and not tile.instance.isValid then
        tile.instance, tile.colour, tile.shape = nil, nil, nil
    end

    if not tile.instance then
        if colour == nil or not createTileInstance(tile) then return end
    end

    local edgeOpacity, fillOpacity = M.settings.edgeOpacity, M.settings.fillOpacity
    if colour ~= nil and (tile.shape ~= shape
            or tile.edgeOpacity ~= edgeOpacity or tile.fillOpacity ~= fillOpacity) then
        local data = tileShapeData(tile.corners, shape, edgeOpacity, fillOpacity)
        if not tile.instance:SetShapeData(data) then return end
        tile.shape, tile.edgeOpacity, tile.fillOpacity = shape, edgeOpacity, fillOpacity
    end

    tile.colour = applyColour(tile.instance, tile.colour, colour)
end

-- Shows or hides the tile's Dive facing arrow, pointed along tile.facing.
-- The arrow is created the first time it is shown and stays hidden when
-- the tile has no facing.
function M.setTileArrow(tile, show)
    -- The client can invalidate instances on its own; recreate it if so.
    if tile.arrow and not tile.arrow.isValid then
        tile.arrow, tile.arrowAngle, tile.arrowVisible = nil, nil, nil
    end

    if not show and not tile.arrow then return end

    if not tile.arrow then
        tile.arrow = createArrowInstance(tile)
        if not tile.arrow then return end
    end

    if tile.arrowAngle ~= tile.facing then
        tile.arrowAngle = tile.facing
        if tile.facing ~= nil then tile.arrow.rotation = arrowRotation(tile.facing) end
    end

    show = show and tile.facing ~= nil or false
    if tile.arrowVisible == show then return end
    tile.arrowVisible = show
    tile.arrow.visible = show
end

-- DONT LOOK BACK MODE UTILITY
-- Determines whether a Dive tile is in front of the player, for the
-- "Hide dive tiles behind" setting.
--
-- main.lua supplies an active tile record (its offset from the player is
-- tile.ox, tile.oz) and the player's facing in compass degrees, which is
-- converted to a compass vector (facingX, facingZ).
--
-- The dot product measures whether the tile lies in front of the player:
--   Positive: Tile is in front of the player.
--   Negative: Tile is behind the player.
--   Zero: Tile is perpendicular to the player's facing direction.
--
-- Tiles in the forward-facing half-plane (including perpendicular tiles)
-- count as in front.
function M.isTileInFront(tile, facing)
    local facingX, facingZ = diveUtils.compassVector(facing)
    return tile.ox * facingX + tile.oz * facingZ >= 0
end

-- dive seems to have 2 distinct modes:
-- 1. if within 10 tiles, it goes towards a tile directly
-- 2. if outside of 10 tiles, it snaps to the 8 octilinear directions
--    (N, NE, E, etc.)
-- mode 1 returns a tile, mode 2 returns an angle
function M.getHoveredDivePosition(playerX, playerZ)
    local mousePos = Mouse.GetPosition()
    local mouseTile = mousePos and ScreenConvert.ScreenToCoordGrid(mousePos)
    if not mouseTile then return {} end

    local dx = mouseTile.x - playerX
    local dz = mouseTile.z - playerZ

    -- Grid distance: diagonal steps count as one tile
    if math.max(math.abs(dx), math.abs(dz)) <= 10 then
        return { tile = mouseTile }
    end

    local angle = math.deg(math.atan(dx, dz)) % 360
    return { angle = math.floor(angle / 45 + 0.5) * 45 % 360 }
end

return M

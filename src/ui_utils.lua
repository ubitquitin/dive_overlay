-- User-facing settings, UI controls, tile rendering, and display filters.
-- Movement and collision decisions deliberately live in other modules.
local M = {}
local TILE_SIZE = 512
local RADIUS = 10
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
        { text = "All diveable tiles",    value = "all" },
        { text = "Outer perimeter only",  value = "perimeter" },
        { text = "Perimeter edges only",  value = "edges" },
        { text = "None",                  value = "none" },
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
            M.setOpacity("edgeOpacity", value)
        end,
    })

    uiWindow:AddText("Fill opacity (%)")
    uiWindow:AddSlider({
        min = 0,
        max = 100,
        step = 1,
        value = M.settings.fillOpacity,
        onChange = function(_, value)
            M.setOpacity("fillOpacity", value)
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
local lines = {0,1,1,2,2,3,3,0}
local tris = {4,5,6,4,6,7}


-- Retrieves the terrain height at a specific world position and plane.
-- Based on https://github.com/PrettyRS/tilemarkers/blob/main/src/draw.lua
-- 
-- Used by tileCorners() and drawDirectionArrow() to position overlay
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
    ShapeList.Draw{
        shapePositions = shapePositions,
        shapeRGBA = colors,
        shapeLines = lines,
        shapeTris = tris,
        translation = Vector3.new(x*TILE_SIZE + TILE_SIZE/2, 0, z*TILE_SIZE + TILE_SIZE/2),
        ignoreDepth = true,
        lineWidth = 3
    }
end


-- Draw only tile edges touching the exterior flood-filled region.
-- Does not draw fills, internal edges, or edges around enclosed holes.
function M.drawPerimeterEdges(x, z, plane, ox, oz, exterior)
    local function key(dx, dz)
        return dx .. "," .. dz
    end

    -- tileCorners returns SW, SE, NE, NW as its first four vertices.
    local corners = tileCorners(x, z, plane)
    if not corners then return end

    local edgeLines = {}

    -- South: SW -> SE
    if exterior[key(ox, oz - 1)] then
        edgeLines[#edgeLines + 1] = 0
        edgeLines[#edgeLines + 1] = 1
    end

    -- East: SE -> NE
    if exterior[key(ox + 1, oz)] then
        edgeLines[#edgeLines + 1] = 1
        edgeLines[#edgeLines + 1] = 2
    end

    -- North: NE -> NW
    if exterior[key(ox, oz + 1)] then
        edgeLines[#edgeLines + 1] = 2
        edgeLines[#edgeLines + 1] = 3
    end

    -- West: NW -> SW
    if exterior[key(ox - 1, oz)] then
        edgeLines[#edgeLines + 1] = 3
        edgeLines[#edgeLines + 1] = 0
    end

    if #edgeLines == 0 then return end

    ShapeList.Draw{
        shapePositions = {
            corners[1], corners[2], corners[3], corners[4]
        },
        shapeRGBA = {
            M.diveRGBA[1], M.diveRGBA[2],
            M.diveRGBA[3], M.diveRGBA[4]
        },
        shapeLines = edgeLines,
        translation = Vector3.new(
            x * TILE_SIZE + TILE_SIZE / 2,
            0,
            z * TILE_SIZE + TILE_SIZE / 2
        ),
        ignoreDepth = true,
        lineWidth = 3,
    }
end

-- Draws an arrow showing the direction the player would face after
-- Diving to a particular tile.
--
-- main.lua uses dive_direction.directionForOffset() to determine the
-- expected facing angle for each Dive destination, then passes that
-- angle to this function when "Dive facing arrows" is enabled.
--
-- The angle is converted into a forward direction (fx, fz) and a
-- perpendicular sideways direction (rx, rz). These vectors are used
-- to construct the arrow's shaft and two arrowhead wings.
--
-- The arrow is positioned above the terrain at the tile's center.
function M.drawDirectionArrow(x, z, plane, angle)
    local centreX = x * TILE_SIZE + TILE_SIZE / 2
    local centreZ = z * TILE_SIZE + TILE_SIZE / 2
    local y = groundHeight(plane, centreX, centreZ)
    if not y then return end
    local radians = math.rad(angle)
    local fx, fz = math.sin(radians), math.cos(radians)
    local rx, rz = fz, -fx
    local len, wing = 165, 85
    local arrowPoints = {
        Vector3.new(-fx * len * 0.38, 0, -fz * len * 0.38),
        Vector3.new(fx * len * 0.62, 0, fz * len * 0.62),
        Vector3.new(fx * len * 0.18 + rx * wing, 0, fz * len * 0.18 + rz * wing),
        Vector3.new(fx * len * 0.62, 0, fz * len * 0.62),
        Vector3.new(fx * len * 0.18 - rx * wing, 0, fz * len * 0.18 - rz * wing),
    }
    ShapeList.Draw{
        shapePositions = arrowPoints,
        shapeRGBA = {0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF,0xFFFFFFFF},
        shapeLines = {0,1,2,3,3,4},
        translation = Vector3.new(x*TILE_SIZE + TILE_SIZE/2, y + 125, z*TILE_SIZE + TILE_SIZE/2),
        ignoreDepth = true,
        lineWidth = 3,
    }
end


-- DONT LOOK BACK MODE UTILITY
-- Determines whether a Dive tile should be displayed based on the
-- player's facing direction and the "Hide dive tiles behind" setting.
--
-- main.lua supplies the tile's relative offset (dx, dz) and the player's
-- facing direction as a compass vector (facingX, facingZ).
--
-- The dot product measures whether the tile lies in front of the player:
--   Positive: Tile is in front of the player.
--   Negative: Tile is behind the player.
--   Zero: Tile is perpendicular to the player's facing direction.
--
-- When Hide Behind is enabled, only tiles in the forward-facing half-plane
-- (including perpendicular tiles) are displayed.
-- If disabled or facing is unavailable, all tiles pass the filter.
function M.isTileInFront(dx, dz, facingX, facingZ)
    if not M.settings.hideBehind or facingX == nil then
        return true
    end

    return dx * facingX + dz * facingZ >= 0
end


-- PERIMETER ONLY MODE UTILITY
-- Filters a set of reachable Dive tiles to only its OUTER perimeter.
--
-- Used when the user selects "Outer perimeter only" in the settings.
-- main.lua supplies the reachable tiles as a set of relative coordinates
-- keyed by "dx,dz", where (0,0) represents the player's tile.
--
-- To distinguish the outside boundary from internal holes, we:
-- 1. Start outside the 10-tile search area.
-- 2. Flood-fill through tiles that are NOT reachable by Dive.
-- 3. Mark all unreachable tiles connected to the outside.
-- 4. Keep only reachable tiles that border this exterior area.
--
-- Unreachable pockets completely enclosed by reachable tiles are not
-- connected to the outside, so their edges are excluded.
--
-- Returns a new set containing only the outer perimeter tiles.
function M.outerPerimeter(reachable)
    local exterior, queue = {}, {}

    -- Converts relative tile coordinates into the string key format
    -- used by the reachable and exterior tile sets.
    local function key(x,z) return x .. "," .. z end

    -- Adds an unreachable tile to the flood-fill queue if it is within
    -- the search boundary and has not already been visited.
    -- Reachable tiles act as barriers that the flood fill cannot cross.
    local function enqueue(x,z)
        if x < -RADIUS-1 or x > RADIUS+1
            or z < -RADIUS-1 or z > RADIUS+1 then return end
        local k = key(x,z)
        if exterior[k] or reachable[k] then return end
        exterior[k] = true
        queue[#queue+1] = {x,z}
    end

    -- initial outer tile to start from
    enqueue(-RADIUS-1, -RADIUS-1)
    -- Explore all unreachable tiles connected to the outside.
    -- The queue grows as neighboring tiles are discovered.
    local head = 1
    while head <= #queue do
        local node = queue[head]
        head = head + 1
        local x,z = node[1],node[2]
        enqueue(x+1,z)
        enqueue(x-1,z)
        enqueue(x,z+1)
        enqueue(x,z-1)
    end
    -- Find reachable tiles adjacent to the exterior region.
    -- These tiles form the visible outer boundary of the Dive area.
    local border = {}
    for dx = -RADIUS,RADIUS do
        for dz = -RADIUS,RADIUS do
            local k = key(dx,dz)
            if reachable[k] and (
                exterior[key(dx+1,dz)] or exterior[key(dx-1,dz)]
                or exterior[key(dx,dz+1)] or exterior[key(dx,dz-1)]
            ) then border[k] = true end
        end
    end
    return border, exterior
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

-- Rendering for active tile records (see active_tiles.lua) with
-- ShapeInstances.

local geometry = require("src/tile/geometry")
local instancePool = require("src/tile/instance_pool")
local persist = require("src/settings/persist")

local M = {}

-- Create and re-use a fixed "pool" of ShapeInstances for better performance
local tilePool = instancePool.new("diveTile:")
local arrowPool = instancePool.new("diveArrow:")

-- Create a ShapeData for a tile following the current preferences.
-- shape is a geometry tile shape bitmask (see geometry.lua).
local function tileShapeData(corners, shape, edgeOpacity, fillOpacity)
    -- mix the current opacity into the shape data RGBA, to be multiplied by
    -- the chosen color for each tile type (surge, escape, dive, hover) later
    local edge = 0xFFFFFF00 | math.floor(255 * edgeOpacity / 100 + 0.5)
    local fill = 0xFFFFFF00 | math.floor(255 * fillOpacity / 100 + 0.5)

    local data = ShapeData.new()
    data.positions = corners
    data.rgba = { edge, edge, edge, edge, fill, fill, fill, fill }
    data.lines = geometry.shapeLines(shape)
    data.tris = geometry.shapeTris(shape)
    return data
end

-- Attach a ShapeInstance from the pool and information about the tile coord
-- to the passed-in active_tile reference
local function createTileInstance(tile)
    local coord = tile.coord
    tile.corners = tile.corners or geometry.tileCorners(coord.x, coord.z, coord.level)
    if not tile.corners then return false end

    local instance = tilePool:take()
    if not instance then return false end

    local centreX, centreZ = geometry.tileCentre(coord.x, coord.z)
    instance.translation = Vector3.new(centreX, 0, centreZ)
    tile.instance = instance
    return true
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
    local centreX, centreZ = geometry.tileCentre(coord.x, coord.z)
    local y = geometry.groundHeight(coord.level, centreX, centreZ)
    if not y then return nil end

    -- Pooled arrows already have the arrow shape; new ones need it set once.
    local instance = arrowPool:take()
    if not instance then return nil end
    if not instance.hasData and not instance:SetShapeData(arrowShapeData()) then
        arrowPool:release(instance)
        return nil
    end

    instance.translation = Vector3.new(centreX, y + 125, centreZ)
    return instance
end

-- Returns the tile's instances to the pool. Called when active_tiles drops
-- the record.
function M.releaseTile(tile)
    tilePool:release(tile.instance)
    arrowPool:release(tile.arrow)
    tile.instance, tile.arrow = nil, nil
end

-- Hides the tile and its arrow.
function M.hideTile(tile)
    M.setTile(tile, nil)
    M.setTileArrow(tile, false)
end

-- Request that the given tile be rendered using the colour/shape passed
function M.setTile(tile, colour, shape)
    -- The client can invalidate instances on its own; take a new one if so.
    if tile.instance and not tile.instance.isValid then
        tile.instance, tile.colour, tile.shape = nil, nil, nil
    end

    if not tile.instance then
        if colour == nil or not createTileInstance(tile) then return end
    end

    -- Only set tile shape data if the tile changed
    local edgeOpacity, fillOpacity = persist.settings.edgeOpacity, persist.settings.fillOpacity
    if colour ~= nil and (
            tile.shape ~= shape or
            tile.edgeOpacity ~= edgeOpacity or
            tile.fillOpacity ~= fillOpacity
        ) then
        local data = tileShapeData(tile.corners, shape, edgeOpacity, fillOpacity)
        if not tile.instance:SetShapeData(data) then return end
        tile.shape, tile.edgeOpacity, tile.fillOpacity = shape, edgeOpacity, fillOpacity
    end

    -- Only set tile colour if it has changed (tile is now in surge/escape path,
    -- or is no longer reachable with dive, or the color preferences just changed)
    if tile.colour == colour then return end
    tile.instance.visible = colour ~= nil
    if colour ~= nil then tile.instance.colour = colour end
    tile.colour = colour
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

return M

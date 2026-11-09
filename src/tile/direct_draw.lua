-- Immediate-mode tile drawing with ShapeList.Draw, for tiles outside the
-- active tile set (which are rendered with instances by instance_draw).

local geometry = require("src/tile/geometry")
local persist = require("src/settings/persist")

local M = {}

local LINES = geometry.shapeLines(geometry.TILE_FULL)
local TRIS = geometry.shapeTris(geometry.TILE_FULL)

-- Per-vertex colours for an RRGGBBAA picker colour: the RGB is kept, and
-- the alpha is scaled by the edge opacity for the outline vertices and the
-- fill opacity for the fill vertices.
local function vertexColours(colour)
    local settings = persist.settings
    local rgb = colour & 0xFFFFFF00
    local alpha = colour & 0xFF
    local edge = rgb | math.floor(alpha * settings.edgeOpacity / 100 + 0.5)
    local fill = rgb | math.floor(alpha * settings.fillOpacity / 100 + 0.5)
    return { edge, edge, edge, edge, fill, fill, fill, fill }
end

-- Draws a tile outline and fill this frame in an RRGGBBAA picker colour.
function M.drawTile(x, z, plane, colour)
    local shapePositions = geometry.tileCorners(x, z, plane)
    if not shapePositions then return end
    local centreX, centreZ = geometry.tileCentre(x, z)
    ShapeList.Draw {
        shapePositions = shapePositions,
        shapeRGBA = vertexColours(colour),
        shapeLines = LINES,
        shapeTris = TRIS,
        translation = Vector3.new(centreX, 0, centreZ),
        ignoreDepth = true,
        lineWidth = 3
    }
end

return M

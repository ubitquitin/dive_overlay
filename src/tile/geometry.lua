-- Tile geometry shared by the tile renderers: world positions,
-- terrain-following corner vertices, and tile shapes.
-- Based on https://github.com/PrettyRS/tilemarkers/blob/main/src/draw.lua

local M = {}

M.TILE_SIZE = 512 -- World units per tile

-- Raises overlays slightly above the terrain.
local GROUND_OFFSET = 30

-- Tile shapes are a bitmask of outline edges plus the fill. Corners are
-- the outline vertex indices, north is up:
--
--          N (4)
--      3 --------- 2
--      |           |
--  W (8)  fill (16)  E (2)
--      |           |
--      0 --------- 1
--          S (1)
M.EDGE_S = 1
M.EDGE_E = 2
M.EDGE_N = 4
M.EDGE_W = 8
M.FILL = 16

-- All four edges plus the fill: 31
M.TILE_FULL = M.EDGE_S | M.EDGE_E | M.EDGE_N | M.EDGE_W | M.FILL

-- The outline vertex pair for each edge bit.
local EDGES = {
    { bit = M.EDGE_S, from = 0, to = 1 },
    { bit = M.EDGE_E, from = 1, to = 2 },
    { bit = M.EDGE_N, from = 2, to = 3 },
    { bit = M.EDGE_W, from = 3, to = 0 },
}

-- Line vertex indices for the edges in a shape.
function M.shapeLines(shape)
    local lines = {}
    for _, edge in ipairs(EDGES) do
        if shape & edge.bit ~= 0 then
            lines[#lines + 1] = edge.from
            lines[#lines + 1] = edge.to
        end
    end
    return lines
end

-- Vertex indices of the two fill triangles, over corner vertices 5-8.
local TRIS = { 4, 5, 6, 4, 6, 7 }
local NO_TRIS = {}

-- Triangle vertex indices for a shape: the fill triangles if it has the
-- fill bit, otherwise none. The returned table is shared; don't modify it.
function M.shapeTris(shape)
    if shape & M.FILL ~= 0 then
        return TRIS
    else
        return NO_TRIS
    end
end

-- World position of a tile's centre on the X and Z axes.
function M.tileCentre(x, z)
    local half = M.TILE_SIZE / 2
    return x * M.TILE_SIZE + half, z * M.TILE_SIZE + half
end

-- Terrain height at a world position and plane, or nil if unavailable.
function M.groundHeight(plane, worldX, worldZ)
    if not World or not World.GetGroundHeight then return nil end
    local ok, height, available = pcall(World.GetGroundHeight, plane, worldX, worldZ)
    if not ok or available ~= true or type(height) ~= "number" then return nil end
    return height
end

-- Eight vertices for a tile overlay, relative to the tile's centre:
--   1-4: Corners of the square outline (SW, SE, NE, NW).
--   5-8: Corners of the filled square (SW, SE, NE, NW).
--
-- Terrain height is sampled independently at each corner so the overlay
-- follows sloped ground. Sampling stops just inside the tile boundary to
-- avoid reading a neighbouring tile. The outline sits one unit above the
-- fill.
--
-- Returns nil if any of the four terrain heights are unavailable.
function M.tileCorners(x, z, plane)
    local x0, z0 = x * M.TILE_SIZE, z * M.TILE_SIZE
    local x1, z1 = x0 + M.TILE_SIZE - 1, z0 + M.TILE_SIZE - 1
    local sw = M.groundHeight(plane, x0, z0)
    local se = M.groundHeight(plane, x1, z0)
    local ne = M.groundHeight(plane, x1, z1)
    local nw = M.groundHeight(plane, x0, z1)
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

return M

-- Active tiles: one record per world tile within RADIUS of the player.
--
-- Records are keyed by CoordGrid:ToPacked() in M.tiles, and also reachable
-- by their offset from the player through M.byOffset[ox][oz]. doTick owns
-- the lifecycle: sync() runs once per tick, before the tick's data is
-- written into the records.
--
-- Record fields:
--   coord, key           CoordGrid and its packed value (set once)
--   corners              ground geometry, filled in by instance_draw when first drawn
--   ox, oz, facing       offset from the player and the facing after Diving
--                        there (updated on sync)
--   isDiveable           whether Dive can reach the tile (per tick)
--   isBehind             hidden by Hide Behind (per tick / setting change)
--   perimeterEdges       edge mask if on the outer perimeter, else nil
--   instance, arrow      ShapeInstances and their applied state (instance_draw)
local diveDirection = require("src/dive_direction")
local diveUtils = require("src/dive_utils")
local geometry = require("src/tile/geometry")
local instanceDraw = require("src/tile/instance_draw")

local M = {}
local RADIUS = 10

M.tiles = {}
M.byOffset = {}

local centreX, centreZ, centreLevel

local function newRecord(x, z, level)
    local coord = CoordGrid.new(level, x // 64, z // 64, x % 64, z % 64)
    return { coord = coord, key = coord:ToPacked() }
end

-- Re-centres the active set on the given CoordGrid. Tiles still in range
-- keep their records and instances, tiles that left range are dropped and
-- their instances returned to the pool, and tiles that entered range get
-- new records.
-- Only does work when the centre changes.
function M.sync(coordGrid)
    local x, z, level = coordGrid.x, coordGrid.z, coordGrid.level
    if x == centreX and z == centreZ and level == centreLevel then return end
    centreX, centreZ, centreLevel = x, z, level

    local old = M.tiles
    local tiles, byOffset = {}, {}
    for ox = -RADIUS, RADIUS do
        local column = {}
        byOffset[ox] = column
        for oz = -RADIUS, RADIUS do
            local tile = newRecord(x + ox, z + oz, level)
            local existing = old[tile.key]
            if existing then
                old[tile.key] = nil
                tile = existing
            end
            tile.ox, tile.oz = ox, oz
            tile.facing = diveDirection.directionForOffset(ox, oz)
            tiles[tile.key] = tile
            column[oz] = tile
        end
    end

    for _, tile in pairs(old) do
        instanceDraw.releaseTile(tile)
    end

    M.tiles, M.byOffset = tiles, byOffset
end

-- Whether Dive can reach the tile after the Hide Behind filter.
function M.isReachable(tile)
    return tile.isDiveable and not tile.isBehind
end

-- The record for a world tile, or nil if it is outside the active range.
function M.at(x, z)
    if centreX == nil then return nil end
    local column = M.byOffset[x - centreX]
    return column and column[z - centreZ]
end

-- Finds reachable tiles along a straight compass direction for Surge/Escape.
--
-- startX, startZ: World tile the line starts from (the player, or the
-- hover tile for the surge-after-dive preview).
-- dx, dz: Direction vector from compassVector(), each component -1, 0, or 1.
-- maxRange: Maximum number of tiles to examine in the given direction.
--
-- Every destination is checked on its own with isDiveable(). A failed
-- destination does not stop the search, because a farther destination may
-- still pass the Dive path simulation.
--
-- Returns a set of the active tile records on the line (record -> true),
-- and a list of { x = tx, z = tz } world coordinates for destinations
-- outside the active range, so they can still be drawn.
function M.traceLine(startX, startZ, dx, dz, maxRange)
    local onLine, outside = {}, {}

    for distance = 1, maxRange do
        local tx, tz = startX + dx * distance, startZ + dz * distance

        if diveUtils.isDiveable(startX, startZ, tx, tz, centreLevel) then
            local tile = M.at(tx, tz)
            if tile then
                onLine[tile] = true
            else
                outside[#outside + 1] = { x = tx, z = tz }
            end
        end
    end

    return onLine, outside
end

-- PERIMETER ONLY MODE UTILITY
-- Sets perimeterEdges on the reachable tiles that form the OUTER perimeter
-- of the reachable area. Callers clear perimeterEdges first.
--
-- Used when the user selects "Outer perimeter only" or the edges-only mode.
--
-- To distinguish the outside boundary from internal holes, we:
-- 1. Start outside the 10-tile search area.
-- 2. Flood-fill through tiles that are NOT reachable by Dive.
-- 3. Mark all unreachable tiles connected to the outside.
-- 4. Keep only reachable tiles that border this exterior area, recording
--    which of their sides touch it as a geometry edge mask (EDGE_S etc.).
--
-- Unreachable pockets completely enclosed by reachable tiles are not
-- connected to the outside, so their edges are excluded.
local OUTER = RADIUS + 1

function M.applyPerimeter()
    -- exterior[ox][oz] is true for flood-filled cells, one ring wider than
    -- the active range so the fill can surround it.
    local exterior = {}
    for ox = -OUTER, OUTER do exterior[ox] = {} end

    -- Adds an unreachable cell to the flood-fill queue if it is within
    -- the search boundary and has not already been visited.
    -- Reachable tiles act as barriers that the flood fill cannot cross.
    -- The queue holds offset pairs: ox at odd indices, oz at even.
    local queue = {}
    local function enqueue(ox, oz)
        if ox < -OUTER or ox > OUTER or oz < -OUTER or oz > OUTER then return end
        if exterior[ox][oz] then return end
        local column = M.byOffset[ox]
        local tile = column and column[oz]
        if tile and M.isReachable(tile) then return end
        exterior[ox][oz] = true
        queue[#queue + 1] = ox
        queue[#queue + 1] = oz
    end

    -- initial outer cell to start from
    enqueue(-OUTER, -OUTER)
    -- Explore all unreachable cells connected to the outside.
    -- The queue grows as neighboring cells are discovered.
    local head = 1
    while head < #queue do
        local ox, oz = queue[head], queue[head + 1]
        head = head + 2
        enqueue(ox + 1, oz)
        enqueue(ox - 1, oz)
        enqueue(ox, oz + 1)
        enqueue(ox, oz - 1)
    end

    -- Find reachable tiles adjacent to the exterior region.
    -- These tiles form the visible outer boundary of the Dive area.
    for _, tile in pairs(M.tiles) do
        if M.isReachable(tile) then
            local ox, oz = tile.ox, tile.oz
            local mask = 0
            if exterior[ox][oz - 1] then mask = mask | geometry.EDGE_S end
            if exterior[ox + 1][oz] then mask = mask | geometry.EDGE_E end
            if exterior[ox][oz + 1] then mask = mask | geometry.EDGE_N end
            if exterior[ox - 1][oz] then mask = mask | geometry.EDGE_W end
            if mask ~= 0 then tile.perimeterEdges = mask end
        end
    end
end

-- Hides every tile.
function M.hideAll()
    for _, tile in pairs(M.tiles) do
        instanceDraw.hideTile(tile)
    end
end

return M

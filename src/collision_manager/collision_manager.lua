-- Collision manager for the Dive overlay.
-- Static collision flags come from packed RuneScape map files.
-- In instances, the game may copy or rotate 8x8 zones from other places.
-- This module finds those source zones, loads their flags, and turns them
-- to match the tiles you see in-game.
-- It also checks live Locs (game objects) to handle doors and other changes.
-- main.lua calls updateRegionState() before rebuildCollisionOverrides().
-- Dive movement code reads the result through getFlags().



-- ============================================================================
-- 1. MODULE DEPENDENCIES AND SHARED STATE
-- ============================================================================

local M = {}
local zoneRotation = require("src/resolve_procedural_zones")
local mapdata = require("src/map_decoder")
local addCollisions = require("src/collision_manager/add_collisions")
local rmCollisions = require("src/collision_manager/rm_collisions")

local DEFAULT_RADIUS = 32 -- Radius used when rebuilding nearby collision flags
local locOverrides = {}

-- ============================================================================
-- 2. PROCEDURAL INSTANCE CLASSIFICATION
-- ============================================================================
-- Classify a source-zone layout by comparing the positions of neighboring
-- 8x8 zones. Classification is separate from per-zone rotation inference.

local PROCEDURAL_SCAN_RADIUS = 2 -- Number of Zones away to scan up to
local isProceduralMapping = false

-- Whether the current region needs to be checked for procedural
-- (stitched or rotated) source-zone mappings.
local mappingClassificationDirty = true
-- Cache source-zone coordinates and rotations for destination 8x8 zones.
local cached_zones = {}


-- Check whether nearby 8x8 zones follow the normal map layout.
-- Called by refreshMappingMode() when an instance needs checking.
-- Return true if any neighboring source zones do not preserve
-- their original relative positions.
local function detectWhetherProcedural(zone_ind_x,zone_ind_z,plane)   
    -- check every zone in the procedural scan radius (typically 2 zones out to combat 2x2 zone groups)
    for x=zone_ind_x-PROCEDURAL_SCAN_RADIUS,zone_ind_x+PROCEDURAL_SCAN_RADIUS do
        for z=zone_ind_z-PROCEDURAL_SCAN_RADIUS,zone_ind_z+PROCEDURAL_SCAN_RADIUS do
            -- Look up the source zone for this destination zone.
            local testZone = zoneRotation.sourceForZone(x, z, plane)

            if testZone then
                -- Look up the source zones of its eastern and northern neighbors.
                local east = zoneRotation.sourceForZone(x+1, z, plane)
                local north = zoneRotation.sourceForZone(x, z+1, plane)
                
                if east then
                    -- Check whether moving east in the instance
                    -- also moves east in the source map.
                    -- If not, return procedural
                    if east.plane ~= testZone.plane
                        or east.source_region_index_x - testZone.source_region_index_x ~= 1
                        or east.source_region_index_z - testZone.source_region_index_z ~= 0 then
                        return true
                    end
                end
                if north then
                    -- Check whether moving north in the instance
                    -- also moves north in the source map.
                    -- If not, return procedural
                    if north.plane ~= testZone.plane
                        or north.source_region_index_x - testZone.source_region_index_x ~= 0
                        or north.source_region_index_z - testZone.source_region_index_z ~= 1 then
                        return true
                    end
                end
            end
        end
    end
    -- If the zone sources are consistent up to two zones away to the north and east, return non-procedural
    return false
end


-- Check whether the current instance uses procedural zone mappings.
-- Only recheck when a region event marks classification as dirty.
-- Once procedural mapping is detected, preserve that result until reset.
local function refreshMappingMode(worldtile_x,worldtile_z,plane,instanced)

    -- Skip classification if nothing has changed since the last check.
    if not mappingClassificationDirty then return end
    
    -- Classification is being handled, so clear the dirty flag.
    mappingClassificationDirty = false

    -- If we are not in an instance and we previously were Procedurally Mapping,
    -- then reset state and set Procedural flag to false.
    if not instanced then
        if isProceduralMapping then
            isProceduralMapping = false
            cached_zones = {}
        end
        return
    end

    -- if we are still in an instance, and Procedural is true, maintain it.
    -- Likely called with a DG door update (regionUpdated trigger)
    if isProceduralMapping then return end

    -- Check for if we have entered a Procedural Zone
    local zone_index_x = math.floor(worldtile_x / 8)
    local zone_index_z = math.floor(worldtile_z / 8)

    if detectWhetherProcedural(zone_index_x, zone_index_z, plane) then
        isProceduralMapping = true

        -- Previously cached zones assumed zero rotation.
        -- Recalculate them using procedural rotation detection.
        cached_zones = {}
    end
end

-- ============================================================================
-- 3. ZONE MAPPING AND CACHE STATE
-- ============================================================================

-- Track the previous instance status to detect transitions.
local previousRegion = nil

-- Turn three numbers into a text key for lookup tables.
-- Used for tile positions and 8x8 zone mappings.
local function key(a,b,c)
    return string.format('%d_%d_%d', a,b,c)
end

-- Ask the game whether the player is inside an instance.
-- Used by updateRegionState(), resolve(), and region event handlers.
-- Returns false if the game API is missing or fails.
local function isInsideInstance()
    if not World or not World.IsRegion then return false end
    local ok, value = pcall(World.IsRegion)
    return ok and value == true
end


-- Clear cached zone mappings and force a classification check.
-- resetInstance=true also forgets the previous procedural classification.
local function clearMappings(resetInstance)
    zoneRotation.clear()
    cached_zones = {}
    mappingClassificationDirty = true
    locOverrides = {}

    if resetInstance then
        isProceduralMapping = false
    end
end

-- Find and remember the source of the 8x8 zone containing a tile.
-- Called by resolve() for individual tile lookups.
-- Outside instances, the source and destination are the same.
-- Inside instances, ask the game for the source zone.
-- For procedural areas, also ask resolve_procedural_zones for rotation.
-- Store the result so later lookups are faster.
local function fetchZone(worldtile_x,worldtile_z,plane,instanced)
    local zone_ind_x,zone_ind_z = math.floor(worldtile_x/8), math.floor(worldtile_z/8)
    local k = key(zone_ind_x,zone_ind_z,plane)
    local cached = cached_zones[k]
    if cached then return cached end

    -- Store the destination zone origin once; all tile offsets within this
    -- zone are relative to this origin when resolving source coordinates.
    local entry = {
        destinationChunkX=zone_ind_x, destinationChunkZ=zone_ind_z, plane=plane,
        destinationOriginX=zone_ind_x*8, destinationOriginZ=zone_ind_z*8
    }
    -- Noninstanced case, source and destination are the same
    if not instanced then
        entry.sourceX,entry.sourceZ,entry.sourcePlane = entry.destinationOriginX,entry.destinationOriginZ,plane
    -- instanced case, get the source region coords
    else
        local source = zoneRotation.sourceForZone(zone_ind_x,zone_ind_z,plane)

        if source then
            entry.sourceX = source.source_region_origin_worldtile_x
            entry.sourceZ = source.source_region_origin_worldtile_z
            entry.sourcePlane = source.plane
        end
    end
    
    if entry.sourceX then
        if instanced and isProceduralMapping then
            -- Per-zone rotation inference from adjacent source-zone mappings.
            local detected, matches = zoneRotation.detect(
                entry.destinationOriginX, entry.destinationOriginZ, plane
            )
            entry.rotation = detected and detected.rotation or nil
        else
            -- Overworld and ordinary instances: original unrotated lookup.
            -- Instanced areas still use their mapped source coordinates.
            entry.rotation = 0
        end
    end
    -- Cache even unresolved entries; a region update explicitly invalidates
    -- these mappings when newly revealed source information may help.
    cached_zones[k] = entry
    return entry
end

-- New region: reset instance state and mappings.
function M.invalidateRegion()
    clearMappings(true)
    previousRegion = nil
end

-- Existing instance updated: refresh mappings but preserve classification.
function M.invalidateRegionUpdate()
    if not isInsideInstance() then return end
    clearMappings(false)
end


-- ============================================================================
-- 4. ZONE ROTATION AND DIRECTIONAL COLLISION FLAGS
-- ============================================================================
-- Convert a tile position within a rotated instanced 8x8 zone to its source position.
-- Used by resolve() after fetchZone() finds the source zone and rotation.
-- Offsets run from 0 to 7 on each axis.
local function rotatedOffset(ox,oz,r)
    if r==90 then return 7-oz,ox end
    if r==180 then return 7-ox,7-oz end
    if r==270 then return oz,7-ox end
    return ox,oz
end

-- Each row maps the source collision bits to their destination
-- bits for one clockwise quarter-turn.
local ROTATE_90 = {
    [2]   = 4,    -- West -> North
    [4]   = 8,    -- North -> East
    [8]   = 16,   -- East -> South
    [16]  = 2,    -- South -> West
    [32]  = 64,   -- NW -> NE
    [64]  = 128,  -- NE -> SE
    [128] = 256,  -- SE -> SW
    [256] = 32    -- SW -> NW
}
-- Rotates collision Flags for Procedural rotated zones
-- Assumes 9-bit collision flags (0-511)
local function rotateCollisionFlags(flags, rotation)
    -- If rotation is 0, we dont need to rotate.
    if rotation == 0 then return flags end
    -- Rotate by 0, 1, 2, or 3 clockwise quarter-turns.
    local turns = (rotation / 90) % 4
    local result = flags
    for _ = 1, turns do
        -- Ignore central collisions
        local rotated = result & 1
        -- get the new rotated bit from lookup table
        for source, destination in pairs(ROTATE_90) do
            if (result & source) ~= 0 then
                rotated = rotated | destination
            end
        end
        result = rotated
    end
    return result
end

-- ============================================================================
-- 5. DESTINATION TILE -> SOURCE TILE RESOLUTION
-- ============================================================================
-- Find the original source tile for a destination tile.
-- Called by getStaticCollisionFlags() whenever collision flags are read.
-- Uses fetchZone() to find the source 8x8 zone and rotatedOffset()
-- to find the right tile within that zone.
-- Returns source x, z, plane, instance status, and rotation; nil on failure.
function M.resolve(x,z,plane)
    if type(x)~='number' or type(z)~='number' or type(plane)~='number' then return nil end
    x,z,plane = math.floor(x),math.floor(z),math.floor(plane)
    local instanced = isInsideInstance()
    local c = fetchZone(x,z,plane,instanced)
    if not c.sourceX or c.rotation==nil then return nil end
    -- Convert the destination tile into a 0..7 offset inside its zone.
    local ox,oz=x-c.destinationOriginX,z-c.destinationOriginZ
    local rx,rz=rotatedOffset(ox,oz,c.rotation)
    return c.sourceX+rx,c.sourceZ+rz,c.sourcePlane,instanced,c.rotation
end

-- Locs are evaluated in destination-world space. Cache raw map tiles unchanged.
-- Rebuild effective flags each draw so dynamic objects can open and close.
-- ============================================================================
-- 6. LOC PROPERTY READING AND STATIC COLLISION LOOKUP
-- ============================================================================
-- Safely read a property from a game object.
-- Returns nil if the property is missing or reading it causes an error.
local function readProperty(obj, field)
    if obj == nil then return nil end
    local ok, value = pcall(function() return obj[field] end)
    if ok then return value end
    return nil
end

-- Read and normalize a Loc into a collision record.
-- Returns nil when required properties are unavailable.
local function readLoc(loc)
    local grid = readProperty(loc, "coordGrid")
    local cfg = readProperty(loc, "config")

    local x = readProperty(grid, "x")
    local z = readProperty(grid, "z")
    local plane = readProperty(grid, "level")

    if type(x) ~= "number"
        or type(z) ~= "number"
        or type(plane) ~= "number" then
        return nil
    end

    local rawBlock = readProperty(cfg, "blockWalk")
    local block = tonumber(rawBlock)

    if rawBlock == true then
        block = 1
    elseif rawBlock == false then
        block = 0
    end

    local hidden = readProperty(loc, "isHidden")

    if block == nil or type(hidden) ~= "boolean" then
        return nil
    end

    local name = readProperty(loc, "displayName")
    if type(name) ~= "string" then name = "" end

    return {
        x = math.floor(x),
        z = math.floor(z),
        plane = math.floor(plane),
        block = block,
        hidden = hidden,
        name = name:lower():match("^%s*(.-)%s*$"),
        rotation = tonumber(readProperty(loc, "rotationType")),
        id = tonumber(readProperty(loc, "configID"))
            or tonumber(readProperty(cfg, "id")),
        width = tonumber(readProperty(loc, "width"))
            or tonumber(readProperty(cfg, "width")) or 1,
        length = tonumber(readProperty(loc, "length"))
            or tonumber(readProperty(cfg, "length")) or 1,
        examineOnly = readProperty(cfg, "isExamineOnly"),
        isActive = readProperty(cfg, "isActive"),
        shape = tonumber(readProperty(loc, "shapeType"))
            or tonumber(readProperty(cfg, "shapeType"))
    }
end


-- Resolve a visible-world tile to its source map tile and read its static
-- collision flags. Rotate wall directions to match the visible instance.
-- Dynamic Loc overrides are applied separately.
local function getStaticCollisionFlags(x, z, plane)
    local sx, sz, sp, _, rotation = M.resolve(x, z, plane)
    if not sx then return nil end

    local ok, flags = pcall(mapdata.getTile, sx, sz, sp)
    if not ok or type(flags) ~= "number" then
        return nil
    end

    if flags < 0 then return nil end

    return rotateCollisionFlags(flags, rotation)
end

-- ============================================================================
-- 7. DYNAMIC COLLISION OVERRIDE RECONSTRUCTION
-- ============================================================================
-- Build the current collision flags around the player from static data and live objects.
-- Called by main.lua after updateRegionState().
-- 1. Read nearby Locs and their state (hidden, blocking, shape, size).
-- 2. Group Locs by origin tile and by every tile their size covers.
-- 3. Read each tile's static flags and remove stale blocking.
-- 4. Add walls and blocking objects that are currently visible.
-- 5. Save the final flags in locOverrides for getFlags().
-- Rebuilds on each call so doors and other changing objects are reflected.
function M.rebuildCollisionOverrides(playerGrid, radius)
    locOverrides = {}
    if not playerGrid or not LocList or not LocList.ByDistance then
        return
    end
    radius = math.max(1, math.floor(radius or DEFAULT_RADIUS))
    local ok, nearby = pcall(LocList.ByDistance, playerGrid, radius+2, true)
    if not ok then
        return
    end
    if type(nearby) ~= 'table' then
        return
    end

    -- Keep one flat list for cross-tile rules and an origin-indexed list
    -- for matching directional objects such as doors at their own tiles.
    local locs, byTile = {}, {}

    for _, loc in pairs(nearby) do
        local record = readLoc(loc)

        if record then
            locs[#locs + 1] = record

            local k = key(record.x, record.z, record.plane)
            byTile[k] = byTile[k] or {}
            byTile[k][#byTile[k] + 1] = record
        end
    end

    -- CENTER checks use the full world-aligned Loc footprints, not only origins.
    -- Keep byTile unchanged for directional-door matching.
    -- Expand multi-tile Loc footprints for CENTER occupancy checks;
    -- directional matching still uses the original byTile index.
    local centerLocsByTile = {}
    for _,loc in ipairs(locs) do
        local width = math.max(1, math.floor(loc.width or 1))
        local length = math.max(1, math.floor(loc.length or 1))
        -- Loc entity dimensions already describe its world-aligned footprint.
        -- Do not swap them again for rotationType (the inspector doesn't).
        for dx=0,width-1 do
            for dz=0,length-1 do
                local k=key(loc.x+dx,loc.z+dz,loc.plane)
                local occupants=centerLocsByTile[k]
                if not occupants then
                    occupants={}
                    centerLocsByTile[k]=occupants
                end
                occupants[#occupants+1]=loc
            end
        end
    end

    -- Resolve all tiles within the requested area; floor masks are not used
    -- to determine walkability.
    local px,pz,plane = readProperty(playerGrid,'x'),readProperty(playerGrid,'z'),readProperty(playerGrid,'level')
    if type(px) ~= 'number' or type(pz) ~= 'number' or type(plane) ~= 'number' then return end
    px,pz,plane = math.floor(px),math.floor(pz),math.floor(plane)
    -- Start with rotated static flags and apply removal rules per tile.
    -- Additions are applied in a separate pass after this grid is built.
    local effectiveByTile = {}
    for x=px-radius,px+radius do
        for z=pz-radius,pz+radius do
            local flags = getStaticCollisionFlags(x,z,plane)
            if type(flags)=='number' and flags>=0 then
                local tileKey = key(x,z,plane)
                effectiveByTile[tileKey] = rmCollisions.effectiveFlags(
                    flags,
                    centerLocsByTile[tileKey] or {},
                    byTile[tileKey] or {},
                    locs
                )
            end
        end
    end

    -- Add visible shape-based directional walls after static clearance.
    addCollisions.addVisibleWallEdges(locs, effectiveByTile)
    addCollisions.applyServerBlockingLocs(locs, effectiveByTile)

    for k,effective in pairs(effectiveByTile) do
        locOverrides[k] = effective
    end
end


-- ============================================================================
-- 8. EFFECTIVE COLLISION LOOKUP
-- ============================================================================
-- Return the collision flags used by Dive movement checks.
-- Called by dive_utils.lua through the collision lookup passed from main.lua.
-- Return live-adjusted flags when available, otherwise static flags.
function M.getFlags(x, z, plane)
    local k = key(math.floor(x), math.floor(z), math.floor(plane))

    if locOverrides[k] ~= nil then
        return locOverrides[k]
    end

    return getStaticCollisionFlags(x, z, plane)
end

-- ============================================================================
-- 9. REGION STATE UPDATE
-- ============================================================================
-- Called before rebuildCollisionOverrides() each overlay update.
-- Handle transitions into/out of instances and classify newly invalidated
-- instance layouts. Individual source zones and static maps load on demand
-- when getStaticCollisionFlags() reads a tile.
function M.updateRegionState(x, z, plane)
    if type(x) ~= "number" or type(z) ~= "number" or type(plane) ~= "number" then
        return
    end

    x, z, plane = math.floor(x), math.floor(z), math.floor(plane)
    local instanced = isInsideInstance()

    -- An instance-status change invalidates mappings from the previous area.
    -- RegionCreated/RegionUpdated events handle changes within an instance.
    if previousRegion ~= nil and previousRegion ~= instanced then
        clearMappings(true)
    end
    previousRegion = instanced

    -- Only scans neighboring source zones when mappingClassificationDirty
    -- was set by a region event or a mapping reset.
    refreshMappingMode(x, z, plane, instanced)
end

return M

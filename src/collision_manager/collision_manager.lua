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
-- The final store object for dynamic collision data
-- This object is accessed by the dive utilities to lookup if a tile nearby is diveable
local effectiveCollisionFlags = {}

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
                    if east.source_region_plane ~= testZone.source_region_plane
                        or east.source_region_index_x - testZone.source_region_index_x ~= 1
                        or east.source_region_index_z - testZone.source_region_index_z ~= 0 then
                        return true
                    end
                end
                if north then
                    -- Check whether moving north in the instance
                    -- also moves north in the source map.
                    -- If not, return procedural
                    if north.source_region_plane ~= testZone.source_region_plane
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
-- Used by updateRegionState(), getSourceTile(), and region event handlers.
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
    effectiveCollisionFlags = {}

    if resetInstance then
        isProceduralMapping = false
    end
end

-- Find and remember the source of the 8x8 zone containing a tile.
-- Called by getSourceTile() for individual tile lookups.
-- Outside instances, the source and destination are the same.
-- Inside instances, ask the game for the source zone.
-- For procedural areas, also ask resolve_procedural_zones for rotation.
-- Store the result so later lookups are faster.
local function fetchZone(worldtile_x,worldtile_z,plane,instanced)
    local zone_ind_x,zone_ind_z = math.floor(worldtile_x/8), math.floor(worldtile_z/8)
    local k = key(zone_ind_x,zone_ind_z,plane)
    
    local cached = cached_zones[k]
    -- If zone info is cached return it.
    -- But retry unresolved mappings and rotations.
    if cached and cached.sourceX ~= nil and cached.rotation ~= nil then
        return cached
    end

    -- Store the destination zone origin once; all tile offsets within this
    -- zone are relative to this origin when resolving source coordinates.
    local entry = {
        destinationChunkX=zone_ind_x, destinationChunkZ=zone_ind_z, plane=plane,
        destinationOriginX=zone_ind_x*8, destinationOriginZ=zone_ind_z*8
    }

    -- Noninstanced case, source and destination are the same
    if not instanced then
        entry.sourceX = entry.destinationOriginX
        entry.sourceZ = entry.destinationOriginZ
        entry.sourcePlane = plane
    -- instanced case, get the source region coords
    else
        -- Instance: resolve the original source zone.
        local source = zoneRotation.sourceForZone(
            zone_ind_x, zone_ind_z, plane
        )

        if source then
            entry.sourceX = source.source_region_origin_worldtile_x
            entry.sourceZ = source.source_region_origin_worldtile_z
            entry.sourcePlane = source.source_region_plane
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

    -- If we've entered or exited an instance,
    -- invalidate cached zone mappings and procedural state.
    -- 
    -- RegionCreated/RegionUpdated events handle changes within an instance.
    if previousRegion ~= nil and previousRegion ~= instanced then
        clearMappings(true)
    end
    previousRegion = instanced

    -- Only scans neighboring source zones when mappingClassificationDirty
    -- was set by a region event or a mapping reset.
    refreshMappingMode(x, z, plane, instanced)
end



-- ============================================================================
-- 4. ZONE ROTATION AND DIRECTIONAL COLLISION FLAGS
-- ============================================================================
-- Convert a tile position within a rotated instanced 8x8 zone to its source position.
-- Used by getSourceTile() after fetchZone() finds the source zone and rotation.
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
function M.getSourceTile(x,z,plane)
    if type(x)~='number' or type(z)~='number' or type(plane)~='number' then return nil end
    
    x,z,plane = math.floor(x),math.floor(z),math.floor(plane)

    local instanced = isInsideInstance()
    local zone = fetchZone(x,z,plane,instanced)

    if not zone.sourceX or zone.rotation==nil then return nil end

    -- Convert the destination tile into a 0..7 offset inside its zone.
    local ox,oz=x-zone.destinationOriginX,z-zone.destinationOriginZ

    -- Get the tile position based on the zone's rotation
    local rx,rz=rotatedOffset(ox,oz,zone.rotation)

    return zone.sourceX+rx,zone.sourceZ+rz,zone.sourcePlane,instanced,zone.rotation
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
    -- get the location's coord grid
    local grid = readProperty(loc, "coordGrid")
    -- get the locations' config
    local cfg = readProperty(loc, "config")
    -- get the locations' coordinates
    local x = readProperty(grid, "x")
    local z = readProperty(grid, "z")
    local plane = readProperty(grid, "level")

    if type(x) ~= "number"
        or type(z) ~= "number"
        or type(plane) ~= "number" then
        return nil
    end
    -- get the locations' blockWalk value
    local rawBlock = readProperty(cfg, "blockWalk")
    local block = tonumber(rawBlock)

    -- blockWalk is 0-2, 0 means no block for our heuristic
    if rawBlock == true then
        block = 1
    elseif rawBlock == false then
        block = 0
    end

    -- get the locations' isHidden property. 
    -- Locations that are hidden often invert their blockWalk
    local hidden = readProperty(loc, "isHidden")

    if block == nil or type(hidden) ~= "boolean" then
        return nil
    end

    -- get the locations' displayName
    local name = readProperty(loc, "displayName")
    if type(name) ~= "string" then name = "" end

    -- return a comprehansive table of Location properties
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
    -- Get the source map tile from the destination tile
    -- This accounts for potential zone rotation in procedural areas
    local sx, sz, sp, _, rotation = M.getSourceTile(x, z, plane)
    if not sx then return nil end

    -- Get the static collision flags from the mapdata cache.
    local ok, flags = pcall(mapdata.getTile, sx, sz, sp)
    if not ok or type(flags) ~= "number" then
        return nil
    end

    if flags < 0 then return nil end

    -- return the flags, rotated if in a procedural rotated zone
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
-- 5. Save the final flags in effectiveCollisionFlags for getFlags().
-- Rebuilds on each call so doors and other changing objects are reflected.
function M.rebuildCollisionOverrides(playerGrid, radius)
    -- Discard the previous collision results so changes to nearby Locs
    -- (such as doors opening or closing) are reflected in this rebuild.
    effectiveCollisionFlags = {}
    -- if there are no nearby locations, and the player is does not have a coordGrid, exit.
    if not playerGrid or not LocList or not LocList.ByDistance then
        return
    end
    
    -- search radius for locs
    radius = math.max(1, math.floor(radius or DEFAULT_RADIUS))

    -- fetch nearby Locs
    local ok, nearby = pcall(LocList.ByDistance, playerGrid, radius+2, true)
    if not ok then
        return
    end
    -- make sure LocList.ByDistance returns a Lua Table
    if type(nearby) ~= 'table' then
        return
    end

    -- Organize nearby Locs in two ways:
    -- locs:   flat list of all valid nearby Locs, used for cross-tile rules.
    -- byTile: Locs grouped by their ORIGIN tile, used for rules that
    --         depend on an object's exact placement (e.g. directional doors).
    local locs, byTile = {}, {}

    for _, loc in pairs(nearby) do
        -- Extract relevant properties into a normalized Lua record.
        -- Invalid/incomplete Locs are skipped.
        local record = readLoc(loc)

        if record then
            -- Add to the complete list of nearby Locs.
            locs[#locs + 1] = record

            -- Also index this Loc by its origin coordinates.
            -- Multiple Locs can share the same origin tile.
            local k = key(record.x, record.z, record.plane)
            byTile[k] = byTile[k] or {}
            -- byTile stores tiles as keys, and a list of records as values
            byTile[k][#byTile[k] + 1] = record
        end
    end

    -- Build a second tile index for CENTER (full-tile blocking) checks.
    --
    -- Unlike byTile, which only indexes a Loc's origin, this table
    -- indexes EVERY tile occupied by a Loc's footprint.
    --
    -- Example: a 2x2 object starting at (100, 200) appears under:
    -- (100,200), (101,200), (100,201), and (101,201).
    --
    -- Directional collision rules still use byTile because walls and
    -- doors are associated with their original placement coordinates.
    local centerLocsByTile = {}
    for _,loc in ipairs(locs) do
        -- Determine the size of the Loc's occupied area in tiles.
        -- Dimensions are already world-aligned, so do not swap
        -- width/length based on rotationType.
        local width = math.max(1, math.floor(loc.width or 1))
        local length = math.max(1, math.floor(loc.length or 1))
        -- Expand the Loc's footprint into individual occupied tiles.
        for dx=0,width-1 do
            for dz=0,length-1 do
                local k=key(loc.x+dx,loc.z+dz,loc.plane)
                -- Create the tile's occupant list if it doesn't exist.
                local occupants=centerLocsByTile[k]
                if not occupants then
                    occupants={}
                    centerLocsByTile[k]=occupants
                end
                -- Add this Loc to every tile covered by its footprint.
                occupants[#occupants+1]=loc
            end
        end
    end

    -- Read the player's current world tile and plane.
    -- These coordinates define the center of the collision search area.
    local px, pz, plane =
        readProperty(playerGrid, 'x'),
        readProperty(playerGrid, 'z'),
        readProperty(playerGrid, 'level')

    if type(px) ~= 'number'
        or type(pz) ~= 'number'
        or type(plane) ~= 'number' then
        return
    end

    px,pz,plane = math.floor(px),math.floor(pz),math.floor(plane)

    -- Build the effective collision grid in two stages:
    --
    -- Stage 1: Start with static map flags and REMOVE blocking that
    --          should no longer exist based on the current Loc states.
    --
    -- Stage 2: ADD blocking from currently visible/active Locs.
    --
    -- This ordering is important: we first clear outdated collision
    -- before reconstructing the current blocking state.
    local effectiveByTile = {}
    -- Process every tile in the square centered on the player.
    for x=px-radius,px+radius do
        for z=pz-radius,pz+radius do
            -- Get the static (and potentially rotated) collision flags
            local flags = getStaticCollisionFlags(x,z,plane)
            if type(flags)=='number' and flags>=0 then
                local tileKey = key(x,z,plane)
                -- Apply collision-removal rules:
                -- Remove center blocking collision if (hidden & (active | blockWalk)) [things like barriers dissappearing]
                -- Remove stale directional blocking collision flags [things like doors opening]
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
    -- Add center collision to edge case locs in special_cases.lua
    addCollisions.applyServerBlockingLocs(locs, effectiveByTile)

    -- Publish the completed collision grid for getFlags().
    --
    -- Each entry contains the FINAL effective flags for that tile,
    -- not just the changes relative to the static collision map.
    --
    -- getFlags() reads these values first and falls back to static
    -- collision flags for tiles outside this rebuilt area.
    for k,effective in pairs(effectiveByTile) do
        effectiveCollisionFlags[k] = effective
    end
end


-- ============================================================================
-- 8. EFFECTIVE COLLISION LOOKUP
-- ============================================================================
-- Return the collision flags used by Dive movement checks.
-- Called by dive_utils.lua through the collision lookup passed from main.lua.
-- Return live-adjusted flags when available, otherwise static flags.
function M.getFlags(x, z, plane)
    -- construct a key for the collision data store with coordinates
    local k = key(math.floor(x), math.floor(z), math.floor(plane))

    -- get the stored dynamic collision flag for the tile.
    if effectiveCollisionFlags[k] ~= nil then
        return effectiveCollisionFlags[k]
    end

    -- fallback if the store doesnt have the key, return static collision flag
    return getStaticCollisionFlags(x, z, plane)
end


return M

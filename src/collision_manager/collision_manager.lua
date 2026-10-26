-- Collision manager for the Dive overlay.
-- Static collision flags come from packed RuneScape map files.
-- In instances, the game may copy or rotate 8x8 zones from other places.
-- This module finds those source zones, loads their flags, and turns them
-- to match the tiles you see in-game.
-- It also checks live Locs (game objects) to handle doors and other changes.
-- main.lua calls update() to prepare maps and updateLocs() to apply live changes.
-- Dive movement code reads the result through getFlags().



-- ============================================================================
-- 1. MODULE DEPENDENCIES AND SHARED STATE
-- ============================================================================

local M = {}
local zoneRotation = require("src/resolve_procedural_zones")
local mapdata = require("src/map_decoder")
local addCollisions = require("src/collision_manager/add_collisions")
local rmCollisions = require("src/collision_manager/rm_collisions")

local DEFAULT_RADIUS = 32 -- Tile radius for collision map search
local TILE_SIZE = 512
local CENTER = 1
local locOverrides = {}
local locStats = {seen=0, applied=0, skipped=0, errors=0, lastError=nil}

-- ============================================================================
-- 2. PROCEDURAL INSTANCE CLASSIFICATION
-- ============================================================================
-- Classify a source-zone layout by comparing the positions of neighboring
-- 8x8 zones. Classification is separate from per-zone rotation inference.

local PROCEDURAL_SCAN_RADIUS = 4 -- Number of Zones away to scan up to
local mappingScanKey, mappingScanMode = nil, "instance_default"

-- Whether the current region needs to be checked for procedural
-- (stitched or rotated) source-zone mappings.
local mappingClassificationDirty = true
local chunks, contextKey
local mappingScanEvidence = nil

-- Find where an 8x8 zone was copied from in an instance.
-- Used by scanSourceMapping() when checking how nearby zones fit together.
-- The game API gives the source zone origin, not the rotation.
-- Returns source zone coordinates, or nil if the lookup fails.
local function sourceZone(zx,zz,plane)
    if not CoordGrid or not World or not World.GetRegionSourceForCoordGrid then return nil end
    local x,z = zx*8,zz*8
    local okCoord,coord=pcall(CoordGrid.new,plane,math.floor(x/64),math.floor(z/64),x%64,z%64)
    if not okCoord or not coord then return nil end
    local ok,src=pcall(World.GetRegionSourceForCoordGrid,coord)
    if not ok or not src or type(src.x)~="number" or type(src.z)~="number"
        or type(src.level)~="number" or src.level<0 then return nil end
    return {x=math.floor(src.x/8),z=math.floor(src.z/8),plane=src.level}
end


-- Check whether nearby 8x8 zones follow the normal map layout.
-- Called by refreshMappingMode() when an instance needs checking.
-- If neighboring source zones do not line up normally, mark it "procedural".
-- Otherwise use "instance_default". Missing zones are ignored.
local function scanSourceMapping(zx,zz,plane)
    local r=PROCEDURAL_SCAN_RADIUS
    local sourceCache={}
    -- Memoize source-zone lookups within this scan, including failures.
    -- The false sentinel prevents repeated API calls for unmapped zones.
    local function get(x,z)
        local k=x..","..z
        local v=sourceCache[k]
        if v==nil then
            v=sourceZone(x,z,plane) or false
            sourceCache[k]=v
        end
        return v~=false and v or nil
    end
    local checked=0
    for x=zx-r,zx+r do
        for z=zz-r,zz+r do
            local a=get(x,z)
            if a then
                local east,north=get(x+1,z),get(x,z+1)
                if east then
                    checked=checked+1
                    if east.plane~=a.plane or east.x-a.x~=1 or east.z-a.z~=0 then
                        return "procedural", "east seam at "..x..","..z
                    end
                end
                if north then
                    checked=checked+1
                    if north.plane~=a.plane or north.x-a.x~=0 or north.z-a.z~=1 then
                        return "procedural", "north seam at "..x..","..z
                    end
                end
            end
        end
    end
    return "instance_default", "no seam in "..checked.." neighbor pairs"
end


-- Decide how to look up tiles in the current area.
-- Called by update() and the old debug helper.
-- Only scans when mappingClassificationDirty is true (such as after a region event).
-- Once a procedural layout is found, keep that choice until the region resets.
-- If the mode changes, clear zone mappings so they can be rebuilt.
local function refreshMappingMode(x,z,plane,instanced)
    local zx,zz=math.floor(x/8),math.floor(z/8)
    local k=string.format("%d_%d_%d_%s",zx,zz,plane,tostring(instanced))
    if not mappingClassificationDirty then return end
    mappingClassificationDirty = false
    mappingScanKey=k
    local mode,evidence="overworld","not instanced"
    if instanced then
        if mappingScanMode == "procedural" then
            -- A detected procedural seam remains authoritative for this instance.
            mode,evidence = "procedural", "procedural seam previously detected"
        else
            mode,evidence = scanSourceMapping(zx,zz,plane)
        end
    end
    mappingScanEvidence=evidence
    if mode~=mappingScanMode then
        mappingScanMode=mode
        -- Invalidate prior 0-degree/rotated mappings and force prefetch.
        chunks={}
        contextKey=nil
    end
end

-- ============================================================================
-- 3. ZONE MAPPING AND CACHE STATE
-- ============================================================================

-- AREA_SIZE is the 8x8 source/destination zone size, not the 64x64 mapsquare
-- size used by packed collision files. `chunks` stores zone mappings.
local AREA_SIZE = 8
local maps, missingMaps = {}, {}
chunks = {}
contextKey = nil
local previousRegion, lastError = nil, nil
local lastCenterX, lastCenterZ, lastPlane = nil, nil, nil

-- Turn three numbers into a text key for lookup tables.
-- Used for tile positions, 8x8 zones, and 64x64 mapsquares.
local function key(a,b,c)
    return string.format('%d_%d_%d', a,b,c)
end

-- Ask the game whether the player is inside an instance.
-- Used by update(), resolve(), and region event handlers.
-- Returns false if the game API is missing or fails.
local function regionActive()
    if not World or not World.IsRegion then return false end
    local ok, value = pcall(World.IsRegion)
    return ok and value == true
end

-- Check whether a 64x64 source mapsquare can be loaded.
-- Called by rawTile() and update() before reading collision flags.
-- Remember both successful and failed checks to avoid repeated loading.
-- map_decoder owns the actual packed map data.
local function getMap(mx,mz,plane)
    local k = key(mx,mz,plane)
    if maps[k] then return true end
    if missingMaps[k] then return nil end
    local ok, data = pcall(mapdata.getMapBytes, mx,mz,plane)
    if not ok or not data then
        missingMaps[k] = true
        lastError = not ok and ('Cannot load packed map ' .. k .. ': ' .. tostring(data))
            or ('Packed map not in index: ' .. k)
        return nil
    end
    maps[k] = true
    return true
end

-- Forget cached 8x8 zone mappings and rotations, but keep packed maps.
-- Called after a region update or a manual mapping refresh.
-- This allows newly revealed rooms to get fresh source mappings.
local function refreshDynamicMappings()
    zoneRotation.clear()
    chunks = {}
    contextKey = nil
end

-- Reset all instance-specific mappings, mode detection, and Loc overrides.
-- Called when a new region starts or the instance state changes.
-- The next update() will rebuild these values.
local function clearMappings()
    chunks = {}
    contextKey = nil
    zoneRotation.clear()
    locOverrides = {}
    mappingScanKey=nil
    mappingScanMode="instance_default"
    mappingScanEvidence=nil
    mappingClassificationDirty=true
end

-- Find and remember the source of the 8x8 zone containing a tile.
-- Called by resolve() for individual tiles and update() for nearby zones.
-- Outside instances, the source and destination are the same.
-- Inside instances, ask the game for the source zone.
-- For procedural areas, also ask resolve_procedural_zones for rotation.
-- Store the result (including errors) so later lookups are faster.
local function chunkFor(x,z,plane,instanced)
    local cx,cz = math.floor(x/AREA_SIZE), math.floor(z/AREA_SIZE)
    local k = key(cx,cz,plane)
    local cached = chunks[k]
    if cached then return cached end

    -- Store the destination zone origin once; all tile offsets within this
    -- zone are relative to this origin when resolving source coordinates.
    local entry = {
        destinationChunkX=cx, destinationChunkZ=cz, plane=plane,
        destinationOriginX=cx*AREA_SIZE, destinationOriginZ=cz*AREA_SIZE
    }
    if not instanced then
        entry.sourceX,entry.sourceZ,entry.sourcePlane = entry.destinationOriginX,entry.destinationOriginZ,plane
    elseif not CoordGrid or not World or not World.GetRegionSourceForCoordGrid then
        entry.error = 'Region source API unavailable'
    else
        local x0,z0 = entry.destinationOriginX,entry.destinationOriginZ
        local okCoord, coord = pcall(CoordGrid.new, plane,
            math.floor(x0/64), math.floor(z0/64), x0%64, z0%64)
        if not okCoord or not coord then
            entry.error = 'CoordGrid.new failed: ' .. tostring(coord)
        else
            local ok, src = pcall(World.GetRegionSourceForCoordGrid, coord)
            if ok and src and type(src.x)=='number' and type(src.z)=='number'
                and type(src.level)=='number' and src.level>=0 then
                entry.sourceX,entry.sourceZ,entry.sourcePlane = src.x,src.z,src.level
            else
                entry.error = ok and 'Unmapped source area' or tostring(src)
            end
        end
    end
    if entry.sourceX then
        entry.lookupMode = instanced and mappingScanMode or "overworld"

        if entry.lookupMode == "procedural" then
            -- Per-zone rotation inference from adjacent source-zone mappings.
            local detected, matches = zoneRotation.detect(
                entry.destinationOriginX, entry.destinationOriginZ, plane
            )
            entry.rotation = detected and detected.rotation or nil
            if not detected then
                entry.error = 'Zone rotation unresolved ('
                    .. tostring(matches) .. ' neighbor votes)'
            end
        else
            -- Overworld and ordinary instances: original unrotated lookup.
            -- Instanced areas still use their mapped source coordinates.
            entry.rotation = 0
        end
    end
    -- Cache even unresolved entries; a region update explicitly invalidates
    -- these mappings when newly revealed source information may help.
    chunks[k] = entry
    if entry.error then
        lastError = string.format('Area (%d,%d): %s',cx,cz,entry.error)
    end
    return entry
end

-- Clear all cached maps, zone mappings, Loc overrides, and error data.
-- Use for a full reset, not for ordinary movement or room updates.
function M.clearCache()
    maps,missingMaps,chunks = {},{},{}
    locOverrides = {}
    if mapdata.clearCache then mapdata.clearCache() end
    contextKey,previousRegion,lastError = nil,nil,nil
    lastCenterX,lastCenterZ,lastPlane = nil,nil,nil
    zoneRotation.clear()
    mappingScanKey=nil
    mappingScanMode="instance_default"
    mappingScanEvidence=nil
    mappingClassificationDirty=true
    locStats = {seen=0, applied=0, skipped=0, errors=0, lastError=nil}
end

-- Handle a new region being created (RegionCreated event).
-- Clear old instance mappings so the next update() starts fresh.
function M.invalidateRegion()
    clearMappings()
    previousRegion = nil
end

-- Handle changes to the current instance (RegionUpdated event).
-- Clear zone mappings and ask update() to check the layout again.
-- Does nothing outside an instance.
function M.invalidateRegionUpdate()
    if not regionActive() then return end
    refreshDynamicMappings()
    mappingClassificationDirty = true
end

-- Force a fresh zone mapping check on the next update().
-- Useful when testing or when a room changes without a region event.
function M.refreshMappings()
    refreshDynamicMappings()
    mappingClassificationDirty = true
end

-- ============================================================================
-- 4. ZONE ROTATION AND DIRECTIONAL COLLISION FLAGS
-- ============================================================================
-- Convert a tile position within a destination 8x8 zone to its source position.
-- Used by resolve() after chunkFor() finds the source zone and rotation.
-- Offsets run from 0 to 7 on each axis.
local function rotatedOffset(ox,oz,r)
    if r==90 then return 7-oz,ox end
    if r==180 then return 7-ox,7-oz end
    if r==270 then return oz,7-ox end
    return ox,oz
end

-- Directional flags in the rsmv exporter:
-- center=1, west=2, north=4, east=8, south=16,
-- northwest=32, northeast=64, southeast=128, southwest=256.
-- Transform each source-facing wall/corner into its destination-facing equivalent.
local directionBits = {
    {2,-1,0}, {4,0,1}, {8,1,0}, {16,0,-1},
    {32,-1,1}, {64,1,1}, {128,1,-1}, {256,-1,-1}
}
local vectorBits = {
    ['-1,0']=2, ['0,1']=4, ['1,0']=8, ['0,-1']=16,
    ['-1,1']=32, ['1,1']=64, ['1,-1']=128, ['-1,-1']=256
}
-- Turn source wall directions into the directions seen in-game.
-- Called by rawTile() when a copied zone is rotated.
-- Keeps CENTER blocking unchanged and rotates wall/corner bits.
-- Also keeps any flag bits that this code does not recognize.
local function rotateFlags(flags,r)
    if r==0 then return flags end
    -- Preserve the CENTER bit while remapping each directional wall/corner.
    local result=flags & 1
    for _,entry in ipairs(directionBits) do
        local bit,dx,dz=entry[1],entry[2],entry[3]
        if (flags & bit)~=0 then
            local rx,rz=dx,dz
            -- Inverse of rotatedOffset(): source direction -> destination direction.
            if r==90 then rx,rz=dz,-dx
            elseif r==180 then rx,rz=-dx,-dz
            elseif r==270 then rx,rz=-dz,dx end
            result=result | vectorBits[rx..','..rz]
        end
    end
    -- Preserve any unknown flag bits rather than silently discarding them.
    local known=1|2|4|8|16|32|64|128|256
    return result | (flags & (~known))
end

-- ============================================================================
-- 5. DESTINATION TILE -> SOURCE TILE RESOLUTION
-- ============================================================================
-- Find the original source tile for a destination tile.
-- Called by rawTile() whenever collision flags are read.
-- Uses chunkFor() to find the source 8x8 zone and rotatedOffset()
-- to find the right tile within that zone.
-- Returns source x, z, plane, instance status, and rotation; nil on failure.
function M.resolve(x,z,plane)
    if type(x)~='number' or type(z)~='number' or type(plane)~='number' then return nil end
    x,z,plane = math.floor(x),math.floor(z),math.floor(plane)
    local instanced = regionActive()
    local c = chunkFor(x,z,plane,instanced)
    if not c.sourceX or c.rotation==nil then return nil end
    -- Convert the destination tile into a 0..7 offset inside its zone.
    local ox,oz=x-c.destinationOriginX,z-c.destinationOriginZ
    local rx,rz=rotatedOffset(ox,oz,c.rotation)
    return c.sourceX+rx,c.sourceZ+rz,c.sourcePlane,instanced,c.rotation
end

-- Locs are evaluated in destination-world space. Cache raw map tiles unchanged.
-- Rebuild effective flags each draw so dynamic objects can open and close.
-- ============================================================================
-- 6. DYNAMIC LOC INSPECTION AND STATIC TILE DECODING
-- ============================================================================
-- Safely read a property from a game object.
-- Used by locTile(), locAttributes(), and updateLocs().
-- Returns nil if the property is missing or reading it causes an error.
local function readProperty(obj, field)
    if obj == nil then return nil end
    local ok, value = pcall(function() return obj[field] end)
    if ok then return value end
    return nil
end

-- Get the world tile coordinates and plane of a Loc (game object).
-- Called by updateLocs() while collecting nearby objects.
-- Returns nil if the object has no usable coordinates.
local function locTile(loc)
    local grid = readProperty(loc, "coordGrid")
    if not grid then return nil end
    local x, z, plane = readProperty(grid, "x"), readProperty(grid, "z"), readProperty(grid, "level")
    if type(x) == "number" and type(z) == "number" and type(plane) == "number" then
        return math.floor(x), math.floor(z), math.floor(plane)
    end
    return nil
end

-- Collect the Loc fields needed by the collision add/remove rules.
-- Called by updateLocs() for each nearby game object.
-- Reads visibility, blocking type, shape, rotation, name, and size.
-- Uses safe defaults when some fields are missing.
local function locAttributes(loc)
    local cfg = readProperty(loc, "config")
    local raw = readProperty(cfg, "blockWalk")
    local block = tonumber(raw)
    if raw == true then block = 1 elseif raw == false then block = 0 end
    -- Dynamic collision is determined by shape, not by blockWalk 1 vs 2.
    -- Parent configuration is no longer needed to force CENTER collision.
    local shape = tonumber(readProperty(loc, "shapeType"))
        or tonumber(readProperty(cfg, "shapeType"))
    local hidden = readProperty(loc, "isHidden")
    if hidden ~= true and hidden ~= false then hidden = nil end
    local name = readProperty(loc, "displayName")
    if type(name) ~= "string" then name = "" end
    -- Normalize names for case-insensitive matching in Loc heuristics.
    name = name:lower():match("^%s*(.-)%s*$")
    local rotation = tonumber(readProperty(loc, "rotationType"))
    local id = tonumber(readProperty(loc, "configID"))
        or tonumber(readProperty(cfg, "id"))
    local width = tonumber(readProperty(loc, "width"))
        or tonumber(readProperty(cfg, "width")) or 1
    local length = tonumber(readProperty(loc, "length"))
        or tonumber(readProperty(cfg, "length")) or 1
    local examineOnly = readProperty(cfg, "isExamineOnly")
    local isActive = readProperty(cfg, "isActive")
    return block, hidden, name, rotation, id, width, length, examineOnly, isActive, shape
end

-- Read static collision flags for a tile in the visible world.
-- Called by updateLocs() and getFlags().
-- First resolve() finds the original source tile, then map_decoder reads it.
-- If the source zone is rotated, rotate the wall direction bits too.
-- Returns static flags (and floor/terrain data), or nil on failure.
-- It does NOT apply live Loc changes; updateLocs() handles those.
local function rawTile(x,z,plane)
    local sx,sz,sp,_,rotation = M.resolve(x,z,plane)
    if not sx then return nil end
    if not getMap(math.floor(sx/64),math.floor(sz/64),sp) then return nil end
    local ok, flags, floor, terrain = pcall(mapdata.getTile,sx,sz,sp)
    if not ok then
        lastError = 'Packed tile decode failed: '..tostring(flags)
        return nil
    end
    if type(flags)~='number' then return nil end
    if flags >= 0 then flags=rotateFlags(flags,rotation) end
    return flags,floor,terrain
end

-- Return a complete effective flag value for a tile; never mutate packed data.
-- Directional/corner flags are preserved unless an explicit Loc rule clears them.

-- ============================================================================
-- 7. DYNAMIC COLLISION RECONSTRUCTION
-- ============================================================================
-- Build the current collision flags around the player from static data and live objects.
-- Called by main.lua during the overlay update/draw cycle.
-- 1. Read nearby Locs and their state (hidden, blocking, shape, size).
-- 2. Group Locs by origin tile and by every tile their size covers.
-- 3. Read each tile's static flags and remove stale blocking.
-- 4. Add walls and blocking objects that are currently visible.
-- 5. Save the final flags in locOverrides for getFlags().
-- Runs again when called, so doors and other changing objects can be reflected.
function M.updateLocs(playerGrid, radius)
    locOverrides = {}
    locStats = {seen=0, applied=0, skipped=0, errors=0, lastError=nil}
    if not playerGrid or not LocList or not LocList.ByDistance then
        locStats.lastError = 'LocList.ByDistance unavailable'
        return
    end
    radius = math.max(1, math.floor(radius or DEFAULT_RADIUS))
    local ok, nearby = pcall(LocList.ByDistance, playerGrid, radius+2, true)
    if not ok then
        locStats.lastError = tostring(nearby)
        locStats.errors = 1
        return
    end
    if type(nearby) ~= 'table' then
        locStats.lastError = 'LocList.ByDistance returned '..type(nearby)
        return
    end

    -- Keep one flat list for cross-tile rules and an origin-indexed list
    -- for matching directional objects such as doors at their own tiles.
    local locs, byTile = {}, {}
    for _,loc in pairs(nearby) do
        locStats.seen = locStats.seen + 1
        local x,z,plane = locTile(loc)
        local block,hidden,name,rotation,id,width,length,examineOnly,isActive,shape = locAttributes(loc)
        if x ~= nil and block ~= nil and hidden ~= nil then
            local record = {x=x,z=z,plane=plane,block=block,hidden=hidden,name=name,rotation=rotation,id=id,width=width,length=length,examineOnly=examineOnly,isActive=isActive,shape=shape}
            locs[#locs+1] = record
            local k = key(x,z,plane)
            if not byTile[k] then byTile[k] = {} end
            byTile[k][#byTile[k]+1] = record
        else
            locStats.skipped = locStats.skipped + 1
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
            local flags = rawTile(x,z,plane)
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
        locStats.applied = locStats.applied + 1
    end
end


-- ============================================================================
-- 8. EFFECTIVE COLLISION LOOKUP
-- ============================================================================
-- Return the collision flags used by Dive movement checks.
-- Called by dive_utils.lua through the collision lookup passed from main.lua.
-- Use the live Loc-adjusted flags from updateLocs() when available.
-- Otherwise return the rotated static flags from rawTile().
-- An override of 0 is valid: it means no blocking remains.
function M.getFlags(x,z,plane)
    local flags = rawTile(x,z,plane)
    if type(flags)~='number' or flags<0 then return nil end
    local k = key(math.floor(x),math.floor(z),math.floor(plane))
    -- A value of zero is a valid override (all collision cleared), so
    -- test against nil rather than checking truthiness.
    local override = locOverrides[k]
    if override ~= nil then return override end
    return flags
end

-- Prefetch all source files referenced by areas intersecting the requested
-- radius. Refresh only on area/plane/region/radius changes.
-- ============================================================================
-- 9. PER-FRAME MAPPING UPDATE AND SOURCE MAP PREFETCH
-- ============================================================================
-- Prepare nearby static collision maps and instance mappings.
-- Called by main.lua before it calculates Dive paths.
-- Detect instance changes, check procedural layouts when needed,
-- and load the source mapsquares for zones near the player.
-- Uses DEFAULT_RADIUS when no radius is supplied.
-- Skips repeated prefetch work while the player stays in the same zone.
-- Does NOT inspect live Locs; updateLocs() does that separately.
function M.update(x,z,plane,radius)
    if type(x)~='number' or type(z)~='number' or type(plane)~='number' then return end
    x,z,plane = math.floor(x),math.floor(z),math.floor(plane)
    radius = math.max(0,math.floor(radius or DEFAULT_RADIUS))
    local instanced = regionActive()
    if previousRegion ~= nil and previousRegion ~= instanced then clearMappings() end
    previousRegion = instanced

    -- Ordinary movement only changes the prefetch neighborhood. Region events
    -- (or first startup) are the only triggers for procedural classification.
    -- Newly entered zones are resolved lazily by chunkFor without rescanning
    -- surrounding source-zone adjacency.

    refreshMappingMode(x,z,plane,instanced)
    local k = key(math.floor(x/AREA_SIZE),math.floor(z/AREA_SIZE),plane)
        .. ':' .. tostring(instanced) .. ':' .. radius
    -- Skip source-map prefetch when the surrounding zone context is unchanged.
    if contextKey==k then return end
    contextKey=k
    lastCenterX,lastCenterZ,lastPlane=x,z,plane
    -- Prefetch all 8x8 zones overlapping the radius, not just the player's
    -- current zone; their source data may live in different mapsquares.
    for cx=math.floor((x-radius)/AREA_SIZE),math.floor((x+radius)/AREA_SIZE) do
        for cz=math.floor((z-radius)/AREA_SIZE),math.floor((z+radius)/AREA_SIZE) do
            local c = chunkFor(cx*AREA_SIZE,cz*AREA_SIZE,plane,instanced)
            if c.sourceX then
                -- The mapped 8x8 area can cross a 64x64 source-file boundary.
                local sx0,sz0=c.sourceX,c.sourceZ
                local sx1,sz1=sx0+AREA_SIZE-1,sz0+AREA_SIZE-1
                for mx=math.floor(sx0/64),math.floor(sx1/64) do
                    for mz=math.floor(sz0/64),math.floor(sz1/64) do
                        getMap(mx,mz,c.sourcePlane)
                    end
                end
            end
        end
    end
end


return M

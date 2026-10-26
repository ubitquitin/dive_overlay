
-- Determines how individual 8x8 zones have been rotated in procedural instances.
--
-- In procedural areas such as Dungeoneering, the game assembles an instance
-- from 8x8 tile zones taken from random locations in one or a few source chunks.
-- These source zones may be rotated when placed into the instance.
--
-- To read the correct collision data, the plugin must know:
-- 1. Which original source zone corresponds to an instanced destination zone.
-- 2. How that zone is rotated relative to its original orientation.
--
-- sourceForZone() obtains the original source zone using the World API.
-- detect() infers rotation by comparing the source locations of neighboring
-- destination zones.
--
-- Rotations describe how to transform DESTINATION-local tile offsets into
-- SOURCE-local tile offsets, not the reverse.
--
-- This module only resolves zone mappings and rotations.
-- It does not load or modify collision data.

local M = {}

-- Cache source-zone lookups and successfully inferred rotations separately.
-- Keys identify DESTINATION zones using (zoneX, zoneZ, plane).
local sourceCache, rotationCache = {}, {}

-- Creates a unique string key for a zone and plane.
local function key(x,z,p)
    return string.format('%d_%d_%d',x,z,p)
end

-- Finds the original source zone corresponding to a destination 8x8 zone.
--
-- zx, zz: Destination zone coordinates (world tile coordinates divided by 8).
-- plane: Destination plane.
--
-- The RuneScape World API can map a coordinate in an instanced region
-- back to its original source location. We use the first tile of the
-- destination zone as the lookup coordinate.
--
-- Returns the source zone's X, Z, and plane, or nil if unavailable.
local function sourceForZone(zx,zz,plane)

    -- Reuse a previously resolved source mapping.
    local k=key(zx,zz,plane)
    if sourceCache[k] then return sourceCache[k] end

    -- Ensure the game APIs required for source-coordinate lookup exist.
    if not CoordGrid or not World or not World.GetRegionSourceForCoordGrid then
        return nil
    end

    -- Convert destination zone coordinates back into world tile coordinates.
    -- For example, zone (400, 401) begins at world tile (3200, 3208).
    local x,z=zx*8,zz*8

    -- Construct the coordinate object expected by the World API.
    -- CoordGrid.new receives the plane, 64x64 mapsquare coordinates,
    -- and the tile's local X/Z position within that mapsquare.
    local okCoord,coord=pcall(
        CoordGrid.new,
        plane,
        math.floor(x/64),
        math.floor(z/64),
        x%64,
        z%64
    )

    -- pcall protects against API errors or invalid coordinates.
    if not okCoord or not coord then return nil end

    -- Ask the game which original map coordinate this destination uses.
    local ok,src=pcall(World.GetRegionSourceForCoordGrid,coord)

    -- Reject failed lookups or invalid source coordinates.
    if not ok or not src
        or type(src.x)~='number'
        or type(src.z)~='number'
        or type(src.level)~='number'
        or src.level<0 then
        return nil
    end

    -- Convert the returned source WORLD TILE coordinates into
    -- SOURCE 8x8 zone coordinates.
    local result={
        zx=math.floor(src.x/8),
        zz=math.floor(src.z/8),
        plane=src.level
    }

    -- Cache successful lookups to avoid repeating the World API call.
    sourceCache[k]=result
    return result
end


-- Expected change in SOURCE zone coordinates when moving one zone
-- east (+X) or north (+Z) in the DESTINATION instance.
--
-- Each rotation contains four coefficients:
-- {sourceX_from_destX, sourceZ_from_destX,
--  sourceX_from_destZ, sourceZ_from_destZ}
--
-- For example, at 90 degrees:
-- Moving east (+1, 0) in the destination corresponds to moving
-- north (0, +1) in the original source map.
-- Moving north (0, +1) corresponds to moving west (-1, 0).
--
-- These transformations are used to identify which rotation makes
-- neighboring destination zones line up with their source locations.
local vectors={
    [0]   = {1,0,0,1},
    [90]  = {0,1,-1,0},
    [180] = {-1,0,0,-1},
    [270] = {0,-1,1,0}
}

-- Four cardinally adjacent destination zones to examine:
-- East, West, North, South.
-- Diagonal neighbors are not considered.
local neighbors={{1,0},{-1,0},{0,1},{0,-1}}


-- Infers the rotation of an 8x8 zone in a procedural instance.
--
-- The World API identifies the original source zone used to populate
-- each destination zone, but only returns its bottom-left coordinate.
-- It does not provide the rotation or individual source tile mappings.
--
-- We therefore infer rotation by comparing neighboring zone positions:
--
-- 1. Find the source zone corresponding to our current destination zone.
-- 2. Examine its four cardinal neighbors in the destination instance.
-- 3. Only consider neighbors whose source zones are also directly adjacent
--    to our source zone, on the same plane. If they are not adjacent it 
--    indicates that we have jumped to a new stitched zone from the source
--    chunk, which likely has a different rotation.
-- 4. Compare the direction between zones in the instance with the
--    direction between their original source zones.
--          E.g. if Zone 2 is to the east of zone 1 in the destination (instance) data,
--               but to the north of zone 1 in the source data, we have
--               rotated 90 degrees.
--
-- For example, if moving east between destination zones corresponds
-- to moving north between their source zones, this supports 90 degrees.
--
-- This is an inference based on neighboring zone arrangements, not a
-- rotation value returned directly by the World API.
function M.detect(x,z,plane)

    -- Convert the requested world tile into its destination 8x8 zone.
    local zx,zz=math.floor(x/8),math.floor(z/8)
    local k=key(zx,zz,plane)

    -- Reuse a previously inferred rotation.
    if rotationCache[k] then
        local result=rotationCache[k]
        return result.result,result.evidence
    end

    -- Find the original source zone corresponding to this destination zone.
    local center=sourceForZone(zx,zz,plane)
    if not center then return nil,0 end

    -- votes[rotation] counts how many neighbors support that rotation.
    -- evidence counts all matching neighbor observations.
    local votes={}
    local evidence=0

    -- Examine the four cardinally adjacent destination zones.
    for _,n in ipairs(neighbors) do
        local dx,dz=n[1],n[2]

        -- Find where this neighboring destination zone originated.
        local adjacent=sourceForZone(zx+dx,zz+dz,plane)

        -- Only compare zones originating from the same source plane.
        if adjacent and adjacent.plane==center.plane then

            -- Calculate the displacement between their SOURCE zones.
            local sx,sz=adjacent.zx-center.zx,adjacent.zz-center.zz

            -- Only use neighbors that are also cardinally adjacent
            -- in the source map (exactly one zone apart).
            --
            -- This avoids treating unrelated dungeon pieces as
            -- orientation evidence.
            if math.abs(sx)+math.abs(sz)==1 then

                -- Compare the observed source displacement against
                -- the displacement predicted by each possible rotation.
                for r,v in pairs(vectors) do

                    -- Transform destination neighbor offset (dx, dz)
                    -- into the expected source offset (ex, ez).
                    local ex,ez=
                        v[1]*dx+v[3]*dz,
                        v[2]*dx+v[4]*dz

                    -- A match means this neighbor supports rotation r.
                    if sx==ex and sz==ez then
                        votes[r]=(votes[r] or 0)+1
                        evidence=evidence+1
                    end
                end
            end
        end
    end

    -- Select the rotation receiving the greatest number of votes.
    -- A tie means the available neighbors do not establish a unique
    -- orientation, so no rotation will be returned.
    local bestRotation,bestCount,tied=nil,0,false

    for r,count in pairs(votes) do
        if count>bestCount then
            bestRotation,bestCount,tied=r,count,false
        elseif count==bestCount then
            tied=true
        end
    end

    local result

    -- Only accept a rotation if at least one neighbor supports it
    -- and there is a unique highest vote count.
    if bestRotation~=nil and not tied then
        result={
            rotation=bestRotation,
            destinationX=zx,
            destinationZ=zz,
            sourceX=center.zx,
            sourceZ=center.zz,
            sourcePlane=center.plane,

            -- Number of neighboring observations supporting the winner.
            evidence=bestCount,

            -- Number of observations supporting other rotations.
            conflicts=evidence-bestCount
        }
    end

    -- Cache only successfully resolved rotations.
    -- Unresolved zones are retried later because newly revealed dungeon
    -- rooms may provide additional neighboring source mappings.
    if result then
        rotationCache[k]={result=result,evidence=evidence}
    end

    return result,evidence
end

-- Discard all previously resolved source mappings and rotations.
-- Used when instance layout information must be refreshed.
function M.clear()
    sourceCache={}
    rotationCache={}
end

return M


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
-- destination zones. This assumes that zones are stitched together in 2x2 blocks.
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

-- Finds the original source zone corresponding to a destination 8x8 zone.
--
-- instance_x, instance_z: Destination zone indeces (world tile coordinates divided by 8).
-- plane: Destination plane.
--
-- The RuneScape World API can map a coordinate in an instanced region
-- back to its original source location. We use the first tile of the
-- destination zone as the lookup coordinate.
--
-- Returns the source zone's X, Z, and plane, or nil if unavailable.
function M.sourceForZone(instance_x,instance_z,plane)

    -- If the zone is cached, then return the source zone.
    local k=string.format('%d_%d_%d',instance_x,instance_z,plane)
    if sourceCache[k] then return sourceCache[k] end

    -- Ensure the game APIs required for source-coordinate lookup exist.
    if not CoordGrid or not World or not World.GetRegionSourceForCoordGrid then
        return nil
    end

    -- Convert destination zone coordinates back into world tile coordinates.
    -- For example, zone (400, 401) begins at world tile (3200, 3208).
    local x,z=instance_x*8,instance_z*8

    -- Construct the coordinate object expected by the World API.
    -- CoordGrid.new receives the plane, 64x64 mapsquare coordinates,
    -- and the tile's local X/Z position within that mapsquare.
    local returnsValid,instance_region_coordgrid=pcall(
        CoordGrid.new,
        plane,
        math.floor(x/64),
        math.floor(z/64),
        x%64,
        z%64
    )

    -- pcall protects against API errors or invalid coordinates.
    if not returnsValid or not instance_region_coordgrid then return nil end

    -- Ask the game which original map coordinate this destination uses.
    local validCall,source_region_coordgrid=pcall(World.GetRegionSourceForCoordGrid,instance_region_coordgrid)

    -- Reject failed lookups or invalid source coordinates.
    if not validCall or not source_region_coordgrid
        or type(source_region_coordgrid.x)~='number'
        or type(source_region_coordgrid.z)~='number'
        or type(source_region_coordgrid.level)~='number'
        or source_region_coordgrid.level<0 then
        return nil
    end

    -- Convert the returned source WORLD TILE coordinates into
    -- SOURCE 8x8 zone coordinates.
    local result={
        source_region_index_x=math.floor(source_region_coordgrid.x/8),
        source_region_index_z=math.floor(source_region_coordgrid.z/8),
        source_region_plane=source_region_coordgrid.level,
        -- Preserve exact source tile coordinates for collision mapping.
        source_region_origin_worldtile_x=source_region_coordgrid.x,
        source_region_origin_worldtile_z=source_region_coordgrid.z
    }

    -- Cache successful lookups to avoid repeating the World API call.
    sourceCache[k]=result
    return result
end


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
function M.detect(instance_worldtile_x,instance_worldtile_z,plane)

    -- Convert the requested world tile into its destination 8x8 zone.
    local instance_zone_index_x,instance_zone_index_z=math.floor(instance_worldtile_x/8),math.floor(instance_worldtile_z/8)
    local k=string.format('%d_%d_%d',instance_zone_index_x,instance_zone_index_z,plane)

    -- If available, Reuse a previously inferred rotation.
    if rotationCache[k] then
        local result=rotationCache[k]
        return result.result,result.evidence
    end

    -- Find the original source zone corresponding to this destination zone.
    local center=M.sourceForZone(instance_zone_index_x,instance_zone_index_z,plane)
    if not center then return nil,0 end

    -- Four cardinally adjacent destination zones to examine:
    -- East, West, North, South.
    -- Diagonal neighbors are not considered.
    local neighbors={{1,0},{-1,0},{0,1},{0,-1}}

    -- Rotate a destination zone offset into source-map coordinates.
    local function rotateOffset(dx, dz, rotation)
        if rotation == 90 then
            return -dz, dx
        elseif rotation == 180 then
            return -dx, -dz
        elseif rotation == 270 then
            return dz, -dx
        end

        return dx, dz -- 0 degrees
    end

    -- votes[rotation] counts how many neighbors support that rotation.
    -- evidence counts all matching neighbor observations.
    local votes={}
    local evidence=0

    -- Examine the four cardinally adjacent destination zones.
    for _,n in ipairs(neighbors) do
        local dx,dz=n[1],n[2]

        -- Find where this neighboring destination zone originated.
        local adjacent=M.sourceForZone(instance_zone_index_x+dx,instance_zone_index_z+dz,plane)

        -- Only compare zones originating from the same source plane.
        if adjacent and adjacent.source_region_plane==center.source_region_plane then

            -- Calculate the displacement between their SOURCE zones.
            local region_dist_x,region_dist_z=adjacent.source_region_index_x-center.source_region_index_x,adjacent.source_region_index_z-center.source_region_index_z

            -- Only use neighbors that are also cardinally adjacent
            -- in the source map (exactly one zone apart).
            --
            -- This avoids treating unrelated dungeon pieces as
            -- orientation evidence.
            if math.abs(region_dist_x)+math.abs(region_dist_z)==1 then

                -- Since we are already in the loop trying each cardinally adjacent neighbor,
                -- We check which rotation transformation makes the source movement line up
                -- with the instance movement. We get the rotational offset given a rotation as
                -- expected (so for exampe {1,0} with a 90 degree rotation would be {0,1}) 
                for _, rotation in ipairs({0, 90, 180, 270}) do
                    local rotated_dx, rotated_dz = rotateOffset(dx, dz, rotation)
                    
                    -- If the actual difference in x and z indeces between the adjacent zones lines up
                    -- with the rotated coords, then we have support for that rotation configuration
                    if region_dist_x == rotated_dx
                        and region_dist_z == rotated_dz then
                        
                        -- We use voting for the rare case where a neighboring 2x2 zone group happens have adjacent source coords
                        votes[rotation] = (votes[rotation] or 0) + 1
                        evidence = evidence + 1
                        break
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
            destinationX=instance_zone_index_x,
            destinationZ=instance_zone_index_z,
            sourceX=center.source_region_index_x,
            sourceZ=center.source_region_index_z,
            sourcePlane=center.source_region_plane,

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

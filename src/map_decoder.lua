
-- Loads and decodes the collision data for individual world tiles.
--
-- RuneScape's collision data is stored in 64x64 tile chunks.
-- The maps/ directory contains compressed collision data for these chunks,
-- organized into shard files. maps/index.lua identifies which shard contains
-- a particular chunk.
--
-- Given a world tile coordinate (x, z, plane), this module:
-- 1. Determines which 64x64 chunk contains the tile.
-- 2. Finds and loads that chunk's collision data from maps/.
-- 3. Decodes the compressed data into bytes.
-- 4. Extracts and returns the collision flags for the requested tile.
--
-- To avoid repeatedly loading and decoding the same chunks, we keep
-- up to 24 recently accessed decoded chunks in memory. When the cache
-- is full, the least recently used chunk is discarded.
--
-- This module only reads the original cached collision data.
-- Dynamic collision changes and procedural instance mapping are handled
-- elsewhere.

local M = {}

-- Maps each chunk key ("cx_cz_plane") to the shard file containing it.
local index = require('maps/index')

-- Shard files contain encoded collision data for multiple chunks.
-- Keep loaded shard tables here so they can be reused.
local shards = {}

-- Cache of decoded chunks, keyed by chunk coordinates and plane.
-- Each entry contains the decoded bytes and its last-access counter.
local cache = {}
local cacheCount = 0
local CACHE_LIMIT = 24

-- Incremented on every chunk lookup.
-- Used to determine which cached chunk was accessed least recently.
local age = 0

-- Each chunk contains 64x64 = 4096 tiles.
-- Each tile's collision flags are stored in 9 bits (values 0 through 511).
local TILE_COUNT = 64 * 64
local COLLISION_BITS = 9

-- 4096 tiles * 9 bits = 36864 bits = 4608 bytes.
local PACKED_BYTES = TILE_COUNT * COLLISION_BITS // 8

-- Some chunks include an additional bitmap identifying missing tiles.
-- One bit per tile = 4096 bits = 512 bytes.
-- This preserves original collision values of -1, which cannot be
-- represented using the normal unsigned 9-bit collision values.
local MISSING_BYTES = TILE_COUNT // 8

-- Base64 is used to store the binary collision data as text in Lua files.
-- This lookup converts each Base64 character into its numeric value (0-63).
local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local lookup = {}

for i = 1, #alphabet do
    lookup[alphabet:sub(i, i)] = i - 1
end

-- Decodes a Base64 string into an array of bytes (integers 0-255).
--
-- Each Base64 character represents 6 bits. This function accumulates
-- those bits until a complete 8-bit byte can be extracted.
-- The resulting byte array still contains packed 9-bit collision values;
-- individual tile values are extracted later by getTile().
local function decode64(s)
    local out = {}
    local buffer, bits = 0, 0

    for i = 1, #s do
        local ch = s:sub(i, i)

        -- '=' is Base64 padding, not part of the encoded data.
        if ch ~= '=' then
            local n = lookup[ch]
            if n == nil then
                error('Invalid base64 character at ' .. i)
            end

            -- Append this character's 6 bits to the accumulated buffer.
            buffer = buffer * 64 + n
            bits = bits + 6

            -- Extract the next complete byte when at least 8 bits exist.
            if bits >= 8 then
                bits = bits - 8
                local divisor = 2 ^ bits
                out[#out + 1] = math.floor(buffer / divisor)

                -- Retain any leftover bits for the next character.
                buffer = buffer % divisor
            end
        end
    end

    return out
end


-- Retrieves the decoded collision bytes for a particular 64x64 chunk.
-- Used by collision manager to get the raw collision data to then update with dynamics.
--
-- cx, cz: chunk coordinates, NOT individual world tile coordinates.
-- plane: The map's vertical plane.
--
-- First checks whether the chunk has already been decoded and cached.
-- Otherwise, uses maps/index.lua to locate its shard, loads the encoded
-- data, decodes it, and adds the result to the cache.
--
-- Returns nil if the requested chunk is absent from the index or shard.
local function getMap(cx, cz, plane)

    -- Construct the chunk lookup key, e.g. "50_50_0".
    local key = cx .. '_' .. cz .. '_' .. plane

    -- Record this lookup so recently accessed chunks remain cached.
    age = age + 1

    -- Reuse already-decoded data whenever possible.
    local existing = cache[key]
    if existing then
        existing.age = age
        return existing.bytes
    end

    -- Find the shard containing this chunk.
    local shardId = index[key]
    if not shardId then return nil end

    -- Reuse the shard table if it has already been loaded.
    local shard = shards[shardId]

    if not shard then
        -- Support both maps/map_01.lua and maps/maps_001.lua naming.
        local paths = {
            string.format('maps/map_%02d', shardId),
            string.format('maps/maps_%03d', shardId),
        }

        local errors = {}

        -- Try each supported filename until the shard loads successfully.
        for _, path in ipairs(paths) do
            local ok, result = pcall(require, path)

            if ok and type(result) == 'table' then
                shard = result
                break
            end

            errors[#errors + 1] = path .. ': ' .. tostring(result)
        end

        if not shard then
            error(table.concat(errors, '\n'))
        end

        shards[shardId] = shard
    end

    -- Retrieve this chunk's Base64-encoded collision data.
    local encoded = shard[key]
    if not encoded then return nil end

    -- Convert Base64 text into the original packed binary bytes.
    local bytes = decode64(encoded)

    -- Valid chunks contain either collision data alone (4608 bytes)
    -- or collision data plus the missing-tile bitmap (512 extra bytes).
    if #bytes ~= PACKED_BYTES and #bytes ~= PACKED_BYTES + MISSING_BYTES then
        error('Bad collision-only map payload size for ' .. key .. ': ' .. #bytes
            .. ' (expected ' .. PACKED_BYTES .. ' or ' .. (PACKED_BYTES + MISSING_BYTES) .. ')')
    end

    -- If 24 decoded chunks are already cached, remove the one that
    -- was accessed least recently before inserting the new chunk.
    if cacheCount >= CACHE_LIMIT then
        local oldestKey, oldestAge

        for k, entry in pairs(cache) do
            if not oldestAge or entry.age < oldestAge then
                oldestKey, oldestAge = k, entry.age
            end
        end

        cache[oldestKey] = nil
        cacheCount = cacheCount - 1
    end

    -- Store the decoded chunk for future tile lookups.
    cache[key] = {bytes = bytes, age = age}
    cacheCount = cacheCount + 1

    return bytes
end


-- Returns the original collision flags for a specific world tile.
-- Used by the collision manager for specific collision tile looksup.
--
-- x, z: World tile coordinates (after procedural instance mapping, if needed).
-- plane: The map's vertical plane.
--
-- Each tile has a 9-bit collision value representing blocked centers,
-- walls, and corners. Returns 0-511, or -1 for a missing tile.
-- Returns nil if the chunk's data cannot be found.
function M.getTile(x, z, plane)

    -- Convert world tile coordinates into 64x64 chunk coordinates.
    -- For example, tile (3205, 3210) belongs to chunk (50, 50).
    local cx, cz = math.floor(x / 64), math.floor(z / 64)

    -- Retrieve the chunk's decoded bytes, loading them if necessary.
    local bytes = getMap(cx, cz, plane)
    if not bytes then return nil end

    -- Find the tile's local position within its 64x64 chunk.
    -- For example, world tile (3205, 3210) becomes local tile (5, 10).
    local lx, lz = x % 64, z % 64

    -- Convert the local X/Z position into a single 0-based tile index.
    -- Tiles are stored row by row, with X varying within each Z row.
    local tile = lz * 64 + lx

    -- Each tile occupies 9 bits, so its data may begin partway through
    -- a byte rather than at a byte boundary.
    local bitpos = tile * COLLISION_BITS

    -- Lua arrays are 1-based, so add 1 to the calculated byte index.
    local bytepos = math.floor(bitpos / 8) + 1

    -- Number of bits to skip within the first byte.
    local shift = bitpos % 8

    -- Read two consecutive bytes because a 9-bit collision value can
    -- span a byte boundary. Combine them into a 16-bit integer.
    local value = (bytes[bytepos] or 0) + (bytes[bytepos + 1] or 0) * 256

    -- Shift away preceding bits, then keep only the next 9 bits.
    -- Modulo 512 is equivalent to masking with 0x1FF (9 bits).
    local collision = math.floor(value / (2 ^ shift)) % 512

    -- If this chunk includes a missing-tile bitmap, check whether
    -- the requested tile was originally marked as missing (-1).
    if #bytes == PACKED_BYTES + MISSING_BYTES then

        -- Locate the bitmap byte containing this tile's missing flag.
        local flagByte = bytes[PACKED_BYTES + 1 + math.floor(tile / 8)]

        -- Extract the corresponding bit. A set bit means the tile is missing.
        if math.floor(flagByte / (2 ^ (tile % 8))) % 2 == 1 then
            collision = -1
        end
    end

    return collision
end

-- Exposes direct access to a complete decoded chunk when needed.
-- Unlike getTile(), this returns the packed byte array, not a tile flag.
-- Example: M.getMapBytes(50, 50, 0)
M.getMapBytes = getMap

-- Clears the decoded chunk cache and resets its access counters.
-- Future tile lookups will decode chunks again as needed.
-- Already-loaded shard modules remain available through Lua's require cache.
function M.clearCache()
    cache, cacheCount, age = {}, 0, 0
end

return M

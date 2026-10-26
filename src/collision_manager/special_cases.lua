-- Special-case data for the dive collision manager.
local M = {}

-- Loc configurations that the server treats as blocking even when
-- config.blockWalk == 0. Only VISIBLE instances are applied.
-- footprint=true: block all tiles occupied by the Loc.
M.serverBlockingLocs = {
    [88060] = {footprint=true, description="ROTS broken rope bridge"},
}

return M

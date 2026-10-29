-- Special-case data for the dive collision manager.
local M = {}

-- Loc configurations that the server treats as blocking even when
-- config.blockWalk == 0. Only VISIBLE instances are applied.
-- footprint=true: block all tiles occupied by the Loc.
M.serverBlockingLocs = {
    [88060] = {footprint=true, description="ROTS broken rope bridge"},
    [50332] = {footprint=true, description="DG frozen Prayer skill door"},
    [50333] = {footprint=true, description="DG abandoned Prayer skill door"},
    [50334] = {footprint=true, description="DG furnished Prayer skill door"},
    [53971] = {footprint=true, description="DG occult Prayer skill door"},
    [55759] = {footprint=true, description="DG warped Prayer skill door"},
    [50278] = {footprint=true, description="DG frozen Runecrafting skill door"},
    [50279] = {footprint=true, description="DG abandoned Runecrafting skill door"},
    [50280] = {footprint=true, description="DG furnished Runecrafting skill door"},
    [53953] = {footprint=true, description="DG occult Runecrafting skill door"},
    [55741] = {footprint=true, description="DG warped Runecrafting skill door"},
    [50329] = {footprint=true, description="DG frozen Magic skill door"},
    [50330] = {footprint=true, description="DG abandoned Magic skill door"},
    [50331] = {footprint=true, description="DG furnished Magic skill door"},
    [53970] = {footprint=true, description="DG occult Magic skill door"},
    [55758] = {footprint=true, description="DG warped Magic skill door"},
    [50327] = {footprint=true, description="DG abandoned Summoning skill door"},
    [50328] = {footprint=true, description="DG furnished Summoning skill door"},
    [53969] = {footprint=true, description="DG occult Summoning skill door"},
    [55757] = {footprint=true, description="DG warped Summoning skill door"},
    [49653] = {footprint=true, description="DG frozen Statues to fix"},
    [49654] = {footprint=true, description="DG abandoned Statues to fix"},
    [49655] = {footprint=true, description="DG furnished Statues to fix"},
    [53993] = {footprint=true, description="DG occult Statues to fix"},
    [50342] = {footprint=true, description="DG door frozen"},
    [50343] = {footprint=true, description="DG door abandoned"},
    [50344] = {footprint=true, description="DG door furnished"},
    [53948] = {footprint=true, description="DG door occult"},
    [55762] = {footprint=true, description="DG door warped"},
}

return M

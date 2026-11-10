-- User settings: defaults, loading and saving through PersistentDB.
-- Colours are RRGGBBAA picker values, stored as 8-digit hex strings.

local debouncer = require("src/debouncer")

local M = {}

local SETTINGS_KEY = "diveOverlaySettings"

local DEFAULT_SETTINGS = {
    diveMode = "all",
    showSurge = true,
    showEscape = true,
    showArrows = false,
    hideBehind = false,
    showHover = true,
    surgeFollowsHover = false,
    diveColour = 0xEBC946FF,
    hoverColour = 0xD70E34FF,
    surgeColour = 0x1266DFFF,
    escapeColour = 0x008000FF,
    edgeOpacity = 29, -- Edge alpha as a percentage of the color picker's alpha
    fillOpacity = 6, -- Fill alpha as a percentage of the color picker's alpha
}

local function loadSettings()
    local saved = PersistentDB:GetStructuredData(SETTINGS_KEY)
    local settings = {}

    for key, default in pairs(DEFAULT_SETTINGS) do
        local value
        if type(saved) == "table" then value = saved[key] end

        if key:match("Colour$") then
            if type(value) == "string"
                and value:match("^%x%x%x%x%x%x%x%x$") then
                value = tonumber(value, 16)
            else
                value = default
            end
        elseif type(value) ~= type(default) then
            value = default
        end

        settings[key] = value
    end

    -- Validate the selected mode.
    if settings.diveMode ~= "all"
        and settings.diveMode ~= "perimeter"
        and settings.diveMode ~= "edges"
        and settings.diveMode ~= "none" then
        settings.diveMode = "all"
    end

    settings.edgeOpacity = math.max(0, math.min(100, settings.edgeOpacity))
    settings.fillOpacity = math.max(0, math.min(100, settings.fillOpacity))

    return settings
end

M.settings = loadSettings()

function M.saveSettings()
    local saved = {}

    for key, value in pairs(M.settings) do
        if key:match("Colour$") then
            saved[key] = string.format("%08X", value)
        else
            saved[key] = value
        end
    end

    PersistentDB:SetStructuredData(SETTINGS_KEY, saved)
end

-- Restores every setting to its default and persists the result.
function M.resetSettings()
    debouncer.cancel("edgeOpacity")
    debouncer.cancel("fillOpacity")

    for key, default in pairs(DEFAULT_SETTINGS) do
        M.settings[key] = default
    end

    M.saveSettings()
end

-- Sets the edge or fill opacity percentage and persists it.
function M.setOpacity(key, value)
    if key ~= "edgeOpacity" and key ~= "fillOpacity" then
        return
    end

    if type(value) ~= "number" then return end

    M.settings[key] = math.max(0, math.min(100, value))
    M.saveSettings()
end

-- Sets a tile colour ("dive", "hover", "surge" or "escape") and persists it.
function M.setColour(kind, value)
    local settingKey = kind .. "Colour"

    if M.settings[settingKey] == nil then return end
    if type(value) ~= "number" then return end

    M.settings[settingKey] = value
    M.saveSettings()
end

return M

-- Settings UI: the buttons in the Plugin Hub settings layer and the
-- PrettyUI window with toggles, modes, opacity sliders and colour pickers.

local debouncer = require("src/debouncer")
local persist = require("src/settings/persist")

local M = {}

local settings = persist.settings

-- The open settings window, or nil when closed, and its colour pickers.
local uiWindow
local colourPickers = {}

local COLOUR_PICKERS = {
    { kind = "dive",   label = "Dive" },
    { kind = "hover",  label = "Hover" },
    { kind = "surge",  label = "Surge" },
    { kind = "escape", label = "Escape" },
}

-- Closes any open colour picker popups.
local function closeColourPickers()
    for _, picker in ipairs(colourPickers) do
        picker:Close()
    end
    colourPickers = {}
end

-- Closes and destroys the settings window and its colour picker popups.
function M.destroy()
    closeColourPickers()

    if uiWindow then
        local window = uiWindow
        uiWindow = nil
        window:Destroy()
    end
end

-- Opens the PrettyUI settings window, replacing one that is already open
-- so its controls show the current settings.
function M.openSettings()
    M.destroy()

    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    uiWindow = prettyui.Window.new(parent, {
        title = "Dive Overlay Settings",
        x = 800,
        y = 200,
        width = 330,
        height = 415,
        resizable = true,
        minWidth = 280,
        minHeight = 140,
        scrollable = true,
        destroyOnClose = true,
        onClose = function(window)
            if window ~= uiWindow then return end
            closeColourPickers()
            uiWindow = nil
        end,
    })

    -- Dive tile mode
    uiWindow:AddTitle("Dive tiles")
    uiWindow:AddRadioButton({
        { text = "All diveable tiles",   value = "all" },
        { text = "Outer perimeter only", value = "perimeter" },
        { text = "Perimeter edges only", value = "edges" },
        { text = "None",                 value = "none" },
    }, {
        selectedValue = settings.diveMode,
        onChange = function(_, value)
            settings.diveMode = value
            persist.saveSettings()
        end,
    })
    uiWindow:AddCheckboxButton({
        { text = "Hover tile", value = "hover", selected = settings.showHover },
    }, {
        onChange = function(_, _, changed, selected)
            if changed ~= "hover" then return end
            settings.showHover = selected
            persist.saveSettings()
        end,
    })

    -- Overlay toggles
    uiWindow:AddTitle("Overlays")
    uiWindow:AddCheckboxButton({
        { text = "Surge tiles",              value = "surge",             selected = settings.showSurge },
        { text = "Escape tiles",             value = "escape",            selected = settings.showEscape },
        { text = "Dive facing arrows",       value = "arrows",            selected = settings.showArrows },
        { text = "Hide dive tiles behind",   value = "behind",            selected = settings.hideBehind },
        { text = "Surge follows Hover Tile", value = "surgeFollowsHover", selected = settings.surgeFollowsHover },
    }, {
        onChange = function(_, _, changed, selected)
            if changed == "surge" then
                settings.showSurge = selected
            elseif changed == "escape" then
                settings.showEscape = selected
            elseif changed == "arrows" then
                settings.showArrows = selected
            elseif changed == "behind" then
                settings.hideBehind = selected
            elseif changed == "surgeFollowsHover" then
                settings.surgeFollowsHover = selected
            else
                return
            end

            persist.saveSettings()
        end,
    })

    -- Opacity sliders
    uiWindow:AddTitle("Tile opacity")

    uiWindow:AddText("Edge opacity (%)")
    uiWindow:AddSlider({
        min = 0,
        max = 100,
        step = 1,
        value = settings.edgeOpacity,
        onChange = function(_, value)
            debouncer.debounce("edgeOpacity", 0.2, function()
                persist.setOpacity("edgeOpacity", value)
            end)
        end,
    })

    uiWindow:AddText("Fill opacity (%)")
    uiWindow:AddSlider({
        min = 0,
        max = 100,
        step = 1,
        value = settings.fillOpacity,
        onChange = function(_, value)
            debouncer.debounce("fillOpacity", 0.2, function()
                persist.setOpacity("fillOpacity", value)
            end)
        end,
    })

    -- Colour pickers
    uiWindow:AddTitle("Tile colours")
    for _, entry in ipairs(COLOUR_PICKERS) do
        uiWindow:AddText(entry.label)
        colourPickers[#colourPickers + 1] = uiWindow:AddColourPicker({
            value = settings[entry.kind .. "Colour"],
            alphaSlider = true,
            windowTitle = entry.label .. " tile colour",
            onChange = function(_, value)
                persist.setColour(entry.kind, value)
            end,
        })
    end
end

-- Builds the Plugin Hub settings layer: a button that opens the PrettyUI
-- window, and a button that resets all settings to defaults.
function M.buildSettings(parent)
    local button = ui.Button.new(parent)
    button.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    button.label = "Open Settings"
    button:SetPos(12, 20)
    button:SetSize(200, 36)

    button:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        M.openSettings()
    end)

    local resetButton = ui.Button.new(parent)
    resetButton.stylesheetID = id.StyleSheet.BUTTON_DEFAULT
    resetButton.label = "Reset to Defaults"
    resetButton:SetPos(12, 64)
    resetButton:SetSize(200, 36)

    resetButton:Subscribe(ui.Hook.ONBUTTONPRESSED, function()
        persist.resetSettings()
        -- Reopen an open window so its controls show the defaults.
        if uiWindow then M.openSettings() end
    end)
end

return M

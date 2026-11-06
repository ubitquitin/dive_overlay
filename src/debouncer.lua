-- Delays calls until a quiet period passes with no other call under the
-- same name. main.lua subscribes onLogic to the Logic event.
local M = {}
local TICKS_PER_SECOND = 50 -- Logic events run at a fixed rate

M.ticks = 0
local pending = {} -- name -> { fn, due }

-- Schedules fn to run after `seconds` with no other call under name,
-- replacing any call still pending under it.
function M.debounce(name, seconds, fn)
    pending[name] = { fn = fn, due = M.ticks + math.ceil(seconds * TICKS_PER_SECOND) }
end

-- Drops the call pending under name, if any.
function M.cancel(name)
    pending[name] = nil
end

-- Logic event handler. Runs the calls that are due.
function M.onLogic()
    M.ticks = M.ticks + 1
    for name, call in pairs(pending) do
        if M.ticks >= call.due then
            pending[name] = nil
            call.fn()
        end
    end
end

-- Runs every pending call now.
function M.flush()
    for name, call in pairs(pending) do
        pending[name] = nil
        call.fn()
    end
end

return M

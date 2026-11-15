-- Tab shell: tracks the active tab and the single persistent main panel.
-- Three navigation levels:
--   _panel  — main tab (Library / Browse / Sources) — kept alive across rebuilds
--   _detail — detail/settings sub-screen shown above the tab panel
--   _export — export sub-screen shown above the detail panel
-- Each level is shown without closing the one below it, so closing a level
-- reveals whatever was underneath automatically via UIManager.
local UIManager = require("ui/uimanager")

local InkstreamUI = {}

InkstreamUI.active_tab = "library"

-- Filled by main.lua — each returns (rows, title, nav) for its tab
InkstreamUI.get_library_rows = nil
InkstreamUI.get_browse_rows  = nil
InkstreamUI.get_sources_rows = nil

local _panel  = nil  -- level 1: main tab panel (persistent)
local _detail = nil  -- level 2: detail / source-settings sub-screen
local _export = nil  -- level 3: export sub-screen

local function close_fn()
    if _G.inkstream_close_all then _G.inkstream_close_all() end
end

-- ── Level 1: main tab ─────────────────────────────────────────────────────────

function InkstreamUI.show(tab)
    if _export then UIManager:close(_export); _export = nil end
    if _detail then UIManager:close(_detail); _detail = nil end

    local same_tab = _panel ~= nil and InkstreamUI.active_tab == (tab or "library")
    InkstreamUI.active_tab = tab or "library"

    local rows, title, nav
    if InkstreamUI.active_tab == "library" and InkstreamUI.get_library_rows then
        rows, title, nav = InkstreamUI.get_library_rows()
    elseif InkstreamUI.active_tab == "browse" and InkstreamUI.get_browse_rows then
        rows, title, nav = InkstreamUI.get_browse_rows()
    elseif InkstreamUI.active_tab == "sources" and InkstreamUI.get_sources_rows then
        rows, title, nav = InkstreamUI.get_sources_rows()
    end

    if not rows then
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text    = "Tab not ready: " .. tostring(InkstreamUI.active_tab),
            timeout = 2,
        })
        return
    end

    local P = require("ui.panel")
    if _panel then
        _panel:swapBody(P.buildTabBody(InkstreamUI.active_tab, rows, title, close_fn, nav), close_fn, same_tab)
    else
        _panel = P.showTabPanel(InkstreamUI.active_tab, rows, title, close_fn, nav)
    end
end

-- ── Level 2: detail panel ─────────────────────────────────────────────────────

function InkstreamUI.setDetail(widget)
    if _export then UIManager:close(_export); _export = nil end
    if _detail then UIManager:close(_detail) end
    _detail = widget
end

function InkstreamUI.clearDetail()
    if _export then UIManager:close(_export); _export = nil end
    _detail = nil
end

-- ── Level 3: export panel ─────────────────────────────────────────────────────

function InkstreamUI.setExport(widget)
    if _export then UIManager:close(_export) end
    _export = widget
end

function InkstreamUI.clearExport()
    _export = nil
end

-- ── Legacy aliases ────────────────────────────────────────────────────────────

function InkstreamUI.showSub(widget)
    InkstreamUI.setDetail(widget)
end

function InkstreamUI.backFromSub()
    if _export then UIManager:close(_export); _export = nil end
    if _detail then UIManager:close(_detail); _detail = nil end
end

-- ── Close everything ──────────────────────────────────────────────────────────

function InkstreamUI.close()
    if _export then UIManager:close(_export); _export = nil end
    if _detail then UIManager:close(_detail); _detail = nil end
    if _panel  then UIManager:close(_panel);  _panel  = nil end
end

return InkstreamUI

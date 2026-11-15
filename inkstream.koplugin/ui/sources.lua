-- Sources screen (pushed from Browse): repositories, installed and available
-- extensions. "Refresh index" is the first (bold) row; tapping an installed
-- extension opens a settings dialog (version/site in the title, Page Mode
-- toggle, Uninstall, Close).
local UIManager    = require("ui/uimanager")
local InputDialog  = require("ui/widget/inputdialog")
local InfoMessage  = require("ui/widget/infomessage")
local ConfirmBox   = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local NetworkMgr   = require("ui/network/manager")
local ExtMgr       = require("core.extmgr")
local Settings     = require("settings")

local Sources = {}

local function rebuild()
    require("ui.main_widget").rebuild_current()
end

local function refresh_index()
    NetworkMgr:runWhenConnected(function()
        UIManager:show(InfoMessage:new{
            text = "Fetching extension index...", timeout = 2 })
        ExtMgr.fetchIndex()
        rebuild()
    end)
end

local function add_repo()
    local dlg
    dlg = InputDialog:new{
        title      = "Add Extension Repo",
        input_hint = "github.com/username/repo",
        buttons    = {{
            {
                text             = "Add",
                is_enter_default = true,
                callback         = function()
                    local raw = (dlg:getInputText() or ""):match("^%s*(.-)%s*$")
                    -- Strip https:// from GitHub URLs so we always store the short form
                    local to_store = raw:gsub("^https?://(github%.com/)", "%1")
                    UIManager:close(dlg)
                    if to_store ~= "" then
                        local added = ExtMgr.addRepo(to_store)
                        UIManager:show(InfoMessage:new{
                            text    = added
                                and "Repo added. Use Refresh index (the row above) to fetch it."
                                or  "Repo already in list.",
                            timeout = 3,
                        })
                        if added then rebuild() end
                    end
                end,
            },
            { text = "Cancel", callback = function() UIManager:close(dlg) end },
        }},
    }
    UIManager:show(dlg)
end

-- ── Extension settings dialog ────────────────────────────────────────────────

function Sources.ext_settings(meta)
    local dlg
    local ext = ExtMgr.get(meta.id)
    local buttons = {}

    if ext and ext.supports_page_mode then
        local pm = Settings:getExt(meta.id, "page_mode", false)
        table.insert(buttons, {{
            text = "Page Mode: " .. (pm and "ON" or "OFF"),
            callback = function()
                UIManager:close(dlg)
                Settings:toggleExt(meta.id, "page_mode", false)
                Sources.ext_settings(meta)  -- reopen with the updated label
            end,
        }})
    end

    table.insert(buttons, {{
        text = "Uninstall",
        callback = function()
            UIManager:close(dlg)
            UIManager:show(ConfirmBox:new{
                text = "Uninstall " .. meta.name .. "?",
                ok_callback = function()
                    ExtMgr.uninstall(meta.id)
                    rebuild()
                end,
            })
        end,
    }})
    table.insert(buttons, {{
        text     = "Close",
        callback = function() UIManager:close(dlg) end,
    }})

    dlg = ButtonDialog:new{
        title   = meta.name .. " — v" .. (meta.version or "?")
            .. "  ·  " .. (meta.site or "?"),
        buttons = buttons,
    }
    UIManager:show(dlg)
end

-- ── Screen builder ────────────────────────────────────────────────────────────

function Sources.build_screen()
    local items = {}

    -- First row: the former ☰ action, now a visible (bold) list row.
    table.insert(items, {
        text     = "↻ Refresh index",
        bold     = true,
        callback = refresh_index,
    })

    -- Repositories
    table.insert(items, { text = "Repositories", dim = true })
    local repos = ExtMgr.getRepos()
    if #repos == 0 then
        table.insert(items, { text = "(no repos added)", dim = true })
    else
        for _, url in ipairs(repos) do
            local u = url
            table.insert(items, {
                text      = u,
                mandatory = "hold to remove",
                dim       = true,
                hold_callback = function()
                    UIManager:show(ConfirmBox:new{
                        text        = "Remove this repo?\n" .. u,
                        ok_callback = function()
                            ExtMgr.removeRepo(u)
                            rebuild()
                        end,
                    })
                end,
            })
        end
    end
    table.insert(items, {
        text     = "+ Add Repo",
        bold     = true,
        callback = add_repo,
    })

    -- Installed
    table.insert(items, { text = "Installed", dim = true })
    local installed = ExtMgr.installed()
    if #installed == 0 then
        table.insert(items, { text = "(no sources installed)", dim = true })
    else
        for _, meta in ipairs(installed) do
            local m       = meta
            local has_upd = ExtMgr.hasUpdate(m.id)
            table.insert(items, {
                text      = m.name .. "  v" .. (m.version or "?") .. "  ·  " .. (m.lang or "en"),
                mandatory = has_upd and "update!" or "installed",
                bold      = has_upd,
                callback  = function() Sources.ext_settings(m) end,
            })
        end
    end

    -- Available
    table.insert(items, { text = "Available", dim = true })
    local avail = ExtMgr.available()
    if #avail == 0 then
        table.insert(items, { text = "(Refresh index to load)", dim = true })
    else
        for _, meta in ipairs(avail) do
            local m       = meta
            local inst    = ExtMgr.isInstalled(m.id)
            local has_upd = inst and ExtMgr.hasUpdate(m.id)
            table.insert(items, {
                text      = m.name .. "  ·  " .. (m.lang or "en"),
                mandatory = inst and (has_upd and "update!" or "installed") or "tap to install",
                dim       = inst and not has_upd,
                callback  = function()
                    if not inst or has_upd then
                        NetworkMgr:runWhenConnected(function()
                            UIManager:show(InfoMessage:new{
                                text    = (has_upd and "Updating " or "Installing ") .. m.name .. "...",
                                timeout = 2,
                            })
                            local ok, err = ExtMgr.install(m)
                            UIManager:show(InfoMessage:new{
                                text    = ok and (m.name .. " installed.") or ("Error: " .. tostring(err)),
                                timeout = 3,
                            })
                            if ok then rebuild() end
                        end)
                    end
                end,
            })
        end
    end

    return { title = "Sources", items = items }
end

return Sources

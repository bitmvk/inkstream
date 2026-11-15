-- Browse screen: source picker → per-source Popular list → search results.
-- Each list screen is a closure over its own context (source, page, search
-- term, results), so back navigation rebuilds the right screen. The source
-- API is paged without a known total, so site pages are list rows: a bold
-- "Search…" row, a "← Previous page" row when page > 1, then the novels, and
-- a "Next page" row last. Novel rows show a cover thumbnail on the left when
-- covers_browse is on. The root picker starts with a "Search all sources…"
-- row (ui/search.lua) and ends with a "Manage sources…" row.
local UIManager   = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr  = require("ui/network/manager")
local ExtMgr      = require("core.extmgr")
local Settings    = require("settings")
local Covers      = require("core.covers")

local Browse = {}
Browse.on_novel_tap = nil

local _fetch_id = 0

-- Builder closure for a pushed list screen (Popular or search results).
function Browse.list_builder(ctx)
    return function() return Browse.build_list_screen(ctx) end
end

function Browse.open_search(ctx)
    local meta = ExtMgr.getMeta(ctx.source_id) or {}
    local dlg
    dlg = InputDialog:new{
        title      = "Search — " .. (meta.name or ctx.source_id),
        input_hint = "Novel title...",
        buttons    = {{
            {
                text             = "Search",
                is_enter_default = true,
                callback         = function()
                    local term = dlg:getInputText()
                    UIManager:close(dlg)
                    if term and term ~= "" then
                        local sctx = {
                            source_id = ctx.source_id,
                            page      = 1,
                            search    = term,
                            novels    = {},
                        }
                        require("ui.main_widget").push(Browse.list_builder(sctx))
                        Browse.fetch_list(sctx, 1, term)
                    end
                end,
            },
            { text = "Cancel", callback = function() UIManager:close(dlg) end },
        }},
    }
    UIManager:show(dlg)
end

function Browse.build_list_screen(ctx)
    local source_id = ctx.source_id
    local novels    = ctx.novels or {}
    local meta      = ExtMgr.getMeta(source_id) or {}
    local is_search = ctx.search ~= nil

    local items = {}

    -- First row: search this source (the former ☰ action).
    table.insert(items, {
        text     = "Search…",
        bold     = true,
        callback = function() Browse.open_search(ctx) end,
    })

    -- Site pages are list rows, so they don't get confused with the Menu
    -- footer, which only pages through the results already loaded.
    if ctx.page > 1 then
        table.insert(items, {
            text     = "← Previous page (" .. (ctx.page - 1) .. ")",
            bold     = true,
            callback = function() Browse.fetch_list(ctx, ctx.page - 1, ctx.search) end,
        })
    end

    if #novels == 0 then
        table.insert(items, { text = "No results", dim = true })
    else
        local cover_urls = {}
        for _, novel in ipairs(novels) do
            local n = novel
            local entry = {
                text      = n.name or n.title or "?",
                subtitle  = n.author,
                callback  = function()
                    if Browse.on_novel_tap then Browse.on_novel_tap(source_id, n) end
                end,
            }
            if Settings:get("covers_browse") and n.cover and n.cover ~= "" then
                entry.cover_url = n.cover
                cover_urls[#cover_urls + 1] = n.cover
            end
            table.insert(items, entry)
        end
        Covers.request(cover_urls, function()
            require("ui.main_widget").rebuild_current()
        end)
    end

    table.insert(items, {
        text     = "Next page (" .. (ctx.page + 1) .. ") →",
        bold     = true,
        callback = function() Browse.fetch_list(ctx, ctx.page + 1, ctx.search) end,
    })

    local title = (meta.name or source_id)
        .. (is_search and ("  —  \"" .. ctx.search .. "\"") or "  —  Popular")

    return { title = title, items = items, items_per_page = 8 }
end

local function push_sources()
    require("ui.main_widget").push(function() return require("ui.sources").build_screen() end)
end

function Browse.build_picker_screen()
    local InkstreamUI = require("ui.main_widget")
    local installed   = ExtMgr.installed()
    local items       = {}

    -- First row: search every installed source at once.
    table.insert(items, {
        text     = "Search all sources…",
        bold     = true,
        callback = function() require("ui.search").open() end,
    })

    if #installed == 0 then
        table.insert(items, {
            text     = "No sources installed — go to Sources",
            dim      = true,
            callback = push_sources,
        })
        return { title = "Browse", items = items }
    end

    for _, meta in ipairs(installed) do
        local m = meta
        table.insert(items, {
            text      = m.name,
            mandatory = m.lang or "en",
            bold      = true,
            callback  = function()
                local ctx = { source_id = m.id, page = 1, search = nil, novels = {} }
                InkstreamUI.push(Browse.list_builder(ctx))
                Browse.fetch_list(ctx, 1, nil)
            end,
        })
    end

    table.insert(items, {
        text     = "Manage sources…",
        bold     = true,
        callback = push_sources,
    })
    return { title = "Browse", items = items }
end

-- Root screen: the source picker.
function Browse.build_screen()
    return Browse.build_picker_screen()
end

function Browse.fetch_list(ctx, page, search_term)
    local ext = ExtMgr.get(ctx.source_id)
    if not ext then
        UIManager:show(InfoMessage:new{
            text    = "Extension not loaded: " .. tostring(ctx.source_id),
            timeout = 3,
        })
        return
    end

    _fetch_id = _fetch_id + 1
    local my_id = _fetch_id

    NetworkMgr:runWhenConnected(function()
        if my_id ~= _fetch_id then return end

        local loading = InfoMessage:new{ text = "Loading…" }
        UIManager:show(loading)

        UIManager:scheduleIn(0.1, function()
            if my_id ~= _fetch_id then
                UIManager:close(loading)
                return
            end

            local novels, err
            if search_term and search_term ~= "" then
                local ok, res = pcall(ext.searchNovels, ext, search_term, page)
                if ok and res then novels = res.novels or res else err = tostring(res) end
            else
                local ok, res = pcall(ext.popularNovels, ext, page, {})
                if ok and res then novels = res.novels or res else err = tostring(res) end
            end

            UIManager:close(loading)

            if err then
                UIManager:show(InfoMessage:new{ text = "Error: " .. err, timeout = 4 })
                return
            end

            ctx.novels = novels or {}
            ctx.page   = page
            ctx.search = (search_term and search_term ~= "") and search_term or nil
            require("ui.main_widget").rebuild_current(true)
        end)
    end)
end

return Browse

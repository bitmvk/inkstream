-- "Search all sources" screen: a custom body (not a Menu list) showing one
-- section per installed source. Each section is a header (source name +
-- result count, with ‹ › paging when a source has more results than fit one
-- row) above a horizontal row of up to three novel cards. Tapping a card
-- opens the novel via Browse.on_novel_tap, exactly as the per-source lists do.
-- When more sources than fit on screen, a bottom ‹ › pager pages the sections
-- at the screen level.
local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Font          = require("ui/font")
local Geom          = require("ui/geometry")
local GestureRange  = require("ui/gesturerange")
local Size          = require("ui/size")
local UIManager     = require("ui/uimanager")
local TextWidget    = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InputDialog   = require("ui/widget/inputdialog")
local InfoMessage   = require("ui/widget/infomessage")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local ExtMgr          = require("core.extmgr")
local BgTask          = require("core.bgtask")
local Covers          = require("core.covers")
local Browse          = require("ui.browse")

local Screen = Device.screen

local Search = {}

local CARDS_PER_ROW = 3

local function rebuild()
    require("ui.main_widget").rebuild_current()
end

-- ── Small tap targets ─────────────────────────────────────────────────────────

local Pager = InputContainer:extend{
    on_tap = nil,
}

function Pager:init()
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function Pager:onTap()
    if self.on_tap then self.on_tap() end
    return true
end

local function make_pager(label, enabled, on_tap)
    local w = Screen:scaleBySize(40)
    local h = Screen:scaleBySize(36)
    return Pager:new{
        dimen  = Geom:new{ w = w, h = h },
        on_tap = enabled and on_tap or nil,
        [1]    = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text    = label,
                face    = Font:getFace("cfont", 20),
                fgcolor = enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
            },
        },
    }
end

local Card = InputContainer:extend{
    on_tap = nil,
}

function Card:init()
    self.ges_events = { Tap = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function Card:onTap()
    if self.on_tap then self.on_tap() end
    return true
end

local function make_card(source_id, novel, L)
    local cover
    if novel.cover and novel.cover ~= "" then
        cover = Covers.thumb_widget(novel.cover, L.card_w, L.cover_h)
    end
    if not cover then cover = Covers.placeholder(L.card_w, L.cover_h) end

    local title = TextBoxWidget:new{
        text                          = novel.name or novel.title or "?",
        face                          = Font:getFace("cfont", L.title_size),
        width                         = L.card_w,
        height                        = L.title_h,
        height_overflow_show_ellipsis = true,
        alignment                     = "center",
    }
    local author = TextWidget:new{
        text      = novel.author or "",
        face      = Font:getFace("cfont", L.author_size),
        max_width = L.card_w,
        fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
    }
    local card = Card:new{
        dimen  = Geom:new{ w = L.card_w, h = L.card_h },
        on_tap = function()
            if Browse.on_novel_tap then Browse.on_novel_tap(source_id, novel) end
        end,
    }
    card[1] = VerticalGroup:new{ align = "center", cover, title, author }
    return card
end

-- ── Body builder ──────────────────────────────────────────────────────────────

-- Per-source card offset is kept in state.offset[source_id] so it survives
-- the rebuilds triggered by paging / cover downloads.
local function get_offset(section)
    return section.state.offset[section.source_id] or 0
end

local function set_offset(section, value)
    section.state.offset[section.source_id] = math.max(0, value)
    rebuild()
end

local function line_h(size)
    return math.floor(size * 1.3 + 0.5)
end

-- "N results", "No results" or "Error: …"; ok tells us whether cards exist.
local function section_status(section)
    local r = section.result
    if r.error then
        return "Error: " .. r.error, false
    end
    local n = r.novels and #r.novels or 0
    if n == 0 then
        return "No results", false
    end
    return n .. " result" .. (n == 1 and "" or "s"), true
end

local function make_header(section, L)
    local status, ok = section_status(section)
    local novels = section.result.novels or {}
    local total  = #novels
    local has_pager = ok and total > CARDS_PER_ROW
    local offset = get_offset(section)

    local pager_w = Screen:scaleBySize(40)
    local label_w = L.avail_w - (has_pager and 2 * pager_w or 0)

    local label = TextWidget:new{
        text      = section.meta.name .. " — " .. status,
        face      = Font:getFace("cfont", L.header_size),
        bold      = ok,
        fgcolor   = ok and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        max_width = label_w,
    }

    local hgroup = HorizontalGroup:new{ align = "center" }
    if has_pager then
        table.insert(hgroup, make_pager("‹", offset > 0, offset > 0 and function()
            set_offset(section, offset - CARDS_PER_ROW)
        end or nil))
    end
    table.insert(hgroup, CenterContainer:new{
        dimen = Geom:new{ w = label_w, h = L.header_h },
        label,
    })
    if has_pager then
        table.insert(hgroup, make_pager("›", offset + CARDS_PER_ROW < total,
            offset + CARDS_PER_ROW < total and function()
                set_offset(section, offset + CARDS_PER_ROW)
            end or nil))
    end

    return CenterContainer:new{
        dimen = Geom:new{ w = L.avail_w, h = L.header_h },
        hgroup,
    }
end

local function make_cards_row(section, L)
    local novels = section.result.novels or {}
    local offset = get_offset(section)
    local row = HorizontalGroup:new{ align = "top" }
    local shown = 0
    for i = 1, CARDS_PER_ROW do
        local novel = novels[offset + i]
        if novel then
            if shown > 0 then
                table.insert(row, HorizontalSpan:new{ width = L.gap })
            end
            table.insert(row, make_card(section.source_id, novel, L))
            shown = shown + 1
        end
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = L.avail_w, h = L.card_h },
        row,
    }
end

local function make_empty_row(section, L)
    local text = section.result.error and ("Error: " .. section.result.error) or "No results"
    return CenterContainer:new{
        dimen = Geom:new{ w = L.avail_w, h = L.card_h },
        TextWidget:new{
            text    = text,
            face    = Font:getFace("cfont", L.title_size),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        },
    }
end

-- A "section" is one installed source and its result (novels or error).
local function build_sections(state)
    local sections = {}
    for _, meta in ipairs(ExtMgr.installed()) do
        sections[#sections + 1] = {
            state     = state,
            meta      = meta,
            source_id = meta.id,
            result    = state.results[meta.id] or { error = "no result" },
        }
    end
    return sections
end

function Search.body(state, w, h)
    local body = InputContainer:new{ dimen = Geom:new{ w = w, h = h } }

    if not state.results then
        body[1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text    = "Searching…",
                face    = Font:getFace("cfont", 18),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
        return body
    end

    local pad = Size.padding.fullscreen
    local avail_w = w - 2 * pad
    local gap = Screen:scaleBySize(8)
    local card_w = math.floor((avail_w - (CARDS_PER_ROW - 1) * gap) / CARDS_PER_ROW)
    local cover_h = math.floor(card_w * 1.5)
    local title_size, author_size, header_size = 16, 14, 16
    local title_h = 2 * line_h(title_size)
    local author_h = line_h(author_size) + 4
    local card_h = cover_h + title_h + author_h
    local pager_h = Screen:scaleBySize(36)
    local header_h = math.max(line_h(header_size) + Screen:scaleBySize(8), pager_h)
    local section_h = header_h + card_h + Screen:scaleBySize(6)

    local L = {
        avail_w = avail_w, gap = gap, card_w = card_w, cover_h = cover_h,
        title_size = title_size, author_size = author_size, header_size = header_size,
        title_h = title_h, author_h = author_h, card_h = card_h, header_h = header_h,
    }

    local sections = build_sections(state)
    local total = #sections
    if total == 0 then
        body[1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            TextWidget:new{
                text    = "No sources installed",
                face    = Font:getFace("cfont", 18),
                fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            },
        }
        return body
    end

    -- Page the sections when there are more than fit on screen (the frame
    -- padding takes `pad` off the top and bottom of the body).
    local inner_h = h - 2 * pad
    local fit = math.max(1, math.floor(inner_h / section_h))
    local page_count = 1
    if total > fit then
        fit = math.max(1, math.floor((inner_h - pager_h) / section_h))
        page_count = math.ceil(total / fit)
    end
    local page = math.max(1, math.min(state.section_page or 1, page_count))
    state.section_page = page
    local first = (page - 1) * fit + 1
    local last  = math.min(page * fit, total)

    local group = VerticalGroup:new{ align = "center" }
    for i = first, last do
        if i > first then
            table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(6) })
        end
        local s = sections[i]
        table.insert(group, make_header(s, L))
        if s.result.error or not (s.result.novels and #s.result.novels > 0) then
            table.insert(group, make_empty_row(s, L))
        else
            table.insert(group, make_cards_row(s, L))
        end
    end

    if page_count > 1 then
        local prev = page > 1 and function()
            state.section_page = page - 1
            rebuild()
        end or nil
        local nxt = page < page_count and function()
            state.section_page = page + 1
            rebuild()
        end or nil
        local label = TextWidget:new{
            text    = "Sources " .. first .. "–" .. last .. " of " .. total,
            face    = Font:getFace("cfont", 14),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
        local row = HorizontalGroup:new{ align = "center" }
        table.insert(row, make_pager("‹", prev ~= nil, prev))
        table.insert(row, HorizontalSpan:new{ width = Screen:scaleBySize(12) })
        table.insert(row, label)
        table.insert(row, HorizontalSpan:new{ width = Screen:scaleBySize(12) })
        table.insert(row, make_pager("›", nxt ~= nil, nxt))
        table.insert(group, CenterContainer:new{
            dimen = Geom:new{ w = avail_w, h = pager_h },
            row,
        })
    end

    -- Download any missing covers in the background; the done callback rebuilds
    -- the body so the placeholders are replaced once the files arrive.
    local urls = {}
    for _, s in ipairs(sections) do
        for _, novel in ipairs(s.result.novels or {}) do
            if novel.cover and novel.cover ~= "" then
                urls[#urls + 1] = novel.cover
            end
        end
    end
    Covers.request(urls, rebuild)

    body[1] = FrameContainer:new{
        padding = pad,
        group,
    }
    return body
end

-- ── Search flow ───────────────────────────────────────────────────────────────

local function search_builder(state)
    return function() return Search.build_screen(state) end
end

function Search.build_screen(state)
    return {
        title = "Search: " .. (state.term or ""),
        body  = function(w, h) return Search.body(state, w, h) end,
    }
end

-- Run searchNovels(term, 1) on every installed extension in one BgTask child.
local function search_all(term)
    local results = {}
    for _, meta in ipairs(ExtMgr.installed()) do
        local ext = ExtMgr.get(meta.id)
        if not ext then
            results[meta.id] = { error = "not loaded" }
        else
            local ok, res = pcall(ext.searchNovels, ext, term, 1)
            if ok then
                results[meta.id] = { novels = (res and res.novels) or res or {} }
            else
                results[meta.id] = { error = tostring(res) }
            end
        end
    end
    return results
end

function Search.start(state)
    local msg = InfoMessage:new{ text = "Searching…" }
    UIManager:show(msg)
    BgTask.start("search-all", BgTask.child(function()
        return search_all(state.term)
    end), function(data)
        UIManager:close(msg)
        state.results = data or {}
        rebuild()
    end)
end

function Search.open()
    local dlg
    dlg = InputDialog:new{
        title      = "Search all sources",
        input_hint = "Novel title...",
        buttons    = {{
            {
                text             = "Search",
                is_enter_default = true,
                callback         = function()
                    local term = dlg:getInputText()
                    UIManager:close(dlg)
                    if term and term ~= "" then
                        local state = {
                            term         = term,
                            results      = nil,
                            offset       = {},
                            section_page = 1,
                        }
                        require("ui.main_widget").push(search_builder(state))
                        Search.start(state)
                    end
                end,
            },
            { text = "Cancel", callback = function() UIManager:close(dlg) end },
        }},
    }
    UIManager:show(dlg)
end

return Search

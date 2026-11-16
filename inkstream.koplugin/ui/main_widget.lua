-- Inkstream UI shell. A full-screen container (covers_fullscreen, white
-- background) holds the screen and a persistent Library|Browse tab bar.
--
-- Screens are a stack of builders. A builder returns either a Menu screen
--   { title, subtitle?, items, items_per_page? }
-- or a custom-body screen
--   { title, subtitle?, body = function(w, h) return widget end }
-- For a custom body the shell shows a KOReader TitleBar (FileManager style:
-- back chevron on the left, ✕ on the right), then the body, then the tab bar,
-- in place of the Menu. Back, the device Back key, the tabs and
-- rebuild_current work for both kinds.
--
-- On root screens the title-bar left icon is a settings gear; on pushed
-- screens it is a back chevron. The footer back arrow and the device Back key
-- pop the stack (closing Inkstream at the root).
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local LineWidget     = require("ui/widget/linewidget")
local Menu           = require("ui/widget/menu")
local Size           = require("ui/size")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local TitleBar        = require("ui/widget/titlebar")
local Covers          = require("core.covers")

local Screen = Device.screen

local InkstreamUI = {}

local _root_builders = {}       -- root name -> builder function
local _menu           = nil     -- the single Menu instance (nil when closed)
local _tab_bar        = nil
local _container      = nil     -- the top-level widget UIManager shows/closes
local _title_bar      = nil     -- TitleBar shown for a custom-body screen
local _body           = nil     -- the custom-body widget (nil for Menu screens)

local TAB_BAR_HEIGHT = Screen:scaleBySize(56)

local function free_detail_cover()
    local ok, Detail = pcall(require, "ui.detail")
    if ok and Detail.free_cover then Detail.free_cover() end
end

-- ── Full-screen container ─────────────────────────────────────────────────────
-- What UIManager:show / UIManager:close act on. It paints a white background
-- and forwards events (tap, hold, swipe, keys) to its child VerticalGroup, so
-- both the Menu (or body) and the tab bar stay interactive.

local InkstreamContainer = WidgetContainer:extend{
    covers_fullscreen = true,
}

function InkstreamContainer:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
end

function InkstreamContainer:paintTo(bb, x, y)
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    WidgetContainer.paintTo(self, bb, x, y)
end

-- ── Bottom tab bar ────────────────────────────────────────────────────────────

local TAB_LABELS = { library = "Library", browse = "Browse" }

local InkstreamTabBar = InputContainer:extend{
    active_tab = nil,  -- "library" or "browse"
    callback   = nil,  -- function(tab_name)
}

local function make_tab_cell(name, width, height, active)
    local indicator = LineWidget:new{
        dimen      = Geom:new{ w = width, h = Size.line.thick },
        background = Blitbuffer.COLOR_BLACK,
        style      = active and "solid" or "none",
    }
    local label = TextWidget:new{
        text     = TAB_LABELS[name],
        face     = Font:getFace("cfont", 20),
        bold     = active,
        fgcolor  = Blitbuffer.COLOR_BLACK,
    }
    return VerticalGroup:new{
        align = "center",
        indicator,
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = height - Size.line.thick },
            label,
        },
    }
end

function InkstreamTabBar:init()
    local screen_w = Screen:getWidth()
    local w1       = math.floor(screen_w / 2)
    local w2       = screen_w - w1

    self.dimen       = Geom:new{ x = 0, y = Screen:getHeight() - TAB_BAR_HEIGHT,
        w = screen_w, h = TAB_BAR_HEIGHT }
    self.cell_widths = { w1, w2 }

    -- Absolute screen ranges (the bar sits at the bottom of the screen).
    self.ges_events = {
        TapTab1 = { GestureRange:new{ ges = "tap", range = Geom:new{
            x = 0, y = self.dimen.y, w = w1, h = TAB_BAR_HEIGHT } } },
        TapTab2 = { GestureRange:new{ ges = "tap", range = Geom:new{
            x = w1, y = self.dimen.y, w = w2, h = TAB_BAR_HEIGHT } } },
    }

    self:_build()
end

function InkstreamTabBar:_build()
    self:clear()
    local cell_h = TAB_BAR_HEIGHT - Size.line.medium  -- space under the hairline
    local cells  = HorizontalGroup:new{ align = "top" }
    table.insert(cells, make_tab_cell("library", self.cell_widths[1],
        cell_h, self.active_tab == "library"))
    table.insert(cells, make_tab_cell("browse", self.cell_widths[2],
        cell_h, self.active_tab == "browse"))
    self[1] = VerticalGroup:new{
        align = "center",
        LineWidget:new{  -- hairline separator along the top edge
            dimen      = Geom:new{ w = self.dimen.w, h = Size.line.medium },
            background = Blitbuffer.COLOR_BLACK,
        },
        cells,
    }
end

function InkstreamTabBar:set_active(name)
    if self.active_tab == name then return end
    self.active_tab = name
    self:_build()
    UIManager:setDirty(self.show_parent or self, "ui", self.dimen)
end

function InkstreamTabBar:onTapTab1()
    return self:select("library")
end

function InkstreamTabBar:onTapTab2()
    return self:select("browse")
end

function InkstreamTabBar:select(name)
    if self.callback then self.callback(name) end
    return true
end

-- ── Menu subclass ─────────────────────────────────────────────────────────────

local InkstreamMenu = Menu:extend{
    is_borderless      = true,
    is_popout          = false,
    title_bar_fm_style = true,
}

-- The builder of the screen currently on top (root, or the last pushed one).
function InkstreamMenu:current_builder()
    return self.paths[#self.paths] or self.root_builder
end

-- Left title-bar icon follows the stack depth: a settings gear on roots, a
-- back chevron on pushed screens.
function InkstreamMenu:update_left_icon()
    local icon = (#self.paths > 0) and "chevron.left" or "appbar.settings"
    if self.title_bar_left_icon ~= icon then
        self.title_bar_left_icon = icon
        self:setTitleBarLeftIcon(icon)
    end
end

function InkstreamMenu:init()
    self.root_builder        = _root_builders[self.root_name]
    self.title_bar_left_icon = "appbar.settings"
    Menu.init(self)
    -- The device Back key pops the screen stack (closing at the root); the
    -- title-bar ✕ (onClose) closes Inkstream entirely.
    if Device:hasKeys() then
        self.key_events.Close = nil
        self.key_events.Back  = { { Device.input.group.Back } }
        if Device:hasFewKeys() then
            self.key_events.Back = { { "Left" } }
        end
    end
end

-- Visual for a row whose entry has a `subtitle` (e.g. novel title + author):
-- title in the item font, subtitle below it smaller and grey, `mandatory` on
-- the right. When the entry carries `cover_url` / `cover_data` a cover
-- thumbnail is drawn on the left. Mirrors MenuItem's own layout (padding,
-- underline).
local function thumb_size(item_h)
    local h = math.floor(item_h * 0.78)
    return math.floor(h * 2 / 3), h
end

local function two_line_row(item)
    local entry  = item.entry
    local w, h   = item.content_width, item.dimen.h
    local dim    = entry.dim and Blitbuffer.COLOR_DARK_GRAY or nil
    local mandatory, mand_w = nil, 0
    if entry.mandatory then
        mandatory = TextWidget:new{ text = tostring(entry.mandatory), face = item.info_face, fgcolor = dim }
        mand_w = mandatory:getWidth() + Size.span.horizontal_default
    end
    local cover, cover_w = nil, 0
    if entry.cover_url or entry.cover_data then
        local tw, th = thumb_size(h)
        cover = Covers.thumb_widget(entry.cover_url, tw, th)
            or Covers.thumb_widget_from_data(entry.cover_data, tw, th)
            or Covers.placeholder(tw, th)
        cover_w = tw + Size.span.horizontal_default
    end
    local text_w = w - cover_w - mand_w
    local lines = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = entry.text, face = item.face, bold = item.bold,
            max_width = text_w, fgcolor = dim },
    }
    if entry.subtitle and entry.subtitle ~= "" then
        table.insert(lines, TextWidget:new{
            text     = entry.subtitle,
            face     = Font:getFace("cfont", item.infont_size),  -- item font, smaller
            max_width = text_w,
            fgcolor  = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    local box = Geom:new{ w = w, h = h }
    local content = HorizontalGroup:new{ align = "center" }
    if cover then
        table.insert(content, cover)
        table.insert(content, HorizontalSpan:new{ width = Size.span.horizontal_default })
    end
    table.insert(content, lines)
    local overlap = OverlapGroup:new{
        dimen = box:copy(),
        LeftContainer:new{ dimen = box:copy(), content },
    }
    if mandatory then
        table.insert(overlap, RightContainer:new{ dimen = box:copy(), mandatory })
    end
    -- MenuItem:onFocus/onUnfocus recolour its _underline_container to draw the
    -- focus indicator (DPad/key devices). Point that field at this row's
    -- underline, keeping a colour the stock row may already have.
    local underline = UnderlineContainer:new{
        color = (item._underline_container and item._underline_container.color)
            or item.line_color,
        linesize = item.linesize,
        vertical_align = "center", padding = 0,
        dimen = Geom:new{ x = 0, y = 0, w = w, h = h },
        overlap,
    }
    item._underline_container = underline
    return FrameContainer:new{
        bordersize = 0, padding = 0,
        HorizontalGroup:new{
            align = "center",
            HorizontalSpan:new{ width = item.items_padding or Size.padding.fullscreen },
            underline,
            HorizontalSpan:new{ width = Size.padding.fullscreen },
        },
    }
end

-- Menu's MenuItem can't style two lines differently, so after the stock
-- layout we redraw rows that carry a subtitle (or a cover). Taps and holds
-- are still handled by the MenuItem itself. If MenuItem ever lacks the fields
-- used here, the row keeps its stock look (title only).
function InkstreamMenu:updateItems(...)
    -- The old rows are about to be cleared, so release their cover BlitBuffers
    -- first (page turns and rebuilds both come through here).
    Covers.free_all()
    Menu.updateItems(self, ...)
    for _, item in ipairs(self.item_group) do
        local e = item.entry
        if e and (e.subtitle or e.cover_url or e.cover_data)
                and item.face and item.info_face and item.infont_size and item.content_width then
            -- Build the replacement first (it reads the stock row's focus
            -- colour), then release the stock row it replaces.
            local row = two_line_row(item)
            if item[1] then item[1]:free() end
            item[1] = row
        end
    end
end

-- Tap = run the item's callback. (The base also fires close_callback, which
-- must not happen for a full-screen navigation menu.)
function InkstreamMenu:onMenuSelect(item)
    if item.callback then item.callback() end
    return true
end

-- Long-press = run the item's hold callback.
function InkstreamMenu:onMenuHold(item)
    if item.hold_callback then item.hold_callback() end
    return true
end

-- Footer back arrow / device Back key: pop and rebuild the previous screen
-- from its builder (fresh data), closing Inkstream at the root.
function InkstreamMenu:onReturn()
    return InkstreamUI.on_return()
end

function InkstreamMenu:onBack()
    return self:onReturn()
end

-- Title-bar left button: back on pushed screens, Settings on roots.
function InkstreamMenu:onLeftButtonTap()
    if #self.paths > 0 then
        self:onReturn()
    else
        require("ui.settings_dialog").show()
    end
end

-- ✕ button (and swipe south / multiswipe): close Inkstream entirely. The base
-- would call UIManager:close on the Menu, but the container is the top-level
-- widget now.
function InkstreamMenu:onClose()
    InkstreamUI.close()
    return true
end

-- ── Custom-body screen ────────────────────────────────────────────────────────
-- Wraps a body widget and handles the device Back key (the TitleBar's back
-- chevron and ✕ are wired separately in render_body).

local BodyScreen = InputContainer:extend{
    on_back = nil,
}

function BodyScreen:init()
    if Device:hasKeys() then
        self.key_events.Back = { { Device.input.group.Back } }
        if Device:hasFewKeys() then
            self.key_events.Back = { { "Left" } }
        end
    end
end

function BodyScreen:onBack()
    if self.on_back then self.on_back() end
    return true
end

-- ── Controller ────────────────────────────────────────────────────────────────

local function current_builder()
    return _menu.paths[#_menu.paths] or _menu.root_builder
end

local function render_menu(screen, itemnumber)
    -- Swap the container back to the Menu (never clear(): WidgetContainer:clear
    -- would free the long-lived _menu/_tab_bar instances). A body screen's
    -- title bar and body belong to that screen only, so release them here.
    if _title_bar then _title_bar:free() end
    if _body then _body:free() end
    _title_bar = nil
    _body      = nil
    _container[1] = VerticalGroup:new{ _menu, _tab_bar }
    -- Screens with subtitle rows ask for fewer, taller rows; nil = default.
    _menu.items_per_page = screen.items_per_page
    _menu:switchItemTable(screen.title or "Inkstream",
        screen.items or {}, itemnumber, nil, screen.subtitle or "")
end

local function render_body(screen)
    -- Rebuilds come through here too: release the screen being replaced
    -- before building its successor.
    if _title_bar then _title_bar:free() end
    if _body then _body:free() end
    -- Build the title bar first so its height is known for the body area.
    _title_bar = TitleBar:new{
        width              = Screen:getWidth(),
        fullscreen         = "true",
        align              = "center",
        title              = screen.title or "Inkstream",
        subtitle           = screen.subtitle or "",
        title_top_padding  = Screen:scaleBySize(6),
        button_padding     = Screen:scaleBySize(5),
        left_icon          = "chevron.left",
        left_icon_size_ratio  = 1,
        right_icon_size_ratio = 1,
        left_icon_tap_callback = function() InkstreamUI.on_return() end,
        close_callback = function() InkstreamUI.close() end,
        show_parent = _container,
    }
    local body_h = Screen:getHeight() - TAB_BAR_HEIGHT - _title_bar:getHeight()
    local body   = screen.body(Screen:getWidth(), body_h)

    _body = BodyScreen:new{
        dimen   = Geom:new{ w = Screen:getWidth(), h = body_h },
        on_back = function() InkstreamUI.on_return() end,
    }
    _body[1] = body

    _container[1] = VerticalGroup:new{ _title_bar, _body, _tab_bar }
    UIManager:setDirty(_container, "ui", _container.dimen)
end

-- Build and show whatever screen is currently on top. Frees the previous
-- screen's cover BlitBuffers first, before this screen's widgets are built
-- (a custom body is built inside render_body), so stale BBs are never painted
-- and full-size images are not kept around.
local function render(itemnumber)
    local builder = current_builder()
    local screen  = builder and builder() or { title = "Inkstream", items = {} }
    _menu.current_screen = screen
    Covers.free_all()
    if screen.body then
        render_body(screen)
    else
        render_menu(screen, itemnumber)
    end
    _menu:update_left_icon()
end

function InkstreamUI.set_root_builder(name, fn)
    _root_builders[name] = fn
end

-- Pop the stack (or close at the root); shared by the Menu footer/Back key,
-- the body TitleBar back chevron and the body Back key.
function InkstreamUI.on_return()
    if _menu and #_menu.paths > 0 then
        table.remove(_menu.paths)
        render(nil)
    else
        InkstreamUI.close()
    end
    return true
end

-- Open Inkstream at the given root, or switch roots in place (resets the
-- stack and the tab-bar highlight).
function InkstreamUI.show(root_name)
    if _container then
        _menu.root_builder = _root_builders[root_name]
        _menu.paths        = {}
        _tab_bar:set_active(root_name)
        render(nil)
        return
    end

    _container = InkstreamContainer:new{}
    _menu = InkstreamMenu:new{
        title       = "Inkstream",
        root_name   = root_name,
        height      = Screen:getHeight() - TAB_BAR_HEIGHT,  -- room for the tab bar
        show_parent = _container,
    }
    _tab_bar = InkstreamTabBar:new{
        active_tab  = root_name,
        show_parent = _container,
        callback    = function(tab_name) InkstreamUI.show(tab_name) end,
    }
    UIManager:show(_container)
    render(nil)
end

-- Push a screen onto the stack.
function InkstreamUI.push(builder)
    if not _menu then return end
    table.insert(_menu.paths, builder)
    render(nil)
end

-- Rebuild the current screen in place, keeping the current page
-- (or going back to the first page when to_top is set).
function InkstreamUI.rebuild_current(to_top)
    if not _menu then return end
    local itemnumber = not to_top and (_menu.page - 1) * (_menu.perpage or 1) + 1 or nil
    render(itemnumber)
end

function InkstreamUI.close()
    Covers.free_all()
    if _container then
        UIManager:close(_container)
        _container = nil
    end
    _menu      = nil
    _tab_bar   = nil
    _title_bar = nil
    _body      = nil
    free_detail_cover()
end

return InkstreamUI

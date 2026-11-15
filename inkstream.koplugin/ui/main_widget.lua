-- Inkstream UI shell. A full-screen container (covers_fullscreen, white
-- background) holds a VerticalGroup of the screen Menu and a persistent
-- Library|Browse tab bar. Screens are a stack of builders that each return
-- { title, subtitle?, items }. The title-bar left icon is a settings gear on
-- root screens and a back chevron on pushed screens; the right ✕ closes
-- Inkstream; the footer back arrow and the device Back key pop the stack
-- (closing Inkstream at the root).
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
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer  = require("ui/widget/container/inputcontainer")
local VerticalGroup   = require("ui/widget/verticalgroup")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local Screen = Device.screen

local InkstreamUI = {}

local _root_builders = {}       -- root name -> builder function
local _menu           = nil     -- the single Menu instance (nil when closed)
local _tab_bar        = nil
local _container      = nil     -- the top-level widget UIManager shows/closes

local TAB_BAR_HEIGHT = Screen:scaleBySize(56)

local function free_detail_cover()
    local ok, Detail = pcall(require, "ui.detail")
    if ok and Detail.free_cover then Detail.free_cover() end
end

-- ── Full-screen container ─────────────────────────────────────────────────────
-- What UIManager:show / UIManager:close act on. It paints a white background
-- and forwards events (tap, hold, swipe, keys) to its child VerticalGroup, so
-- both the Menu and the tab bar stay interactive.

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

-- Build and show a screen. itemnumber >= 1 keeps the current page; nil resets.
function InkstreamMenu:render_screen(itemnumber)
    local builder = self:current_builder()
    local screen  = builder and builder() or { title = "Inkstream", items = {} }
    self.current_screen = screen
    -- Screens with two-line rows ask for fewer, taller rows; nil = default.
    self.items_per_page = screen.items_per_page
    self:switchItemTable(screen.title or "Inkstream",
        screen.items or {}, itemnumber, nil, screen.subtitle or "")
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
    self:render_screen(nil)
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
    if #self.paths > 0 then
        table.remove(self.paths)
        self:render_screen(nil)
        self:update_left_icon()
    else
        InkstreamUI.close()
    end
    return true
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

-- ── Controller API ────────────────────────────────────────────────────────────

function InkstreamUI.set_root_builder(name, fn)
    _root_builders[name] = fn
end

-- Open Inkstream at the given root, or switch roots in place (resets the
-- stack and the tab-bar highlight).
function InkstreamUI.show(root_name)
    if _container then
        _menu.root_builder = _root_builders[root_name]
        _menu.paths        = {}
        _tab_bar:set_active(root_name)
        _menu:render_screen(nil)
        _menu:update_left_icon()
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
    _container[1] = VerticalGroup:new{ _menu, _tab_bar }
    UIManager:show(_container)
end

-- Row text with a second line (e.g. title + author). Menu turns "\n" into a
-- space, but keeps U+2028 LINE SEPARATOR, which its text box breaks on.
-- Screens using this should set items_per_page so rows are tall enough.
function InkstreamUI.two_lines(first, second)
    if not second or second == "" then return first end
    return first .. "\226\128\168" .. second  -- U+2028
end

-- Push a screen onto the stack.
function InkstreamUI.push(builder)
    if not _menu then return end
    table.insert(_menu.paths, builder)
    _menu:render_screen(nil)
    _menu:update_left_icon()
end

-- Rebuild the current screen in place, keeping the current page
-- (or going back to the first page when to_top is set).
function InkstreamUI.rebuild_current(to_top)
    if not _menu then return end
    local itemnumber = not to_top and (_menu.page - 1) * (_menu.perpage or 1) + 1 or nil
    _menu:render_screen(itemnumber)
end

function InkstreamUI.close()
    if _container then
        UIManager:close(_container)
        _container = nil
    end
    _menu    = nil
    _tab_bar = nil
    free_detail_cover()
end

return InkstreamUI

-- USAGE -- {{{1
-- A conky widget is:
-- {
--     icon  = <string>: image filename
--     label = <string>: plaintext
--     conky = <string>: to call conky_parse() on
--     updater = <function>: gets passed the result from conky, and the wiboxes
--                           for conky, icon, and label, in that order
--
--    <list> of nested conky widget declarations
--           OR other wiboxes
-- }
--
-- s.myconky = conky.widget:setup {
--    {
--      icon = "cpu",
--      conky = "${cpu%}",
--      width = 30,        -- minimum width for conky text field
--      {
--          -- nested widgets
--          { conky = "$cpu1%" },
--          { conky = "$cpu2%" },
--          { conky = "$cpu3%" },
--          { conky = "$cpu4%" },
--          cat_litter_box_status_widget,   -- include other wiboxes
--      }
--    },
--    {
--      label = "RAM",
--      conky = "$memperc%",
--    },
--    {
--      label = "↑",
--      label_width = 12,           -- minimum width for label
--      conky = "${upspeed eth0}",
--    },
--    {
--      label = "↓",
--      label_width = 12,
--      conky = "${downspeed eth0}",
--    },
--    {
--      icon = "resting_bear.png"       -- widget consisting of only an icon
--      conky = "$cpu%"
--      updater = (function()                     -- supply an updater function
--          local still = "resting_bear.png"      -- to do ... whatever, really
--          local current_frame = 1
--          local frames = {
--              "dancing_bear_01.png",
--              "dancing_bear_02.png",
--              "dancing_bear_03.png",
--              "dancing_bear_04.png",
--              "dancing_bear_05.png",
--          }
--          return function(conky_update, conky_wibox, icon_wibox, label_wibox)
--              local cpu = tonumber(string.sub(conky_update, 1, -2))
--              if cpu < 40 then
--                  icon_wibox:set_image(still)
--              else
--                  icon_wibox:set_image(frames[current_frame])
--                  current_frame = current_frame + 1
--                  if current_frame > 5 then current_frame = 1 end
--              end
--          end
--      end)()
--    }
-- }

-- TODO: add props to match out client specifically

-- INIT -- {{{1
local awful = require("awful")
local gears = require("gears")
local wibox = require("wibox")
awful.client = require("awful.client")

local const = require("conky/common-constants")

-- luacheck: ignore dbus awesome

local dbus = dbus



--local load = loadstring or load
--local tostring = tostring
--local ipairs = ipairs
--local table = table
--local unpack = unpack or table.unpack
--local type = type


local widget = {}  -- for the window that awesome draws
local updater = {} -- for updating the widget
local window = {}  -- for conky's own window
local public = {}  -- public interface


local conky = {}
conky.rule = { rule = { class = "Conky" },
               properties = {
                 floating = true,
                 sticky = true,
                 ontop = true,
                 focusable = false,
                 x = 0,
                 y = 20,
                 width = 1050,
                 height = 510
               },
             }

-- PUBLIC INTERFACE -- {{{1
function public.widget(root) -- {{{2
    -- builds the widget from nested tables
    local unprocessed = widget.Stack()
    local processed   = widget.Stack()

    unprocessed.push(widget.maybe_require(root))

    for raw_wibox in unprocessed.head do
        -- already processed or premade wibox: leaf
        -- (wiboxes are type:table so we look for the draw function)
        if raw_wibox.draw then
            processed.push(unprocessed.pop())

        -- not seen before, so mark, pass properties to children,
        -- and push children onto the unprocessed stack
        elseif not raw_wibox[0] then
            raw_wibox[0] = true
            for _, nested in ipairs(raw_wibox) do
                nested = widget.maybe_require(nested)
                unprocessed.push(nested)
                widget.inherit_properties(nested, raw_wibox)
            end

        -- seen before, so all children are on the processed stack
        else
            -- make wibox and wrap in layout
            local layout = widget.conkybox_for(raw_wibox)
            for _, _ in ipairs(raw_wibox) do
                layout:add(processed.pop())
            end
            -- pop raw and push processed
            unprocessed.pop()
            processed.push(layout)
        end
    end
    -- when unprocessed stack is empty
    -- finished wibox is single element on processed
    return processed.pop()
end

function public.show_key(key, mod) -- {{{2
    -- sets the key to hold for the conky window to be visible
    return awful.key(mod or {}, key, window.raise, window.lower_delayed,
           { description = "conky window on top while held", group = "conky" })
end

function public.toggle_key(key, mod)  -- {{{2
    -- sets the key to press to toggle the conky window visibility
    return awful.key(mod or {}, key, window.toggle,
           { description = "toggle conky window on top", group = "conky" })
end

function public.rule()  -- {{{2
    return conky.rule
end


-- WIDGET -- {{{1
function widget.conkybox_for(raw) -- {{{2
    local layout = wibox.layout.fixed.horizontal()

    local iconbox = nil
    if raw.icon then
        iconbox = wibox.widget.imagebox(raw.icon, true)
        widget.apply_properties(raw, iconbox, "iconbox")
        layout:add(iconbox)
    end

    local labelbox = nil
    if raw.label then
        labelbox = wibox.widget.textbox(raw.label)
        widget.apply_properties(raw, labelbox, "labelbox")
        layout:add(labelbox)
    end

    if raw.conky then
        local conkybox = wibox.widget.textbox("")
        widget.apply_properties(raw, conkybox, "conkybox")
        layout:add(conkybox)

        updater.add_string(raw.conky)
        updater.add(conkybox, iconbox, labelbox, raw.updater)
    end

    return layout
end

function widget.inherit_properties(child, parent) -- {{{2
    for prop, value in pairs(parent) do
        -- assume all number keys are list items/nested widgets
        if type(prop) == "number" then
            repeat until true -- noop/continue
        elseif prop == "conkybox" or
               prop == "labelbox" or
               prop == "iconbox"
            then if child[prop] then
                widget.inherit_properties(child[prop], value)
            else
                child[prop] = value
            end
        else
            child[prop] = child[prop] or value
        end
    end
end

function widget.apply_properties(raw, w, wtype)
    local props = {}
    for prop, value in pairs(raw) do
        if type(prop) == "number" or
           prop == "conkybox" or
           prop == "labelbox" or
           prop == "iconbox" or
           prop == "label" or
           prop == "conky" or
           prop == "updater" or
           prop == "icon" then repeat until true
        else
            props[prop] = value
        end
    end

    for prop, value in pairs(raw[wtype] or {}) do
        props[prop] = value
    end

    for prop, value in pairs(props) do
        w[prop] = value
    end
end

function widget.set_width(wb, width) -- {{{2
    -- forces a minimum with, if provided
    if (width or 0) <= 0 then
        return wb
    else
        return wibox.container.constraint(wb, "min", width)
    end
end

function widget.maybe_require(t_or_str) -- {{{2
    if type(t_or_str) == "string" then
        t_or_str = require("conky/widgets/" .. t_or_str)
    end
    return t_or_str
end

function widget.Stack() -- {{{2
    return (function()
        local stack = {}
        local head = 0
        return {
            head = function()
                return stack[head]
            end,

            push = function(e)
                head = head + 1
                stack[head] = e
            end,

            pop = function()
                if head == 0 then return nil end
                local e = stack[head]
                stack[head] = nil
                head = head - 1
                return e
            end
        }
    end)()
end


-- WINDOW -- {{{1
function window.toggle() -- {{{2
    local c = window.client()
    c.below = not c.below
    c.ontop = not c.ontop
end

function window.raise() -- {{{2
    window.client().below = false
    window.client().ontop = true
end

function window.lower() -- {{{2
    window.client().ontop = false
    window.client().below = true
end

-- function window.lower_auto() -- {{{2
window.timer = gears.timer({ timeout = 0.05 })
window.timer:connect_signal("timeout", function()
    window.timer:stop()
    window.lower()
end)

function window.lower_delayed() -- {{{2
    window.timer:again()
end

function window.spawn() -- {{{2
    awful.spawn(const("CONKY_LAUNCH"),
                true, -- keep startup notifications
                updater.send_string)
end
awesome.connect_signal("started",
                       function()
                           return window.client().valid or window.spawn()
                       end)

function window.client() -- {{{2
    -- finds and returns the client object
    if window.c and window.c.valid then
    return window.c
    end

    window.c = awful.client.iterate(function(c)
                                        return c.class == "Conky"
                                    end)()
    return window.c or {}
end

-- UPDATER -- {{{1
-- function updater.handle_update() -- {{{2
if dbus then
    dbus.add_match("session",
        "type='signal', interface='" .. const("UPDATE_FOR_WIDGET") .. "'")

    dbus.connect_signal(const("UPDATE_FOR_WIDGET"),

        (function()
            local all_but_delim = "[^" .. const("DELIMITER") .. "]+"
            local widget_update = const("MEMBER")
            local need_string = const("CONKY_NEEDS_STRING")

            return function(data, conky_update)
                if data.member == widget_update then

                                     -- lua "split string"
                    local from_conky_iter = string.gmatch(conky_update, all_but_delim)
                    for _,update_func in ipairs(updater) do
                        update_func(from_conky_iter())
                    end
                elseif data.member == need_string then
                    updater.send_string()
                end
            end
        end)()
    )
else
    error("No DBus!")
end


function updater.send_string() -- {{{2
    dbus.emit_signal("session",
                     const("DBUS_PATH"),
                     const("STRING_FOR_CONKY"),
                     const("MEMBER"),
                     "string", updater.string)
end

function updater.add(conkybox, iconbox, labelbox, func) -- {{{2
    -- make an updater function and add to the list
    table.insert(updater, (function()
        -- luacheck: ignore
        local conkybox = conkybox
        local iconbox = iconbox
        local labelbox = labelbox
        local func = func or    function(result, conky, icon, label)
                                    conky:set_text(result)
                                end
        local last_update = nil

        return function(conky_result)
            if conky_result == last_update then return end
            func(conky_result, conkybox, iconbox, labelbox)
            last_update = conky_result
        end
        -- luacheck: ignore
    end)())
end

function updater.add_string(conkystr) -- {{{2
    if updater.string then
        updater.string = updater.string .. const("DELIMITER") .. conkystr
    else
        updater.string = conkystr
    end
end

-- RETURN PUBLIC INTERFACE --- {{{1

return public
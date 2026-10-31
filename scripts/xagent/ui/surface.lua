-- Rounded surfaces using the bundled runtime's rectangle primitive.
local M = {}

function M.rounded(rg, x, y, w, h, radius, color)
    local r = math.max(0, math.floor(math.min(radius, w / 2, h / 2)))
    local function rect(rx, ry, rw, rh)
        if rw > 0 and rh > 0 then rg.draw_rectangle(rx, ry, rw, rh, table.unpack(color)) end
    end
    rect(x, y + r, w, h - 2 * r)
    for row = 0, r - 1 do
        local dy = r - row - 0.5
        local inset = math.floor(r - math.sqrt(r * r - dy * dy) + 0.5)
        rect(x + inset, y + row, w - 2 * inset, 1)
        rect(x + inset, y + h - row - 1, w - 2 * inset, 1)
    end
end

-- Keep raygui responsible for hit testing, lock state and keyboard editing;
-- restore every style property so the rest of the app retains its theme.
local function styled(rg, control, values, draw)
    local saved = {}
    for prop, value in pairs(values) do
        saved[prop] = rg.get_style(control, prop)
        rg.set_style(control, prop, value)
    end
    local result = table.pack(draw())
    for prop, value in pairs(saved) do rg.set_style(control, prop, value) end
    return table.unpack(result, 1, result.n)
end

local function packed(c)
    return (c[1] << 24) | (c[2] << 16) | (c[3] << 8) | (c[4] or 255)
end

function M.button(rg, x, y, w, h, label, bg, ink, radius)
    local mx, my = rg.get_mouse()
    local over = mx >= x and mx < x + w and my >= y and my < y + h
    local color = bg
    if over then
        color = {}
        for i = 1, 3 do color[i] = math.floor(bg[i] * 0.9 + ink[i] * 0.1) end
        color[4] = 255
    end
    M.rounded(rg, x, y, w, h, radius, color)
    return styled(rg, rg.BUTTON, {
        [rg.BORDER_WIDTH] = 0,
        [rg.BASE_COLOR_NORMAL] = 0, [rg.BASE_COLOR_FOCUSED] = 0, [rg.BASE_COLOR_PRESSED] = 0,
        [rg.TEXT_COLOR_NORMAL] = packed(ink), [rg.TEXT_COLOR_FOCUSED] = packed(ink),
        [rg.TEXT_COLOR_PRESSED] = packed(ink),
    }, function() return rg.button(x, y, w, h, label) end)
end

function M.editor(rg, bg, x, y, w, h, value, edit, enter_sends)
    return styled(rg, rg.TEXTBOX, {
        [rg.BORDER_WIDTH] = 0,
        [rg.BORDER_COLOR_NORMAL] = packed(bg), [rg.BORDER_COLOR_FOCUSED] = packed(bg),
        [rg.BORDER_COLOR_PRESSED] = packed(bg),
        [rg.BASE_COLOR_NORMAL] = packed(bg), [rg.BASE_COLOR_FOCUSED] = packed(bg),
        [rg.BASE_COLOR_PRESSED] = packed(bg),
    }, function() return rg.textbox_multi(x, y, w, h, value, edit, enter_sends) end)
end

return M

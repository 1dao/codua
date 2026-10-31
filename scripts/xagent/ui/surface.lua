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

function M.icon(rg, x, y, kind)
    local ix, iy = math.floor(x), math.floor(y)
    local function rect(dx, dy, rw, rh, color)
        rg.draw_rectangle(ix + dx, iy + dy, rw, rh, table.unpack(color))
    end
    if kind == 'save' then
        M.rounded(rg, ix + 1, iy, 18, 20, 3, { 37, 91, 176, 255 })
        M.rounded(rg, ix + 2, iy + 1, 16, 18, 2, { 64, 132, 235, 255 })
        rect(5, 1, 10, 6, { 237, 245, 255, 255 })
        rect(11, 1, 3, 5, { 37, 91, 176, 255 })
        M.rounded(rg, ix + 5, iy + 11, 10, 8, 1, { 249, 252, 255, 255 })
        rect(7, 14, 6, 1, { 143, 177, 219, 255 })
        rect(7, 17, 6, 1, { 143, 177, 219, 255 })
    elseif kind == 'folder' then
        M.rounded(rg, ix, iy + 3, 9, 6, 2, { 202, 143, 42, 255 })
        M.rounded(rg, ix, iy + 6, 20, 12, 2, { 202, 143, 42, 255 })
        M.rounded(rg, ix + 1, iy + 8, 18, 10, 2, { 246, 193, 83, 255 })
        rect(2, 8, 16, 1, { 255, 219, 137, 255 })
    end
end

function M.icon_button(rg, x, y, w, h, kind, bg, ink)
    local clicked = M.button(rg, x, y, w, h, '', bg, ink, 7)
    M.icon(rg, x + (w - 20) / 2, y + (h - 20) / 2, kind)
    return clicked
end

function M.editor(rg, bg, x, y, w, h, value, edit, enter_sends)
    return styled(rg, rg.TEXTBOX, {
        [rg.BORDER_WIDTH] = 0,
        [rg.BASE_COLOR_NORMAL] = packed(bg), [rg.BASE_COLOR_FOCUSED] = packed(bg),
        [rg.BASE_COLOR_PRESSED] = packed(bg),
    }, function() return rg.textbox_multi(x, y, w, h, value, edit, enter_sends) end)
end

function M.tooltip(rg, x, y, w, h, label, bg, ink)
    local mx, my = rg.get_mouse()
    if mx < x or mx >= x + w or my < y or my >= y + h then return end
    local sw, sh = rg.screen_size()
    local width, height = rg.measure_text(label, 14) + 20, 28
    local left = math.max(4, math.min(mx + 12, sw - width - 4))
    local top = my + 20
    if top + height > sh - 4 then top = y - height - 6 end
    M.rounded(rg, left - 1, top - 1, width + 2, height + 2, 7, ink)
    M.rounded(rg, left, top, width, height, 6, bg)
    rg.draw_text(label, left + 10, top + 7, 14, table.unpack(ink))
end

return M

-- Draw the existing GUI in WebView. All editing, selection and IME state live in
-- browser controls; the Lua GUI still owns the values and handles submission.
local xutils = require('xutils')
local fs = dofile('scripts/core/share/xfs.lua')
local xpath = dofile('scripts/core/share/xpath.lua')
local xtext = dofile('scripts/core/share/xtext.lua')

-- The frame is serialized with json_pack, which rejects invalid UTF-8 by
-- returning nil (the whole frame would go out empty). Native raygui draws
-- stray bytes harmlessly, so display strings can carry them (byte-cut CJK,
-- binary tool output). Repair at the WebView boundary; the utf8.len fast
-- path keeps clean strings allocation-free.
local function clean(s)
    if type(s) ~= 'string' or utf8.len(s) then return s end
    return xtext.valid_utf8(s)
end

local M = {}
local styles = {}
local input, frame, clip, folder, caret
local mouse = { x = -1, y = -1, down = false }
local scale, width, height, dpi = 1, 960, 700, 1
local metrics, metrics_revision, requested, metric_count = {}, 0, nil, 0
local textures, pending_textures, deleted_textures, texture_id = {}, {}, {}, 0
local selection_ids = setmetatable({}, { __mode = 'k' })
local next_selection_id = 0
local closing, locked, released, pressed
local cursor = 'default'

for _, name in ipairs({ 'DEFAULT', 'BUTTON', 'TEXTBOX', 'SLIDER', 'PROGRESSBAR', 'CHECKBOX', 'VALUEBOX',
    'BORDER_WIDTH', 'TEXT_SIZE', 'TEXT_SPACING', 'TEXT_PADDING', 'TEXT_LINE_SPACING', 'TEXT_ALIGNMENT',
    'TEXT_ALIGN_LEFT', 'BACKGROUND_COLOR', 'LINE_COLOR' }) do M[name] = name end

local defaults = {
    BORDER_WIDTH = 1, TEXT_SIZE = 16, TEXT_SPACING = 0, TEXT_PADDING = 6, TEXT_ALIGNMENT = M.TEXT_ALIGN_LEFT,
    BACKGROUND_COLOR = 0xf6f8f6ff, LINE_COLOR = 0xd6ddd6ff,
    BASE_COLOR_NORMAL = 0xf6f8f6ff, BORDER_COLOR_NORMAL = 0xa9b7adff, TEXT_COLOR_NORMAL = 0x24352aff,
    BASE_COLOR_FOCUSED = 0xe3efe7ff, BORDER_COLOR_FOCUSED = 0x739882ff, TEXT_COLOR_FOCUSED = 0x24352aff,
    BASE_COLOR_PRESSED = 0xc6e0cfff, BORDER_COLOR_PRESSED = 0x4d8668ff, TEXT_COLOR_PRESSED = 0x182c20ff,
    BASE_COLOR_DISABLED = 0xf1f3f1ff, BORDER_COLOR_DISABLED = 0xd6ddd6ff, TEXT_COLOR_DISABLED = 0x819087ff,
}
for _, state in ipairs({ 'NORMAL', 'FOCUSED', 'PRESSED', 'DISABLED' }) do
    for _, property in ipairs({ 'BASE_COLOR_', 'BORDER_COLOR_', 'TEXT_COLOR_' }) do
        local key = property .. state
        M[key] = key
    end
end
M.KEY_ESCAPE, M.KEY_DOWN, M.KEY_UP = 'Escape', 'ArrowDown', 'ArrowUp'

function M.get_style(control, key)
    return (styles[control] or {})[key] or (styles[M.DEFAULT] or {})[key] or defaults[key] or 0
end

function M.set_style(control, key, value)
    if control == M.DEFAULT then
        for _, values in pairs(styles) do values[key] = nil end
    end
    styles[control] = styles[control] or {}
    styles[control][key] = value
end

local function color(r, g, b, a)
    return (math.floor(r) << 24) | (math.floor(g) << 16) | (math.floor(b) << 8) | math.floor(a or 255)
end

local function draw(kind, ...)
    frame.commands[#frame.commands + 1] = { kind, ... }
end

local function bounded(number, min, max, fallback)
    if type(number) ~= 'number' or number ~= number then return fallback end
    return math.min(max, math.max(min, number))
end

function M.prepare(state)
    input = state
    width = bounded(state.width, 300, 8192, width)
    height = bounded(state.height, 240, 8192, height)
    dpi = bounded(state.dpi, 0.5, 8, dpi)
    local pointer = state.mouse
    pressed, released = false, false
    if type(pointer) == 'table' then
        mouse.x = bounded(pointer.x, -8192, 8192, mouse.x)
        mouse.y = bounded(pointer.y, -8192, 8192, mouse.y)
        pressed = pointer.down == true and not mouse.down
        released = pointer.down == false and mouse.down and not pointer.cancelled
        mouse.down = pointer.down == true
    end
    if type(state.measurements) == 'table' then
        if metric_count > 20000 then metrics, metric_count = {}, 0 end
        for _, measurement in ipairs(state.measurements) do
            local size, value, advance = table.unpack(measurement)
            if type(size) == 'number' and type(value) == 'string' and type(advance) == 'number'
                and #value <= 8192 and advance >= 0 then
                metrics[size] = metrics[size] or {}
                if metrics[size][value] == nil then metric_count = metric_count + 1 end
                metrics[size][value] = advance
            end
        end
        if #state.measurements > 0 then metrics_revision = metrics_revision + 1 end
    end
    frame = { commands = {}, editors = {}, measure = {}, scale = scale, cursor = cursor }
    requested, clip, locked = {}, nil, false
end

function M.response()
    frame.scale = scale
    frame.cursor = cursor
    frame.folder = folder
    frame.close = closing
    if input.reset then
        frame.add_images = {}
        for _, entry in pairs(textures) do frame.add_images[#frame.add_images + 1] = entry end
    else
        frame.add_images = pending_textures
    end
    frame.remove_images = deleted_textures
    pending_textures, deleted_textures = {}, {}
    return frame
end

function M.init() end
function M.close() end
function M.should_close() return false end
function M.request_close() closing = true end
function M.load_system_font() return true end
function M.set_ui_scale(value) scale = value end
function M.screen_size() return math.floor(width / scale), math.floor(height / scale) end
function M.display_info() return { dpi_x = dpi, dpi_y = dpi, ui_scale = scale, metrics_revision = metrics_revision } end
function M.get_mouse() return mouse.x / scale, mouse.y / scale end
function M.mouse_down() return mouse.down end
function M.get_wheel() return bounded(input.wheel, -30, 30, 0) end
function M.is_key_pressed(key) return input.keys and input.keys[key] == true end
function M.set_mouse_cursor(shape) cursor = shape == 4 and 'pointer' or 'default' end
function M.set_clipboard(value) frame.clipboard = clean(value) end
function M.set_completion_keys(value) frame.completion = value end
function M.lock() locked = true end
function M.unlock() locked = false end

function M.begin()
    local w, h = M.screen_size()
    draw('rect', 0, 0, w, h, M.get_style(M.DEFAULT, M.BACKGROUND_COLOR))
end

function M.finish() end

function M.draw_rectangle(x, y, w, h, r, g, b, a)
    draw('rect', x, y, w, h, color(r, g, b, a))
end

function M.draw_rounded_rectangle(x, y, w, h, radius, r, g, b, a)
    draw('rounded', x, y, w, h, radius, color(r, g, b, a))
end

function M.draw_text(value, x, y, size, r, g, b, a)
    draw('text', x, y, size, color(r, g, b, a), clean(value))
end

function M.begin_selection(x, y, w, h)
    frame.selection = { clip = { x, y, w, h }, lines = {} }
end

function M.selection_line(entry, row, column, x, y, size, value, join)
    if not entry or not row then return end
    local id = selection_ids[entry]
    if not id then
        next_selection_id = next_selection_id + 1
        id = next_selection_id
        selection_ids[entry] = id
    end
    local lines = frame.selection.lines
    lines[#lines + 1] = { id .. ':' .. row .. ':' .. column, x, y, size, clean(value), join }
end

function M.selection_dragged()
    return input.mouse and input.mouse.selection_dragged == true
end

function M.begin_scissor(x, y, w, h)
    clip = { x, y, w, h, clip }
    draw('clip', x, y, w, h)
end

function M.end_scissor()
    clip = clip and clip[5]
    draw('unclip')
end

function M.measure_text(value, size)
    value = clean(value)
    size = size or M.get_style(M.DEFAULT, M.TEXT_SIZE)
    local measured = metrics[size] and metrics[size][value]
    if measured then return measured end
    local key = tostring(size) .. '\0' .. value
    if #frame.measure < 450 and #value <= 8192 and not requested[key] then
        frame.measure[#frame.measure + 1] = { size, value }
        requested[key] = true
    end
    local chars = utf8.len(value) or #value
    local narrow = select(2, value:gsub('[\0-\127]', ''))
    return math.ceil((chars - narrow * 0.46) * size)
end

local icon_labels = { ['#113#'] = '×', ['#121#'] = '➤', ['#211#'] = '↻' }

local function contains(x, y, w, h)
    local mx, my = M.get_mouse()
    if mx < x or mx >= x + w or my < y or my >= y + h then return false end
    local box = clip
    while box do
        if mx < box[1] or mx >= box[1] + box[3] or my < box[2] or my >= box[2] + box[4] then return false end
        box = box[5]
    end
    return true
end

function M.button(x, y, w, h, value)
    local over = not locked and contains(x, y, w, h)
    local state = over and (mouse.down and 'PRESSED' or 'FOCUSED') or 'NORMAL'
    local border = M.get_style(M.BUTTON, M.BORDER_WIDTH)
    draw('button', x, y, w, h, M.get_style(M.DEFAULT, M.TEXT_SIZE), icon_labels[value] or clean(value),
        M.get_style(M.BUTTON, 'BASE_COLOR_' .. state), M.get_style(M.BUTTON, 'BORDER_COLOR_' .. state),
        M.get_style(M.BUTTON, 'TEXT_COLOR_' .. state), border, M.get_style(M.BUTTON, M.TEXT_ALIGNMENT),
        M.get_style(M.BUTTON, M.TEXT_PADDING))
    return over and released
end

function M.label(x, y, w, h, value)
    draw('label', x, y, w, h, M.get_style(M.DEFAULT, M.TEXT_SIZE), M.get_style(M.DEFAULT, M.TEXT_COLOR_NORMAL), clean(value))
end

function M.set_textbox_cursor(position) caret = position end

local function textbox(x, y, w, h, value, edit, multiline, enter_sends, id, disabled, label)
    id = id or ('field:%d:%d'):format(math.floor(x), math.floor(y))
    local event = input.edits and input.edits[id]
    local editable = not locked and not disabled
    if editable and pressed then edit = contains(x, y, w, h) end
    if editable and event then
        if type(event.value) == 'string' and utf8.len(event.value) then value = event.value end
        if event.blur then edit = false end
    end
    local state = edit and 'FOCUSED' or 'NORMAL'
    local size = M.get_style(M.DEFAULT, M.TEXT_SIZE)
    local ink = M.get_style(M.TEXTBOX, 'TEXT_COLOR_' .. state)
    local edge = M.get_style(M.TEXTBOX, 'BORDER_COLOR_' .. state)
    local bg = M.get_style(M.TEXTBOX, 'BASE_COLOR_' .. state)
    local border = M.get_style(M.TEXTBOX, M.BORDER_WIDTH)
    if w > 0 and h > 0 then
        draw('rect', x, y, w, h, edge)
        draw('rect', x + border, y + border, w - 2 * border, h - 2 * border, bg)
        if editable then
            local box, left, top, right, bottom = clip, x, y, x + w, y + h
            while box do
                left, top = math.max(left, box[1]), math.max(top, box[2])
                right, bottom = math.min(right, box[1] + box[3]), math.min(bottom, box[2] + box[4])
                box = box[5]
            end
            if left < right and top < bottom then
                frame.editors[#frame.editors + 1] = { id = id, x = x, y = y, w = w, h = h, text = clean(value),
                    size = size, ink = ink, focused = not not edit, multiline = multiline, enter_sends = enter_sends, label = label,
                    caret = id:sub(1, 9) == 'composer:' and caret or nil,
                    clip = { top - y, x + w - right, y + h - bottom, left - x } }
                if id:sub(1, 9) == 'composer:' then caret = nil end
            end
        elseif value ~= '' then
            draw('label', x + 6, y, w - 12, h, size, ink, clean(value))
        end
    end
    return value, editable and not not edit, editable and event and event.submit == true
end

function M.textbox(x, y, w, h, value, edit, id, label)
    local text, focused = textbox(x, y, w, h, value, edit, false, false, id, false, label)
    return text, focused
end

function M.textbox_multi(x, y, w, h, value, edit, enter_sends, id, disabled)
    return textbox(x, y, w, h, value, edit, true, enter_sends, id, disabled)
end

function M.take_pasted_image()
    local image = input.image
    if type(image) ~= 'table' or type(image[1]) ~= 'string' or type(image[2]) ~= 'number' or type(image[3]) ~= 'number' then return end
    local png = xutils.base64_decode(image[1])
    if png and png:sub(1, 8) == '\137PNG\r\n\26\n' then return png, image[2], image[3] end
end

function M.load_texture_mem(bytes)
    texture_id = texture_id + 1
    local entry = { texture_id, xutils.base64_encode(bytes) }
    textures[texture_id] = entry
    pending_textures[#pending_textures + 1] = entry
    return texture_id
end

function M.load_texture(path)
    local bytes = fs.read_file(path)
    return bytes and M.load_texture_mem(bytes)
end

function M.unload_texture(id)
    textures[id] = nil
    deleted_textures[#deleted_textures + 1] = id
end

function M.draw_texture(id, x, y, w, h)
    if textures[id] then draw('image', id, x, y, w, h) end
end

function M.draw_texture_ex(id, sx, sy, sw, sh, x, y, w, h)
    if textures[id] then draw('subimage', id, sx, sy, sw, sh, x, y, w, h) end
end

local function set_folder(path)
    local entries, err = xutils.list_dir(path, 4000, true)
    if not entries then return nil, tostring(err) end
    local dirs = {}
    for _, entry in ipairs(entries) do
        if entry.dir then dirs[#dirs + 1] = entry.name end
    end
    table.sort(dirs, function(a, b) return a:lower() < b:lower() end)
    local parent = xpath.dirname(path:gsub('[\\/]+$', ''))
    if parent == '' and path:sub(1, 1) == '/' then parent = '/' end
    if parent == '.' or parent == path or path == '/' then parent = nil end
    if parent and parent:match('^%a:$') then parent = parent .. '\\' end
    return { path = path, parent = parent, dirs = dirs }
end

function M.file_dialog_open(root)
    local next_folder, err = set_folder(root)
    folder = next_folder or { path = root, dirs = {}, error = err }
end

function M.file_dialog()
    local action = input.folder
    if not folder or not action then return 'active' end
    if action.kind == 'cancel' then folder = nil; return 'cancel' end
    local path = action.path
    if type(path) ~= 'string' or not xpath.is_absolute(path) or path:find('\0', 1, true) then
        folder.error = '请输入绝对路径。'
        return 'active'
    end
    local next_folder, err = set_folder(path)
    if not next_folder then folder.error = err; return 'active' end
    if action.kind == 'select' then folder = nil; return 'select', path end
    folder = next_folder
    return 'active'
end

return M

-- xagent/ui/transcript.lua — a scrolling, word-wrapping chat transcript view
-- drawn with raygui render primitives (draw_text / measure_text / scissor /
-- wheel). The wrap logic is pure and measure-injectable, so it unit-tests
-- offline without a window.

local emoji = require('xagent.ui.emoji')
local markdown = require('xagent.ui.markdown')
local source = require('xagent.ui.source_highlighter')
local surface = require('xagent.ui.surface')

local M = {}

-- ── pure wrapping (UTF-8 aware; CJK has no spaces so it breaks per char) ─────
-- O(N): we track the running line WIDTH and add (spacing + single-char width)
-- per char/word instead of re-measuring the whole growing line each step. The
-- old O(N²) version made long messages take seconds to lay out on load.
local function break_long(word, max_w, line, line_w, measure, spacing, out)
    local i, n = 1, #word
    while i <= n do
        local nexti = utf8.offset(word, 2, i) or (n + 1)
        local ch = word:sub(i, nexti - 1)
        local cw = measure(ch)
        if line == '' then
            line, line_w = ch, cw
        elseif line_w + spacing + cw <= max_w then
            line = line .. ch
            line_w = line_w + spacing + cw
        else
            out[#out + 1] = line
            line, line_w = ch, cw
        end
        i = nexti
    end
    return line, line_w
end

local function wrap_para(s, max_w, measure, spacing, out)
    local line, line_w = '', 0
    local space_w = measure(' ')
    for word in s:gmatch('%S+') do
        local ww = measure(word)
        if line == '' then
            if ww <= max_w then line, line_w = word, ww
            else line, line_w = break_long(word, max_w, '', 0, measure, spacing, out) end
        else
            local cand = line_w + 2 * spacing + space_w + ww   -- " word" adds 2 gaps + space + word
            if cand <= max_w then
                line, line_w = line .. ' ' .. word, cand
            else
                out[#out + 1] = line
                if ww <= max_w then line, line_w = word, ww
                else line, line_w = break_long(word, max_w, '', 0, measure, spacing, out) end
            end
        end
    end
    out[#out + 1] = line   -- always emit (possibly the only/last line of the paragraph)
end

-- wrap(text, max_width, measure [, spacing]) -> array of line strings.
-- `measure(str)` returns pixel width; `spacing` is the per-glyph gap (TEXT_SPACING).
function M.wrap(text, max_width, measure, spacing)
    spacing = spacing or 0
    local out = {}
    local s = tostring(text or '')
    local start = 1
    while true do
        local nl = s:find('\n', start, true)
        local para = nl and s:sub(start, nl - 1) or s:sub(start)
        if para == '' then out[#out + 1] = '' else wrap_para(para, max_width, measure, spacing, out) end
        if not nl then break end
        start = nl + 1
    end
    return out
end

-- ── role colors (r,g,b,a) ──────────────────────────────────────────────────
M.role_colors = {
    user        = { 120, 175, 255, 255 },
    assistant   = { 228, 228, 234, 255 },
    tool        = { 90, 200, 200, 255 },
    tool_result = { 150, 150, 162, 255 },
    error       = { 240, 105, 105, 255 },
    system      = { 150, 150, 162, 255 },
    thinking    = { 130, 140, 155, 255 },   -- transient "thinking…" placeholder
}
local function role_color(role) return M.role_colors[role] or M.role_colors.assistant end

-- Clickable links: bare URLs in the text (e.g. a plain http://… address) are
-- drawn in this color + underlined and open on click.
M.link_color = { 96, 170, 255, 255 }
M.card_colors = {
    user = { 239, 247, 244, 255 }, assistant = { 255, 255, 255, 255 },
    label = { 18, 111, 100, 255 },
}

-- find_links(s) -> { { s=byte_start, e=byte_end, url=string }, … } for each
-- scheme://… run in `s`. URL chars are ASCII, so byte offsets are also valid
-- UTF-8 boundaries (safe for s:sub on mixed CJK lines). Trailing sentence
-- punctuation is trimmed so "…：http://x/y.html。" links just the URL.
local TRAIL = '[%)%]%}>,%.;:!%?，。、）】！？”’]+$'
local function find_links(s)
    local out, init = {}, 1
    s = tostring(s or '')
    while true do
        local a, b = s:find('%a[%w%+%.%-]*://%S+', init)
        if not a then break end
        local url = s:sub(a, b)
        local trimmed = url:gsub(TRAIL, '')
        if #trimmed > 0 then
            out[#out + 1] = { s = a, e = a + #trimmed - 1, url = trimmed }
        end
        init = b + 1
    end
    return out
end
M.find_links = find_links   -- exposed for tests

-- ── the view (needs the global `raygui`) ───────────────────────────────────
local View = {}
View.__index = View

function M.new_view(opts)
    opts = opts or {}
    local fs = opts.font_size or 18
    return setmetatable({
        rg = assert(opts.raygui or rawget(_G, 'raygui'), 'transcript.new_view needs opts.raygui'),
        emoji_tex = opts.emoji_tex,   -- atlas texture handle, or nil to disable
        bg = opts.bg or { 24, 24, 28, 255 },
        font_size = fs,
        line_h = math.floor(fs * 1.5),
        pad = 14,
        cards = not opts.anchor_top,
        scroll = 0,
        -- anchor_top: read top-down, never auto-jump to the bottom (used by the
        -- API-log detail). Default views follow the streaming tail (chat).
        anchor_top = opts.anchor_top or nil,
        follow = not opts.anchor_top,   -- stick to bottom unless the user scrolls up
        cache = setmetatable({}, { __mode = 'k' }),   -- entry -> { width, len, lines }
        layout = nil,         -- tail-first incremental rows for the current entries/width
    }, View)
end

function View:measure_fn()
    local fs, rg = self.font_size, self.rg
    if self.emoji_tex then
        return function(s) return emoji.measure_width(s, fs, function(t) return rg.measure_text(t, fs) end) end
    end
    return function(s) return rg.measure_text(s, fs) end
end

-- Logical lines for an entry: assistant text is Markdown-styled; other roles are
-- a single line in their role color.
function View:logical_lines(entry)
    if entry.role == 'assistant' then
        return markdown.render(entry.text)
    elseif entry.role == 'tool_result' then
        return markdown.render_tool(entry.text, role_color(entry.role))
    end
    return { { text = entry.text, color = entry.role == 'user' and markdown.palette.text or role_color(entry.role) } }
end

-- Drop cached layout (call when colors/theme change so rows re-render).
function View:invalidate()
    self.cache = setmetatable({}, { __mode = 'k' })
    self.layout = nil
end

-- Wrapped rows retain code, emphasis and table metadata. Cached by text length.
function View:entry_rows(entry, width)
    local c = self.cache[entry]
    if c and c.width == width and c.len == #entry.text then return c.rows end
    local measure = self:measure_fn()
    local spacing = 0
    pcall(function()
        if self.rg.TEXT_SPACING then spacing = self.rg.get_style(self.rg.DEFAULT, self.rg.TEXT_SPACING) or 0 end
    end)
    local rows = {}
    local logical = self:logical_lines(entry)
    local table_header = true
    for _, ll in ipairs(logical) do
        if ll.cells then
            if not ll.separator then
                local cell_width = width / math.max(1, #ll.cells)
                local columns, count = {}, 1
                for col, value in ipairs(ll.cells) do
                    columns[col] = M.wrap(value, math.max(1, cell_width - 16), measure, spacing)
                    count = math.max(count, #columns[col])
                end
                for line = 1, count do
                    local cells = {}
                    for col = 1, #columns do cells[col] = columns[col][line] or '' end
                    rows[#rows + 1] = { text = '', cells = cells, cell_width = cell_width,
                        table_header = table_header, color = ll.color, entry = entry }
                end
                table_header = false
            end
        else
            table_header = true
            if ll.code_start then
                rows[#rows + 1] = { text = ll.code.title or (ll.code.language ~= '' and ll.code.language or '代码'),
                    color = M.card_colors.label, bg = ll.bg, code_header = ll.code, entry = entry }
            end
            local wrapped
            local gutter = ll.number and math.min(width * .3, measure('000000') + 12) or 0
            if ll.code then
                -- Code whitespace is significant. The prose word wrapper collapses
                -- indentation and repeated spaces, so wrap code by UTF-8 character.
                wrapped = {}
                local tail = break_long(ll.text, math.max(1, width - 16 - gutter), '', 0, measure, spacing, wrapped)
                wrapped[#wrapped + 1] = tail
            else
                wrapped = M.wrap(ll.text, math.max(1, width), measure, spacing)
            end
            local offset = 1
            for part, sl in ipairs(wrapped) do
                local first = ll.text:find(sl, offset, true) or offset
                local bold_spans = {}
                for _, span in ipairs(ll.bold_spans or {}) do
                    local a, b = math.max(first, span.first), math.min(first + #sl - 1, span.last)
                    if a <= b then bold_spans[#bold_spans + 1] = { first = a - first + 1, last = b - first + 1 } end
                end
                local syntax = {}
                for _, span in ipairs(ll.syntax or {}) do
                    local a, b = math.max(first, span.first), math.min(first + #sl - 1, span.last)
                    if a <= b then syntax[#syntax + 1] = { first = a - first + 1, last = b - first + 1, kind = span.kind } end
                end
                offset = first + #sl
                rows[#rows + 1] = { text = sl, color = ll.color, bg = ll.bg,
                    bold = ll.bold, bold_spans = bold_spans, syntax = syntax,
                    number = part == 1 and ll.number or nil, gutter = gutter, code = ll.code, entry = entry }
            end
        end
    end
    self.cache[entry] = { width = width, len = #entry.text, rows = rows }
    return rows
end

-- Draw one wrapped line at (x, y) with inline emoji from the atlas.
function View:draw_line(line, x, y, color)
    local rg, fs = self.rg, self.font_size
    if not self.emoji_tex then
        rg.draw_text(line, x, y, fs, color[1], color[2], color[3], color[4])
        return
    end
    local cx = x
    for _, tok in ipairs(emoji.tokenize(line)) do
        if tok.text then
            rg.draw_text(tok.text, cx, y, fs, color[1], color[2], color[3], color[4])
            cx = cx + rg.measure_text(tok.text, fs)
        else
            local sx, sy, sw, sh = emoji.src(tok.emoji)
            rg.draw_texture_ex(self.emoji_tex, sx, sy, sw, sh, cx, y, fs, fs)
            cx = cx + fs
        end
    end
end

local function now_ms()
    return os.clock() * 1000
end

local function entry_block(self, entry, width)
    local block = {}
    if self.cards and (entry.role == 'user' or entry.role == 'assistant') then
        block[#block + 1] = { text = entry.role == 'user' and '你' or 'codua',
            color = M.card_colors.label, label = true, entry = entry }
    end
    for _, r in ipairs(self:entry_rows(entry, width)) do block[#block + 1] = r end
    -- copy button on any content message (skip the short tool-call cards + system,
    -- and any entry that opted out via no_copy)
    if #entry.text > 0 and not entry.no_copy
        and (entry.role == 'assistant' or entry.role == 'user' or entry.role == 'tool_result') then
        block[#block + 1] = { copy = entry, entry = entry }
    end
    block[#block + 1] = { text = '' }
    return block
end

-- The layout caches wrapped rows for the STABLE entries [lo, hi], where hi =
-- #entries-1 (everything except the last). The LAST entry is "live": it grows
-- during streaming, so it is re-laid-out every frame (cheap — entry_rows caches
-- by length, so a non-changing last entry is a cache hit). `hi` grows as new
-- messages arrive (append the just-stabilised entry); `lo` shrinks toward 1 as
-- older history is laid out tail-first during idle frames / scroll-up.
function View:ensure_layout(entries, width)
    local l = self.layout
    if not (l and l.entries == entries and l.width == width) then
        l = { entries = entries, width = width, lo = #entries, hi = #entries - 1, rows = {} }
        self.layout = l
        self.scroll = 0
        self.follow = not self.anchor_top
        return l
    end
    -- same entries+width: append entries that just became stable (new messages)
    local target_hi = #entries - 1
    while l.hi < target_hi do
        l.hi = l.hi + 1
        if l.lo > l.hi then l.lo = l.hi end
        local block = entry_block(self, entries[l.hi], width)
        for j = 1, #block do l.rows[#l.rows + 1] = block[j] end
    end
    return l
end

-- Lay out OLDER stable entries (toward index 1) tail-first, bounded by a frame
-- budget, until `min_rows` stable rows exist. Returns the number of rows added.
function View:layout_backward_until(entries, width, min_rows, budget_ms)
    local l = self:ensure_layout(entries, width)
    if l.lo <= 1 then return 0 end
    local deadline = now_ms() + (budget_ms or 2)
    local blocks, added = {}, 0
    while #l.rows + added < min_rows and l.lo > 1 do
        l.lo = l.lo - 1
        local block = entry_block(self, entries[l.lo], width)
        blocks[#blocks + 1] = block
        added = added + #block
        if now_ms() >= deadline then break end
    end
    if added > 0 then
        local old, rows = l.rows, {}
        for i = #blocks, 1, -1 do
            local b = blocks[i]
            for j = 1, #b do rows[#rows + 1] = b[j] end
        end
        for i = 1, #old do rows[#rows + 1] = old[i] end
        l.rows = rows
    end
    return added
end

function View:draw(entries, x, y, w, h)
    local rg, pad = self.rg, self.pad
    local SB_W = 8                          -- scrollbar track/thumb width
    local inset = self.cards and 14 or 0
    local width = math.max(1, w - pad * 2 - SB_W - 4 - inset * 2)
    local text_x = x + pad + inset
    local viewport_h = h - pad * 2
    local visible_rows = math.max(1, math.ceil(viewport_h / self.line_h))
    local l = self:ensure_layout(entries, width)

    -- Tail-first initial fill of the stable rows (bounded per frame).
    self:layout_backward_until(entries, width, visible_rows + 20, 6)

    -- wheel scroll when the pointer is over the view (lock_input: a modal
    -- dialog is overlaying the view — its list owns the wheel)
    local mx, my = rg.get_mouse()
    if not self.lock_input and mx >= x and mx <= x + w and my >= y and my <= y + h then
        local d = rg.get_wheel()
        if d ~= 0 then
            self.scroll = self.scroll - d * self.line_h * 3
            self.follow = false
        end
    end

    -- Near the top: prepend older rows and compensate scroll so content doesn't
    -- jump. Otherwise keep filling older history during idle frames.
    if not self.follow and l.lo > 1 and self.scroll < self.line_h * 20 then
        local added = self:layout_backward_until(entries, width, #l.rows + 120, 8)
        if added > 0 then self.scroll = self.scroll + added * self.line_h end
    elseif l.lo > 1 then
        self:layout_backward_until(entries, width, #l.rows + 30, 2)
    end

    -- The live (last) entry is re-laid-out every frame so streaming updates now.
    local live = (#entries >= 1) and entry_block(self, entries[#entries], width) or {}
    local n_stable = #l.rows
    local total = n_stable + #live
    local function row_at(i)
        if i <= n_stable then return l.rows[i] end
        return live[i - n_stable]
    end

    local total_h = total * self.line_h
    local max_scroll = math.max(0, total_h - viewport_h)

    -- ── draggable scrollbar (right gutter) ──────────────────────────────────
    -- Drag the thumb (or click the track) to jump anywhere instantly, instead
    -- of crawling with the wheel. Geometry is reused by the draw pass below.
    local sb_x, sb_y, sb_h = x + w - SB_W - 2, y + 2, h - 4
    local function thumb_geom()
        local th = math.min(sb_h, math.max(28, sb_h * viewport_h / total_h))
        local trange = sb_h - th
        local ty = sb_y + (max_scroll > 0 and (self.scroll / max_scroll) or 0) * trange
        return th, ty, trange
    end
    -- Hidden by default; revealed when the pointer nears the right edge (a zone a
    -- bit wider than the thin bar, so it's easy to find/grab) or while dragging.
    local hot = mx >= sb_x - 12 and mx <= x + w and my >= y and my <= y + h
    local down = (rg.mouse_down and rg.mouse_down()) or false
    -- Link click edges, captured before self.prev_down is overwritten below.
    -- A click = press AND release on the same link rect (so drags/scrolls don't
    -- fire). Record where the press began + whether it started on the scrollbar.
    local link_released = (self.prev_down and not down)
    if down and not self.prev_down then
        self.press_x, self.press_y, self._press_on_sb = mx, my, hot
    end
    if max_scroll > 0 and not self.lock_input then
        local th, ty, trange = thumb_geom()
        if down and not self.prev_down and hot then            -- press edge
            self.sb_drag = (my >= ty and my <= ty + th) and (my - ty) or (th / 2)
        end
        if self.sb_drag and down then                          -- dragging: map y → scroll
            local rel = trange > 0 and ((my - self.sb_drag - sb_y) / trange) or 0
            self.scroll = math.max(0, math.min(1, rel)) * max_scroll
            self.follow = false
        end
    end
    if not down then self.sb_drag = nil end
    self.prev_down = down

    if self.follow then self.scroll = max_scroll end
    if self.scroll > max_scroll then self.scroll = max_scroll end
    if self.scroll < 0 then self.scroll = 0 end
    if not self.anchor_top and self.scroll >= max_scroll - 1 then self.follow = true end

    -- which message is the pointer over? the copy button shows on hover only
    local hover_entry
    if mx >= x and mx <= x + w and my >= y and my <= y + h then
        local f0 = math.max(1, math.floor(self.scroll / self.line_h))
        for i = f0, total do
            local ly = y + pad + (i - 1) * self.line_h - self.scroll
            if ly > y + h then break end
            local r = row_at(i)
            if my >= ly and my < ly + self.line_h and r.entry then
                hover_entry = r.entry
                break
            end
        end
    end

    local bg = self.bg
    rg.draw_rectangle(x, y, w, h, bg[1], bg[2], bg[3], bg[4])
    rg.begin_scissor(x + 1, y + 1, w - 2, h - 2)
    -- Paint whole message surfaces before the rows. Only visible spans are
    -- visited; rounded ends remain outside the viewport for long messages.
    if self.cards then
        local start = math.max(1, math.floor(self.scroll / self.line_h))
        while start <= total do
            local row = row_at(start)
            local top = y + pad + (start - 1) * self.line_h - self.scroll
            if top > y + h then break end
            local finish = start
            if row.entry and M.card_colors[row.entry.role] then
                local limit = math.ceil((self.scroll + h) / self.line_h) + 1
                while finish < math.min(total, limit) and row_at(finish + 1).entry == row.entry do finish = finish + 1 end
                -- When the first row is clipped, hide its artificial top corners.
                if start > 1 and row_at(start - 1).entry == row.entry then top = top - 16 end
                local bottom = y + pad + finish * self.line_h - self.scroll
                surface.rounded(rg, x + pad, top - 10, width + inset * 2, bottom - top + 16,
                    14, M.card_colors[row.entry.role])
            end
            start = finish + 1
        end
    end
    local frame_links = {}                 -- clickable URL rects drawn this frame
    local measure = self:measure_fn()
    local function draw_links(value, left, top)
        if not self.on_link then return end
        for _, lk in ipairs(find_links(value)) do
            local lx = left + measure(value:sub(1, lk.s - 1))
            local lw, color = measure(lk.url), M.link_color
            rg.draw_text(lk.url, lx, top, self.font_size, table.unpack(color))
            rg.draw_rectangle(lx, top + self.font_size + 1, lw, 1, table.unpack(color))
            frame_links[#frame_links + 1] = { x = lx, y = top, w = lw, h = self.line_h, url = lk.url }
        end
    end
    local first = math.max(1, math.floor(self.scroll / self.line_h))
    for i = first, total do
        local ly = y + pad + (i - 1) * self.line_h - self.scroll
        if ly > y + h then break end
        local r = row_at(i)
        if r.copy then
            if r.copy == hover_entry and ly >= y - self.line_h then
                if surface.button(rg, text_x, ly, 56, self.line_h - 2, '复制',
                    M.card_colors[r.copy.role] or bg, M.card_colors.label, 5) and self.on_copy then
                    self.on_copy(r.copy)
                end
            end
        elseif r.cells then
            local fill = r.table_header and M.card_colors.user or M.card_colors.assistant
            local border = markdown.palette.hr
            for col, value in ipairs(r.cells) do
                local cx = text_x + (col - 1) * r.cell_width
                rg.draw_rectangle(cx, ly, r.cell_width, self.line_h, table.unpack(fill))
                rg.draw_rectangle(cx, ly, r.cell_width, 1, table.unpack(border))
                rg.draw_rectangle(cx, ly + self.line_h - 1, r.cell_width, 1, table.unpack(border))
                rg.draw_rectangle(cx, ly, 1, self.line_h, table.unpack(border))
                self:draw_line(value, cx + 8, ly, r.color)
                if r.table_header then self:draw_line(value, cx + 8.6, ly, r.color) end
                draw_links(value, cx + 8, ly)
            end
            rg.draw_rectangle(text_x + width - 1, ly, 1, self.line_h, table.unpack(border))
        elseif r.text and (r.text ~= '' or r.bg) then
            if r.bg then
                rg.draw_rectangle(text_x, ly - 1, width, self.line_h, table.unpack(r.bg))
            end
            local draw_x = text_x + (r.bg and 8 or 0)
            if r.label or r.code_header then
                rg.draw_text(r.text, draw_x, ly + 2, 12, table.unpack(r.color))
                if r.code_header and surface.button(rg, text_x + width - 56, ly, 56, self.line_h - 2,
                    '复制', r.bg, M.card_colors.label, 4) and self.on_copy then
                    self.on_copy({ text = table.concat(r.code_header.lines, '\n'), role = 'assistant' })
                end
            else
                if r.number and r.number ~= '' then
                    self:draw_line(r.number, draw_x, ly, markdown.palette.quote)
                end
                draw_x = draw_x + (r.gutter or 0)
                if r.syntax and #r.syntax > 0 then
                    local at = 1
                    for _, span in ipairs(r.syntax) do
                        if span.first > at then self:draw_line(r.text:sub(at, span.first - 1),
                            draw_x + measure(r.text:sub(1, at - 1)), ly, r.color) end
                        self:draw_line(r.text:sub(span.first, span.last),
                            draw_x + measure(r.text:sub(1, span.first - 1)), ly, source.color(span.kind, r.bg or self.bg))
                        at = span.last + 1
                    end
                    if at <= #r.text then self:draw_line(r.text:sub(at), draw_x + measure(r.text:sub(1, at - 1)), ly, r.color) end
                else self:draw_line(r.text, draw_x, ly, r.color) end
                if r.bold then self:draw_line(r.text, draw_x + 0.6, ly, r.color) end
                if not r.bold then
                    for _, span in ipairs(r.bold_spans or {}) do
                        local bx = draw_x + measure(r.text:sub(1, span.first - 1))
                        self:draw_line(r.text:sub(span.first, span.last), bx + 0.6, ly, r.color)
                    end
                end
            end
            -- Overdraw any URLs in link color + underline, and record a rect so a
            -- click on it opens the link. Same glyphs over the same pixels, so it
            -- just recolors; alignment uses the emoji-aware measure_fn.
            if not r.code and not r.code_header and not r.label then
                draw_links(r.text, draw_x, ly)
            end
        end
    end
    rg.end_scissor()

    -- Fire a link click: press and release both landed on the same rect, the
    -- press didn't start on the scrollbar, and no modal is overlaying us.
    if link_released and self.on_link and not self.lock_input and not self._press_on_sb then
        local px, py = self.press_x or -1, self.press_y or -1
        for _, lk in ipairs(frame_links) do
            local over_rel = mx >= lk.x and mx <= lk.x + lk.w and my >= lk.y and my <= lk.y + lk.h
            local over_pre = px >= lk.x and px <= lk.x + lk.w and py >= lk.y and py <= lk.y + lk.h
            if over_rel and over_pre then self.on_link(lk.url); break end
        end
    end

    -- scrollbar track + thumb — only while hovered (hot) or being dragged
    if max_scroll > 0 and (hot or self.sb_drag) then
        local th, ty = thumb_geom()
        local b = self.bg
        local lum = 0.299 * b[1] + 0.587 * b[2] + 0.114 * b[3]
        local base = lum < 128 and 255 or 0
        rg.draw_rectangle(sb_x, sb_y, SB_W, sb_h, base, base, base, 28)
        rg.draw_rectangle(sb_x, ty, SB_W, th, base, base, base, self.sb_drag and 150 or 115)
    end
end

return M

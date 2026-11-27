-- xagent/ui/transcript.lua — a scrolling, word-wrapping chat transcript view
-- drawn with raygui render primitives (draw_text / measure_text / scissor /
-- wheel). The wrap logic is pure and measure-injectable, so it unit-tests
-- offline without a window.

local emoji = require('xagent.ui.emoji')
local markdown = require('xagent.ui.markdown')
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

local function wrap_para(s, max_w, measure, spacing, out, joins)
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
                if joins then joins[#out] = ' ' end
                if ww <= max_w then line, line_w = word, ww
                else line, line_w = break_long(word, max_w, '', 0, measure, spacing, out) end
            end
        end
    end
    out[#out + 1] = line   -- always emit (possibly the only/last line of the paragraph)
end

-- wrap(text, max_width, measure [, spacing]) -> array of line strings.
-- `measure(str)` returns pixel width; `spacing` is the per-glyph gap (TEXT_SPACING).
function M.wrap(text, max_width, measure, spacing, joins)
    spacing = spacing or 0
    local out = {}
    local s = tostring(text or '')
    local start = 1
    while true do
        local nl = s:find('\n', start, true)
        local para = nl and s:sub(start, nl - 1) or s:sub(start)
        if para == '' then out[#out + 1] = '' else wrap_para(para, max_width, measure, spacing, out, joins) end
        if not nl then break end
        if joins then joins[#out] = '\n' end
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
-- scheme://… run in `s`. Keep Unicode host and path characters, and trim
-- sentence punctuation as whole characters so draw runs stay valid UTF-8.
local TRAIL = {
    [')'] = true, [']'] = true, ['}'] = true, ['>'] = true, [','] = true,
    ['.'] = true, [';'] = true, [':'] = true, ['!'] = true, ['?'] = true,
    ['，'] = true, ['。'] = true, ['、'] = true, ['）'] = true, ['】'] = true,
    ['！'] = true, ['？'] = true, ['”'] = true, ['’'] = true,
}
local URL_BODY = "[%w%.%-_~:/?#%[%]@!$&'()*+,;=%%\128-\255]+"
local function find_links(s)
    local out, init = {}, 1
    s = tostring(s or '')
    while true do
        local a, b, body = s:find('%a[%w%+%.%-]*://()' .. URL_BODY, init)
        if not a then break end
        local last = b
        while last >= body do
            local first = utf8.offset(s, -1, last + 1)
            if not TRAIL[s:sub(first, last)] then break end
            last = first - 1
        end
        if last >= body then
            out[#out + 1] = { s = a, e = last, url = s:sub(a, last) }
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
    end
    return { { text = entry.text, color = entry.role == 'user' and markdown.palette.text or role_color(entry.role) } }
end

-- Forward declaration; defined after entry_rows below. invalidate() re-wraps the
-- already-laid-out rows, so it needs the block builder.
local entry_block

-- Drop cached WRAPPING and re-wrap the laid-out rows in place (call when glyph
-- measurements, colors or theme change). Resetting `layout` here was wrong: the
-- old behaviour restarted the tail-first layout and reset follow/scroll, which
-- snapped a scrolled-up view back to the bottom and made the scrollbar thumb
-- oscillate. Re-wrapping preserves the incremental layout and the reader's place.
function View:invalidate()
    self.cache = setmetatable({}, { __mode = 'k' })
    self.live_cache = nil
    local l = self.layout
    if not l then return end
    local rows = {}
    for i = l.lo, l.hi do
        local block = entry_block(self, l.entries[i], l.width)
        for j = 1, #block do rows[#rows + 1] = block[j] end
    end
    l.rows = rows
end

-- Wrapped rows retain code, emphasis and table metadata. Cached by text length.
-- Within one entry+width, wrapped rows are ALSO cached per logical line so a
-- streaming (growing) entry only re-wraps its changed tail: the stable prefix
-- lines hit the line cache instead of re-wrapping the whole answer every frame.
local LINE_CACHE_MAX = 4096
local LINE_CACHE_BYTES = 2000000
local LINE_CACHE_ROWS = 20000
function View:entry_rows(entry, width)
    local c = self.cache[entry]
    if c and c.width == width and c.len == #entry.text then return c.rows end
    local prev = c
    local line_cache, lc_count, lc_bytes, lc_rows
    if prev and prev.width == width and prev.line_cache then
        line_cache, lc_count, lc_bytes, lc_rows = prev.line_cache, prev.lc_count or 0, prev.lc_bytes or 0, prev.lc_rows or 0
    else
        line_cache, lc_count, lc_bytes, lc_rows = {}, 0, 0, 0
    end
    local measure = self:measure_fn()
    local spacing = 0
    pcall(function()
        if self.rg.TEXT_SPACING then spacing = self.rg.get_style(self.rg.DEFAULT, self.rg.TEXT_SPACING) or 0 end
    end)
    local rows = {}
    local logical = self:logical_lines(entry)
    local table_header = true
    for li, ll in ipairs(logical) do
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
                rows[#rows + 1] = { text = ll.code.language ~= '' and ll.code.language or '代码',
                    color = M.card_colors.label, bg = ll.bg, code_header = ll.code, entry = entry }
            end
            local offset = 1
            local joins = self.rg.selection_line and {} or nil
            local kind = (ll.code and 'c' or (joins and 's' or 'w')) .. (ll.bold and 'b' or '')
            local key = kind .. ll.text
            local cached = line_cache[key]
            -- The LAST logical line of a still-growing entry is re-keyed by every
            -- delta (a single-paragraph answer IS one logical line). Caching those
            -- growing prefixes retains a quadratic copy of the answer per turn, so
            -- only closed lines — or a settled entry — enter the line cache.
            local cacheable = li < #logical or (prev and prev.len == #entry.text and prev.width == width)
            if not cached then
                cached = {}
                local wrapped
                if ll.code then
                    -- Code whitespace is significant. The prose word wrapper collapses
                    -- indentation and repeated spaces, so wrap code by UTF-8 character.
                    wrapped = {}
                    local tail = break_long(ll.text:gsub('\t', '    '), math.max(1, width - 16), '', 0, measure, spacing, wrapped)
                    wrapped[#wrapped + 1] = tail
                else
                    wrapped = M.wrap(ll.text, math.max(1, width), measure, spacing, joins)
                end
                for index, sl in ipairs(wrapped) do
                    local first = ll.text:find(sl, offset, true) or offset
                    local bold_spans = {}
                    for _, span in ipairs(ll.bold_spans or {}) do
                        local a, b = math.max(first, span.first), math.min(first + #sl - 1, span.last)
                        if a <= b then bold_spans[#bold_spans + 1] = { first = a - first + 1, last = b - first + 1 } end
                    end
                    offset = first + #sl
                    cached[#cached + 1] = { text = sl, color = ll.color, bg = ll.bg,
                        bold = ll.bold, bold_spans = bold_spans, code = ll.code, entry = entry,
                        selection_join = joins and (index == #wrapped and '\n' or joins[index] or '') }
                end
                if cacheable then
                    -- A mid-stream unclosed fence re-keys the whole code line each
                    -- delta; cap the cache so that cannot grow quadratically.
                    if lc_count >= LINE_CACHE_MAX or lc_bytes >= LINE_CACHE_BYTES or lc_rows >= LINE_CACHE_ROWS then
                        line_cache, lc_count, lc_bytes, lc_rows = {}, 0, 0, 0
                    end
                    line_cache[key] = cached
                    lc_count = lc_count + 1
                    lc_bytes = lc_bytes + #ll.text
                    lc_rows = lc_rows + #cached
                end
            end
            for i = 1, #cached do rows[#rows + 1] = cached[i] end
        end
    end
    if self.rg.selection_line then
        for i, row in ipairs(rows) do row.selection_index = i end
    end
    self.cache[entry] = { width = width, len = #entry.text, rows = rows,
        line_cache = line_cache, lc_count = lc_count, lc_bytes = lc_bytes, lc_rows = lc_rows }
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

entry_block = function(self, entry, width)
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

    -- The live (last) entry grows during streaming. Re-render it at most every
    -- 250ms (a full markdown+wrap pass is O(answer size)); between renders the
    -- previous rows stay on screen, so the tail lags by at most one interval.
    local live = {}
    local live_entry = entries[#entries]
    if live_entry then
        local lc = self.live_cache
        local t = now_ms()
        if lc and lc.entry == live_entry and lc.width == width and t - lc.at < 250 then
            live = lc.rows
        else
            live = entry_block(self, live_entry, width)
            self.live_cache = { entry = live_entry, width = width, at = t, rows = live }
        end
    end
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
        -- Map the pointer to scroll while held AND on the frame it is released.
        -- Without the release pass, a quick press-drag-release that fits between
        -- two rendered frames keeps the stale (bottom) scroll and snaps back.
        if self.sb_drag and (down or self.prev_down) then
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
    -- Re-arm tail-follow only when the user actually reaches the bottom, never
    -- while a scrollbar drag is active: grabbing the thumb at the bottom must
    -- disengage follow, not re-arm it on the same frame.
    if not self.anchor_top and not self.sb_drag and self.scroll >= max_scroll - 1 then
        self.follow = true
    end

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
    if rg.begin_selection and not self.lock_input then
        rg.begin_selection(x + 1, y + 1, w - 2, h - 2)
    end
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
    -- Fake bold redraws the run one PHYSICAL pixel to the right. The native
    -- renderer snaps every glyph to whole device pixels, so the old +0.6
    -- logical offset rounded differently per glyph (some doubled, some not)
    -- and read as a blurry ghost image. 1/(dpi*zoom) is exactly one device
    -- pixel at any DPI/zoom, so every glyph in the run shifts uniformly.
    local bold_dx = 1
    if rg.display_info then
        local info = rg.display_info()
        local sx = (info.dpi_x or 1) * (info.ui_scale or 1)
        if sx > 0 then bold_dx = 1 / sx end
    end
    local function draw_text_runs(value, left, top, color, bold, spans, allow_links)
        local links = allow_links and self.on_link and find_links(value) or {}
        local boundaries = {1, #value + 1}
        for _, link in ipairs(links) do
            boundaries[#boundaries + 1] = link.s
            boundaries[#boundaries + 1] = link.e + 1
        end
        for _, span in ipairs(spans or {}) do
            boundaries[#boundaries + 1] = span.first
            boundaries[#boundaries + 1] = span.last + 1
        end
        table.sort(boundaries)
        local function position(first)
            if first == 1 then return left end
            -- Text measurement omits trailing character spacing. A sentinel
            -- preserves that advance when a styled run starts mid-line.
            return left + measure(value:sub(1, first - 1) .. ' ') - measure(' ')
        end
        for i = 1, #boundaries - 1 do
            local first, last = boundaries[i], boundaries[i + 1] - 1
            if first <= last then
                local ink, strong = color, bold
                for _, link in ipairs(links) do
                    if first >= link.s and first <= link.e then ink = M.link_color; break end
                end
                for _, span in ipairs(spans or {}) do
                    if first >= span.first and first <= span.last then strong = true; break end
                end
                local run, draw_x = value:sub(first, last), position(first)
                self:draw_line(run, draw_x, top, ink)
                if strong then self:draw_line(run, draw_x + bold_dx, top, ink) end
            end
        end
        for _, link in ipairs(links) do
            local lx, lw = position(link.s), measure(link.url)
            rg.draw_rectangle(lx, top + self.font_size + 1, lw, 1, table.unpack(M.link_color))
            frame_links[#frame_links + 1] = { x = lx, y = top, w = lw, h = self.line_h, url = link.url }
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
                draw_text_runs(value, cx + 8, ly, r.color, r.table_header, nil, true)
                if rg.selection_line and not self.lock_input then
                    rg.selection_line(r.entry, r.selection_index, col, cx + 8, ly, self.font_size,
                        value, col == #r.cells and '\n' or '\t')
                end
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
                draw_text_runs(r.text, draw_x, ly, r.color, r.bold, r.bold_spans, not r.code)
            end
        end
        if rg.selection_line and not self.lock_input and r.selection_join then
            rg.selection_line(r.entry, r.selection_index, 1, text_x + (r.bg and 8 or 0), ly,
                self.font_size, r.text, r.selection_join)
        end
    end
    rg.end_scissor()

    -- Fire a link click: press and release both landed on the same rect, the
    -- press didn't start on the scrollbar, and no modal is overlaying us.
    if link_released and self.on_link and not self.lock_input and not self._press_on_sb
        and not (rg.selection_dragged and rg.selection_dragged()) then
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

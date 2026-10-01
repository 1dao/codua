-- xagent/tools/html_md.lua — HTML → compact Markdown for WebFetch, plus the
-- page map (headings, anchors) that lets the model jump into a big page instead
-- of reading it front to back. Pure string code: no I/O, offline-testable.
--
-- convert(html, base_url) returns
--   { markdown = string, title = string|nil,
--     headings = { { level, text, offset, id }... },
--     anchors = { [id] = offset }, main_offset = number|nil }
-- Offsets are 0-based byte positions in `markdown`. They are recorded while
-- emitting, so they stay exact; nothing post-processes the text afterwards.

local M = {}

-- Elements whose content is never page text. nav/footer are site chrome that
-- otherwise fills the 16KB budget before the article starts.
local SKIP = {
    script = true, style = true, noscript = true, svg = true, template = true,
    iframe = true, nav = true, footer = true, head = true, button = true,
    select = true, canvas = true, object = true,
}
-- Raw-text elements: their content may contain '<' that is not markup, so the
-- close tag is found literally rather than by nesting.
local RAW = { script = true, style = true, noscript = true, template = true, textarea = true }

local BLOCK = {
    p = true, div = true, section = true, article = true, header = true,
    main = true, aside = true, blockquote = true, figure = true, figcaption = true,
    form = true, fieldset = true, address = true, details = true, summary = true,
    dl = true, dt = true, dd = true, center = true, caption = true,
    table = true, thead = true, tbody = true, tfoot = true, body = true, html = true,
}

local VOID = {
    br = true, hr = true, img = true, input = true, meta = true, link = true,
    area = true, base = true, col = true, embed = true, source = true,
    track = true, wbr = true, param = true,
}

local ENTITIES = {
    nbsp = ' ', amp = '&', lt = '<', gt = '>', quot = '"', apos = "'",
    middot = '·', mdash = '—', ndash = '–', hellip = '…', copy = '©',
    reg = '®', trade = '™', deg = '°', times = '×', divide = '÷',
    lsquo = '‘', rsquo = '’', ldquo = '“', rdquo = '”', laquo = '«',
    raquo = '»', bull = '•', rarr = '→', larr = '←', uarr = '↑', darr = '↓',
    harr = '↔', rArr = '⇒', lArr = '⇐', le = '≤', ge = '≥', ne = '≠',
    plusmn = '±', sect = '§', para = '¶', shy = '', zwj = '', zwnj = '',
    ensp = ' ', emsp = ' ', thinsp = ' ', hyphen = '-', minus = '−',
    euro = '€', pound = '£', yen = '¥', cent = '¢', infin = '∞', lambda = 'λ',
}

local function decode_entities(s)
    if not s:find('&', 1, true) then return s end
    return (s:gsub('&(#?[xX]?)(%w+);', function(kind, name)
        if kind == '' then return ENTITIES[name] or ENTITIES[name:lower()] end
        local n = (kind == '#') and tonumber(name) or tonumber(name, 16)
        if n and n > 0 and n <= 0x10FFFF and not (n >= 0xD800 and n <= 0xDFFF) then
            return utf8.char(n)
        end
        return ''
    end))
end
M.decode_entities = decode_entities

-- Windows-1252 differs from Latin-1 only in 0x80–0x9F; browsers decode a
-- declared "iso-8859-1" as 1252, so we do too.
local CP1252 = {
    [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E,
    [0x85] = 0x2026, [0x86] = 0x2020, [0x87] = 0x2021, [0x88] = 0x02C6,
    [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152,
    [0x8E] = 0x017D, [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C,
    [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
    [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A,
    [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178,
}

-- Charset from the Content-Type header, else from a <meta> in the first 2KB.
function M.charset(body, content_type)
    local cs = tostring(content_type or ''):lower():match('charset%s*=%s*["\']?([%w_.:-]+)')
    if not cs then
        cs = tostring(body or ''):sub(1, 2048):lower():match('<meta[^>]-charset%s*=%s*["\']?([%w_.:-]+)')
    end
    return cs
end

-- Re-encode a single-byte Western page as UTF-8; otherwise valid_utf8 would
-- turn every accented byte into U+FFFD. Other charsets are left alone, and so
-- is a body that already parses as UTF-8: servers often declare latin1 while
-- actually serving UTF-8.
function M.to_utf8(body, charset)
    body = tostring(body or '')
    charset = tostring(charset or '')
    local single = charset:find('8859%-1', 1) or charset:find('latin', 1, true)
        or charset:find('1252', 1, true) or charset == 'ascii' or charset == 'us-ascii'
    if not single or utf8.len(body) then return body end
    return (body:gsub('[\128-\255]', function(c)
        local b = c:byte()
        return utf8.char(CP1252[b] or b)
    end))
end

-- Value of attribute `name` in the raw tag text (`tag`, lowercased copy `ltag`).
-- Matching runs on the lowercased copy; the value comes from the original.
local function attr(tag, ltag, name)
    for _, pat in ipairs({
        '[%s/]' .. name .. '%s*=%s*"()[^"]*()"',
        '[%s/]' .. name .. "%s*=%s*'()[^']*()'",
        '[%s/]' .. name .. '%s*=%s*()[^%s"\'>]+()',
    }) do
        local s, e = ltag:match(pat)
        if s then return decode_entities(tag:sub(s, e - 1)) end
    end
end

-- Content a browser does not show: the `hidden` attribute, aria-hidden,
-- display:none, or a bare utility class `hidden`. Tabbed docs (redis.io's
-- per-client API panels) ship every inactive tab this way, which otherwise
-- buries the page text under a dozen copies of the same signatures. A
-- responsive `hidden lg:flex` is visible on desktop, so it is kept.
local function is_hidden(ltag)
    -- Not hidden, but chrome all the same: Sphinx marks its sidebar and the
    -- prev/next bars <div role="navigation"> rather than using <nav>.
    if ltag:find('%srole%s*=%s*["\']?navigation') then return true end
    local bare = ltag:gsub('"[^"]*"', '""'):gsub("'[^']*'", "''")
    if bare:find('%shidden[%s/>=]') then return true end
    if ltag:find('aria%-hidden%s*=%s*["\']?true') then return true end
    local style = ltag:match('%sstyle%s*=%s*"([^"]*)"') or ltag:match("%sstyle%s*=%s*'([^']*)'")
    if style and style:find('display%s*:%s*none') then return true end
    local class = ltag:match('%sclass%s*=%s*"([^"]*)"') or ltag:match("%sclass%s*=%s*'([^']*)'")
    if class and (' ' .. class .. ' '):find('%shidden%s') then
        for token in class:gmatch('%S+') do
            if token:find('^[%w-]+:') and not token:find(':hidden$') then return false end
        end
        return true
    end
    return false
end

-- Resolve `href` against the page URL so the model can fetch it directly.
-- Fragment-only links stay as-is: they name anchors on this same page.
function M.resolve_url(base, href)
    href = href:gsub('^%s+', ''):gsub('%s+$', '')
    if href == '' or href:sub(1, 1) == '#' or href:match('^%a[%w+.-]*:') then return href end
    local scheme, origin = (base or ''):match('^((%a[%w+.-]*):)//[^/?#]*')
    origin = base and base:match('^%a[%w+.-]*://[^/?#]*')
    if not origin then return href end
    if href:sub(1, 2) == '//' then return scheme .. href end
    local path
    if href:sub(1, 1) == '/' then
        path = href
    elseif href:sub(1, 1) == '?' then
        return (base:gsub('[?#].*$', '')) .. href
    else
        local bpath = base:sub(#origin + 1):gsub('[?#].*$', '')
        path = bpath:gsub('[^/]*$', '') .. href
        if path:sub(1, 1) ~= '/' then path = '/' .. path end
    end
    -- Collapse ./ and ../ segments; the query/fragment is left untouched.
    local tail = path:match('[?#].*$') or ''
    path = path:sub(1, #path - #tail)
    local parts = {}
    for seg in (path .. (path:sub(-1) == '/' and '' or '')):gmatch('[^/]*') do parts[#parts + 1] = seg end
    local out = {}
    for i, seg in ipairs(parts) do
        if seg == '..' then
            if #out > 1 then out[#out] = nil end
            if i == #parts then out[#out + 1] = '' end
        elseif seg == '.' then
            if i == #parts then out[#out + 1] = '' end
        elseif seg ~= '' or i == 1 or i == #parts then
            out[#out + 1] = seg
        end
    end
    local joined = table.concat(out, '/')
    if joined:sub(1, 1) ~= '/' then joined = '/' .. joined end
    return origin .. joined .. tail
end

function M.convert(html, base_url)
    html = tostring(html or '')
    local lower = html:lower()
    local n = #html

    local pieces, len = {}, 0
    local trail_nl = 0          -- newlines at the end of the output so far
    local at_line_start = true
    local last_space = false    -- output ends with ' ' (a "- " or "| " prefix)
    local pending_space = false
    -- Just emitted a line prefix ("- ", "### "): a block element right inside
    -- (<li><p>) must not break the line and orphan the prefix.
    local fresh = false
    local pre_fresh = false     -- the newline right after <pre> is not content
    local pre_indent = ''       -- a fence inside a list item is indented under it

    local pre_depth = 0
    local cell_depth = 0        -- inside <td>/<th>: line breaks become spaces
    local lists = {}            -- stack of { ordered = bool, count = n }
    local links = {}            -- stack of open <a href> { href, idx, has_text } or false
    local link_depth = 0        -- open <a href> entries in `links`
    local marks = {}            -- stack of open inline marks: piece index of the opener
    local code_depth = 0        -- open `code` spans: text inside is not escaped
    local heading = nil         -- { level, offset, piece, id }
    local rows = {}             -- stack of tables: { row = n, cells = n }
    local headings, anchors = {}, {}
    local title, main_offset

    local function emit(s)
        if s == '' then return end
        if pending_space and not at_line_start and not last_space and not s:find('^%s') then
            pieces[#pieces + 1] = ' '
            len = len + 1
        end
        pending_space = false
        pieces[#pieces + 1] = s
        len = len + #s
        local nl = #s:match('\n*$')
        if nl == #s then trail_nl = trail_nl + nl else trail_nl = nl end
        at_line_start = nl > 0
        last_space = s:sub(-1) == ' '
        fresh = false
    end

    -- Closing markers hug the preceding text: `**bold**`, not `**bold **`.
    local function emit_close(s)
        local p = pending_space
        pending_space = false
        emit(s)
        pending_space = p
    end

    -- Drop the last piece (an empty mark or link spacer) and re-derive the
    -- writer state from what is now last.
    local function drop_last()
        local p = table.remove(pieces)
        len = len - #p
        local last = pieces[#pieces] or ''
        -- Breaks are often separate "\n" pieces, so count back across them.
        local nl, k = 0, #pieces
        while k > 0 do
            local q = pieces[k]
            local tail = #q:match('\n*$')
            nl = nl + tail
            if tail < #q then break end
            k = k - 1
        end
        trail_nl = nl
        at_line_start = (#pieces == 0) or nl > 0
        last_space = last:sub(-1) == ' '
    end

    -- `soft` breaks come from generic blocks (<p>, <div>) and yield to a line
    -- prefix just emitted; structural ones (headings, list items) do not.
    local function brk(count, soft)
        if len == 0 then pending_space = false; return end
        -- Inside a cell or a link a newline would break the Markdown syntax:
        -- a docs "card" is <a><p class=title>…</p><p>…</p></a>.
        if cell_depth > 0 or link_depth > 0 or (soft and fresh) then pending_space = true; return end
        -- A <div> inside a list item ("C++11" badge, then the link) would put
        -- the rest of the item on an unindented line; keep the item on one.
        if soft and #lists > 0 then pending_space = true; return end
        -- Inside a list a paragraph break would detach the item text; one newline.
        -- Same inside a table: a blank line between <thead> and <tbody> rows
        -- ends the Markdown table after its header.
        if #lists > 0 or #rows > 0 then count = 1 end
        pending_space = false
        if trail_nl < count then emit(string.rep('\n', count - trail_nl)) end
    end

    -- An item that produced nothing (<li><select>…</li>, a separator holding
    -- only an icon) would leave a bare "- " line: take its prefix back.
    local function drop_empty_item()
        local top = lists[#lists]
        if top and top.prefix_idx and top.prefix_idx == #pieces then
            drop_last()
            if top.ordered then top.count = top.count - 1 end
            fresh = false
        end
        if top then top.prefix_idx = nil end
    end

    local function list_indent()
        return string.rep('  ', math.max(#lists - 1, 0))
    end

    local function text(s)
        if s == '' then return end
        s = decode_entities(s)
        if pre_depth > 0 then
            s = s:gsub('\r\n?', '\n')
            if pre_fresh then s = s:gsub('^\n', ''); pre_fresh = false end
            if pre_indent ~= '' and s ~= '' then
                s = s:gsub('\n([^\n])', '\n' .. pre_indent .. '%1')
                if at_line_start then s = pre_indent .. s end
            end
            emit(s)
            return
        end
        if s:find('^%s') then pending_space = true end
        local words = s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
        if words ~= '' then
            -- Text that happens to start a line with '#' is not a heading.
            if (at_line_start or len == 0) and words:sub(1, 1) == '#' then words = '\\' .. words end
            -- A literal '*' next to emphasis (Sphinx: <em><span>*</span>args</em>)
            -- would read as another mark: "**args*".
            if code_depth == 0 then words = words:gsub('%*', '\\*') end
            -- After a code block or <br> in a list item the text continues
            -- the item; unindented it would end the list.
            if at_line_start and len > 0 and #lists > 0 and cell_depth == 0 then
                emit(string.rep('  ', #lists))
            end
            emit(words)
            for i = 1, #links do if links[i] then links[i].has_text = true end end
            if s:find('%s$') then pending_space = true end
        end
    end

    local function record_anchor(id)
        if not id or id == '' then return end
        if anchors[id] == nil then anchors[id] = len end
        if heading and not heading.id then heading.id = id end
    end

    -- Index just past the matching close of `tag` opened before `pos`, counting
    -- nested opens; raw-text elements match the first literal close.
    local function skip_past(tag, pos)
        local close = '</' .. tag
        if RAW[tag] then
            local s = lower:find(close, pos, true)
            if not s then return n + 1 end
            local e = lower:find('>', s, true)
            return (e or n) + 1
        end
        local depth, p = 1, pos
        local open_pat = '<' .. tag .. '[%s/>]'
        while true do
            local cs = lower:find(close, p, true)
            if not cs then return n + 1 end
            local os = lower:find(open_pat, p)
            if os and os < cs then
                depth = depth + 1
                p = os + #tag + 1
            else
                depth = depth - 1
                local e = lower:find('>', cs, true) or n
                if depth == 0 then return e + 1 end
                p = e + 1
            end
        end
    end

    -- Find the end of a tag starting at `i` ('<'), honouring quoted values.
    local function tag_end(i)
        local p = i + 1
        while p <= n do
            local c = lower:find('[>"\']', p)
            if not c then return n end
            local ch = lower:sub(c, c)
            if ch == '>' then return c end
            local q = lower:find(ch, c + 1, true)
            if not q then return n end
            p = q + 1
        end
        return n
    end

    local t = lower:match('<title[^>]*>(.-)</title>')
    if t then
        local s = lower:find('<title', 1, true)
        local cs = lower:find('>', s, true) + 1
        title = decode_entities(html:sub(cs, cs + #t - 1)):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
        if title == '' then title = nil end
    end

    local i = 1
    while i <= n do
        local lt = html:find('<', i, true)
        if not lt then text(html:sub(i)); break end
        if lt > i then text(html:sub(i, lt - 1)) end
        if lower:sub(lt, lt + 3) == '<!--' then
            local e = lower:find('-->', lt + 4, true)
            i = (e and e + 3) or n + 1
        elseif lower:sub(lt + 1, lt + 1):match('[!?]') then
            local e = lower:find('>', lt, true)
            i = (e or n) + 1
        else
            local closing, name = lower:match('^<(/?)([%a][%w:-]*)', lt)
            if not name then
                text('<')
                i = lt + 1
            else
                local te = tag_end(lt)
                local tag, ltag = html:sub(lt, te), lower:sub(lt, te)
                i = te + 1
                local hlevel = tonumber(name:match('^h([1-6])$'))
                if closing == '' then
                    if pre_depth > 0 then
                        if name == 'pre' then pre_depth = pre_depth + 1
                        elseif name == 'br' then emit('\n') end
                        record_anchor(attr(tag, ltag, 'id'))
                    elseif SKIP[name] and not ltag:find('/>$') then
                        -- A <head> without its close tag would swallow the
                        -- page; only skip it when the close exists.
                        if name ~= 'head' or lower:find('</head', i, true) then
                            i = skip_past(name, i)
                        end
                    elseif not VOID[name] and not ltag:find('/>$') and is_hidden(ltag) then
                        i = skip_past(name, i)
                    else
                        if hlevel then
                            -- <li><h4> stays "- #### x"; a heading in a table
                            -- cell gets no '#' (it would break the row) but
                            -- still goes into the section list.
                            if not fresh then brk(2) end
                            heading = { level = hlevel, offset = len }
                            record_anchor(attr(tag, ltag, 'id'))
                            if cell_depth == 0 and link_depth == 0 then
                                emit(string.rep('#', hlevel) .. ' ')
                            end
                            heading.piece = #pieces + 1
                            fresh = cell_depth == 0
                        elseif name == 'pre' then
                            brk(2)
                            record_anchor(attr(tag, ltag, 'id'))
                            -- The language is on <pre class> or the <code> right inside.
                            local cls = attr(tag, ltag, 'class') or ''
                            local inner = lower:match('^%s*(<code[^>]*>)', i)
                            if inner then cls = cls .. ' ' .. (attr(inner, inner, 'class') or '') end
                            local lang = cls:match('language%-([%w_+-]+)') or cls:match('lang%-([%w_+-]+)') or ''
                            pre_indent = (#lists > 0 and cell_depth == 0) and string.rep('  ', #lists) or ''
                            emit(pre_indent .. '```' .. lang .. '\n')
                            pre_depth = 1
                            pre_fresh = true
                        elseif name == 'li' then
                            drop_empty_item()
                            if cell_depth > 0 then
                                pending_space = true
                            else
                                brk(1)
                            end
                            record_anchor(attr(tag, ltag, 'id'))
                            local top = lists[#lists]
                            if cell_depth == 0 then
                                if top and top.ordered then
                                    top.count = top.count + 1
                                    emit(list_indent() .. top.count .. '. ')
                                else
                                    emit(list_indent() .. '- ')
                                end
                                if top then top.prefix_idx = #pieces end
                                fresh = true
                            end
                        elseif name == 'ul' or name == 'ol' or name == 'menu' then
                            brk(#lists == 0 and 2 or 1)
                            record_anchor(attr(tag, ltag, 'id'))
                            lists[#lists + 1] = { ordered = name == 'ol',
                                count = (tonumber(attr(tag, ltag, 'start') or '') or 1) - 1 }
                        elseif name == 'tr' then
                            brk(1)
                            record_anchor(attr(tag, ltag, 'id'))
                            local tb = rows[#rows]
                            if tb then tb.cells = 0; tb.row = tb.row + 1; tb.header = false end
                            if cell_depth == 0 then emit('|') end
                        elseif name == 'td' or name == 'th' then
                            record_anchor(attr(tag, ltag, 'id'))
                            local tb = rows[#rows]
                            if tb then
                                tb.cells = tb.cells + 1
                                if name == 'th' then tb.header = true end
                            end
                            if cell_depth == 0 then emit(' ') end
                            cell_depth = cell_depth + 1
                        elseif name == 'table' then
                            brk(2)
                            record_anchor(attr(tag, ltag, 'id'))
                            rows[#rows + 1] = { row = 0, cells = 0, header = false }
                        elseif name == 'br' then
                            -- <br> after a block (cplusplus.com: </table><br>)
                            -- must not stack a third newline onto its break.
                            -- A mark opened just before the break (<strong><br>x</strong>,
                            -- learn.unity.com) would leave "**" dangling at the end
                            -- of the line: drop it, and its close with it.
                            if marks[#marks] and marks[#marks] == #pieces then
                                drop_last()
                                -- and the space emitted ahead of it
                                if pieces[#pieces] == ' ' then drop_last() end
                                marks[#marks] = -1
                            end
                            if cell_depth > 0 or link_depth > 0 then
                                pending_space = true
                            elseif len > 0 and trail_nl < 2 then
                                -- In a list item the next line must stay indented.
                                emit('\n' .. (#lists > 0 and (list_indent() .. '  ') or ''))
                            end
                        elseif name == 'hr' then
                            brk(2); emit('---'); brk(2)
                        elseif name == 'code' or name == 'kbd' or name == 'samp' or name == 'tt' then
                            record_anchor(attr(tag, ltag, 'id'))
                            if code_depth > 0 then
                                marks[#marks + 1] = -2
                            else
                                emit('`'); marks[#marks + 1] = #pieces
                            end
                            code_depth = code_depth + 1
                        elseif name == 'strong' or name == 'b' then
                            record_anchor(attr(tag, ltag, 'id'))
                            -- In a code span a mark would be literal text:
                            -- Sphinx writes <code>getenv(<em>s</em>)</code>.
                            if code_depth > 0 then marks[#marks + 1] = -2
                            else emit('**'); marks[#marks + 1] = #pieces end
                        elseif name == 'em' or name == 'i' then
                            record_anchor(attr(tag, ltag, 'id'))
                            if code_depth > 0 then marks[#marks + 1] = -2
                            else emit('*'); marks[#marks + 1] = #pieces end
                        elseif name == 'a' then
                            record_anchor(attr(tag, ltag, 'id'))
                            record_anchor(attr(tag, ltag, 'name'))
                            local href = attr(tag, ltag, 'href')
                            if href and not href:lower():match('^%s*javascript:') then
                                -- '[' is inserted at close time, only if the link has text.
                                local space_idx
                                if pending_space and not at_line_start and not last_space then
                                    emit(' ')
                                    space_idx = #pieces
                                end
                                link_depth = link_depth + 1
                                links[#links + 1] = { href = M.resolve_url(base_url, href),
                                    idx = #pieces + 1, has_text = false, space_idx = space_idx }
                            else
                                links[#links + 1] = false
                            end
                        else
                            if BLOCK[name] then brk((name == 'dd' or name == 'dt') and 1 or 2, true) end
                            if name == 'main' and not main_offset then main_offset = len end
                            record_anchor(attr(tag, ltag, 'id'))
                            if name == 'img' then
                                local alt = attr(tag, ltag, 'alt')
                                if alt and alt ~= '' then
                                    -- In a link the alt only names an image-only
                                    -- link; a thumbnail beside a title would
                                    -- repeat the title.
                                    local link = links[#links]
                                    if link then
                                        link.alt = link.alt or alt
                                    elseif link_depth == 0 then
                                        text(' ' .. alt .. ' ')
                                    end
                                end
                            end
                        end
                    end
                else
                    -- Closing tag.
                    if pre_depth > 0 then
                        if name == 'pre' then
                            pre_depth = pre_depth - 1
                            if pre_depth == 0 then
                                if trail_nl == 0 then emit('\n') end
                                emit(pre_indent .. '```')
                                pre_indent = ''
                                brk(2)
                            end
                        end
                    elseif hlevel then
                        if heading then
                            -- The heading as plain text: link targets and inline marks dropped.
                            local htext = table.concat(pieces, '', heading.piece)
                                :gsub('%[(.-)%]%b()', '%1'):gsub('[`*]', '')
                                :gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '')
                            headings[#headings + 1] = { level = heading.level, text = htext,
                                offset = heading.offset, id = heading.id }
                            heading = nil
                        end
                        brk(2)
                    elseif name == 'li' then
                        -- the next <li> or list close breaks the line
                        drop_empty_item()
                    elseif name == 'ul' or name == 'ol' or name == 'menu' then
                        drop_empty_item()
                        lists[#lists] = nil
                        brk(#lists == 0 and 2 or 1)
                    elseif name == 'td' or name == 'th' then
                        if cell_depth > 0 then cell_depth = cell_depth - 1 end
                        if cell_depth == 0 then emit_close(' |') end
                    elseif name == 'tr' then
                        local tb = rows[#rows]
                        if tb and cell_depth == 0 and tb.row == 1 and tb.cells > 0 then
                            -- Markdown tables need a separator after the first row.
                            brk(1)
                            emit('|' .. string.rep(' --- |', tb.cells))
                        end
                        brk(1)
                    elseif name == 'table' then
                        rows[#rows] = nil
                        brk(2)
                    elseif name == 'code' or name == 'kbd' or name == 'samp' or name == 'tt'
                        or name == 'strong' or name == 'b' or name == 'em' or name == 'i' then
                        local marker = (name == 'strong' or name == 'b') and '**'
                            or ((name == 'em' or name == 'i') and '*' or '`')
                        local opener = table.remove(marks)
                        if marker == '`' and code_depth > 0 then code_depth = code_depth - 1 end
                        if opener == -2 then
                            -- a mark nested in a code span: nothing was emitted
                        elseif opener == -1 then
                            -- opener already dropped at a <br>
                        elseif opener and opener == #pieces and pieces[#pieces] == marker then
                            -- Nothing between the marks (an icon <i class="icon">):
                            -- a bare "**" would turn the rest of the line bold.
                            drop_last()
                        else
                            emit_close(marker)
                        end
                    elseif name == 'a' then
                        local link = table.remove(links)
                        if link then link_depth = link_depth - 1 end
                        local permalink = false
                        if link and link.has_text and link.href:sub(1, 1) == '#' then
                            -- Sphinx's headerlink "¶" (and "#", "§", "🔗" elsewhere)
                            -- is a self-link glyph, not text; it would also land in
                            -- every heading of the section list.
                            local t = table.concat(pieces, '', link.idx):gsub('%s', '')
                            permalink = t == '¶' or t == '#' or t == '§' or t == '🔗'
                        end
                        if permalink then
                            while #pieces >= link.idx do drop_last() end
                            if link.space_idx and link.space_idx == #pieces then drop_last() end
                            pending_space = false
                        elseif link and link.has_text then
                            table.insert(pieces, link.idx, '[')
                            len = len + 1
                            emit_close('](' .. link.href .. ')')
                        elseif link and link.alt then
                            emit('[' .. link.alt .. '](' .. link.href .. ')')
                        elseif link and link.space_idx and link.space_idx == #pieces then
                            -- A text-less link (a heading's icon permalink) leaves
                            -- nothing behind, not even the space emitted for it.
                            drop_last()
                            pending_space = true
                        end
                    elseif BLOCK[name] then
                        brk(name == 'dt' and 1 or 2, true)
                    end
                end
            end
        end
    end

    local md = table.concat(pieces):gsub('%s+$', '')
    return { markdown = md, title = title, headings = headings,
        anchors = anchors, main_offset = main_offset }
end

-- Target of a <meta http-equiv="refresh" content="0; url=…"> redirect stub
-- (docs.python.org keeps one at every moved page), resolved against
-- `base_url`; nil when the page is not one. Only small bodies qualify: a real
-- page that auto-reloads itself is not a redirect.
function M.meta_refresh(html, base_url)
    if #html > 8192 then return nil end
    local lower = html:lower()
    for tag_start in lower:gmatch('()<meta[^>]-http%-equiv%s*=%s*["\']?refresh') do
        local tag_end = lower:find('>', tag_start, true) or #lower
        local tag, ltag = html:sub(tag_start, tag_end), lower:sub(tag_start, tag_end)
        local content = attr(tag, ltag, 'content')
        local url = content and content:match('[Uu][Rr][Ll]%s*=%s*["\']?([^"\']+)')
        if url then
            url = url:gsub('%s+$', '')
            return M.resolve_url(base_url, url)
        end
    end
    return nil
end

-- Headings of a Markdown/plain-text document (outside code fences), so a long
-- .md file gets the same table of contents as an HTML page.
function M.markdown_headings(md)
    local headings, in_fence, pos = {}, false, 0
    for line in (md .. '\n'):gmatch('([^\n]*)\n') do
        if line:match('^%s*```') or line:match('^%s*~~~') then
            in_fence = not in_fence
        elseif not in_fence then
            local hashes, htext = line:match('^(#+)%s+(.-)%s*#*%s*$')
            if hashes and #hashes <= 6 then
                headings[#headings + 1] = { level = #hashes, text = htext, offset = pos }
            end
        end
        pos = pos + #line + 1
    end
    return headings
end

-- Offset of anchor `frag` (exact, then percent-decoded, then case-insensitive),
-- backed up to the start of its line so a heading keeps its '#' prefix.
function M.find_anchor(doc, frag)
    if not frag or frag == '' then return nil end
    local off = doc.anchors[frag]
    if not off then
        local dec = frag:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
        off = doc.anchors[dec]
        if not off then
            local lf = dec:lower()
            for id, o in pairs(doc.anchors) do
                if id:lower() == lf then off = o; break end
            end
        end
    end
    if not off then return nil end
    local md = doc.markdown
    local p = off
    while p > 0 and md:sub(p, p) ~= '\n' do p = p - 1 end
    return p
end

-- Slice `limit` bytes starting at 0-based `offset`, never splitting a UTF-8
-- sequence and preferring to end on a line break. Returns text, next_offset
-- (nil when the slice reaches the end).
function M.window(md, offset, limit)
    local total = #md
    local s = math.max(0, math.min(offset or 0, total))
    while s < total and s > 0 do
        local b = md:byte(s + 1)
        if b < 0x80 or b >= 0xC0 then break end
        s = s + 1
    end
    if total - s <= limit then return md:sub(s + 1), nil, s end
    local e = s + limit             -- exclusive 0-based end
    local nl = md:sub(s + 1, e):match('.*()\n')
    if nl and nl > limit * 3 / 4 then
        e = s + nl
    else
        while e > s do
            local b = md:byte(e + 1)
            if b < 0x80 or b >= 0xC0 then break end
            e = e - 1
        end
    end
    return md:sub(s + 1, e), e, s
end

-- A table of contents within `budget` bytes: deeper heading levels are dropped
-- first, so a page with hundreds of h3 entries still lists its h1/h2 skeleton.
function M.toc(headings, budget)
    if #headings == 0 then return nil end
    local function render(max_level)
        local lines, min_level = {}, 6
        for _, h in ipairs(headings) do
            if h.level < min_level then min_level = h.level end
        end
        for _, h in ipairs(headings) do
            if h.level <= max_level then
                lines[#lines + 1] = string.format('%s- %s (offset=%d%s)',
                    string.rep('  ', h.level - min_level), h.text, h.offset,
                    h.id and (', #' .. h.id) or '')
            end
        end
        return table.concat(lines, '\n'), #lines
    end
    local min_level = 6
    for _, h in ipairs(headings) do min_level = math.min(min_level, h.level) end
    for level = 6, min_level, -1 do
        local s = render(level)
        if #s <= budget then return s end
    end
    local s = render(min_level)
    local cut = s:sub(1, budget):match('^(.*)\n') or s:sub(1, budget)
    return cut .. '\n- ...'
end

return M

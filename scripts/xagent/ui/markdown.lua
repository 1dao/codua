-- xagent/ui/markdown.lua — light-weight Markdown styling for the transcript.
--
-- Renders an assistant message into a list of "logical lines", each carrying a
-- color (and optional background for code blocks). The transcript then wraps and
-- draws each logical line. Inline markers are removed from visible text;
-- bold spans, code blocks and table cells retain metadata for the renderer.
--
-- The active GUI theme supplies the palette for both light and dark surfaces.

local xtext = dofile('scripts/core/share/xtext.lua')
local source = require('xagent.ui.source_highlighter')

local M = {}

M.palette = {
    text    = { 214, 210, 224, 255 },   -- body
    heading = { 120, 175, 255, 255 },   -- # headings → blue
    code    = { 140, 210, 160, 255 },   -- code → green
    bullet  = { 150, 160, 200, 255 },   -- list lines
    quote   = { 160, 165, 178, 255 },   -- > blockquote
    hr      = { 90, 90, 104, 255 },     -- --- rule
    table   = { 196, 192, 210, 255 },   -- | table | rows
}
M.code_bg = { 34, 36, 42, 255 }

-- Expand tabs before lexing so wrapping and byte spans use identical text.
local function code_row(block, line, number)
    block.lines[#block.lines + 1] = line
    return { text = line:gsub('\t', '    '), color = M.palette.code, bg = M.code_bg,
        code = block, code_start = #block.lines == 1, number = number }
end

local function highlight(out)
    local blocks = {}
    for _, row in ipairs(out) do
        if row.code then
            local rows = blocks[row.code] or {}
            blocks[row.code] = rows
            rows[#rows + 1] = row
        end
    end
    for block, rows in pairs(blocks) do
        local lang = source.fence(block.language)
        local lines = {}
        for i, row in ipairs(rows) do lines[i] = row.text end
        local tokens = not block.per_line and source.tokenize(table.concat(lines, '\n'), lang) or {}
        local offset, cursor = 0, 1
        for _, row in ipairs(rows) do
            row.syntax = {}
            local current = tokens
            if block.per_line then current = source.tokenize(row.text, lang); offset, cursor = 0, 1 end
            while current[cursor] and current[cursor].last <= offset do cursor = cursor + 1 end
            local j = cursor
            while current[j] and current[j].first <= offset + #row.text do
                local token = current[j]
                row.syntax[#row.syntax + 1] = { first = math.max(1, token.first - offset),
                    last = math.min(#row.text, token.last - offset), kind = token.kind }
                j = j + 1
            end
            offset = offset + #row.text + 1
        end
    end
    return out
end

-- Strip inline markup down to its visible text.
local function strip_inline(s)
    s = s:gsub('%[(.-)%]%((.-)%)', '%1')   -- [text](url) -> text
    s = s:gsub('%*%*(.-)%*%*', '%1')       -- **bold** -> bold
    s = s:gsub('__(.-)__', '%1')           -- __bold__ -> bold
    s = s:gsub('`([^`]*)`', '%1')          -- `code` -> code
    return s
end

local function styled(s, color)
    local parts, spans, syntax, length = {}, {}, {}, 0
    local function append(value)
        parts[#parts + 1], length = value, length + #value
    end
    local function parse(fragment, depth)
        if depth >= 8 then append(fragment); return end
        local pos = 1
        while pos <= #fragment do
            local a, b, content = fragment:find('%*%*(.-)%*%*', pos)
            local kind = 'bold'
            local ua, ub, uc = fragment:find('__(.-)__', pos)
            if ua and (not a or ua < a) then a, b, content = ua, ub, uc end
            local ca, cb, cc = fragment:find('`([^`]*)`', pos)
            if ca and (not a or ca < a) then a, b, content, kind = ca, cb, cc, 'code' end
            append(a and fragment:sub(pos, a - 1) or fragment:sub(pos))
            if not a then break end
            local first = length + 1
            if kind == 'code' then
                append(content)
                syntax[#syntax + 1] = { first = first, last = length, kind = 'string' }
            else
                parse(content, depth + 1)
                spans[#spans + 1] = { first = first, last = length }
            end
            pos = b + 1
        end
    end
    parse(s:gsub('%[(.-)%]%((.-)%)', '%1'), 0)
    return { text = table.concat(parts), color = color, bold_spans = spans, syntax = syntax }
end

local function classify(line, P)
    if line == '' then return { text = '', color = P.text } end

    local hashes, htext = line:match('^(#+)%s+(.*)$')
    if hashes then
        local row = styled(htext, P.heading)
        row.bold = true
        return row
    end

    if line:match('^%s*[%-%*_]%s*[%-%*_]%s*[%-%*_][%s%-%*_]*$') then
        return { text = string.rep('─', 48), color = P.hr }   -- horizontal rule
    end

    local q = line:match('^%s*>%s?(.*)$')
    if q then return styled('┃ ' .. q, P.quote) end

    local ind, _, rest = line:match('^(%s*)([%-%*%+])%s+(.*)$')
    if rest then return styled(ind .. '• ' .. rest, P.bullet) end

    local ind2, num, rest2 = line:match('^(%s*)(%d+[%.%)])%s+(.*)$')
    if rest2 then return styled(ind2 .. num .. ' ' .. rest2, P.bullet) end

    if line:match('^%s*|.*|%s*$') then
        local cells, separator = {}, true
        local body = line:match('^%s*|(.*)|%s*$')
        for cell in (body .. '|'):gmatch('(.-)|') do
            cells[#cells + 1] = strip_inline(cell:match('^%s*(.-)%s*$'))
            if not cell:match('^%s*:?-+:?%s*$') then separator = false end
        end
        return { text = line, color = P.table, cells = cells, separator = separator }
    end

    return styled(line, P.text)
end

-- render(text) -> list of { text, color, bg? }
function M.render(text)
    local P = M.palette
    local out = {}
    local in_code = false
    local block
    for _, line in ipairs(xtext.split_lines(text)) do
        local fence, info = line:match('^%s*(```+)%s*(.*)$')
        if not fence then fence, info = line:match('^%s*(~~~+)%s*(.*)$') end
        if fence and not in_code then
            in_code = true
            block = { language = info, lines = {}, fence = fence }
        elseif in_code and fence and fence:sub(1, 1) == block.fence:sub(1, 1)
            and #fence >= #block.fence and info == '' then
            in_code = false
        elseif in_code then
            out[#out + 1] = code_row(block, line)
        else
            out[#out + 1] = classify(line, P)
        end
    end
    return highlight(out)
end

-- Recognize only the listing formats emitted by CodeExplore, Read and Grep.
-- Prose stays literal, including unknown paths and Markdown-looking source.
function M.render_tool(text, color)
    local out, block, mode = {}, nil, nil
    local explore = text:find('Source below is verbatim with line numbers', 1, true)
    local function finish()
        if block and #block.lines == 0 then out[#out + 1] = { text = block.title, color = color } end
        block = nil
    end
    local function start(title, path, kind)
        local lang = source.language(path)
        if not lang then return false end
        block = { title = title, language = lang.name, lines = {}, per_line = kind == 'grep', path = path }
        mode = kind
        return true
    end
    for _, line in ipairs(xtext.split_lines(text)) do
        local number, code = line:match('^ *(%d+)\t(.*)$')
        local path, hit, body = line:match('^(.-):(%d+):(.*)$')
        if block and mode == 'read' and not number then finish() end
        if block and mode == 'grep' and path ~= block.path then finish() end
        local heading = explore and line:match('^## (.*)$')
        if heading then
            finish()
            if not start(heading, heading, 'explore') then
                out[#out + 1] = { text = line, color = color }
            end
        elseif block and mode == 'explore' then
            if line ~= '' then out[#out + 1] = code_row(block, code or line:gsub('^\t+', ''), number or '') end
        elseif block and mode == 'read' then
            out[#out + 1] = code_row(block, code, number)
        elseif block and mode == 'grep' then
            out[#out + 1] = code_row(block, body, hit)
        else
            local read_path = line:match('^(.*) %(lines %d+%-%d+ of %d+%)$') or line:match('^(.*) %(%d+ lines%)$')
            if read_path and start(line, read_path, 'read') then
                -- Header is drawn by the first source row.
            elseif path and start(path, path, 'grep') then
                out[#out + 1] = code_row(block, body, hit)
            else out[#out + 1] = { text = line, color = color } end
        end
    end
    -- Preserve empty Read results rather than swallowing their header.
    finish()
    return highlight(out)
end

M.strip_inline = strip_inline   -- exposed for tests

return M

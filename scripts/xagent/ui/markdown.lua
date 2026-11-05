-- xagent/ui/markdown.lua — light-weight Markdown styling for the transcript.
--
-- Renders an assistant message into a list of "logical lines", each carrying a
-- color (and optional background for code blocks). The transcript then wraps and
-- draws each logical line. Inline markers are removed from visible text;
-- bold spans, code blocks and table cells retain metadata for the renderer.
--
-- The active GUI theme supplies the palette for both light and dark surfaces.

local xtext = dofile('scripts/core/share/xtext.lua')

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

-- Strip inline markup down to its visible text.
local function strip_inline(s)
    s = s:gsub('%[(.-)%]%((.-)%)', '%1')   -- [text](url) -> text
    s = s:gsub('%*%*(.-)%*%*', '%1')       -- **bold** -> bold
    s = s:gsub('__(.-)__', '%1')           -- __bold__ -> bold
    s = s:gsub('`([^`]*)`', '%1')          -- `code` -> code
    return s
end

local function styled(s, color)
    local parts, spans, pos, length = {}, {}, 1, 0
    while pos <= #s do
        local a, b, content = s:find('%*%*(.-)%*%*', pos)
        local ua, ub, uc = s:find('__(.-)__', pos)
        if ua and (not a or ua < a) then a, b, content = ua, ub, uc end
        local plain = strip_inline(a and s:sub(pos, a - 1) or s:sub(pos))
        parts[#parts + 1], length = plain, length + #plain
        if not a then break end
        content = strip_inline(content)
        spans[#spans + 1] = { first = length + 1, last = length + #content }
        parts[#parts + 1], length, pos = content, length + #content, b + 1
    end
    return { text = table.concat(parts), color = color, bold_spans = spans }
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
        if line:match('^%s*```') then
            in_code = not in_code
            if in_code then
                block = { language = line:match('^%s*```%s*(%S*)') or '', lines = {} }
            end
        elseif in_code then
            block.lines[#block.lines + 1] = line
            out[#out + 1] = { text = line, color = P.code, bg = M.code_bg,
                code = block, code_start = #block.lines == 1 }
        else
            out[#out + 1] = classify(line, P)
        end
    end
    return out
end

M.strip_inline = strip_inline   -- exposed for tests

return M

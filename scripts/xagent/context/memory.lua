-- Bounded, offline retrieval from the append-only learned memory file. Selected
-- notes live in the request system prompt, never the durable conversation.
local project_md = require('xagent.context.project_md')
local prompt = require('xagent.context.system_prompt')
local tokens = require('xagent.context.tokens')
local text = dofile('scripts/core/share/xtext.lua')

local M = {}
local MAX_SCAN_BYTES = 1024 * 1024
local MAX_QUERY_BYTES = 4096
local MAX_ENTRIES = 2000
local MAX_CONTEXT_BYTES = 4096
local STOP = {}
for word in ('the and for with this that from have into please help fix implement project current ' ..
    '如何 这个 那个 一下 当前 项目 功能 实现 修改 帮我 请帮 进行 需要 可以'):gmatch('%S+') do STOP[word] = true end

local function cut(s, limit)
    if #s <= limit then return s end
    local last = math.max(0, limit)
    while last > 0 and (s:byte(last + 1) or 0) >= 0x80 and (s:byte(last + 1) or 0) < 0xc0 do last = last - 1 end
    return s:sub(1, last)
end

local function terms(s, limit)
    local result, count = {}, 0
    s = text.valid_utf8(s):lower()
    local function add(word)
        if #word >= 2 and #word <= 96 and not STOP[word] and not result[word] and (not limit or count < limit) then
            result[word] = true
            count = count + 1
        end
    end
    for word in s:gmatch('[a-z0-9_]+') do
        add(word)
        for part in word:gmatch('[a-z0-9]+') do add(part) end
    end
    -- Adjacent Han characters allow Chinese matching without a dictionary or
    -- provider call. Do not create pairs across punctuation/ASCII boundaries.
    local previous
    for _, code in utf8.codes(s) do
        if (code >= 0x3400 and code <= 0x9fff) or (code >= 0x20000 and code <= 0x2fa1f) then
            local char = utf8.char(code)
            if previous then add(previous .. char) end
            previous = char
        else previous = nil end
    end
    return result
end

local function records(raw, partial)
    local out, current, fence = {}, nil, nil
    local function finish()
        if current then
            current.body = table.concat(current.body, '\n'):match('^%s*(.-)%s*$')
            if current.title ~= '' or current.body ~= '' then out[#out + 1] = current end
        end
    end
    local line_number = 0
    for raw_line in (raw .. '\n'):gmatch('(.-)\n') do
        line_number = line_number + 1
        local line = raw_line:gsub('\r$', '')
        local marker = line:match('^%s*(```+)') or line:match('^%s*(~~~+)')
        local title = not fence and line:match('^##%s+(.+)')
        if title then
            finish()
            current = { title = title, body = {}, line = line_number, order = #out + 1 }
        else
            if not current and not partial then current = { title = '', body = {}, line = line_number, order = 1 } end
            if current then current.body[#current.body + 1] = line end
        end
        if marker then
            if not fence then fence = marker
            elseif marker:sub(1, 1) == fence:sub(1, 1) and #marker >= #fence then fence = nil end
        end
    end
    finish()
    local bounded, seen = {}, {}
    -- Recent exact duplicates win and scan cost is bounded independently of the
    -- final context budget. Similar but distinct lessons remain independent.
    for i = #out, math.max(1, #out - MAX_ENTRIES + 1), -1 do
        local item = out[i]
        local key = (item.title .. '\n' .. item.body):gsub('%s+', ' ')
        if not seen[key] then seen[key] = true; bounded[#bounded + 1] = item end
    end
    return bounded
end

-- Pure selector, also usable by other hosts with remotely fetched memory text.
-- The byte budget includes reference rules, provenance and entry separators.
function M.select(raw, query, opts)
    opts = opts or {}
    local budget = math.max(0, math.min(MAX_CONTEXT_BYTES, math.floor(opts.max_bytes or MAX_CONTEXT_BYTES)))
    local query_terms = terms(cut(tostring(query or ''), MAX_QUERY_BYTES), 128)
    if not next(query_terms) or type(raw) ~= 'string' or raw == '' then return nil, {} end
    local items = records(text.valid_utf8(raw), opts.partial)
    local frequency = {}
    for _, item in ipairs(items) do
        item.title_terms, item.body_terms = terms(item.title), terms(item.body)
        for term in pairs(query_terms) do
            if item.title_terms[term] or item.body_terms[term] then frequency[term] = (frequency[term] or 0) + 1 end
        end
    end
    local ranked = {}
    for _, item in ipairs(items) do
        item.score = 0
        for term in pairs(query_terms) do
            if item.title_terms[term] or item.body_terms[term] then
                item.score = item.score + math.log(1 + #items / frequency[term]) * (item.title_terms[term] and 3 or 1)
            end
        end
        if item.score > 0 then ranked[#ranked + 1] = item end
    end
    table.sort(ranked, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.order > b.order
    end)
    local parts, selected = {}, {}
    local used = #prompt.memory_section(' ') - 1
    for _, item in ipairs(ranked) do
        if #selected >= math.min(4, opts.max_entries or 4) then break end
        local source = opts.partial and 'tail entry ' .. item.order or 'line ' .. item.line
        local prefix = '## ' .. cut(item.title ~= '' and item.title or 'Untitled lesson', 240) .. ' (' .. source .. ')\n'
        local room = math.min(1200, budget - used - 2) - #prefix
        if room >= 64 then
            local body = item.body
            if #body > room then
                local first
                local lower = body:lower()
                for term in pairs(query_terms) do
                    local at = lower:find(term, 1, true)
                    if at and (not first or at < first) then first = at end
                end
                -- Keep the matching passage when the lesson is longer than its
                -- share, rather than always sending its unrelated introduction.
                if first and first > room / 2 then
                    local start = math.max(1, first - 120)
                    while start <= #body and body:byte(start) >= 0x80 and body:byte(start) < 0xc0 do start = start + 1 end
                    body = '...\n' .. body:sub(start)
                end
                body = cut(body, room - #'\n...[truncated]') .. '\n...[truncated]'
            end
            local entry = prefix .. body
            parts[#parts + 1] = entry
            selected[#selected + 1] = { title = item.title, line = item.line, score = item.score }
            used = used + #entry + 2
        end
    end
    if #selected == 0 then return nil, selected end
    return prompt.memory_section(table.concat(parts, '\n\n')), selected
end

function M.retrieve(cwd, query, opts)
    local file = io.open(project_md.memory_path(cwd), 'rb')
    if not file then return nil, {} end
    local size = file:seek('end')
    if not size then file:close(); return nil, {} end
    local start = math.max(0, size - MAX_SCAN_BYTES)
    file:seek('set', start)
    local raw = file:read(MAX_SCAN_BYTES) or ''
    file:close()
    local settings = {}
    for key, value in pairs(opts or {}) do settings[key] = value end
    settings.partial = start > 0
    return M.select(raw, query, settings)
end

function M.query(messages)
    for i = #(messages or {}), 1, -1 do
        local message = messages[i]
        if message.role == 'user' then
            if type(message.content) == 'string' then return message.content end
            local parts = {}
            for _, block in ipairs(type(message.content) == 'table' and message.content or {}) do
                if block.type == 'text' and type(block.text) == 'string' and block.text:sub(1, 17) ~= '<system-reminder>' then
                    parts[#parts + 1] = block.text
                end
            end
            if #parts > 0 then return table.concat(parts, '\n') end
        end
    end
    return ''
end

function M.prepare(system, cwd, query, cfg)
    cfg = cfg or {}
    local window = tokens.get_effective_context_window_size(cfg.model, cfg.context_window)
    local ok, context = pcall(M.retrieve, cwd, query, { max_bytes = math.floor(window * 0.08) })
    -- Memory retrieval is optional; missing/unreadable notes must not fail a task.
    if not ok or not context then return system end
    return (system or '') .. '\n\n' .. context
end

return M

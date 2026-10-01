-- xagent/tools/web_fetch.lua — fetch a URL and return its content as Markdown.
-- Uses the shared async HTTP/HTTPS client (follows redirects, gunzips); HTML is
-- converted by html_md, which also maps headings and anchors so the model can
-- jump to `url#anchor` or page through with `offset` instead of getting the
-- first 16KB of a large manual. MUST run inside the agent coroutine (await).
-- The `prompt` is advisory — the main model reads the returned text.

local async = dofile('scripts/core/share/xasync.lua')
local text = dofile('scripts/core/share/xtext.lua')
local httpc = dofile('scripts/core/share/xhttp_client.lua')
local html_md = require('xagent.tools.html_md')

-- The page text is resent on every later turn; 16KB keeps the main content of
-- most docs pages without carrying a whole site's worth of navigation.
local MAX_OUTPUT = 16000
-- The table of contents rides along on a first read of a page that does not
-- fit, so the model can pick the section to read next.
local MAX_TOC = 4000
local UA = 'Mozilla/5.0 (compatible; xagent/0.1)'

local M = {}

-- Reading a big page takes several calls (#anchor, then offset=…), and a slow
-- host can take a minute per download (lua.org's 364KB manual from here), so
-- keep the last few successful responses briefly.
local CACHE_SIZE, CACHE_TTL = 4, 300
local cache = {}

local function cached_get(url)
    local now = os.time()
    for i, e in ipairs(cache) do
        if e.url == url then
            table.remove(cache, i)
            if now - e.at <= CACHE_TTL then table.insert(cache, 1, e); return nil, e.resp end
            break
        end
    end
    local err, resp = async.await(function(resolve)
        httpc.get(url, { timeout_ms = 20000, headers = { ['User-Agent'] = UA } },
            function(e, r) resolve(e, r) end)
    end)
    if not err and (tonumber(resp.status) or 0) < 400 then
        table.insert(cache, 1, { url = url, at = now, resp = resp })
        cache[CACHE_SIZE + 1] = nil
    end
    return err, resp
end

-- Build the tool output from a fetched body. Split from `call` so the paging,
-- anchor and TOC logic is testable without the network.
--   opts = { url, fragment, offset, status, content_type }
function M.render(body, opts)
    body = body or ''
    local ctype = (opts.content_type or ''):lower()
    local is_html = ctype:find('html', 1, true)
        or (ctype == '' and body:sub(1, 512):lower():find('<html', 1, true))
    local doc
    if is_html then
        body = html_md.to_utf8(body, html_md.charset(body, ctype))
        doc = html_md.convert(body, opts.url)
    else
        local md = text.valid_utf8(body)
        doc = { markdown = md, anchors = {}, headings = html_md.markdown_headings(md) }
    end
    local md = doc.markdown
    local notes = {}

    local start = 0
    local auto_start = 0      -- where a plain first read starts (<main> / <h1>)
    local explicit = opts.offset ~= nil
    if explicit then
        start = math.max(0, math.floor(tonumber(opts.offset) or 0))
    elseif opts.fragment and opts.fragment ~= '' then
        local off = html_md.find_anchor(doc, opts.fragment)
        if not off then
            -- Markdown/plain text has no ids; fall back to a heading whose
            -- GitHub-style slug matches.
            local want = opts.fragment:lower()
            for _, h in ipairs(doc.headings) do
                local slug = h.text:lower():gsub('[^%w%s_-]', ''):gsub('%s', '-')
                if slug == want then off = h.offset; break end
            end
        end
        if off then
            start = off
            notes[#notes + 1] = 'from #' .. opts.fragment
        else
            notes[#notes + 1] = 'anchor #' .. opts.fragment .. ' not found; showing the page start'
        end
    elseif doc.main_offset and doc.main_offset > 0 then
        -- Skip the site header before <main>; offset=0 still reads it.
        start = doc.main_offset
        auto_start = start
        notes[#notes + 1] = string.format('starting at <main>; offset=0 for the %d chars before it',
            doc.main_offset)
    elseif is_html and not doc.main_offset then
        -- No <main> (cplusplus.com): a lone <h1> still marks where the
        -- article starts, after the sidebar menus.
        local h1
        for _, h in ipairs(doc.headings) do
            if h.level == 1 then
                if h1 then h1 = nil; break end
                h1 = h
            end
        end
        if h1 and h1.offset > 0 then
            start = h1.offset
            auto_start = start
            notes[#notes + 1] = string.format('starting at the page <h1>; offset=0 for the %d chars before it',
                h1.offset)
        end
    end

    local chunk, next_off, s = html_md.window(md, start, MAX_OUTPUT)
    local first_read = not explicit and (s == 0 or s == auto_start)
    local lines = {}
    lines[#lines + 1] = string.format('Fetched %s (HTTP %s, %d bytes)%s', opts.url,
        tostring(opts.status), #body, doc.title and (' — ' .. doc.title) or '')
    if next_off or s > 0 then
        notes[#notes + 1] = string.format('chars %d-%d of %d', s, s + #chunk, #md)
    end
    if #notes > 0 then lines[#lines + 1] = '[' .. table.concat(notes, '; ') .. ']' end
    lines[#lines + 1] = ''
    -- The window usually ends on a line break; the notice adds its own.
    lines[#lines + 1] = (chunk:gsub('\n+$', ''))
    if next_off then
        lines[#lines + 1] = ''
        lines[#lines + 1] = string.format('...[truncated: %d more chars; call WebFetch with offset=%d to continue]',
            #md - next_off, next_off)
    end
    -- On a first read that does not fit, or a missed anchor, list the sections
    -- with their offsets so the next call can go straight to one.
    if (next_off and first_read) or (opts.fragment and opts.fragment ~= '' and start == 0 and not explicit) then
        local toc = html_md.toc(doc.headings, MAX_TOC)
        if toc then
            lines[#lines + 1] = ''
            lines[#lines + 1] = 'Page sections (pass offset=N, or use url#anchor):'
            lines[#lines + 1] = toc
        end
    end
    return text.valid_utf8(table.concat(lines, '\n'))
end

M.tool = {
    name = 'WebFetch',
    description =
        'Fetch a URL over HTTP(S) and return its content as Markdown (headings, ' ..
        'code blocks, lists, tables kept). Output is capped at 16KB: a `#anchor` ' ..
        'in the url starts at that element (e.g. ' ..
        'https://www.lua.org/manual/5.4/manual.html#pdf-string.format); a long ' ..
        'page ends with the next `offset` to continue and, on the first read, a ' ..
        'table of sections with their offsets. `prompt` describes what you are ' ..
        'looking for.',
    input_schema = {
        type = 'object',
        properties = {
            url = { type = 'string', description = 'The URL to fetch (http or https); may end in #anchor' },
            prompt = { type = 'string', description = 'What to look for in the page' },
            offset = { type = 'integer', description =
                'Character offset into the converted page to start reading at (from a ' ..
                'previous truncated result or its section list). Overrides #anchor.' },
        },
        required = { 'url' },
    },
    is_read_only = function() return true end,

    call = function(input)
        local url = input.url
        if type(url) ~= 'string' or not url:match('^https?://') then
            return { content = 'Error: a http(s) url is required', is_error = true }
        end
        -- The fragment never goes over the wire; it picks the starting anchor.
        local fetch_url, fragment = url:match('^([^#]*)#(.*)$')
        fetch_url = fetch_url or url

        local err, resp = cached_get(fetch_url)
        if err then
            return { content = 'Error fetching ' .. url .. ': ' .. tostring(err), is_error = true }
        end
        -- HTTP redirects are followed by the client; meta-refresh stubs are
        -- not, so follow a few here, keeping the #fragment for the target.
        for _ = 1, 3 do
            local ctype = (resp.headers and resp.headers['content-type'] or ''):lower()
            local target = ctype:find('html', 1, true) and html_md.meta_refresh(resp.body or '', fetch_url)
            if not target or not target:match('^https?://') or target == fetch_url then break end
            local e2, r2 = cached_get(target)
            if e2 then break end
            fetch_url, resp = target, r2
        end

        return { content = M.render(resp.body or '', {
            url = fetch_url, fragment = fragment, offset = input.offset,
            status = resp.status,
            content_type = resp.headers and resp.headers['content-type'] or '',
        }), is_error = (tonumber(resp.status) or 0) >= 400 }
    end,
}

-- Exposed for the offline spec; the registry only reads the tool fields.
M.tool.render = M.render

return M.tool

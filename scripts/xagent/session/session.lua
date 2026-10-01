-- xagent/session/session.lua — a multi-turn conversation with persistence.
--
-- Holds the message history across user turns so the agent remembers earlier
-- exchanges (the headless `main.lua` is one-shot; this is what an interactive
-- driver — and later the GUI — sits on top of). Persists to JSON under
-- ~/.xagent/sessions/<id>.json and reloads for resume.

local loop = require('xagent.core.loop')
local tokens = require('xagent.context.tokens')
local fs = dofile('scripts/core/share/xfs.lua')
local xutils = require('xutils')

-- Compaction replaces the head of the history with a continuation-summary user
-- message; it must never become the session title.
local CONTINUE_PREFIX = 'This session is being continued'

-- Tool results also have role=user; only actual user text or attachments start
-- a durable conversation. Keep both archives and legacy/compacted contexts.
local function user_input(messages)
    for _, message in ipairs(messages or {}) do
        if message.role == 'user' then
            if type(message.content) == 'string' and message.content:match('%S') then return true end
            if type(message.content) == 'table' then
                for _, block in ipairs(message.content) do
                    if block.type == 'image' or (block.type == 'text' and type(block.text) == 'string' and block.text:match('%S')) then return true end
                end
            end
        end
    end
    return false
end
local function has_user_input(value)
    return user_input(value.transcript) or user_input(value.messages)
end

local function first_user_text(messages)
    local saw_continuation = false
    for _, m in ipairs(messages or {}) do
        if m.role == 'user' then
            if type(m.content) == 'string' and m.content ~= '' then
                if m.content:sub(1, #CONTINUE_PREFIX) ~= CONTINUE_PREFIX then
                    return m.content
                end
                saw_continuation = true
            elseif type(m.content) == 'table' then
                -- image+text block message: title from the real text part (skip
                -- the resume hint that replaces stripped images on re-save)
                for _, b in ipairs(m.content) do
                    if b.type == 'text' and (b.text or '') ~= ''
                       and b.text:sub(1, #'[图片') ~= '[图片'
                       and b.text:sub(1, 17) ~= '<system-reminder>' then
                        return b.text
                    end
                end
                for _, b in ipairs(m.content) do
                    if b.type == 'image' or (b.type == 'text' and b.text:sub(1, #'[图片') == '[图片') then
                        return '[图片]'
                    end
                end
            end
        end
    end
    return saw_continuation and '（已压缩的会话）' or '(no prompt)'
end

math.randomseed(os.time())

local M = {}
local Session = {}
Session.__index = Session
M.Session = Session

-- UI history is separate from the context mutated by compaction. Never share
-- message/block tables, and do not duplicate image payloads in the transcript.
local function archive_message(message)
    local copy = { role = message.role, content = message.content }
    if type(message.content) == 'table' then
        copy.content = {}
        for _, block in ipairs(message.content) do
            copy.content[#copy.content + 1] = block.type == 'image'
                and { type = 'text', text = '[图片附件]' }
                or assert(xutils.json_unpack(assert(xutils.json_pack(block))))
        end
    end
    return copy
end

local function gen_id()
    return string.format('%x%04x', os.time(), math.random(0, 0xffff))
end

function M.dir()
    return (fs.home():gsub('[/\\]+$', '')) .. '/.xagent/sessions'
end

-- opts: { cfg, cwd, tools, system, max_tokens, id? }
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        id = opts.id or gen_id(),
        cfg = opts.cfg,
        cwd = opts.cwd or '.',
        tools = opts.tools,
        system = opts.system,
        max_tokens = opts.max_tokens,
        title = opts.title,        -- custom display name (nil → derived from 1st msg)
        messages = {},
        transcript = {},
        usage = { input_tokens = 0, output_tokens = 0 },
        created_at = os.time(),
    }, Session)
end

-- content: a plain string, or an array of content blocks (e.g. image + text).
function Session:add_user(content)
    self.messages[#self.messages + 1] = { role = 'user', content = content }
    self.transcript[#self.transcript + 1] = archive_message(self.messages[#self.messages])
    return self
end

function Session:has_user_input() return has_user_input(self) end

local function clone(value)
    return assert(xutils.json_unpack(assert(xutils.json_pack(value))))
end

function Session:turn_count()
    local count = 0
    for _, message in ipairs(self.transcript) do
        if user_input({ message }) then count = count + 1 end
    end
    return count
end

-- Return an independent candidate; callers persist it before changing active state.
local function turn_bounds(self, turn)
    assert(type(turn) == 'number' and turn >= 1 and turn % 1 == 0, 'Invalid turn')
    local count, first, last = 0, nil, #self.transcript
    for i, message in ipairs(self.transcript) do
        if user_input({ message }) then
            count = count + 1
            if count == turn then first = i end
            if count == turn + 1 then last = i - 1; break end
        end
    end
    assert(first, '对话轮次已变化，请重新选择')
    return first, last
end

function Session:fork(turn)
    local child = M.new({cfg=self.cfg, cwd=self.cwd, tools=self.tools, system=self.system, max_tokens=self.max_tokens})
    while child.id == self.id or fs.read_file(M.dir() .. '/' .. child.id .. '.json') do child.id = gen_id() end
    child.messages, child.transcript = clone(self.messages), clone(self.transcript)
    if turn then
        local _, last = turn_bounds(self, turn)
        child.transcript = {}
        for i = 1, last do child.transcript[i] = clone(self.transcript[i]) end
        child.messages = clone(child.transcript)
    end
    child.skill_id = self.skill_id
    child.parent_id = self.id
    local base = self.title or first_user_text(self.transcript)
    if self.parent_id then
        -- Forking a fork stays in the same numbered name family.
        while true do
            local stripped, n = base:gsub(' · 分叉%s*%d*$', '')
            base = stripped
            if n == 0 then break end
        end
    end
    local prefix, highest = base .. ' · 分叉', 0
    local function include(title)
        if title == prefix then highest = math.max(highest, 1)
        elseif title:sub(1, #prefix) == prefix then
            local number = tonumber(title:sub(#prefix + 1):match('^ (%d+)$'))
            if number then highest = math.max(highest, number) end
        end
    end
    include(self.title or '')
    for _, item in ipairs(M.list()) do include(item.title or '') end
    child.title = prefix .. ' ' .. (highest + 1)
    return child
end

function Session:without_turn(turn)
    local first, last = turn_bounds(self, turn)
    local candidate = M.new({id=self.id, cfg=self.cfg, cwd=self.cwd, tools=self.tools, system=self.system, max_tokens=self.max_tokens})
    candidate.created_at, candidate.title = self.created_at, self.title
    candidate.skill_id, candidate.parent_id = self.skill_id, self.parent_id
    for i, message in ipairs(self.transcript) do
        if i < first or i > last then candidate.transcript[#candidate.transcript+1] = clone(message) end
    end
    -- Rebuild from the durable transcript so a compacted summary cannot retain
    -- deleted turns. Tool calls and their results remain in the same retained turn.
    candidate.messages = clone(candidate.transcript)
    if turn == 1 then candidate.title = nil; candidate:ensure_title() end
    return candidate
end

function Session:without_last_turn() return self:without_turn(self:turn_count()) end

-- Capture a durable title from the first real user message BEFORE the history
-- can be reshaped: compaction replaces the head with a summary, after which a
-- display-time derivation has nothing real left to show.
function Session:ensure_title()
    if self.title and self.title ~= '' then return end
    local t = first_user_text(self.messages)
    if t and t ~= '(no prompt)' and t ~= '（已压缩的会话）' then self.title = t end
end

local function history_has_text(messages, text)
    for _, m in ipairs(messages) do
        if m.role == 'user' and type(m.content) == 'table' then
            for _, b in ipairs(m.content) do
                if b.type == 'text' and b.text == text then return true end
            end
        end
    end
    return false
end

-- The skills listing rides in the conversation, not the system prompt: the
-- system prompt heads every request, so changing it (a conditional skill
-- activated by a file touch) re-bills the whole history at uncached price.
-- Appended as a trailing text block of the turn's user message, only when the
-- history does not already carry this exact listing — the first turn, after
-- the listing changed, or after compaction folded it away. Only appends, so
-- the cached prefix is untouched.
function Session:inject_skills_listing()
    local rem = require('xagent.skills').reminder()
    if rem == '' or history_has_text(self.messages, rem) then return end
    local last = self.messages[#self.messages]
    if not last or last.role ~= 'user' then return end
    local c = last.content
    if type(c) == 'string' then
        c = (c ~= '') and { { type = 'text', text = c } } or {}
    elseif type(c) ~= 'table' then
        c = {}
    end
    c[#c + 1] = { type = 'text', text = rem }
    last.content = c
end

-- Run one assistant turn over the accumulated history. loop.run appends the
-- assistant message (and any tool_result turns) to self.messages in place, and
-- may compact the history when it nears the context window. The usage anchor is
-- threaded across turns so the token estimate stays cheap and accurate.
function Session:run(on_event)
    self:ensure_title()
    self:inject_skills_listing()

    local res = loop.run({
        cfg = self.cfg,
        messages = self.messages,
        system = self.system,
        tools = self.tools,
        ctx = { cwd = self.cwd, session_id = self.id, confirm = self.confirm, tool_guard = self.tool_guard },
        max_tokens = self.max_tokens,
        on_event = function(event)
            if event.type == 'assistant' then
                self.transcript[#self.transcript + 1] = archive_message(event.message)
            elseif event.type == 'tool_result' then
                self.transcript[#self.transcript + 1] = archive_message({ role = 'user', content = {
                    { type = 'tool_result', tool_use_id = event.id, content = event.result.content, is_error = event.result.is_error }
                } })
            end
            if on_event then on_event(event) end
        end,
        last_usage = self.last_usage,
        usage_anchor_index = self.usage_anchor_index,
        should_stop = function() return self.cancelled end,
    })
    tokens.add_usage(self.usage, res.usage)
    self.last_usage = res.last_usage
    self.usage_anchor_index = res.usage_anchor_index
    return res
end

-- Force a full context compaction now (the /compact command). Runs inside a
-- coroutine (it calls the model). Returns the compaction result table.
function Session:compact(focus, on_event)
    self:ensure_title()
    local compaction = require('xagent.context.compaction')
    local res = compaction.auto_compact_if_needed({
        -- Same system + tools as a turn, so the summary reuses the cached prefix.
        messages = self.messages, cfg = self.cfg, system = self.system, tools = self.tools,
        usage = self.last_usage, usage_anchor_index = self.usage_anchor_index,
        focus = focus, force = true,
    })
    if res.did_compact or res.did_micro then
        compaction.replace_in_place(self.messages, res.messages)
        self.last_usage, self.usage_anchor_index = nil, nil   -- history reshaped
    end
    if on_event then
        on_event({ type = 'compact', did_compact = res.did_compact, did_micro = res.did_micro,
                   summary = res.summary, kept_tail = res.kept_tail, error = res.error })
    end
    return res
end

function Session:to_table()
    return {
        version = 2,
        id = self.id,
        cwd = self.cwd,
        model = self.cfg and self.cfg.model,
        created_at = self.created_at,
        title = self.title,
        usage = self.usage,
        messages = self.messages,
        transcript = self.transcript,
        skill_id = self.skill_id,
        parent_id = self.parent_id,
    }
end

-- Persist to <dir>/<id>.json (dir defaults to ~/.xagent/sessions). Returns path.
function Session:save(dir)
    if not self:has_user_input() then return nil, 'empty session' end
    dir = dir or M.dir()
    fs.mkdirp(dir)
    local path = dir .. '/' .. self.id .. '.json'
    local encoded, encode_err = xutils.json_pack(self:to_table())
    if not encoded then return nil, encode_err or 'session encoding failed' end
    -- Write a sibling temp file and replace, so an interrupted write leaves the
    -- last completed session intact instead of a truncated file.
    local temporary = xutils.temp_file and xutils.replace_file and xutils.temp_file(dir)
    if not temporary then
        local ok, err = fs.write_file(path, encoded)
        if not ok then return nil, err end
        return path
    end
    local ok, err = fs.write_file(temporary, encoded)
    if ok then ok, err = xutils.replace_file(temporary, path) end
    if not ok then os.remove(temporary); return nil, err end
    return path
end

-- Resumed sessions don't re-send historical images (heavy base64 on every
-- request, for pictures the model already saw). Each image block is replaced
-- by this text hint so the conversation stays coherent for the model.
M.IMAGE_RESUME_HINT = '[图片已省略：原会话中用户在此粘贴过一张图片，恢复会话后不再随请求发送]'

local function strip_image_blocks(messages)
    for _, m in ipairs(messages or {}) do
        if type(m.content) == 'table' then
            for i, b in ipairs(m.content) do
                if b.type == 'image' then
                    m.content[i] = { type = 'text', text = M.IMAGE_RESUME_HINT }
                end
            end
        end
    end
end

-- Rehydrate a session from a saved file. cfg/tools/system are runtime-only and
-- must be supplied again (they're not persisted by reference).
function M.load(path, opts)
    opts = opts or {}
    local data = fs.read_file(path)
    if not data then return nil, 'cannot read ' .. tostring(path) end
    local t = xutils.json_unpack(data)
    if type(t) ~= 'table' then return nil, 'bad session file' end
    strip_image_blocks(t.messages)
    local s = M.new({
        cfg = opts.cfg, cwd = t.cwd, tools = opts.tools,
        system = opts.system, max_tokens = opts.max_tokens, id = t.id,
    })
    s.messages = t.messages or {}
    s.transcript = {}
    for _, message in ipairs(t.transcript or s.messages) do s.transcript[#s.transcript + 1] = archive_message(message) end
    s.usage = t.usage or s.usage
    s.created_at = t.created_at or s.created_at
    s.title = t.title
    s.skill_id = type(t.skill_id) == 'string' and t.skill_id or nil
    s.parent_id = t.parent_id
    return s
end

-- List ALL saved sessions, most-recent first. Returns { {id, path, created_at,
-- title, n}, ... }. Ids start with a hex timestamp, so a descending id sort is
-- recency order. (Reads every file once — callers should list on open, not per
-- frame.) `title` prefers a stored custom name, else the first user message.
function M.list(dir)
    dir = dir or M.dir()
    local entries = xutils.scan_dir(dir)
    if not entries then return {} end

    local files = {}
    for _, e in ipairs(entries) do
        local id = (e.rel or ''):match('([^/\\]+)%.json$')
        if id then files[#files + 1] = { id = id, path = e.path } end
    end
    table.sort(files, function(a, b) return a.id > b.id end)

    local items = {}
    for _, f in ipairs(files) do
        local data = fs.read_file(f.path)
        local t = data and xutils.json_unpack(data)
        if type(t) == 'table' and has_user_input(t) then
            local title = (type(t.title) == 'string' and t.title ~= '') and t.title
                or first_user_text(t.transcript or t.messages)
            items[#items + 1] = {
                id = t.id or f.id,
                path = f.path,
                created_at = t.created_at or 0,
                title = title,
                cwd = t.cwd,
                n = #(t.transcript or t.messages or {}),
            }
        end
    end
    return items
end

-- Rename a saved session (writes a custom `title` into its file).
function M.rename(path, new_title)
    local data = fs.read_file(path)
    local t = data and xutils.json_unpack(data)
    if type(t) ~= 'table' then return nil, 'bad session file' end
    t.title = tostring(new_title or '')
    return fs.write_file(path, xutils.json_pack(t))
end

-- Delete a saved session file.
function M.delete(path)
    return os.remove(path)
end

return M

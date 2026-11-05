-- Pure, bounded lexical highlighting shared by Markdown and tool listings.
-- Offsets are UTF-8 byte offsets, as used by the transcript's string slices.
local M = {}
local function words(s)
    local out = {}
    for w in s:gmatch('%S+') do out[w] = true end
    return out
end
local languages, aliases = {}, {}
local function language(name, extensions, keywords, opts)
    local lang = opts or {}
    lang.name, lang.keywords = name, words(keywords or '')
    languages[name:lower()] = lang
    for ext in extensions:gmatch('%S+') do aliases[ext] = lang end
    return lang
end
language('Lua', 'lua', 'and break do else elseif end for function goto if in local not or repeat return then until while', { line = '--', long = true })
local ck = 'auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while '
language('C', 'c h', ck, { line = '//', block = true, preprocessor = true })
language('C++', 'cc cpp cxx c++ hpp hh hxx h++ ino', ck .. 'alignas alignof catch class concept constexpr consteval constinit co_await co_return co_yield decltype delete explicit export final friend mutable namespace new noexcept operator override private protected public requires static_assert template this thread_local throw try typeid typename using virtual', { line = '//', block = true, preprocessor = true })
language('Python', 'py pyw pyi python3 py3', 'and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield', { line = '#', triple = true, annotation = true })
language('Java', 'java', 'abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package permits private protected public record return sealed static strictfp super switch synchronized this throw throws transient try var void volatile while yield', { line = '//', block = true, triple = true, annotation = true })
language('Kotlin', 'kt kts', 'abstract actual annotation as break by catch class companion const constructor continue crossinline data do else enum expect external final finally for fun get if import in infix init inline inner interface internal is lateinit noinline object open operator out override package private protected public reified return sealed set super suspend tailrec this throw try typealias val value var vararg when where while', { line = '//', block = true, triple = true, raw = true, annotation = true })
language('Go', 'go golang', 'break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var', { line = '//', block = true, backtick = true, raw = true })
local js = 'async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield '
language('JavaScript', 'js mjs cjs jsx node', js, { line = '//', block = true, backtick = true, annotation = true })
language('TypeScript', 'ts tsx mts cts ets arkts', js .. 'abstract as asserts declare enum implements infer interface is keyof namespace override private protected public readonly satisfies type unique', { line = '//', block = true, backtick = true, annotation = true })
language('HTML', 'html htm xhtml', '', { markup = true })
language('XML', 'xml svg xsl plist', '', { markup = true })
language('Markdown', 'md markdown mdx', '', { markdown = true })
language('Shell', 'sh bash zsh ksh bashrc zshrc profile bash_profile shellscript', 'if then else elif fi for while until do done case esac in function select time coproc', { line = '#', shell = true, backtick = true })
language('Batch', 'bat cmd dosbatch batchfile', 'if else for in do goto call exit not exist defined errorlevel equ neq lss leq gtr geq setlocal endlocal enabledelayedexpansion disabledelayedexpansion', { batch = true })
language('Makefile', 'mk mak make', 'include define endef ifdef ifndef ifeq ifneq else endif override export unexport private vpath', { line = '#', shell = true })
language('JSON', 'json jsonc', '', { line = '//', block = true })
local constants = words('nil true false null nullptr NULL None True False undefined NaN Infinity iota')
local types = words('void char short int long float double signed unsigned bool size_t string boolean number any unknown never self cls print pairs ipairs require assert tostring tonumber table math os io utf8 String Object Array List Map Set Promise console Int Boolean Unit echo printf cd pwd export local set copy del move mkdir')

function M.language(path)
    local name = path:gsub(' %(outline%)$', ''):match('([^/\\]+)$') or path
    name = name:lower()
    if name == 'makefile' or name == 'gnumakefile' then return languages.makefile end
    return aliases[name:match('%.([^%.]+)$') or '']
end

function M.fence(info)
    local tag = (info:match('^%s*(%S+)') or ''):lower():gsub('^{%.?', ''):gsub('}$', '')
    return languages[tag] or aliases[tag]
end

-- Both palettes keep comments and strings readable on the active code surface.
local dark = { keyword = {198,155,255,255}, type = {111,202,222,255}, constant = {237,173,105,255},
    string = {158,211,151,255}, number = {237,173,105,255}, comment = {147,157,167,255},
    preprocessor = {218,162,226,255}, ['function'] = {235,211,143,255}, tag = {111,177,255,255}, attribute = {111,202,222,255} }
local light = { keyword = {126,55,163,255}, type = {0,108,135,255}, constant = {160,79,14,255},
    string = {42,116,61,255}, number = {160,79,14,255}, comment = {100,111,117,255},
    preprocessor = {145,61,135,255}, ['function'] = {134,94,12,255}, tag = {35,91,171,255}, attribute = {0,108,135,255} }
function M.color(kind, bg)
    local palette = (bg[1] * .299 + bg[2] * .587 + bg[3] * .114 > 128) and light or dark
    return palette[kind]
end

function M.tokenize(s, lang, depth)
    depth = depth or 0
    if not lang or #s > 200000 or depth >= 8 then return {} end
    if lang.markdown then
        local out, offset, fence, embedded, chunk, chunk_start = {}, 0, nil, nil, {}, 1
        local function token(first, last, kind)
            out[#out + 1] = { first = first, last = last, kind = kind }
        end
        local function flush()
            for _, t in ipairs(M.tokenize(table.concat(chunk, '\n'), embedded, depth + 1)) do
                token(t.first + chunk_start - 1, t.last + chunk_start - 1, t.kind)
            end
            chunk = {}
        end
        for line in (s .. '\n'):gmatch('(.-)\n') do
            local mark, info = line:match('^%s*(```+)%s*(.*)$')
            if not mark then mark, info = line:match('^%s*(~~~+)%s*(.*)$') end
            if not fence and mark then
                fence, embedded, chunk_start = mark, M.fence(info), offset + #line + 2
                token(offset + 1, offset + #line, 'comment')
            elseif fence then
                if mark and mark:sub(1,1) == fence:sub(1,1) and #mark >= #fence and info == '' then
                    flush(); fence = nil
                    token(offset + 1, offset + #line, 'comment')
                else chunk[#chunk + 1] = line end
            elseif line:match('^%s*[#>%-*]') then token(offset + 1, offset + #line, 'keyword')
            else
                local at = 1
                while at <= #line do
                    local a, b = line:find('`[^`]*`', at)
                    if not a then break end
                    token(offset + a, offset + b, 'string'); at = b + 1
                end
            end
            offset = offset + #line + 1
        end
        flush()
        return out
    end
    local out, i, n = {}, 1, #s
    local function emit(last, kind)
        out[#out + 1] = { first = i, last = last, kind = kind }
        i = last + 1
    end
    local function starts(value) return s:sub(i, i + #value - 1) == value end
    local function through(close, from)
        local a = s:find(close, from, true)
        return a and a + #close - 1 or n
    end
    local in_tag, blank, script = false, true, false
    local lower = lang.name == 'HTML' and s:lower() or nil
    while i <= n do
        local c, rest = s:sub(i, i), s:sub(i, math.min(n, i + 256))
        local line_start = i == 1 or s:sub(i - 1, i - 1) == '\n'
        local eq = lang.long and c == '[' and s:match('^%[(=*)%[', i)
        local ceq = lang.long and c == '-' and s:match('^%-%-%[(=*)%[', i)
        if ceq then emit(through(']' .. ceq .. ']', i + 4 + #ceq), 'comment')
        elseif eq then emit(through(']' .. eq .. ']', i + 2 + #eq), 'string')
        elseif lang.markup and starts('<!--') then emit(through('-->', i + 4), 'comment')
        elseif lang.block and starts('/*') then emit(through('*/', i + 2), 'comment')
        elseif lang.line and starts(lang.line) then emit((s:find('\n', i, true) or n + 1) - 1, 'comment')
        elseif lang.batch and line_start and (rest:lower():match('^%s*@?rem%s') or rest:match('^%s*::')) then
            emit((s:find('\n', i, true) or n + 1) - 1, 'comment')
        elseif lang.preprocessor and c == '#' and blank then
            emit(i + #(rest:match('^#%s*[%w_]+') or '#') - 1, 'preprocessor')
        elseif lang.markup and c == '<' then
            in_tag = true
            script = lower and lower:match('^<script[%s>]', i) ~= nil
            emit(i + #(rest:match('^</?[%w_:%.%-]+') or '<') - 1, 'tag')
        elseif lang.markup and c == '>' then
            in_tag = false; emit(i, 'tag')
            if script then
                local close = lower:find('</script', i, true) or n + 1
                local first = i
                for _, t in ipairs(M.tokenize(s:sub(first, close - 1), languages.javascript, depth + 1)) do
                    out[#out + 1] = { first = first + t.first - 1, last = first + t.last - 1, kind = t.kind }
                end
                i, script = close, false
            end
        elseif c == '"' or c == "'" or (lang.backtick and c == '`') then
            local triple = lang.triple and s:sub(i, i + 2) == c:rep(3)
            local close, j = triple and c:rep(3) or c, i + (triple and 3 or 1)
            local raw = lang.raw and (triple or c == '`')
            while j <= n do
                if s:sub(j, j + #close - 1) == close then j = j + #close; break end
                if not triple and c ~= '`' and s:sub(j, j) == '\n' then break end
                if not raw and s:sub(j, j) == '\\' then j = j + 2 else j = j + 1 end
            end
            emit(math.min(n, j - 1), 'string')
        elseif lang.shell and c == '$' then
            local var = rest:match('^%$%b{}') or rest:match('^%$%b()') or rest:match('^%$[%w_?@#*!%-]+') or c
            emit(i + #var - 1, 'constant')
        elseif lang.batch and (c == '%' or c == '!') then
            local var = rest:match('^%%[^%%\n]+%%') or rest:match('^![^!\n]+!') or rest:match('^%%[%w*]') or c
            emit(i + #var - 1, 'constant')
        elseif lang.markdown and line_start and rest:match('^%s*[#>%-*]') then
            emit((s:find('\n', i, true) or n + 1) - 1, 'keyword')
        elseif c:match('%d') and not s:sub(i - 1, i - 1):match('[%w_]') then
            local num = rest:match('^0[xX][%da-fA-F_]+') or rest:match('^%d[%d_]*%.?[%d_]*[eE][%+%-]?%d+') or rest:match('^%d[%d_]*%.?[%d_]*')
            emit(i + #num - 1, 'number')
        elseif c:match('[%a_$]') then
            local w = s:match('^[%w_$]+', i)
            local key = lang.batch and w:lower() or w
            local kind = lang.keywords[key] and 'keyword' or constants[key] and 'constant' or types[key] and 'type'
            if lang.markup and in_tag then kind = 'attribute' end
            if not kind and s:match('^%s*%(', i + #w) then kind = 'function' end
            if kind then emit(i + #w - 1, kind) else i = i + #w end
        elseif lang.annotation and c == '@' then
            emit(i + #(rest:match('^@[%w_%.]+') or '@') - 1, 'preprocessor')
        else i = i + 1 end
        if c == '\n' then blank = true elseif c:match('%S') then blank = false end
    end
    return out
end

return M

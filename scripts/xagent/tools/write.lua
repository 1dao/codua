-- xagent/tools/write.lua — the Write tool. Creates or overwrites a file.

local path = dofile('scripts/core/share/xpath.lua')
local fs = dofile('scripts/core/share/xfs.lua')
local xutils = require('xutils')

return {
    name = 'Write',
    description =
        'Write content to a file, creating it or overwriting it entirely. The ' ..
        'parent directories are created automatically. Prefer Edit for changing part of an ' ..
        'existing file.',
    input_schema = {
        type = 'object',
        properties = {
            file_path = { type = 'string', description = 'Absolute or relative path to write' },
            content = { type = 'string', description = 'Full file content' },
        },
        required = { 'file_path', 'content' },
    },
    is_read_only = function() return false end,

    call = function(input, ctx)
        local fp = input.file_path
        if type(fp) ~= 'string' or fp == '' then
            return { content = 'Error: file_path is required', is_error = true }
        end
        if type(input.content) ~= 'string' then
            return { content = 'Error: content is required', is_error = true }
        end
        local resolved = path.resolve(fp, ctx and ctx.cwd)
        local ok, err = xutils.mkdir_p(path.dirname(resolved))
        if ok then ok, err = fs.write_file(resolved, input.content) end
        if not ok then return { content = 'Error: cannot write ' .. resolved .. ': ' .. tostring(err), is_error = true } end
        return { content = string.format('Wrote %s (%d bytes)', resolved, #input.content) }
    end,
}

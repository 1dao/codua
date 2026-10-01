-- Filesystem tools use xutils and Lua io/os, never shell command strings.
local utils = require('xutils')
local paths = dofile('scripts/core/share/xpath.lua')
local M = {}

local function normalize(path)
    if paths.is_windows then path = path:gsub('\\', '/') end
    local parts = {}
    for part in path:gmatch('[^/]+') do
        assert(part ~= '..', 'Parent traversal is not allowed')
        if part ~= '.' then parts[#parts + 1] = part end
    end
    return (path:sub(1, 1) == '/' and '/' or '') .. table.concat(parts, '/')
end
local function checked(path, ctx, mutation)
    assert(type(path) == 'string' and path ~= '' and not path:find('\0', 1, true), 'A valid path is required')
    local resolved = normalize(paths.resolve(path, ctx.cwd))
    if android_bridge then assert(android_bridge.check_path(resolved), 'Path outside workspace') end
    if mutation then assert(resolved ~= normalize(ctx.cwd), 'Cannot replace or remove the workspace root') end
    return resolved
end
local function stat(path) local info, err = utils.stat(path); assert(info, err); return info end
local function ensure_parent(path) local ok, err = utils.mkdir_p(paths.dirname(path)); assert(ok, err) end
local function success(text) return { content = text } end
local function tool(name, description, properties, required, read_only, fn)
    return { name = name, description = description,
        input_schema = { type = 'object', properties = properties, required = required },
        is_read_only = function() return read_only end,
        call = function(input, ctx)
            local ok, result = pcall(fn, input, ctx)
            if not ok then return { is_error = true, content = tostring(result) } end
            return result
        end }
end
local path_schema = { path = { type = 'string' } }
local pair_schema = { source = { type = 'string' }, destination = { type = 'string' } }

function M.tools()
    return {
        tool('FileInfo', 'Read file or directory type, size and modification time without shell commands. Missing paths return exists=false.', path_schema, { 'path' }, true, function(input, ctx)
            return success(assert(utils.json_pack(stat(checked(input.path, ctx)))))
        end),
        tool('MakeDirectory', 'Create a directory and missing parent directories using the native filesystem API. Requires approval.', path_schema, { 'path' }, false, function(input, ctx)
            local path = checked(input.path, ctx)
            local ok, err = utils.mkdir_p(path); assert(ok, err)
            return success('Directory ready: ' .. path)
        end),
        tool('CopyFile', 'Copy a regular file (up to 64 MiB) without shell commands. Creates destination parents; refuses to overwrite an existing destination. Requires approval.', pair_schema, { 'source', 'destination' }, false, function(input, ctx)
            local source, dest = checked(input.source, ctx), checked(input.destination, ctx, true)
            local info = stat(source)
            assert(info.exists and info.type == 'file', 'Source must be a regular file')
            assert(info.size <= 64 * 1024 * 1024, 'Copy limit is 64 MiB')
            assert(not stat(dest).exists, 'Destination exists; choose another path')
            ensure_parent(dest)
            local reader = assert(io.open(source, 'rb'))
            local writer, err = io.open(dest, 'wb')
            if not writer then reader:close(); error(err) end
            local ok, copy_err = pcall(function()
                local total = 0
                while true do
                    local chunk, read_err = reader:read(65536)
                    if not chunk then assert(not read_err, read_err); break end
                    total = total + #chunk; assert(total <= 64 * 1024 * 1024, 'Copy limit exceeded')
                    assert(writer:write(chunk))
                end
            end)
            reader:close()
            local closed, close_err = writer:close()
            if not ok or not closed then os.remove(dest); error(copy_err or close_err) end
            return success('Copied to ' .. dest)
        end),
        tool('MovePath', 'Move or rename a file or directory in the workspace using the native filesystem. Creates destination parents; refuses to overwrite. Requires approval.', pair_schema, { 'source', 'destination' }, false, function(input, ctx)
            local source, dest = checked(input.source, ctx, true), checked(input.destination, ctx, true)
            assert(stat(source).exists, 'Source does not exist')
            assert(not stat(dest).exists, 'Destination exists; choose another path')
            assert(dest:sub(1, #source + 1) ~= source .. '/', 'Cannot move a directory into itself')
            ensure_parent(dest)
            local ok, err = os.rename(source, dest); assert(ok, err)
            return success('Moved to ' .. dest)
        end),
        tool('DeletePath', 'Delete a file or empty directory using native APIs. Set recursive=true explicitly for a directory tree. Cannot delete the workspace root. Requires approval.',
            { path = { type = 'string' }, recursive = { type = 'boolean' } }, { 'path' }, false, function(input, ctx)
                local path = checked(input.path, ctx, true)
                local info = stat(path)
                if not info.exists then return success('Already absent: ' .. path) end
                local ok, err
                if info.type == 'directory' and input.recursive == true then ok, err = utils.rmtree(path)
                else ok, err = os.remove(path) end
                assert(ok, err)
                return success('Deleted: ' .. path)
            end),
    }
end
return M

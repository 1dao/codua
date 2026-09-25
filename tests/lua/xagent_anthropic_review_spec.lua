-- Run from the Android assets directory or the desktop repository root.
package.path = 'scripts/?.lua;' .. package.path
local f = io.open('tests/lua/spec_helper.lua', 'rb')
local root = f and '' or '../../../../'
if f then f:close() end
local spec = dofile(root .. 'tests/lua/spec_helper.lua')
local json = require('xutils')
local codec = require('xagent.llm.anthropic')
local function event(d, value) d:on_sse(value.type, json.json_pack(value)) end

spec.describe('Anthropic review regressions', function()
    spec.it('preserves OAuth user content, tool names, choice and history', function()
        for _, mode in ipairs({'claude', 'anthropic_oauth'}) do
            local history = {{role='user', content={{type='text', text='codua2a OpenCode opencode'}}}}
            local tools = {{name='mcp_Read', description='Read codua', input_schema={type='object'}}}
            local req = codec.build_request({api_key='test', auth_type=mode}, {
                messages=history, tools=tools, tool_choice={type='tool', name='mcp_Read'}, system='SYS'})
            local body = json.json_unpack(req.body)
            spec.equal(req.headers.authorization, 'Bearer test')
            spec.nil_value(req.headers['x-api-key'])
            spec.contains(body.system[1].text, 'Claude Code')
            spec.equal(body.messages[1].content[1].text, history[1].content[1].text)
            spec.equal(body.tools[1].name, 'mcp_Read')
            spec.equal(body.tools[1].description, 'Read codua')
            spec.equal(body.tool_choice.name, body.tools[1].name)
            spec.nil_value(history[1].content[1].cache_control)
        end
    end)
    spec.it('preserves initial text, signed and redacted thinking, and real mcp tool names', function()
        local result, text, tool
        local d = codec.new_decoder({on_done=function(v) result=v end,
            on_text=function(v) text=v end, on_tool_use_start=function(_, name) tool=name end})
        for i, block in ipairs({{type='text',text='initial'},
            {type='thinking',thinking='thought',signature='signed'},
            {type='redacted_thinking',data='opaque'},
            {type='tool_use',id='t',name='mcp_Read',input={path='file'}}}) do
            event(d, {type='content_block_start', index=i-1, content_block=block})
            event(d, {type='content_block_stop', index=i-1})
        end
        event(d, {type='message_stop'})
        spec.equal(text, 'initial'); spec.equal(tool, 'mcp_Read')
        spec.equal(result.message.content[2].signature, 'signed')
        spec.equal(result.message.content[3].data, 'opaque')
        spec.equal(result.message.content[4].name, tool)
        spec.equal(result.message.content[4].input.path, 'file')
    end)
    spec.it('rejects unfinished tool blocks even after a stop reason or message_stop', function()
        for _, stop in ipairs({'message_delta','message_stop'}) do
            local result, err
            local d=codec.new_decoder({on_done=function(v) result=v end,on_error=function(v) err=v end})
            event(d,{type='content_block_start',index=0,content_block={type='tool_use',id='t',name='Bash'}})
            event(d,{type='content_block_delta',index=0,delta={type='input_json_delta',partial_json='{"command":'}})
            event(d,{type=stop,delta={stop_reason='tool_use'}}); d:finish()
            spec.nil_value(result); spec.contains(err,'content blocks completed')
        end
    end)
    spec.it('accepts complete blocks when a gateway omits message_stop', function()
        local result
        local d=codec.new_decoder({on_done=function(v) result=v end})
        event(d,{type='content_block_start',index=0,content_block={type='text',text='ok'}})
        event(d,{type='content_block_stop',index=0})
        event(d,{type='message_delta',delta={stop_reason='end_turn'},usage={input_tokens=5,
            output_tokens=2,cache_read_input_tokens=20,cache_creation_input_tokens=3}})
        d:finish()
        spec.equal(result.usage.input_tokens,5); spec.equal(result.usage.cache_read_input_tokens,20)
        spec.equal(result.usage.cache_creation_input_tokens,3)
    end)
end)
return {__init=function() if spec.finish()>0 then os.exit(1) end; xthread.stop(0) end}

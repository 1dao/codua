-- Explicit interactive CLI mode only; unattended runs must never read stdin.
local question_tool = require('xagent.tools.ask_user_question')
local M = {}

function M.request(request, read, write)
    read = read or function() return io.read('*l') end
    write = write or function(s) io.write(s); io.flush() end
    local answers = {}
    for _, q in ipairs(request.questions) do
        write('\n' .. q.question .. '\n')
        for i, o in ipairs(q.options) do
            write(string.format('  %d. %s%s\n', i, o.label, o.description ~= '' and (' — ' .. o.description) or ''))
        end
        while true do
            write((#q.options > 0 and 'Choose number(s), separated by commas, or type an answer' or 'Type an answer') ..
                ' (/cancel stops; text: forces free text): ')
            local line = read()
            if not line or line == '/cancel' then return { cancelled = true } end
            local a = { selected = {}, text = '' }
            local literal = line:match('^text:(.*)$')
            local valid = true
            if not literal and #q.options > 0 and line:match('^%s*%d[%d,%s]*$') then
                for index in line:gmatch('%d+') do
                    local option = q.options[tonumber(index)]
                    if option then a.selected[#a.selected + 1] = option.label else valid = false end
                end
            else
                a.text = literal or line
            end
            answers[q.id] = a
            local checked, err = question_tool.validate_answers({ questions = { q } }, answers)
            if valid and checked then break end
            write((err or 'Invalid choice') .. '\n')
        end
    end
    return { answers = answers }
end

return M

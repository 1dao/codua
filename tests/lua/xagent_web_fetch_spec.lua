-- Unit specs for WebFetch's offline logic: html_md (HTML → markdown, anchors,
-- paging, TOC, charset) and web_fetch.render (anchor/offset selection and the
-- result layout). The HTTP fetch itself is exercised by live agent runs.
-- Run via: bin/xnet tests/lua/xagent_web_fetch_spec.lua

package.path = 'scripts/?.lua;' .. package.path

local spec = dofile('tests/lua/spec_helper.lua')
local html_md = require('xagent.tools.html_md')
local web_fetch = require('xagent.tools.web_fetch')

local function md(html, base) return html_md.convert(html, base).markdown end

spec.describe('html_md.convert', function()
    spec.it('renders headings, paragraphs and inline marks', function()
        local out = md('<h2>Title</h2><p>Some <b>bold</b> and <code>x = 1</code> text.</p>')
        spec.equal(out, '## Title\n\nSome **bold** and `x = 1` text.')
    end)

    spec.it('keeps <pre> verbatim in a fence with its language', function()
        local out = md('<pre><code class="language-lua">\nlocal t = {}\n  if a &lt; b then end\n</code></pre>')
        spec.equal(out, '```lua\nlocal t = {}\n  if a < b then end\n```')
    end)

    spec.it('renders nested and ordered lists', function()
        local out = md('<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul><ol start="3"><li>x</li><li>y</li></ol>')
        spec.equal(out, '- a\n  - b\n- c\n\n3. x\n4. y')
    end)

    spec.it('renders a table with a separator after the first row', function()
        local out = md('<table><tr><th>Opt</th><th>Meaning</th></tr><tr><td>NX</td><td><p>only if absent</p></td></tr></table>')
        spec.equal(out, '| Opt | Meaning |\n| --- | --- |\n| NX | only if absent |')
    end)

    spec.it('drops script, style and nav chrome', function()
        local out = md('<nav><a href="/x">Menu</a></nav><script>if (a<b) {}</script><style>p{}</style><p>Body</p>')
        spec.equal(out, 'Body')
    end)

    -- redis.io ships every inactive client tab as class="... hidden".
    spec.it('drops content a browser hides, keeps responsive hidden', function()
        local out = md('<div class="sig">py</div><div class="sig hidden">java</div>'
            .. '<p hidden>meta</p><p aria-hidden="true">icon</p><p style="display: none">x</p>'
            .. '<p class="hidden lg:flex">wide</p><p data-x="a hidden b">kept</p>')
        spec.equal(out, 'py\n\nwide\n\nkept')
    end)

    spec.it('drops a text-less permalink and its space from a heading', function()
        local doc = html_md.convert('<h2 id="args">  Required arguments  <a href="#args"><svg></svg></a></h2><p>x</p>')
        spec.equal(doc.markdown, '## Required arguments\n\nx')
        spec.equal(doc.headings[1].text, 'Required arguments')
    end)

    -- dev.epicgames.com cards: <a><img alt=title><p>title</p><p>desc</p></a>.
    spec.it('keeps a block-structured link card on one line without the alt', function()
        local out = md('<ul><li><a href="/x"><div><img alt="New"></div><div><p>New</p>'
            .. '<p>What changed</p></div></a></li></ul>', 'https://e.com/docs/')
        spec.equal(out, '- [New What changed](https://e.com/x)')
    end)

    spec.it('keeps <thead> and <tbody> rows in one table', function()
        local out = md('<table><thead><tr><th>A</th><th>B</th></tr></thead>'
            .. '<tbody><tr><td>1</td><td>2</td></tr></tbody></table><p>after</p>')
        spec.equal(out, '| A | B |\n| --- | --- |\n| 1 | 2 |\n\nafter')
    end)

    -- cplusplus.com: <li><h4>…</h4><ul><li><div>C++11</div><a>…</a></li>, and
    -- a <br> straight after </table>.
    spec.it('keeps list headings and badge divs on the item line', function()
        local out = md('<ul><li><h4><a href="/c/">C library:</a></h4><ul>'
            .. '<li><div class="C_Label"><div>C++11</div></div><a href="/cfenv/">cfenv</a></li>'
            .. '</ul></li></ul>', 'https://cplusplus.com/reference/')
        spec.equal(out, '- #### [C library:](https://cplusplus.com/c/)\n'
            .. '  - C++11 [cfenv](https://cplusplus.com/cfenv/)')
    end)

    spec.it('does not stack <br> breaks after a block', function()
        spec.equal(md('<table><tr><td>a</td></tr></table><br>next<br><br><br>end'),
            '| a |\n| --- |\n\nnext\n\nend')
    end)

    spec.it('omits the # prefix for a heading inside a table cell', function()
        local doc = html_md.convert('<table><tr><td><h4>Tutorial</h4> text</td></tr></table>')
        spec.equal(doc.markdown, '| Tutorial text |\n| --- |')
        spec.equal(doc.headings[1].text, 'Tutorial')
    end)

    -- learn.unity.com: "Lemon. <strong> <br/><br/>#</strong> To learn".
    spec.it('drops a mark opened right before a <br> and escapes a leading #', function()
        spec.equal(md('<p>Lemon. <strong> <br/><br/>#</strong> To learn</p>'),
            'Lemon.\n\n\\# To learn')
        spec.equal(md('<p><b>a<br>b</b></p>'), '**a\nb**')
    end)

    -- docs.python.org (Sphinx): <div role="navigation"> bars whose items hold
    -- only a <select> or an icon.
    spec.it('drops role=navigation chrome and empty list items', function()
        spec.equal(md('<div role="navigation"><ul><li>index</li></ul></div><p>Body</p>'), 'Body')
        spec.equal(md('<ul><li>a</li><li><select><option>x</option></select></li><li></li><li>b</li></ul>'),
            '- a\n- b')
        spec.equal(md('<ol><li>a</li><li><button>x</button></li><li>b</li></ol>'), '1. a\n2. b')
    end)

    spec.it('drops Sphinx permalink glyphs from headings and the section list', function()
        local doc = html_md.convert('<h2 id="if">4.1. <code>if</code> Statements'
            .. '<a class="headerlink" href="#if" title="Link">¶</a></h2><p>x <a href="#if">see</a></p>')
        spec.equal(doc.markdown, '## 4.1. `if` Statements\n\nx [see](#if)')
        spec.equal(doc.headings[1].text, '4.1. if Statements')
    end)

    spec.it('indents a code block and the text after it inside a list item', function()
        spec.equal(md('<ul><li><p>Capture with:</p><pre>case p:\n    pass</pre><p>more</p></li><li>b</li></ul>'),
            '- Capture with:\n  ```\n  case p:\n      pass\n  ```\n  more\n- b')
    end)

    spec.it('escapes literal asterisks outside code', function()
        spec.equal(md('<p>str.format(<em><span>*</span>args</em>, <em><span>**</span>kwargs</em>) '
            .. 'and <code>**rest</code></p>'),
            'str.format(*\\*args*, *\\*\\*kwargs*) and `**rest`')
    end)

    -- docs.python.org c-api: <code>getenv(<em>s</em>)</code>.
    spec.it('emits no emphasis marks inside a code span', function()
        spec.equal(md('<p>Like <code>getenv(<em>s</em>)</code> and <code>__attribute__((<em>name</em>))</code>,'
            .. ' <code><code>x</code></code> <em>y</em></p>'),
            'Like `getenv(s)` and `__attribute__((name))`, `x` *y*')
    end)

    spec.it('finds a meta-refresh redirect target', function()
        local stub = '<html><head><meta http-equiv="refresh" content="0; url=../builtins/stdtypes.html">'
            .. '</head><body>You should have been redirected.</body></html>'
        spec.equal(html_md.meta_refresh(stub, 'https://docs.python.org/3.14/library/stdtypes.html'),
            'https://docs.python.org/3.14/builtins/stdtypes.html')
        spec.nil_value(html_md.meta_refresh('<meta http-equiv="refresh" content="30">', 'https://x/'))
    end)

    spec.it('uses the alt as the text of an image-only link', function()
        spec.equal(md('<p><a href="https://e.com/"><img alt="Logo"></a></p>'), '[Logo](https://e.com/)')
    end)

    spec.it('drops empty inline marks such as icon <i> elements', function()
        spec.equal(md('<p><i class="icon"></i>Ask <b></b>here <i>now</i></p>'), 'Ask here *now*')
    end)

    spec.it('resolves links against the page url', function()
        local out = md('<p><a href="../set/">SET</a> and <a href="#nx">NX</a></p>',
            'https://redis.io/docs/latest/commands/get/')
        spec.equal(out, '[SET](https://redis.io/docs/latest/commands/set/) and [NX](#nx)')
    end)

    spec.it('decodes named and numeric entities', function()
        spec.equal(md('<p>1 &ndash; a&middot;b &#955; &#x3bb; &copy;</p>'), '1 – a·b λ λ ©')
    end)

    spec.it('records headings with their anchors and the <main> offset', function()
        local doc = html_md.convert('<header>Site</header><main><h1 id="top">Top</h1>'
            .. '<h3>3.1 &ndash; <a name="3.1">Sub</a></h3></main>')
        spec.equal(#doc.headings, 2)
        spec.equal(doc.headings[1].id, 'top')
        spec.equal(doc.headings[2].text, '3.1 – Sub')
        spec.equal(doc.headings[2].id, '3.1')
        spec.truthy(doc.main_offset and doc.main_offset > 0, 'main_offset set')
        spec.equal(doc.markdown:sub(doc.main_offset + 1, doc.main_offset + 5), '# Top')
    end)
end)

spec.describe('html_md anchors, window and toc', function()
    local doc = html_md.convert('<p>intro</p><h3><a name="pdf-string.format"><code>string.format</code></a></h3>'
        .. '<p>Returns a formatted string.</p><h2 id="Other">Other</h2>')

    spec.it('find_anchor starts at the line holding the anchor', function()
        local off = html_md.find_anchor(doc, 'pdf-string.format')
        spec.equal(doc.markdown:sub(off + 1, off + 20), '### `string.format`\n')
    end)

    spec.it('find_anchor accepts percent-encoded and case-different fragments', function()
        spec.truthy(html_md.find_anchor(doc, 'pdf-string%2Eformat'))
        spec.truthy(html_md.find_anchor(doc, 'other'))
        spec.nil_value(html_md.find_anchor(doc, 'missing'))
    end)

    spec.it('window pages on line breaks and never splits UTF-8', function()
        local text = string.rep('ab\n', 10) .. 'λλλλ'
        local chunk, next_off = html_md.window(text, 0, 20)
        spec.equal(chunk, string.rep('ab\n', 6))
        spec.equal(next_off, 18)
        local tail_chunk, done = html_md.window('λλλλ', 0, 3)
        spec.equal(tail_chunk, 'λ')
        spec.equal(done, 2)
        spec.nil_value(select(2, html_md.window('short', 0, 100)))
    end)

    spec.it('toc drops deeper levels first to fit the budget', function()
        local hs = { { level = 1, text = 'One', offset = 0 } }
        for i = 1, 50 do hs[#hs + 1] = { level = 3, text = 'fn' .. i, offset = i * 10 } end
        hs[#hs + 1] = { level = 1, text = 'Two', offset = 999, id = 'two' }
        local toc = html_md.toc(hs, 200)
        spec.equal(toc, '- One (offset=0)\n- Two (offset=999, #two)')
    end)

    spec.it('markdown_headings skips fenced code', function()
        local hs = html_md.markdown_headings('# A\n```\n# not\n```\n## B ##\n')
        spec.equal(#hs, 2)
        spec.equal(hs[2].text, 'B')
        spec.equal(hs[2].offset, 18)
    end)
end)

spec.describe('html_md charset', function()
    spec.it('reads the charset from the header, then from <meta>', function()
        spec.equal(html_md.charset('', 'text/html; charset=ISO-8859-1'), 'iso-8859-1')
        spec.equal(html_md.charset('<META HTTP-EQUIV="content-type" CONTENT="text/html; charset=iso-8859-1">', 'text/html'),
            'iso-8859-1')
        spec.equal(html_md.charset('<meta charset="utf-8">', ''), 'utf-8')
    end)

    spec.it('re-encodes latin1/1252 bytes as UTF-8', function()
        spec.equal(html_md.to_utf8('caf\233 \147q\148 \128', 'iso-8859-1'), 'café “q” €')
    end)

    spec.it('leaves bodies that are already UTF-8 or another charset alone', function()
        spec.equal(html_md.to_utf8('café', 'iso-8859-1'), 'café')
        spec.equal(html_md.to_utf8('\200\201', 'gbk'), '\200\201')
    end)
end)

spec.describe('web_fetch.render', function()
    local page = '<html><head><title>Manual</title></head><body><nav>menu</nav><header>Site header</header><main>'
        .. '<h1 id="intro">Intro</h1><p>' .. string.rep('word ', 5000) .. '</p>'
        .. '<h2 id="fmt">Format</h2><p>format text</p></main></body></html>'
    local opts = { url = 'https://example.com/manual.html', status = 200, content_type = 'text/html' }

    spec.it('starts at <main>, truncates and lists sections on a first read', function()
        local out = web_fetch.render(page, opts)
        spec.contains(out, 'Fetched https://example.com/manual.html (HTTP 200, ')
        spec.contains(out, '— Manual')
        spec.contains(out, 'starting at <main>')
        spec.contains(out, '...[truncated: ')
        spec.contains(out, 'Page sections (pass offset=N, or use url#anchor):')
        spec.contains(out, '- Format (offset=')
        spec.truthy(not out:find('menu', 1, true), 'nav dropped')
    end)

    -- cplusplus.com has no <main>: 9KB of sidebar menus precede the one <h1>.
    spec.it('starts at a lone <h1> when the page has no <main>', function()
        local out = web_fetch.render('<html><body><h3>Reference</h3><ul><li>menu</li></ul>'
            .. '<h1>printf</h1><p>Print formatted data</p></body></html>', opts)
        spec.contains(out, '[starting at the page <h1>; offset=0 for the ')
        spec.contains(out, '\n\n# printf\n\nPrint formatted data')
        spec.truthy(not out:find('menu', 1, true), 'sidebar skipped')
        local two = web_fetch.render('<p>menu</p><h1>A</h1><h1>B</h1>', opts)
        spec.contains(two, 'menu')
    end)

    spec.it('jumps to a #fragment', function()
        local out = web_fetch.render(page, { url = opts.url, status = 200, content_type = 'text/html', fragment = 'fmt' })
        spec.contains(out, '[from #fmt; ')
        spec.contains(out, '\n\n## Format\n\nformat text')
    end)

    spec.it('reports a missing anchor and shows the outline', function()
        local out = web_fetch.render(page, { url = opts.url, status = 200, content_type = 'text/html', fragment = 'nope' })
        spec.contains(out, 'anchor #nope not found')
        spec.contains(out, 'Page sections')
    end)

    spec.it('continues from an explicit offset without a section list', function()
        local first = web_fetch.render(page, opts)
        local next_off = tonumber(first:match('offset=(%d+) to continue'))
        local out = web_fetch.render(page, { url = opts.url, status = 200, content_type = 'text/html', offset = next_off })
        spec.contains(out, '## Format')
        spec.truthy(not out:find('Page sections', 1, true), 'no TOC on a continuation')
    end)

    spec.it('jumps to a slug heading in a markdown file', function()
        local out = web_fetch.render('# Doc\n\nintro\n\n## Set Options\n\nNX only', {
            url = 'https://example.com/README.md', status = 200, content_type = 'text/markdown', fragment = 'set-options' })
        spec.contains(out, '[from #set-options')
        spec.contains(out, '## Set Options\n\nNX only')
    end)

    spec.it('decodes a latin1 page', function()
        local out = web_fetch.render('<html><body><p>caf\233</p></body></html>',
            { url = opts.url, status = 200, content_type = 'text/html; charset=iso-8859-1' })
        spec.contains(out, 'café')
    end)
end)

return {
    __init = function()
        local failed = spec.finish()
        if failed > 0 then os.exit(1) end
        xthread.stop(0)
    end,
}

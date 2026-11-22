'use strict';

const canvas = document.querySelector('#surface');
const context = canvas.getContext('2d', { alpha: false });
const editorLayer = document.querySelector('#editors');
const transcriptText = document.querySelector('#transcript-text');
const transcriptCopy = document.querySelector('#transcript-copy');
const feedback = document.querySelector('#feedback');
const folderPicker = document.querySelector('#folder-picker');
const folderPath = document.querySelector('#folder-path');
const folderList = document.querySelector('#folder-list');
const folderError = document.querySelector('#folder-error');
const folderUp = document.querySelector('#folder-up');
const fontFamily = 'system-ui, "Segoe UI", "PingFang SC", "Microsoft YaHei", sans-serif';
const encoder = new TextEncoder();
const editors = new Map();
const transcriptLines = new Map();
const images = new Map();
const pointerEdges = [];
let pointer = { x: -1, y: -1, down: false };
let edits = {};
let keys = {};
let wheel = 0;
let image;
let folder;
let currentFolder;
let revision = 0;
let measurements = [];
let completion = false;
let reset = true;
let closing = false;
let selectionPress;
let copyValue = '';

function rgba(value) {
    return `rgba(${value >>> 24},${(value >>> 16) & 255},${(value >>> 8) & 255},${(value & 255) / 255})`;
}

function font(size) {
    return `${size}px ${fontFamily}`;
}

function text(value, x, y, size, ink) {
    context.fillStyle = rgba(ink);
    context.font = font(size);
    context.fillText(value, x, y);
}

function rect(x, y, w, h, ink) {
    if (w <= 0 || h <= 0) return;
    context.fillStyle = rgba(ink);
    context.fillRect(x, y, w, h);
}

function rounded(x, y, w, h, radius, ink) {
    if (w <= 0 || h <= 0) return;
    const r = Math.max(0, Math.min(radius, w / 2, h / 2));
    const right = x + w;
    const bottom = y + h;
    context.beginPath();
    context.moveTo(x + r, y);
    context.arcTo(right, y, right, bottom, r);
    context.arcTo(right, bottom, x, bottom, r);
    context.arcTo(x, bottom, x, y, r);
    context.arcTo(x, y, right, y, r);
    context.closePath();
    context.fillStyle = rgba(ink);
    context.fill();
}

function clip(x, y, w, h) {
    context.beginPath();
    context.rect(x, y, Math.max(0, w), Math.max(0, h));
    context.clip();
}

function paintButton(x, y, w, h, size, value, fill, edge, ink, border, alignment, padding) {
    if (border > 0) rect(x, y, w, h, edge);
    rect(x + border, y + border, w - 2 * border, h - 2 * border, fill);
    if (!value) return;
    context.save();
    clip(x, y, w, h);
    const icon = value === '×' || value === '➤' || value === '↻';
    context.textAlign = alignment === 'TEXT_ALIGN_LEFT' && !icon ? 'left' : 'center';
    text(value, context.textAlign === 'left' ? x + padding : x + w / 2, y + (h - size) / 2, size, ink);
    context.restore();
}

function drawFrame(frame) {
    for (const [id, data] of Object.values(frame.add_images ?? {})) {
        const asset = new Image();
        asset.src = 'data:image/png;base64,' + data;
        images.set(id, asset);
    }
    for (const id of Object.values(frame.remove_images ?? {})) images.delete(id);

    const dpi = window.devicePixelRatio || 1;
    const width = Math.round(innerWidth * dpi);
    const height = Math.round(innerHeight * dpi);
    if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
    }
    context.save();
    context.setTransform(dpi * frame.scale, 0, 0, dpi * frame.scale, 0, 0);
    context.textBaseline = 'top';
    let clips = 0;
    for (const [kind, ...args] of Object.values(frame.commands)) {
        switch (kind) {
            case 'rect': rect(...args); break;
            case 'rounded': rounded(...args); break;
            case 'text': text(args[4], ...args.slice(0, 4)); break;
            case 'label': {
                const [x, y, w, h, size, ink, value] = args;
                context.save();
                clip(x, y, w, h);
                text(value, x, y + (h - size) / 2, size, ink);
                context.restore();
                break;
            }
            case 'button': paintButton(...args); break;
            case 'clip': context.save(); clip(...args); clips++; break;
            case 'unclip': if (clips > 0) { context.restore(); clips--; } break;
            case 'image':
            case 'subimage': {
                const asset = images.get(args[0]);
                if (asset?.complete && asset.naturalWidth) context.drawImage(asset, ...args.slice(1));
                break;
            }
        }
    }
    while (clips-- > 0) context.restore();
    context.restore();
    canvas.style.cursor = frame.cursor;
    measurements = Object.values(frame.measure).map(([size, value]) => {
        context.font = font(size);
        return [size, value, Math.ceil(context.measureText(value).width)];
    });
}

function editValue(state, submit = false, blur = false) {
    state.revision = ++revision;
    edits[state.id] = { value: state.node.value, submit, blur };
}

function addEditor(spec) {
    const node = document.createElement(spec.multiline ? 'textarea' : 'input');
    const state = { id: spec.id, node, revision: 0, focused: false, composing: false, enterSends: spec.enter_sends };
    node.className = 'editor';
    node.dataset.editor = spec.id;
    node.spellcheck = false;
    node.setAttribute('aria-label', spec.label ?? (spec.id.startsWith('composer:') ? '消息' : '文本输入'));
    node.addEventListener('compositionstart', () => { state.composing = true; });
    node.addEventListener('compositionend', () => { state.composing = false; editValue(state); });
    node.addEventListener('input', () => { if (!state.composing) editValue(state); });
    node.addEventListener('keydown', event => {
        if (event.isComposing || state.composing || event.keyCode === 229) return;
        if (event.key === 'Enter' && !spec.multiline) {
            event.preventDefault();
            editValue(state, false, true);
            node.blur();
            return;
        }
        if (event.key === 'Enter' && state.enterSends && !event.ctrlKey && !event.metaKey && !event.shiftKey) {
            event.preventDefault();
            if (!event.repeat) editValue(state, true);
        }
        if (completion && state.id.startsWith('composer:') && ['ArrowUp', 'ArrowDown'].includes(event.key)) {
            event.preventDefault();
        }
    });
    node.addEventListener('paste', event => {
        if (!state.id.startsWith('composer:')) return;
        const file = Array.from(event.clipboardData.files).find(item => item.type.startsWith('image/'));
        if (file) {
            event.preventDefault();
            attach(file).catch(() => showError('无法读取剪贴板上的图片。'));
        }
    });
    editorLayer.append(node);
    editors.set(spec.id, state);
    return state;
}

function textOffset(value, bytes) {
    let index = 0;
    let consumed = 0;
    for (const char of value) {
        consumed += encoder.encode(char).length;
        if (consumed > bytes) break;
        index += char.length;
    }
    return index;
}

function updateEditors(specs, scale, acknowledged) {
    const visible = new Set();
    let focus;
    const active = document.activeElement;
    for (const spec of Object.values(specs)) {
        visible.add(spec.id);
        const state = editors.get(spec.id) ?? addEditor(spec);
        const { node } = state;
        state.enterSends = spec.enter_sends;
        node.style.left = `${spec.x * scale}px`;
        node.style.top = `${spec.y * scale}px`;
        node.style.width = `${spec.w * scale}px`;
        node.style.height = `${spec.h * scale}px`;
        node.style.fontSize = `${spec.size * scale}px`;
        node.style.lineHeight = `${spec.size * 1.25 * scale}px`;
        node.style.color = rgba(spec.ink);
        node.style.clipPath = `inset(${spec.clip.map(value => `${value * scale}px`).join(' ')})`;
        if (!state.composing && state.revision <= acknowledged && node.value !== spec.text) node.value = spec.text;
        if (spec.focused && (!state.focused || spec.caret !== undefined || node === active)) focus = state;
        if (spec.caret !== undefined && !state.composing) {
            const index = textOffset(node.value, spec.caret);
            node.setSelectionRange(index, index);
        }
        state.focused = spec.focused;
    }
    for (const [id, state] of editors) {
        if (!visible.has(id)) { state.node.remove(); editors.delete(id); }
    }
    if (focus && !currentFolder && focus.node !== active) focus.node.focus({ preventScroll: true });
}

function updateTranscript(selection, scale) {
    const specs = Object.values(selection?.lines ?? {});
    const visible = new Set(specs.map(spec => spec[0]));
    for (const [key, node] of transcriptLines) {
        if (!visible.has(key)) { node.remove(); transcriptLines.delete(key); }
    }
    if (!selection) return;
    const [x, y, w, h] = selection.clip.map(value => value * scale);
    transcriptText.style.clipPath = `inset(${y}px ${Math.max(0, innerWidth - x - w)}px ${Math.max(0, innerHeight - y - h)}px ${x}px)`;

    // Keep existing text nodes in place while frames arrive so the browser
    // keeps its selection, including when a reply appends to a visible line.
    let next = transcriptText.firstChild;
    for (const [key, left, top, size, value, join] of specs) {
        let node = transcriptLines.get(key);
        if (!node) {
            node = document.createElement('div');
            node.className = 'transcript-line';
            node.append(document.createTextNode(value));
            transcriptLines.set(key, node);
        }
        const content = node.firstChild;
        node.dataset.join = join;
        if (value !== content.data) {
            if (value.startsWith(content.data)) content.appendData(value.slice(content.length));
            else content.data = value;
        }
        if (node !== next) transcriptText.insertBefore(node, next);
        next = node.nextSibling;
        node.style.left = `${left * scale}px`;
        node.style.top = `${top * scale}px`;
        node.style.fontSize = `${size * scale}px`;
        node.style.lineHeight = `${size * 1.25 * scale}px`;
    }
}

function selectedTranscript() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !transcriptText.contains(selection.anchorNode)
        || !transcriptText.contains(selection.focusNode)) return '';
    const range = selection.getRangeAt(0);
    let value = '';
    let join = '';
    for (const line of transcriptText.children) {
        if (!range.intersectsNode(line)) continue;
        const text = line.firstChild;
        const start = range.startContainer === text ? range.startOffset : 0;
        const end = range.endContainer === text ? range.endOffset : text.length;
        value += join + text.data.slice(start, end);
        join = line.dataset.join;
    }
    return value;
}

transcriptText.addEventListener('contextmenu', event => {
    const value = selectedTranscript();
    if (!value) return;
    event.preventDefault();
    copyValue = value;
    transcriptCopy.hidden = false;
    transcriptCopy.style.left = `${Math.min(event.clientX, innerWidth - transcriptCopy.offsetWidth - 4)}px`;
    transcriptCopy.style.top = `${Math.min(event.clientY, innerHeight - transcriptCopy.offsetHeight - 4)}px`;
    transcriptCopy.focus({ preventScroll: true });
});

transcriptCopy.addEventListener('pointerdown', event => event.preventDefault());
transcriptCopy.addEventListener('click', () => {
    clipboard(copyValue);
    transcriptCopy.hidden = true;
});

document.addEventListener('copy', event => {
    if (document.activeElement?.matches('input, textarea')) return;
    const value = selectedTranscript();
    if (!value || !event.clipboardData) return;
    event.preventDefault();
    event.clipboardData.setData('text/plain', value);
});

async function attach(file) {
    const bitmap = await createImageBitmap(file);
    try {
        const png = document.createElement('canvas');
        png.width = bitmap.width;
        png.height = bitmap.height;
        if (png.width * png.height > 16_000_000) throw new Error('Image too large');
        png.getContext('2d').drawImage(bitmap, 0, 0);
        const data = png.toDataURL('image/png').split(',')[1];
        if (!data || data.length > 18_000_000) throw new Error('Image too large');
        image = [data, png.width, png.height];
    } finally {
        bitmap.close();
    }
}

function showError(message) {
    feedback.textContent = message;
    feedback.hidden = false;
}

function folderAction(kind, path) { folder = { kind, path }; }

function updateFolder(spec) {
    if (!spec) {
        if (folderPicker.open) folderPicker.close();
        currentFolder = undefined;
        return;
    }
    if (currentFolder !== spec.path) {
        currentFolder = spec.path;
        folderPath.value = spec.path;
        folderUp.disabled = !spec.parent;
        folderUp.onclick = () => folderAction('go', spec.parent);
        folderList.replaceChildren();
        const separator = spec.path.includes('\\') ? '\\' : '/';
        const prefix = /[\\/]$/.test(spec.path) ? spec.path : spec.path + separator;
        for (const name of Object.values(spec.dirs)) {
            const button = document.createElement('button');
            button.type = 'button';
            button.textContent = name;
            button.addEventListener('click', () => folderAction('go', prefix + name));
            folderList.append(button);
        }
    }
    folderError.hidden = !spec.error;
    folderError.textContent = spec.error ?? '';
    if (!folderPicker.open) folderPicker.showModal();
}

document.querySelector('#folder-go').onclick = () => folderAction('go', folderPath.value);
document.querySelector('#folder-select').onclick = () => folderAction('select', folderPath.value);
document.querySelector('#folder-cancel').onclick = () => folderAction('cancel');
folderPath.addEventListener('keydown', event => {
    if (event.key === 'Enter' && !event.isComposing && event.keyCode !== 229) folderAction('go', folderPath.value);
});
folderPicker.addEventListener('cancel', event => { event.preventDefault(); folderAction('cancel'); });

window.addEventListener('keydown', event => {
    if (event.key === 'Escape' && !transcriptCopy.hidden) {
        transcriptCopy.hidden = true;
        return;
    }
    const state = editors.get(document.activeElement?.dataset.editor);
    if (currentFolder || state?.composing || event.isComposing || event.keyCode === 229) return;
    if (['Escape', 'ArrowDown', 'ArrowUp'].includes(event.key)) keys[event.key] = true;
});

window.addEventListener('pointermove', event => { pointer = { ...pointer, x: event.clientX, y: event.clientY }; });
function pointerEdge(event, down, cancelled = false, selectionDragged = false) {
    if (event.button !== 0 && !cancelled) return;
    pointer = { x: event.clientX, y: event.clientY, down, cancelled, selection_dragged: selectionDragged };
    if (pointerEdges.length < 16) pointerEdges.push(pointer);
}
window.addEventListener('pointerdown', event => {
    if (event.target === transcriptCopy) return;
    transcriptCopy.hidden = true;
    if (event.button === 0 && transcriptText.contains(event.target)) selectionPress = [event.clientX, event.clientY];
    if (!currentFolder) pointerEdge(event, true);
});
window.addEventListener('pointerup', event => {
    if (event.target === transcriptCopy) return;
    const dragged = !!selectionPress && (Math.abs(event.clientX - selectionPress[0]) > 3
        || Math.abs(event.clientY - selectionPress[1]) > 3);
    selectionPress = undefined;
    pointerEdge(event, false, dragged, dragged);
});
window.addEventListener('pointercancel', event => { selectionPress = undefined; pointerEdge(event, false, true); });
window.addEventListener('blur', () => { if (pointer.down) pointerEdge({ clientX: -1, clientY: -1 }, false, true); });
function scrollWorkspace(event) {
    event.preventDefault();
    wheel -= event.deltaMode === 0 ? event.deltaY / 110 : event.deltaY / 3;
}
canvas.addEventListener('wheel', scrollWorkspace, { passive: false });
transcriptText.addEventListener('wheel', scrollWorkspace, { passive: false });

function clipboard(value) {
    const fallback = () => {
        const previous = document.activeElement;
        const field = document.createElement('textarea');
        field.value = value;
        field.style.position = 'fixed';
        field.style.opacity = '0';
        document.body.append(field);
        field.select();
        document.execCommand('copy');
        field.remove();
        previous?.focus({ preventScroll: true });
    };
    if (navigator.clipboard) navigator.clipboard.writeText(value).catch(fallback);
    else fallback();
}

async function pump() {
    if (closing) return;
    const acknowledged = revision;
    const state = { width: innerWidth, height: innerHeight, dpi: devicePixelRatio, reset,
        mouse: pointerEdges.shift() ?? pointer, keys, wheel, edits, image, measurements, folder };
    reset = false;
    edits = {};
    keys = {};
    wheel = 0;
    image = undefined;
    folder = undefined;
    measurements = [];
    try {
        const response = await fetch('frame', { method: 'POST', body: JSON.stringify(state) });
        if (!response.ok) throw new Error(await response.text());
        const frame = await response.json();
        if (frame.close) {
            closing = true;
            window.coduaClose?.(location.href);
            return;
        }
        feedback.hidden = true;
        completion = frame.completion;
        drawFrame(frame);
        updateTranscript(frame.selection, frame.scale);
        updateFolder(frame.folder);
        updateEditors(frame.editors, frame.scale, acknowledged);
        if (frame.clipboard !== undefined) clipboard(frame.clipboard);
    } catch (error) {
        showError(error.message);
    }
    setTimeout(pump, document.hidden ? 150 : 16);
}

pump();

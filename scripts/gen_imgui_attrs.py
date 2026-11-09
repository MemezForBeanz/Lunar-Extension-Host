"""Generate src/lua/core/imgui/attrs.lua from the patched IUP sources.

For every IUP class: which attributes are registered, their default values and whether
they inherit. The ImGui host's Element uses it so attribute inheritance and defaults
follow IUP exactly instead of a hand-kept list.

    python scripts/gen_imgui_attrs.py <iup-src/src> src/lua/core/imgui/attrs.lua
"""
import os
import re
import sys

src, out = sys.argv[1], sys.argv[2]

CALL = re.compile(r'iupClassRegisterAttribute(Id)?\s*\(\s*ic\s*,\s*"([A-Z0-9_]+)"\s*,(.*?)\)\s*;', re.S)
NAME = re.compile(r'ic->name\s*=\s*"([a-z0-9_]+)"')
FUNC = re.compile(r'^(?:IUP_SDK_API\s+|static\s+)?(?:void|Iclass\*)\s+(\w+)\s*\(([^)]*)\)\s*$', re.M)

def split_args(s):
    args, depth, cur, q = [], 0, '', False
    for ch in s:
        if ch == '"' :
            q = not q
        if not q and ch == '(':
            depth += 1
        if not q and ch == ')':
            depth -= 1
        if ch == ',' and depth == 0 and not q:
            args.append(cur.strip()); cur = ''
        else:
            cur += ch
    args.append(cur.strip())
    return args

def parse_default(a, b):
    # IupClassRegisterAttribute(ic, name, get, set, default_value, system_default, flags)
    for v in (a, b):
        m = re.match(r'^"(.*)"$', v)
        if m:
            return m.group(1)
        if v in ('IUPAF_SAMEASSYSTEM',):
            continue
    m = re.match(r'^"(.*)"$', b)
    return m.group(1) if m else None

def attrs_in(text):
    found = {}
    for m in CALL.finditer(text):
        args = split_args(m.group(3))
        if len(args) < 5:
            continue
        default, sysdef, flags = args[2], args[3], args[4]
        value = None
        dm = re.match(r'^"(.*)"$', default)
        sm = re.match(r'^"(.*)"$', sysdef)
        if dm:
            value = dm.group(1)
        elif default == 'IUPAF_SAMEASSYSTEM' and sm:
            value = sm.group(1)
        if default.startswith('IUP_FLAT_'):
            value = {'IUP_FLAT_BORDERCOLOR': '50 150 255', 'IUP_FLAT_HIGHCOLOR': '200 225 245',
                     'IUP_FLAT_PRESSCOLOR': '150 200 235', 'IUP_FLAT_FORECOLOR': '220 220 220',
                     'IUP_FLAT_BACKCOLOR': '220 220 220'}.get(default, value)
        noinherit = ('IUPAF_NO_INHERIT' in flags) or ('IUPAF_READONLY' in flags) or ('IUPAF_WRITEONLY' in flags)
        found[m.group(2)] = (value, noinherit, m.group(1) == 'Id')
    return found

classes = {}
base = {}
for fn in sorted(os.listdir(src)):
    if not fn.endswith('.c'):
        continue
    text = open(os.path.join(src, fn), encoding='latin-1').read()
    if fn == 'iup_classbase.c':
        base = attrs_in(text)
        continue
    names = NAME.findall(text)
    if not names:
        continue
    found = attrs_in(text)
    for n in names:
        classes.setdefault(n, {}).update(found)

def lua_str(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'

lines = ['--- IUP attribute registrations, generated from the patched IUP 3.32 sources by',
         '-- scripts/gen_imgui_attrs.py. Do not edit by hand.',
         '--',
         '-- [class][NAME] = { default (string or false), noinherit (boolean), id (boolean) }',
         '-- `base` is what every class registers (iup_classbase.c).',
         '-- @module core.imgui.attrs',
         'local A = {}']

def emit(table_name, found):
    lines.append('A[%s] = {' % lua_str(table_name))
    for k in sorted(found):
        v, ni, idd = found[k]
        key = k if re.match(r'^[A-Za-z_]\w*$', k) else '[%s]' % lua_str(k)
        lines.append('\t%s = { %s, %s, %s },' % (key, lua_str(v) if v is not None else 'false',
                                                  'true' if ni else 'false', 'true' if idd else 'false'))
    lines.append('}')

emit('base', base)
for n in sorted(classes):
    emit(n, classes[n])
lines.append('return A')
open(out, 'w', newline='\n', encoding='utf-8').write('\n'.join(lines) + '\n')
print(len(classes), 'classes', sum(len(v) for v in classes.values()), 'attributes')

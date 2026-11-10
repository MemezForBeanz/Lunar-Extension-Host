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

# Function bodies of every C file, the core's and the Windows driver's: a class also
# registers what the helpers it calls with `ic` register (iupdrvTextInitClass in
# win/iupwin_text.c, iupFlatScrollBarRegister, ...), as IUP's class creation runs them.
DEF = re.compile(r'^[A-Za-z_][\w \t\*]*?\b(\w+)\s*\(([^;{}]*)\)\s*\{', re.M)
CALLS_IC = re.compile(r'\b(\w+)\s*\(\s*ic\s*[,)]')

def functions(text):
    out = {}
    for m in DEF.finditer(text):
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == '{':
                depth += 1
            elif text[i] == '}':
                depth -= 1
                if depth == 0:
                    break
            i += 1
        out[m.group(1)] = text[m.end():i]
    return out

files = []
for sub in ('', 'win'):
    d = os.path.join(src, sub)
    for fn in sorted(os.listdir(d)):
        if fn.endswith('.c'):
            files.append((sub, fn, open(os.path.join(d, fn), encoding='latin-1').read()))

bodies = {}
for sub, fn, text in files:
    for name, body in functions(text).items():
        # the Windows driver's definition wins over a stub elsewhere
        if name not in bodies or sub == 'win':
            bodies[name] = body

def helper_attrs(body, seen):
    found = {}
    for name in CALLS_IC.findall(body):
        if name in seen or name not in bodies or name.startswith('iupClassRegister'):
            continue
        seen.add(name)
        found.update(helper_attrs(bodies[name], seen))
        found.update(attrs_in(bodies[name]))
    # iupBaseRegisterCommonAttrib registers CANFOCUS YES or NO by ic->is_interactive; the
    # host decides it from the class (Element's registered_default), not from a branch.
    found.pop('CANFOCUS', None)
    return found

classes = {}
base = {}
for sub, fn, text in files:
    if sub:
        continue
    if fn == 'iup_classbase.c':
        base = attrs_in(text)
        continue
    names = NAME.findall(text)
    if not names:
        continue
    found = helper_attrs(text, set())
    found.update(attrs_in(text))
    # the driver registers last (iupdrvXInitClass runs after the core's registrations)
    for k, v in helper_attrs(text, set()).items():
        if k.startswith('PADDING') or k not in found or found[k][0] is None:
            found[k] = v
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

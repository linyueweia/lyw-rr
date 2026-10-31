#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""板级 DTS 语法门（无需内核树、无需 dtc，纯文本，~1 秒）

本文件自 lyw-OS(T68M) 仓移植（2026-10-29，两仓构建流程对齐）；
下方两起事故发生在 T68M 线，但同类错在 K1 线同样要等内核 make 才报。

为什么要有它 —— 两次真实事故，都是**纯文本可判定**的错，却要等内核 make 才报：
  * 2026-10-28 run #62：`poll-interval = <100>;` 写成 `poll-interval = 100>;`
    → dtc 报 `rk3568-lyt-t68m.dts:51.19-22 syntax error`，烧掉 3414 秒（57 分钟）。
  * 2026-10-28 run #65：`&hdmi` 里 `ports { }` 之后又写了 `status = "okay";`
    → dtc 报 `348.2-18 Properties must precede subnodes` + `FATAL ERROR: Unable to
    parse input tree`，烧掉 3608 秒。当时的门禁只查括号配平，这条漏了。

判据（只做"必错"的判断，不猜语义）：
  1. `{` `}` 必须配平
  2. `<` `>` 必须配平（且 `>` 不能先于 `<`）
  3. `"` 必须配平、转义闭合
  4. `name = value;` 的 value 必须是下列之一（可逗号连接）：
       空（布尔属性） / "字符串" / <cells> / &label / [hex字节] / 纯数字
     其余形态（如 `100>`、`<100`、裸 `}` 后跟垃圾）一律判错
  5. **同一作用域内属性必须写在子节点之前**（dtc: Properties must precede subnodes）
  6. `#include` 行不参与检查；`/dts-v1/;` 允许；`/delete-node/` `/delete-property/` 不受 5 约束

用法：
  python3 dts-lint.py <file.dts> [more.dts ...]   # 检查文件
  python3 dts-lint.py --selftest                  # 判据自身的正/负例自测（负例不响=判据没在干活）
"""
import sys, os, re

ALLOWED_VALUE = re.compile(
    r'^(?:'
    r'\s*'
    r'(?:'
    r'"(?:[^"\\]|\\.)*"'                # 字符串
    r'|<[A-Za-z0-9_<>&,\s\-\.\[\]()|*+:~/]*>'   # cells（含 &label、宏、数字）
    r'|&[A-Za-z_][A-Za-z0-9_]*'         # 单独的 phandle
    r'|\[[0-9A-Fa-f\s]*\]'              # hex 字节
    r'|-?\d+'                           # 纯数字
    r'|\*'                              # 少数 binding 用 *
    r'|[A-Za-z_][A-Za-z0-9_]*'          # 裸宏（cpp 会展开成字符串/数字，如 LED_FUNCTION_LAN）
    r')'
    r'(?:\s*,\s*(?:"(?:[^"\\]|\\.)*"|<[A-Za-z0-9_<>&,\s\-\.\[\]()|*+:~/]*>|&[A-Za-z_][A-Za-z0-9_]*|\[[0-9A-Fa-f\s]*\]|-?\d+|[A-Za-z_][A-Za-z0-9_]*))*'
    r'\s*)$')

# 属性赋值语句的开头：`name = ` / `#address-cells = ` / `label: name = `（label 前缀少见但允许）
PROP_BEGIN = re.compile(r'^\s*(?:[A-Za-z_][\w\-]*\s*:\s*)*([#A-Za-z_][\w,\-\.#]*)\s*=\s*')
# 非属性行：include / 版本标记 / 删除指令
DIRECTIVE = re.compile(
    r'^\s*(?:#\s*include|/dts-v1/|/plugin/|/memreserve/|/delete-node/|/delete-property/|/omit-if-no-ref/)')


def strip_comments(text):
    """去注释但保留换行，行号不变"""
    out, i, n = [], 0, len(text)
    while i < n:
        if text.startswith('/*', i):
            j = text.find('*/', i + 2)
            if j < 0:
                return ''.join(out) + '\n@@UNTERMINATED_COMMENT@@\n'
            out.append('\n' * text.count('\n', i, j + 2))
            i = j + 2
        elif text.startswith('//', i):
            j = text.find('\n', i)
            if j < 0:
                j = n
            i = j
        else:
            out.append(text[i])
            i += 1
    return ''.join(out)


def _code_chars(line):
    """返回一行里"字符串之外"的字符序列（用于数括号）"""
    out, i, n, instr = [], 0, len(line), False
    while i < n:
        c = line[i]
        if instr:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True
        else:
            out.append(c)
        i += 1
    return ''.join(out)


def check_prop_order(text, errs):
    """判据 5：同一作用域内，属性不得出现在子节点之后（dtc: Properties must precede subnodes）"""
    depth = 0
    sub_seen = []          # sub_seen[d] = 作用域 d 内是否已经出现过子节点
    for ln, raw in enumerate(text.split('\n'), 1):
        code = _code_chars(raw)
        is_directive = bool(DIRECTIVE.match(raw))
        if not is_directive and '{' not in code:
            m = PROP_BEGIN.match(raw)
            if m and depth > 0 and depth <= len(sub_seen) and sub_seen[depth - 1]:
                errs.append((ln, m.start(1) + 1,
                             '属性不能写在子节点之后（dtc: Properties must precede subnodes）'))
        for c in code:
            if c == '{':
                while len(sub_seen) < depth:
                    sub_seen.append(False)
                sub_seen.append(False)
                depth += 1
                if 0 <= depth - 2 < len(sub_seen):
                    sub_seen[depth - 2] = True
            elif c == '}':
                if depth > 0:
                    depth -= 1
                    del sub_seen[depth:]
    return errs


def lint(path):
    raw = open(path, encoding='utf-8', errors='replace').read()
    text = strip_comments(raw)
    errs = []
    line = lambda pos: (text[:pos].count('\n') + 1,
                        pos - (text.rfind('\n', 0, pos) + 1) + 1)

    if '@@UNTERMINATED_COMMENT@@' in text:
        ln, col = line(text.find('@@UNTERMINATED_COMMENT@@'))
        errs.append((ln, col, '注释未闭合（缺 */）'))

    # 逐字符配平
    brace = angle = 0
    instr = False
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if instr:
            if c == '\\':
                i += 2
                continue
            if c == '"':
                instr = False
            i += 1
            continue
        if c == '"':
            instr = True
        elif c == '{':
            brace += 1
        elif c == '}':
            brace -= 1
            if brace < 0:
                ln, col = line(i)
                errs.append((ln, col, '多余的 }'))
                brace = 0
        elif c == '<':
            if text.startswith('<<', i):      # CPP 左移运算符，不是 cells 定界符
                i += 2
                continue
            angle += 1
        elif c == '>':
            if text.startswith('>>', i):      # CPP 右移运算符
                i += 2
                continue
            angle -= 1
            if angle < 0:
                ln, col = line(i)
                errs.append((ln, col, '出现了没有对应 < 的 >（多半是少了 <）'))
                angle = 0
        i += 1
    if instr:
        errs.append((len(text.split('\n')), 1, '字符串未闭合（缺 "）'))
    if brace > 0:
        errs.append((len(text.split('\n')), 1, '{ 未闭合，还差 %d 个 }' % brace))
    if angle > 0:
        errs.append((len(text.split('\n')), 1, '< 未闭合，还差 %d 个 >' % angle))

    # 逐条属性 value 形态
    for m in re.finditer(r'^([ \t]*)([A-Za-z_][A-Za-z0-9_,\-\\.]*)[ \t]*=[ \t]*(.*?);[ \t]*$',
                         text, re.M):
        val = m.group(3)
        if val == '' or ALLOWED_VALUE.match(val):
            continue
        pos = m.start(3)
        ln, col = line(pos)
        errs.append((ln, col, '属性值形态非法：%r（应为 "" / <> / &label / 数字）' % val.strip()[:40]))

    # 判据 5
    check_prop_order(text, errs)

    return errs


def selftest():
    """判据自身的正/负例自测：负例不响 = 判据没在干活（run #65 就是这么漏掉的）"""
    import tempfile
    cases = [
        ('good_only_props',
         '/dts-v1/;\n&hdmi {\n\tavdd-0v9-supply = <&v>;\n\tstatus = "okay";\n};\n', 0),
        ('good_props_then_subnode',
         '&hdmi {\n\tstatus = "okay";\n\tports {\n\t\tport@1 {\n\t\t\treg = <1>;\n\t\t};\n\t};\n};\n', 0),
        ('bad_prop_after_subnode',      # run #65 的真实形态
         '&hdmi {\n\tports {\n\t\tport@1 {\n\t\t\treg = <1>;\n\t\t};\n\t};\n\tstatus = "okay";\n};\n', 1),
        ('bad_value_form',              # run #62 的真实形态
         '&keys {\n\tpoll-interval = 100>;\n};\n', 1),
        ('bad_unbalanced_brace', '&x {\n\ta = <1>;\n', 1),
        ('bad_unbalanced_angle', '&x {\n\ta = <1;\n};\n', 1),
        ('good_delete_after_subnode',
         '&x {\n\tchild {\n\t\treg = <0>;\n\t};\n\t/delete-node/ obsolete;\n};\n', 0),
    ]
    bad = 0
    for name, body, want_bad in cases:
        fd, p = tempfile.mkstemp(suffix='.dts')
        os.close(fd)
        try:
            open(p, 'w', encoding='utf-8').write(body)
            errs = lint(p)
        finally:
            os.unlink(p)
        got = 1 if errs else 0
        ok = (got == want_bad)
        bad |= (0 if ok else 1)
        flag = '✅' if ok else '❌'
        print('%s selftest %s: 期望%s，实际%s%s'
              % (flag, name, '报错' if want_bad else '通过', '报错' if got else '通过',
                 '' if ok else '  ← %s' % (errs[:2],)))
    if bad:
        print('\n!! 语法门自测失败 —— 判据本身有问题，先修判据再谈 DTS。')
    return bad


def main():
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        return 2
    if '--selftest' in args:
        return selftest()
    bad = 0
    for p in args:
        errs = lint(p)
        name = os.path.basename(p)
        if errs:
            bad = 1
            print('❌ %s' % name)
            for ln, col, msg in sorted(set(errs)):
                print('    %s:%d:%d: %s' % (name, ln, col, msg))
        else:
            print('✅ %s 语法形态通过' % name)
    if bad:
        print('\n!! 板级 DTS 语法门未通过 —— 这类错 dtc 要等内核 make 才报（实测 3414/3608 秒），'
              '在这里 1 秒判死。')
    return bad


if __name__ == '__main__':
    sys.exit(main())

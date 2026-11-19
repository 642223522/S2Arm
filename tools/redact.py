"""Shared stdlib-only redaction. Importing this module performs no file access."""
from pathlib import Path
import re

KEY_LINE = re.compile(r'(?im)^(?P<prefix>[ \t]*[A-Za-z0-9_.-]+[ \t]*=[ \t]*)(?P<value>[0-9a-f]{32,})[^\r\n]*(?=\r?$)')

SECRET = re.compile(r'(?i)(?:password|passwd|secret|token|api[_-]?key|authorization|cookie|serial(?:number)?|udid|uuid|imei|device[_-]?id|android[_-]?id|idfa|idfv|mac[_-]?address|uniqueidentifier|identifierforvendor|tester|(?:^|[_-])keys?(?:[_-]|$)|(?:^|[_-])(?:kek|bek|seed|keyblob)(?:[_-]|$)|titlekek|masterkey|headerkey)')

# Scan keys separately so an innocent outer field cannot hide a nested secret assignment.
# 名字只从一串 [A-Za-z0-9_.-] 的开头试（前面的数字 / 点 / 横线由 [0-9.-]* 吃掉，名字仍从串里第一个字母或下划线起）：原写法从串里每个位置起
#   都把名字吞到串尾再回退，长串（40 KB 的一行日志、base64）上是平方级，40 KB 一行脱敏 18 秒、诊断导出单测 96 秒（11-14 门禁提速）。
#   结果不变：名字后面必须紧跟引号 / 空白 / [:=]，从串里任何位置起名字都只能在串尾结束，最左匹配本来就落在串里第一个字母或下划线上
ASSIGNMENT_KEY = re.compile(r"""["']?(?<![A-Za-z0-9_.-])[0-9.-]*(?P<name>[A-Za-z_][A-Za-z0-9_.-]*)["']?[^\S\r\n]*[:=][^\S\r\n]*""")


# 按确切名字放行（维护者 11-19 定：不放宽上面的密钥名规则）：key=（着色器 / 管线缓存键，代码内容的哈希，nvn_mtl.m「K … key=%s」、
#   selection.c「direct attempt … key=%.64s」；诊断里原先 17 万行全成 key=[REDACTED]）和 binaryUUID（我们自己二进制的构建号，崩溃符号化要用）。
#   放行的是名字不是值：真密钥原值照样按值先抹（redact_text 开头），prod.keys / title.keys 整行照样按 KEY_LINE 抹，64 位以上十六进制照样当密钥材料
ALLOWED_NAMES = frozenset({'key', 'binaryUUID'})
_BINARY_UUID_BEFORE = re.compile(r'binaryUUID["\']?[^\S\r\n]*[:=][^\S\r\n]*["\']?\Z')


def redact_assignments(text):
    pieces, cursor = [], 0
    for match in ASSIGNMENT_KEY.finditer(text):
        if match.end() <= cursor or match['name'] in ALLOWED_NAMES or not SECRET.search(match['name']):
            continue
        start = match.end()
        q = text[start] if start < len(text) and text[start] in ('"', "'") else ''
        # Quotes may also start inside an unquoted value (shell-style fragments).
        quote = q or None
        end = start + (1 if q else 0)
        while end < len(text) and text[end] not in '\r\n':
            if quote and text[end] == '\\':
                end += 1
                if end < len(text) and text[end] not in '\r\n':
                    end += 1
            elif quote:
                if text[end] == quote:
                    quote = None
                end += 1
            elif text[end] in ('"', "'"):
                quote = text[end]
                end += 1
            elif text[end].isspace() or text[end] in (',;}]' if q else ',;}'):
                break
            else:
                end += 1
        closed = quote is None
        if end > start:
            # Preserve valid JSON quotes; scan state also covers adjacent fragments and tails.
            pieces.extend((text[cursor:start], q + '[REDACTED]' + (q if closed else '')))
            cursor = end
    pieces.append(text[cursor:])
    return ''.join(pieces)


def load_key_values(paths=None) -> frozenset[str]:
    """Read Switch key assignments lazily; an empty iterable disables default files."""
    if paths is None:
        paths = (Path.home() / '.switch' / 'prod.keys', Path.home() / '.switch' / 'title.keys')
    values = set()
    for path in paths:
        try:
            with Path(path).open(encoding='utf-8', errors='replace') as stream:
                for line in stream:
                    match = KEY_LINE.fullmatch(line.rstrip('\r\n'))
                    if match:
                        values.add(match['value'].lower())
        except FileNotFoundError:
            continue
    return frozenset(values)



# Shared identity contract: tests/fixtures/redact_cases.tsv (Python/Swift/iOS).
# Apply after secret assignments so explicit udid=/serial= retain [REDACTED].
# Shape matches use ASCII alphanumeric boundaries, independent of Unicode \b.
# A legacy 40-hex value is private only on a physical line containing the
# standalone word udid/device/serial; ordinary Git SHAs remain unchanged.
# Device owner is a nonempty token delimited by whitespace, quotes, brackets,
# or log/JSON punctuation. Keep 的iPhone/的iPad so the model remains useful.
IDENTITY_RULES = (
    # Preserve known field labels first; unknown '=' prefixes are ambiguous and hidden.
    (r'''(?i)((?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])(?:contact|email|mail|from|to|reply[_-]?to|user)["']?[ \t]*[:=][ \t]*["']?)[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])''', r'\1[EMAIL]'),
    (r"(?i)(?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])", '[EMAIL]'),
    (r'''(?i)(\bDEVELOPMENT_TEAM[ \t]*=[ \t]*["']?|\bSigning[ \t]+with[ \t]+team[ \t]+)(?<![A-Z0-9])[A-Z0-9]{10}(?![A-Z0-9])''', r'\1[TEAM_ID]'),
    (r'(?i)(?<![A-Z0-9])(s2arm\.)[A-Z0-9]{10}(\.[A-F0-9]{16})(?![A-Z0-9])', r'\1[TEAM_ID]\2'),
    (r'(?i)(?<![A-Z0-9])[A-F0-9]{8}-[A-F0-9]{16}(?![A-Z0-9])', '[DEVICE_ID]'),
)
DEVICE_CONTEXT = re.compile(r'(?i)\b(?:udid|device|serial)\b')
LEGACY_UDID = re.compile(r'(?i)(?<![A-Z0-9])[A-F0-9]{40}(?![A-Z0-9])')
# 只在一串非分隔字符的开头试（前面不是同类字符）：原写法从串里每个位置起都往后吞到底再回退，长串（长 JSON 值、零字节）上是平方级——
#   4 MiB 的任务记录脱敏要几分钟（#917）。结果不变：最左匹配本来就从串首开始
DEVICE_NAME = re.compile(r'''(?<![^\s"'<>:=,;{}\[\]，。])[^\s"'<>:=,;{}\[\]，。]+的(iPhone|iPad)''')


def redact_identity(text):
    for pattern, replacement in IDENTITY_RULES:
        text = re.sub(pattern, replacement, text)
    # Preserve CR/LF and restrict device context to that physical line.
    text = re.sub(r'[^\r\n]+', lambda match: LEGACY_UDID.sub('[DEVICE_ID]', match[0])
                  if DEVICE_CONTEXT.search(match[0]) else match[0], text)
    return DEVICE_NAME.sub(r'[DEVICE_NAME]的\1', text)


def _private_path(match):
    """路径换成占位；Windows 路径保留长度和层数（不含内容），WinError 206 这类问题要靠它分清是不是路径太长"""
    path = match.group(0).replace('\\\\', '\\')
    if '\\' not in path:
        return '[PRIVATE_PATH]'
    return f"[PRIVATE_PATH len={len(path)} depth={path.count(chr(92))}]"


# 系统错误原文（strerror）：路径匹配会一直吞到行尾（路径本身可能带空格，不能按空白截断），「cp: <路径>: Operation not permitted」的原因
#   原先跟着路径一起变成 [PRIVATE_PATH]，玩家诊断里看不出是没权限、没空间还是文件不在（11-09 01007EF00011E000拷字体失败 7 行全是这样）。
#   只认这张表里的原文（不收任意尾巴，免得把路径里冒号后的名字漏出去）：末尾是「: 原文」就只换前面的路径
ERRNO_REASONS = ("Operation not permitted", "Permission denied", "No such file or directory", "File exists", "Read-only file system",
                 "No space left on device", "Is a directory", "Not a directory", "Input/output error", "Resource busy", "Device not configured",
                 "File name too long", "Too many open files", "Disc quota exceeded", "Bad file descriptor", "Directory not empty", "Invalid argument",
                 "Cross-device link", "Operation not supported", "Operation timed out", "Resource deadlock avoided", "Resource temporarily unavailable",
                 "Too many levels of symbolic links", "Bad address", "Result too large")
# macOS cp -c 在系统错误前还带系统调用名（#290：「…bfttf: clonefile failed: Cross-device link」），一起保留
_REASON_TAIL = re.compile(r'(?i): (?:(?:clonefile|fclonefileat|copyfile) failed: )?(?:' + '|'.join(map(re.escape, ERRNO_REASONS)) + r')\.?[ \t]*$')


# 我方日志在路径后面接着写的读数（诊断#343862：「存档提交 #N：<路径> 克隆 + 原子交换 25.5 ms」整段成了 [PRIVATE_PATH]，存档耗时拿不到）：
#   行尾「 <中文词 / 符号 / 数字>… <数字> <单位>」留下。尾巴里不许有英文字母（单位除外）和斜杠，带空格的英文目录名照旧算路径。
#   只用锚在行尾的短正则认读数，前面的词从后往前逐个看（线性；一条大正则在长串上会回溯到平方级以上）
_MEASURE_END = re.compile(r'(?:[ \t]+|[ \t]*[（(])[0-9][0-9.,]*[ \t]?(?:ms|µs|us|ns|s|秒|毫秒|分钟|KB|MB|GB|TB|KiB|MiB|GiB|B|%|帧|fps|次|项|条|个|块|行|款|份|lines|files)[)）\]]*\.?[ \t]*\Z')
_MEASURE_WORD = re.compile(r'[^\x00-\x7f\s]+|[+=#×~≈-]|[0-9][0-9.,]*')


def _measure_tail_start(text):
    end = _MEASURE_END.search(text)
    if not end:
        return None
    start = end.start()
    while True:
        cut = start
        while cut > 0 and text[cut - 1] not in ' \t':   # 前一个词
            cut -= 1
        word = text[cut:start]
        gap = cut
        while gap > 0 and text[gap - 1] in ' \t':
            gap -= 1
        if not word or gap == cut or not _MEASURE_WORD.fullmatch(word):
            return start
        start = gap


def _private_path_keep_reason(match):
    text = match.group(0)
    tail = _REASON_TAIL.search(text)
    at = tail.start() if tail else _measure_tail_start(text)
    if not at:
        return _private_path(match)
    return _private_path(re.match(r'.*', text[:at], re.S)) + text[at:]


def redact_text(text, *, key_values=None, preserve_identity=False) -> str:
    """Redact known values before shape rules, including formal identity fields."""
    values = load_key_values() if key_values is None else key_values
    patterns = [f'(?i:{re.escape(value)})' if re.fullmatch(r'[0-9a-fA-F]+', value) else re.escape(value)
                for value in sorted(set(values), key=len, reverse=True) if value]
    s = re.sub('|'.join(patterns), '[REDACTED]', str(text)) if patterns else str(text)
    s = KEY_LINE.sub(lambda match: match['prefix'] + '[REDACTED]', s)
    s = redact_assignments(s)
    s = re.sub(r'(?im)(authorization\s*[:=]\s*)[^\r\n]+', r'\1[REDACTED]', s)
    s = re.sub(r'(?i)(https?://)[^/\s:@]+:[^/\s@]+@', r'\1[REDACTED]@', s)
    s = re.sub(r'(?i)([?&](?:token|key|api_key|secret|password|auth|signature|session|access_token)=)[^&#\s]+', r'\1[REDACTED]', s)
    # [a-z0-9_]*_key 只从一串 [a-z0-9_] 的开头试（同上 ASSIGNMENT_KEY：串中间起能成的，从串头起也成、且更靠左，原本就轮不到它；原写法长串上平方级）
    s = re.sub(r'(?i)((?:password|passwd|secret|token|api[_-]?key|(?<![a-z0-9_])[a-z0-9_]*_key(?:_[a-z0-9]+)*|titlekek|masterkey|headerkey|cookie|serial(?:number)?|udid|(?<!(?-i:binary))uuid|imei|device[_-]?id|android[_-]?id|idfa|idfv|mac[_-]?address|uniqueidentifier|identifierforvendor)\s*["\x27]?\s*[:=]\s*["\x27]?)[^\s,"\x27;}]+', r'\1[REDACTED]', s)
    s = redact_identity(s)
    s = re.sub(r'(?:/Volumes/|/private/var/|/var/mobile/|/data/user/|/data/data/|\\\\)[^\r\n\"\x27<>]*', _private_path_keep_reason, s)
    s = re.sub(r'(?:/Users/|/home/|[A-Za-z]:[\\/](?:Users|Documents)[\\/])[^\r\n\"\x27<>]*', _private_path_keep_reason, s)
    s = re.sub(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b',
               lambda m: m[0] if _BINARY_UUID_BEFORE.search(s, max(0, m.start() - 40), m.start()) else '[DEVICE_ID]', s)
    if not preserve_identity:
        s = re.sub(r'(?i)\b[0-9a-f]{64,}\b', '[KEY_MATERIAL]', s)
    return ''.join(c if c in '\n\t' or ord(c) >= 32 and ord(c) != 127 else '\ufffd' for c in s)


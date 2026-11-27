#!/bin/bash
# ============================================================================
# change_node.sh —— EasyTier 公共节点「在线检测 / 自动更换」工具 (Batocera ES Ports)
#
# 放置位置: /userdata/roms/ports/change_node.sh   (给执行权限 755)
# 运行方式: ES 界面 -> Ports (游戏端口) -> 「EasyTier节点检测/更换」
#
# 界面按 [1] 当前状态 / [2] 检测与候选 / [3] 结论 / [4] 确认与执行 四段显示，
# 确认倒计时用 printf '\r' 在原地读秒（不滚屏、不装任何额外程序、不用 Python 做 UI）。
#
# 流程:
#   1) 检查联网 + 显示服务开关状态 + 列出当前节点
#   2) 对 easytier.toml 里的每个节点做「两阶段」探测:
#      tcp:// -> DNS 预解析(重试/多A记录) + 分散 TCP 握手采样
#      udp:// -> UDP 无连接，无法握手，只做 DNS 解析校验（界面明确标注）
#      首轮异常的节点等 8 秒后二次复核，只有复核仍异常才判失效（防抖动误报）
#   3) 若 >=2 个失效 -> 运行时从多个在线清单实时抓取节点(含 tcp / udp)，
#      合并去重后逐个实测，挑优质低延迟节点
#   4) 显示替换计划 + 18 秒原地读秒倒计时，按 ESC 取消，否则自动执行
#   5) 确认后: 停服务 -> 备份 easytier.toml.YYYYMMDDbak -> 只改失效 uri
#      -> 等 3 秒 -> 启服务。服务原本是关的就不主动开启，保持开关状态。
#
# 本工具执行频率很低，宁可多跑几十秒也不误判，探测参数取得比较宽松。
#
# 关于节点清单:
#   * 不需要人工维护，每次运行都去 NODE_LIST_URLS 里的地址实时拉取。
#   * 用户维护的 Gitee uri.txt 也作为源之一（含 udp 节点）。
#   * 前两个监控页在 Batocera 上实测 TLS 被重置，取不到就跳过不阻断。
#   * 额外自定义源: /userdata/system/easytier/node_urls.txt 里一行写一个 URL。
#   * 所有在线源都取不到可用地址时，才回退到内置 CANDIDATES 兜底。
#   * tcp://225284.xyz:11010 为「保底锚点」：延迟偏高但豁免延迟阈值，
#     已在配置里且能连通就绝不换掉，保证多台机子始终有共同会合点。
#
# 单文件自包含：辅助 Python 脚本每次运行自动生成到 /tmp（只做探测/解析/改配置，
# 界面与倒计时全部由 bash 负责，Python 不负责显示交互）。
# ============================================================================

# ------------------------- 可调参数 -------------------------
CONF="${CHANGE_NODE_CONF:-/userdata/system/easytier/easytier.toml}"
SERVICE="${CHANGE_NODE_SERVICE:-/userdata/system/services/easytier}"
WAIT_SECONDS="${CHANGE_NODE_WAIT:-18}"          # 替换前原地读秒的秒数（与 editnode 统一）
EXIT_WAIT="${CHANGE_NODE_EXIT_WAIT:-7}"         # 结论显示完，自动退出前的停留秒数
NO_RESTART="${CHANGE_NODE_NO_RESTART:-0}"      # =1 时跳过服务启停(仅自检用)
SWITCH_DELAY="${CHANGE_NODE_SWITCH_DELAY:-3}" # 改完配置后等几秒再启动服务
HELPER="/tmp/change_node_helper.py"
STATE="/tmp/change_node_state"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
# -----------------------------------------------------------

# ---------- 在 ES 界面弹出 xterm 显示执行结果 ----------
# 注意：这里刻意不接 tee 管道 —— 一旦 stdout 变成管道，printf '\r' 的原地读秒
#       会被缓冲住看不见。日志不是必需的，界面正确性优先。
if [ -z "$IN_CHANGE_NODE_XTERM" ]; then
    exec </dev/tty >/dev/tty 2>&1
    export DISPLAY=:0.0
    XTERM_BIN="/usr/bin/xterm"
    XTERM_TMP="/tmp/xterm_change_node"
    if [ -x "$XTERM_BIN" ]; then
        cp "$XTERM_BIN" "$XTERM_TMP" 2>/dev/null
        chmod 755 "$XTERM_TMP" 2>/dev/null
        USE_XTERM="$XTERM_TMP"
        [ -x "$USE_XTERM" ] || USE_XTERM="$XTERM_BIN"
    else
        USE_XTERM="$(which xterm 2>/dev/null)"
        [ -z "$USE_XTERM" ] && { echo "xterm not found"; exit 1; }
    fi
    exec env DISPLAY=:0.0 "$USE_XTERM" -fs 26 -maximized \
        -fg white -bg black -fa "DejaVuSansMono" -en UTF-8 \
        -e bash -c "IN_CHANGE_NODE_XTERM=1 bash '$SCRIPT_PATH'"
fi

# ================= xterm 内部：实际逻辑开始 =================
export DISPLAY=:0.0

# ---------- 生成自包含的 Python 辅助脚本 ----------
gen_helper() {
cat > "$HELPER" <<'PYEOF'
#!/usr/bin/env python3
# 由 change_node.sh 自动生成，勿单独编辑
import sys, os, re, socket, time, shutil, datetime, subprocess
from concurrent.futures import ThreadPoolExecutor

STATE = "/tmp/change_node_state"

# ---- 探测参数（执行频率低，宁可跑久一点也不误判）----
CURRENT_TIMES    = 5       # 首轮：已配置节点每个探测次数
RECHECK_TIMES    = 6       # 复核轮：疑似失效节点再测次数
CAND_TIMES       = 4       # 候选节点每个探测次数
MIN_OK           = 2       # 成功次数 >= 此值才算有效
ROUND1_INTERVAL  = 2.0     # 首轮每次探测间隔(秒)
RECHECK_GAP      = 8       # 首轮判异常后，等多少秒再复核
RECHECK_INTERVAL = 2.5     # 复核轮每次探测间隔(秒)
CAND_INTERVAL    = 1.2     # 候选节点每次探测间隔(秒)
STAGGER          = 0.6     # 各节点起测错开，避免同一瞬间 DNS/连接风暴
PROBE_TIMEOUT    = 3.0     # 单次 TCP 连接超时(秒)
RESOLVE_TRIES    = 3       # DNS 预解析失败重试次数
RESOLVE_GAP      = 1.0     # DNS 重试间隔(秒)
FETCH_TIMEOUT    = 8       # 单个在线清单的 curl 超时(秒)
MAX_LATENCY      = 300.0   # 平均延迟超过此值(ms)视为「延迟过高」，不选
MAX_WORKERS      = 5       # 并发探测上限
# udp:// 无法 TCP 握手，没有真实延迟；给一个略低于阈值的占位值用于排序，
# 让它排在优质 TCP 节点之后、仅作补位，界面上延迟列显示 '-' 并标注「仅验DNS」。
UDP_SORT_LATENCY = 250.0

# 官方团队推荐的长期有效节点：延迟偏高但胜在稳定，作为「保底」。
ANCHOR = "tcp://225284.xyz:11010"

OVERSEAS_HOSTS = {
    'us01.225284.xyz', 'et.0612.fun', '154.9.255.133',
}


def parse_uri(uri):
    m = re.match(r'^([a-z]+)://([^:/]+)(?::(\d+))?$', uri.strip())
    if not m:
        return None
    return (m.group(1), m.group(2), int(m.group(3)) if m.group(3) else None)


def is_oversea(uri):
    p = parse_uri(uri)
    if not p:
        return False
    h = p[1]
    return h in OVERSEAS_HOSTS or h.endswith('.225284.xyz')


# ---------------------------------------------------------------
# 在线节点清单源（运行时实时拉取，不需要人工维护）
# ---------------------------------------------------------------
WIKI = ("https://raw.githubusercontent.com/SHORiN-KiWATA/Shorin-ArchLinux-Guide"
        "/main/wiki/archlinux/%E8%99%9A%E6%8B%9F%E5%B1%80%E5%9F%9F%E7%BD%91.md")
NODE_LIST_URLS = [
    ("https://ruixuan.online/uptime/easytier", "用户指定·节点监控页"),
    ("https://upt.qicwken.top/status/easytier", "社区·节点监控页"),
    ("https://gitee.com/lhw9527/easytiernode/raw/master/uri.txt", "用户维护·Gitee uri.txt"),
    (WIKI, "社区公开节点表 GitHub"),
    ("https://cdn.jsdelivr.net/gh/SHORiN-KiWATA/Shorin-ArchLinux-Guide@main/wiki/archlinux/%E8%99%9A%E6%8B%9F%E5%B1%80%E5%9F%9F%E7%BD%91.md", "社区节点表 jsdelivr"),
    ("https://raw.githubusercontent.com/myqfeng/qt-easy-tier/master/assets/publicservers.json", "qt-easy-tier 公共服务器"),
    ("https://cdn.jsdelivr.net/gh/myqfeng/qt-easy-tier@master/assets/publicservers.json", "qt-easy-tier jsdelivr"),
    ("https://raw.githubusercontent.com/hntjb/EasyTier/main/README_CN.md", "官方 README 镜像A"),
    ("https://raw.githubusercontent.com/hongjie7202/EasyTier/refs/heads/main/README_CN.md", "官方 README 镜像B"),
]
# 可选：在下面这个文件里一行写一个 URL，即可追加自定义清单源，无需改脚本
EXTRA_URLS_FILE = os.environ.get("CN_EXTRA_URLS", "/userdata/system/easytier/node_urls.txt")

# ---------------------------------------------------------------
# 内置兜底清单：只有所有在线源都取不到可用地址时才用。
# 顺序 = 优先级；保底锚点固定在第一位。tcp / udp 都有。
# ---------------------------------------------------------------
CANDIDATES = [
    ("tcp://225284.xyz:11010",           "官方推荐·长期有效 [保底锚点]", False),
    ("tcp://easytier.weiai.org.cn:11010", "厦门电信 唯爱 [推荐]", False),
    ("tcp://183.230.36.171:11010",        "重庆移动跨网专线", False),
    ("tcp://et.sumnight.top:11010",       "社区节点(原配置)", False),
    ("tcp://47.92.208.217:11010",        "国内云主机", False),
    ("tcp://ros.scpsl.com.cn:11010",      "国内 SCPSL", False),
    ("tcp://et.basd1.de:11010",          "枣庄BGP 宇智波.希", False),
    ("udp://et.basd1.de:11010",           "UDP·Gitee 清单 [仅验DNS]", False),
    ("tcp://boi.de5.net:11010",           "国内(待确认)", False),
    ("tcp://ethd.ruixuan.online:22020",   "海波 2.7.0 端口22020", False),
    ("tcp://har.yqst.top:11010",          "邵阳电信", False),
    ("tcp://mc.yqst.top:11010",           "邵阳电信 Enterprise", False),
    ("tcp://public2.easytier.cn:54321",   "官方备用 端口54321", False),
    ("tcp://et.fpfast.top:48625",         "社区 端口48625", False),
    ("tcp://47.108.52.1:11012",           "国内 端口11012", False),
    ("tcp://sh.vomiku.com:7910",          "国内 端口7910", False),
    ("tcp://c.oee.icu:60006",             "国内 端口60006", False),
    ("tcp://103.217.186.78:11011",        "国内 端口11011", False),
    # ---- 以下为海外节点，默认不选 ----
    ("udp://us01.225284.xyz:11010",      "美国·UDP [仅验DNS]", True),
    ("tcp://154.9.255.133:11010",        "海外/未知", True),
    ("tcp://us01.225284.xyz:11010",      "美国 海波", True),
    ("tcp://et.0612.fun:11010",          "美国 罐头", True),
]

# 从任意文本(HTML / JSON / Markdown / 纯文本)里抓节点地址
URI_RE  = re.compile(r'(?:tcp|udp|ws|wss|txt)://[A-Za-z0-9._\-]+(?::\d+)?')
# 注意：负向后顾里必须包含 "." 与 "-"，否则会把 easytier.weiai.org.cn:11010
# 误拆成 weiai.org.cn:11010 这种不存在的假节点。
BARE_RE = re.compile(r'(?<![\w/.\-])([A-Za-z0-9][A-Za-z0-9._\-]*\.[A-Za-z]{2,}):(\d{2,5})(?!\d)')


def valid_node(uri):
    """保留可实测的公网 tcp:// 与 udp:// 节点（都必须带端口）"""
    p = parse_uri(uri)
    if not p:
        return False
    scheme, host, port = p
    if scheme not in ('tcp', 'udp') or not port:
        return False
    if host in ('0.0.0.0', 'localhost') or host.startswith('127.'):
        return False
    if re.match(r'^(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.', host):
        return False
    if any(c in host for c in '<> '):
        return False
    return True


def extract_uris(text):
    found = []
    for u in URI_RE.findall(text):
        found.append(u.lower())
    # 兼容 publicservers.json 里 "game.udad.top:61123" 这种不带协议前缀的写法
    # 裸地址无法知道协议，按 tcp 处理（Gitee uri.txt 里都是带协议的完整地址）
    for host, port in BARE_RE.findall(text):
        found.append('tcp://%s:%s' % (host.lower(), port))
    out, seen = [], set()
    for u in found:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out


def resolve(host, port):
    """预解析域名，返回 IPv4 地址列表，失败自动重试。
    tcp / udp 都用：把「DNS 抽风」和「节点真的连不上」区分开，
    也避免每次 connect 都重新解析（Batocera 上 DNS 偶发抖动很常见）。"""
    for i in range(RESOLVE_TRIES):
        try:
            infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_STREAM)
            ips = sorted({x[4][0] for x in infos})
            if ips:
                return ips
        except Exception:
            pass
        if i < RESOLVE_TRIES - 1:
            time.sleep(RESOLVE_GAP)
    return []


def probe_udp(uri, times):
    """UDP 是无连接协议，connect() 不会握手、永远「成功」，所以不能照搬 TCP。
    这里只做带重试的 DNS 解析校验：解析成功即视为地址有效，延迟返回 None
    （界面显示 '-' 并标注「仅验DNS」），排序时用 UDP_SORT_LATENCY 占位。"""
    p = parse_uri(uri)
    _, host, port = p
    ips = resolve(host, port)
    if not ips:
        return (0, None, 'DNSFAIL', 'UDP 域名解析失败(已重试 %d 次)' % RESOLVE_TRIES)
    return (times, None, 'OK', 'UDP 无连接，仅验 DNS 可用')


def probe(uri, times, interval):
    """返回 (成功次数, 平均延迟ms 或 None, 状态 OK/FAIL/DNSFAIL/SKIP, 备注)"""
    p = parse_uri(uri)
    if not p or not p[2]:
        return (0, None, 'SKIP', '地址不完整，不检测')
    scheme, host, port = p
    if scheme == 'udp':
        return probe_udp(uri, times)
    if scheme != 'tcp':
        return (0, None, 'SKIP', '暂不支持 %s 协议探测' % scheme)

    ips = resolve(host, port)
    if not ips:
        return (0, None, 'DNSFAIL', '域名解析失败(已重试 %d 次)' % RESOLVE_TRIES)
    ok, lats = 0, []
    for i in range(times):
        t0 = time.time()
        hit = False
        for ip in ips:
            s = socket.socket()
            s.settimeout(PROBE_TIMEOUT)
            try:
                s.connect((ip, port))
                hit = True
                lats.append((time.time() - t0) * 1000)
            except Exception:
                pass
            finally:
                try:
                    s.close()
                except Exception:
                    pass
            if hit:
                break
        if hit:
            ok += 1
        if i < times - 1:
            time.sleep(interval)
    avg = sum(lats) / len(lats) if lats else None
    note = '%d 个解析IP' % len(ips) if len(ips) > 1 else ''
    return (ok, avg, 'OK' if ok >= MIN_OK else 'FAIL', note)


def probe_staggered(args):
    """线程池入口：按序号错开起测时间，避免同一瞬间 DNS/连接风暴"""
    idx, uri, times, interval = args
    time.sleep(min(idx, 8) * STAGGER)
    return probe(uri, times, interval)


def read_uris(conf):
    out = []
    with open(conf, 'r', encoding='utf-8') as f:
        for line in f:
            m = re.match(r'^\s*uri\s*=\s*"([^"]+)"', line)
            if m:
                out.append(m.group(1))
    return out


def write_state(d):
    with open(STATE, 'w', encoding='utf-8') as f:
        for k, v in d.items():
            if isinstance(v, str):
                f.write("%s='%s'\n" % (k, v))
            else:
                f.write("%s=%s\n" % (k, v))


def fetch_one(item):
    url, label = item
    try:
        r = subprocess.run(
            ['curl', '-sS', '-L', '-m', str(FETCH_TIMEOUT), '-A', 'Mozilla/5.0', url],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=FETCH_TIMEOUT + 3)
        if r.returncode != 0:
            return (label, None)
        return (label, r.stdout.decode('utf-8', 'replace'))
    except Exception:
        return (label, None)


def collect_online_nodes():
    urls = list(NODE_LIST_URLS)
    if os.path.exists(EXTRA_URLS_FILE):
        try:
            with open(EXTRA_URLS_FILE, 'r', encoding='utf-8') as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        urls.append((line, '自定义·' + line.split('/')[2][:24]))
        except Exception:
            pass
    found, fail, ok = [], [], 0
    with ThreadPoolExecutor(max_workers=6) as ex:
        results = list(ex.map(fetch_one, urls))
    for label, text in results:
        if text is None:
            fail.append(label)
            continue
        ok += 1
        found.extend(extract_uris(text))
    out, seen = [], set()
    for u in found:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out, {'ok': ok, 'total': len(results), 'fail': fail}


def cmd_plan(conf):
    cur = read_uris(conf)
    st = {}
    print('  首轮：%d 个节点 × %d 次 / 间隔 %.1fs / 超时 %.1fs；异常节点 %ds 后复核'
          % (len(cur), CURRENT_TIMES, ROUND1_INTERVAL, PROBE_TIMEOUT, RECHECK_GAP))
    print('  tcp:// 实测握手；udp:// 无连接，只做 DNS 解析校验')
    sys.stdout.flush()
    tasks = [(i, u, CURRENT_TIMES, ROUND1_INTERVAL) for i, u in enumerate(cur)]
    with ThreadPoolExecutor(max_workers=max(1, min(MAX_WORKERS, len(cur)))) as ex:
        res1 = list(ex.map(probe_staggered, tasks))
    print('')
    print('  状态 OK=正常 / FAIL=失效 / DNSFAIL=解析失败 / SKIP=不支持的协议')
    print('  ' + '-' * 74)
    print('  序号  状态      成功      延迟     节点地址')
    for i, (u, (ok, avg, flag, note)) in enumerate(zip(cur, res1), 1):
        lat = ('%.0fms' % avg) if avg is not None else '-'
        print('  [%-2d] %-8s %-9s %-9s %s%s'
              % (i, flag, '%d/%d' % (ok, CURRENT_TIMES), lat, u,
                 ('  (%s)' % note) if note else ''))

    # 首轮异常的节点一律先复核，绝不直接判死刑
    suspect = [(u, r) for u, r in zip(cur, res1) if r[2] not in ('OK', 'SKIP')]
    recheck = {}
    if suspect:
        print('')
        print('  [!] %d 个节点首轮异常，%d 秒后二次复核（排除抖动 / DNS 抽风）...'
              % (len(suspect), RECHECK_GAP))
        sys.stdout.flush()
        time.sleep(RECHECK_GAP)
        t2 = [(i, u, RECHECK_TIMES, RECHECK_INTERVAL) for i, (u, _) in enumerate(suspect)]
        with ThreadPoolExecutor(max_workers=max(1, min(MAX_WORKERS, len(suspect)))) as ex:
            rr = list(ex.map(probe_staggered, t2))
        recheck = dict((u, r) for (u, _), r in zip(suspect, rr))
        print('  复核结果：')
        for u, r1 in suspect:
            r2 = recheck[u]
            print('    %s  首轮 %d/%d[%s] -> 复核 %d/%d[%s] → %s'
                  % (u, r1[0], CURRENT_TIMES, r1[2],
                     r2[0], RECHECK_TIMES, r2[2],
                     '正常(抖动已忽略)' if r2[2] == 'OK' else '失效'))
            if r1[3]:
                print('        首轮: %s' % r1[3])
            if r2[3]:
                print('        复核: %s' % r2[3])

    failed = []
    for u, r1 in zip(cur, res1):
        if r1[2] in ('OK', 'SKIP'):
            continue
        r2 = recheck.get(u)
        if r2 is None or r2[2] != 'OK':
            failed.append(u)
    ignored = sum(1 for u, _ in suspect if recheck.get(u) and recheck[u][2] == 'OK')
    print('')
    print('  最终判定：%d 个节点失效%s'
          % (len(failed), '（复核已排除 %d 个瞬时抖动误报）' % ignored if ignored else ''))
    st['TOTAL'] = len(cur)
    st['FAILED'] = len(failed)
    st['FAILED_URIS'] = ' '.join(failed)
    st['NEED_ACTION'] = 1 if len(failed) >= 2 else 0

    if not st['NEED_ACTION']:
        st['PICK_COUNT'] = 0
        st['PICKS'] = ''
        write_state(st)
        return 0

    print('')
    print('  >>> %d 个节点失效，实时拉取在线节点清单 ...' % len(failed))
    sys.stdout.flush()
    online, src = collect_online_nodes()
    if isinstance(src, dict):
        print('  在线源 %d/%d 可用，合并去重 %d 个地址'
              % (src['ok'], src['total'], len(online)))
        if src['fail']:
            print('  取不到：%s%s' % ('、'.join(src['fail'][:4]),
                                    ' ...' if len(src['fail']) > 4 else ''))
    else:
        print('  在线源共取得 %d 个不重复地址' % len(online))
    sys.stdout.flush()

    online_set = set(online)
    pool, seen = [], set(cur)
    for u in online:
        if u in seen or not valid_node(u):
            continue
        seen.add(u)
        pool.append(u)
    used_fallback = False
    if not pool:
        used_fallback = True
        print('  [!] 在线清单未取得可用地址，回退到内置兜底清单。')
        for u, desc, oversea in CANDIDATES:
            if u in seen or not valid_node(u):
                continue
            seen.add(u)
            pool.append(u)
    n_udp = sum(1 for u in pool if parse_uri(u) and parse_uri(u)[0] == 'udp')
    print('  待实测候选：%d 个（tcp %d / udp %d），来源：%s'
          % (len(pool), len(pool) - n_udp, n_udp,
             '内置兜底' if used_fallback else '在线实时清单'))
    print('  候选实测：每个 %d 次 / 间隔 %.1fs ...' % (CAND_TIMES, CAND_INTERVAL))
    sys.stdout.flush()
    tc = [(i, u, CAND_TIMES, CAND_INTERVAL) for i, u in enumerate(pool)]
    with ThreadPoolExecutor(max_workers=max(1, min(MAX_WORKERS, len(pool)))) as ex:
        cres = list(ex.map(probe_staggered, tc))
    print('')
    print('  实测结果（延迟 <= %.0fms 可选；保底锚点豁免）：' % MAX_LATENCY)
    print('  ' + '-' * 74)
    scored = []
    for u, (ok, avg, flag, reason) in zip(pool, cres):
        tag = '在线' if u in online_set else '内置'
        pp = parse_uri(u)
        is_udp = bool(pp and pp[0] == 'udp')
        if u == ANCHOR:
            extra = ' [保底锚点]'
        elif is_oversea(u):
            extra = ' [海外]'
        else:
            extra = ''
        if flag != 'OK':
            note = '不可用' + ('(%s)' % reason if reason else '')
        elif u != ANCHOR and avg is not None and avg > MAX_LATENCY:
            note = '延迟过高'
        elif avg is None and not is_udp:
            note = '不可用(无延迟数据)'
        else:
            note = '可选' + (' [UDP·仅验DNS]' if is_udp else '') + extra
            scored.append((u, ok, avg if avg is not None else UDP_SORT_LATENCY, is_udp))
        lat = ('%.0fms' % avg) if avg is not None else '-'
        print('  %-4s %-8s %-9s %-18s %s'
              % (tag, '%d/%d' % (ok, CAND_TIMES), lat, note, u))
    print('  ' + '-' * 74)
    # 优先级：国内优质 TCP(0) -> 保底锚点(1) -> UDP 补位(1.5) -> 海外(2)
    # UDP 只验 DNS，可靠性弱于锚点，所以即使占位延迟更低也必须排在锚点之后。
    def rank(x):
        u, ok, avg, is_udp = x
        if u == ANCHOR:
            group = 1
        elif is_oversea(u):
            group = 2
        elif is_udp:
            group = 1.5
        else:
            group = 0
        return (group, -ok, avg)
    scored.sort(key=rank)
    picks = [u for u, _, _, _ in scored[:len(failed)]]
    if picks:
        print('  选中 %d 个节点：' % len(picks))
        for u in picks:
            print('    -> ' + u + ('  [保底锚点]' if u == ANCHOR else ''))
    else:
        print('  (无可用新节点)')
    st['PICK_COUNT'] = len(picks)
    st['PICKS'] = ' '.join(picks)
    write_state(st)
    return 0


def cmd_apply(conf, failed_s, picks_s):
    failed, picks = failed_s.split(), picks_s.split()
    if not failed or len(picks) < len(failed):
        print('  参数不足，取消替换（未修改任何文件）')
        return 1
    pairs = list(zip(failed, picks))
    day = datetime.datetime.now().strftime('%Y%m%d')
    bak = conf + '.' + day + 'bak'
    n = 2
    while os.path.exists(bak):
        bak = conf + '.' + day + 'bak_%d' % n
        n += 1
    shutil.copy2(conf, bak)
    print('  备份完成: %s' % os.path.basename(bak))

    with open(conf, 'r', encoding='utf-8', newline='') as f:
        lines = f.readlines()
    mapping = dict(pairs)
    out, changed = [], 0
    for line in lines:
        m = re.match(r'^(\s*uri\s*=\s*")([^"]+)(".*)$', line.rstrip('\r\n'))
        if m and m.group(2) in mapping:
            newu = mapping[m.group(2)]
            out.append(m.group(1) + newu + m.group(3) + '\n')
            print('  替换: %s  ->  %s' % (m.group(2), newu))
            changed += 1
        else:
            out.append(line)
    with open(conf, 'w', encoding='utf-8', newline='\n') as f:
        f.writelines(out)
    print('  共替换 %d 个节点；hostname / ipv4 / 网络名 / 密码 / 注释均未改动。' % changed)
    return 0 if changed == len(pairs) else 1


if __name__ == '__main__':
    c = sys.argv[1]
    if c == 'plan':
        sys.exit(cmd_plan(sys.argv[2]))
    elif c == 'apply':
        sys.exit(cmd_apply(sys.argv[2], sys.argv[3], sys.argv[4]))
    else:
        print('unknown command')
        sys.exit(2)
PYEOF
    [ -s "$HELPER" ]
}

# ---------- 结论显示完：一行提示 + 直接等待，不再逐秒刷屏 ----------
hold_exit() {
    local n="${1:-$EXIT_WAIT}"
    echo "  ${n} 秒后自动退出 ..."
    sleep "$n"
}

# ============================ 主流程 ============================
clear 2>/dev/null || true
echo "============================================================"
echo "   EasyTier 节点检测 / 更换"
echo "============================================================"
echo ""

if [ ! -f "$CONF" ]; then
    echo "  [X] 找不到配置文件: $CONF"
    hold_exit; exit 1
fi
if ! gen_helper; then
    echo "  [X] 无法生成辅助脚本，无法继续。"
    hold_exit; exit 1
fi

# ---- [1] 当前状态 ----
echo "[1] 当前状态"
ONLINE=0
curl -sS -m 6 -o /dev/null https://www.baidu.com 2>/dev/null && ONLINE=1
if [ "$ONLINE" -eq 0 ]; then
    ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && ONLINE=1
fi
if [ "$ONLINE" -eq 0 ]; then
    echo "  互联网        : 不通"
    echo "  [X] 未检测到可用互联网，请先连上网络再运行本工具。"
    hold_exit
    exit 0
fi
echo "  互联网        : 可达"
if pgrep -x easytier-core >/dev/null 2>&1; then
    echo "  EasyTier 服务 : 运行中"
    SVC_WAS_RUNNING=1
else
    echo "  EasyTier 服务 : 未运行（不会主动开启，只写配置）"
    SVC_WAS_RUNNING=0
fi
echo "  当前节点      :"
grep 'uri[[:space:]]*=' "$CONF" 2>/dev/null \
    | sed 's/^[[:space:]]*uri[[:space:]]*=[[:space:]]*//; s/"//g; s/^/    /' | head -6
echo ""

# ---- [2] 检测当前节点 + 在线获取候选 ----
echo "[2] 检测与候选"
rm -f "$STATE"
python3 "$HELPER" plan "$CONF"
if [ ! -s "$STATE" ]; then
    echo "  [X] 检测失败，无法继续。"
    hold_exit; exit 1
fi
# shellcheck disable=SC1090
source "$STATE"
echo ""

# ---- [3] 结论 ----
echo "[3] 结论"
if [ "${NEED_ACTION:-0}" -ne 1 ]; then
    echo "  共 ${TOTAL:-0} 个节点，其中 ${FAILED:-0} 个异常，不影响组网。"
    echo "  规则：只有 >= 2 个节点失效才触发更换，本次无需修改。"
    hold_exit
    exit 0
fi
if [ "${PICK_COUNT:-0}" -lt 1 ]; then
    echo "  ${FAILED} 个节点已失效，但没有找到可用的新节点。"
    echo "  按设定：不备份、不修改、不重启，保持原配置。可稍后重试。"
    hold_exit
    exit 0
fi
if [ "$PICK_COUNT" -lt "$FAILED" ]; then
    echo "  注意：只找到 ${PICK_COUNT} 个可用新节点，少于 ${FAILED} 个失效节点，"
    echo "        将只替换前 ${PICK_COUNT} 个。"
fi
echo "  计划替换（只改失效节点，其余配置一字不动）："
old_arr=( $FAILED_URIS )
new_arr=( $PICKS )
APPLY_OLDS=""
APPLY_NEWS=""
for ((i=0; i<PICK_COUNT; i++)); do
    echo "    ${old_arr[$i]}  ->  ${new_arr[$i]}"
    APPLY_OLDS="$APPLY_OLDS ${old_arr[$i]}"
    APPLY_NEWS="$APPLY_NEWS ${new_arr[$i]}"
done
echo "  备份文件名: $(basename "$CONF").$(date +%Y%m%d)bak"
if [ "$SVC_WAS_RUNNING" -eq 1 ]; then
    echo "  执行顺序：停止服务 -> 备份并改配置 -> 等 ${SWITCH_DELAY} 秒 -> 启动服务。"
else
    echo "  服务原本未运行：只写入配置，不启动服务。"
fi
echo ""

# ---- [4] 确认与执行 ----
echo "[4] 确认与执行"
echo "  如不需要修改，请按 [ESC] 键"
# 纯 bash 原地读秒：\r 回车回到行首覆盖同一行，%2d 固定宽度不留残影。
# 前提：xterm 包装里没有 tee 管道，stdout 直连 pty 才看得见。
CANCELLED=0
n="$WAIT_SECONDS"
while [ "$n" -gt 0 ]; do
    [ -t 1 ] && printf '\r    %2d 秒后开始替换（按 ESC 取消）   ' "$n"
    key=""
    if read -s -n 1 -t 1 key 2>/dev/null; then
        [ "$key" = $'\e' ] && { CANCELLED=1; break; }
    fi
    # stdin 不是终端(自检/重定向)时 read 不等，补 1 秒保证窗口时长准确
    [ -t 0 ] || sleep 1
    n=$((n - 1))
done
echo ""
if [ "$CANCELLED" -eq 1 ]; then
    echo "  >>> 已取消：未停服务、未备份、未修改。3 秒后退出。"
    sleep 3
    exit 0
fi

echo "  >>> 开始执行：停止服务 -> 备份并改配置 -> 启动服务 ..."
if [ "$NO_RESTART" -eq 1 ]; then
    echo "  [自检模式] 跳过服务启停。"
elif [ "$SVC_WAS_RUNNING" -eq 1 ]; then
    "$SERVICE" stop >/dev/null 2>&1
    sleep 1
fi

python3 "$HELPER" apply "$CONF" "$APPLY_OLDS" "$APPLY_NEWS"
APPLY_RC=$?
echo ""
if [ "$APPLY_RC" -ne 0 ]; then
    echo "  [X] 替换未成功，请检查上面的输出。"
    if [ "$NO_RESTART" -ne 1 ] && [ "$SVC_WAS_RUNNING" -eq 1 ]; then
        echo "  正在恢复 EasyTier 服务..."
        "$SERVICE" start >/dev/null 2>&1
    fi
    sleep 6
    exit 1
fi

if [ "$NO_RESTART" -eq 1 ]; then
    echo "  [自检模式] 跳过服务启动。"
elif [ "$SVC_WAS_RUNNING" -eq 1 ]; then
    sleep "$SWITCH_DELAY"
    "$SERVICE" start >/dev/null 2>&1
    echo "  EasyTier 服务已启动（若本机配置了开机延迟，请耐心等待）。"
else
    echo "  服务原本未运行：未主动启动，配置已写入，下次启用服务时生效。"
fi
echo ""
echo "  >>> 完成。${EXIT_WAIT} 秒后自动退出 ..."
sleep "$EXIT_WAIT"
exit 0

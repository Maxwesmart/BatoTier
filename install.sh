#!/bin/bash
# ============================================================================
# install.sh —— EasyTier for Batocera 一键安装（DHCP / MC 组播修复 ）
#
# 用法：把整个发布包（install.sh + roms/ + system/）复制到 Batocera 的某个目录，
#       然后在 SSH 终端里执行：
#           cd /userdata/xxx/EasyTier包目录
#           chmod +x install.sh
#           ./install.sh
#
# EasyTier core 在 Batocera 上本身稳定，去掉守护进程可避免误判/重启风暴。
# MC 组播修复（224.0.2.60/32 + tun0 MULTICAST）保留在服务脚本里，功能不受影响。
#
# 设计目标：
#   * 不需要手工改 toml 里的 IP 末位 —— DHCP 模式，IP 自动分配
#   * 不需要手工写 hostname —— 自动读取 /userdata/system/batocera.conf 的
#     system.hostname= 值（读不到再用 `hostname` 命令兜底）
#   * 配置向导只问两件事：网络名称、网络密码（100 秒超时自动用默认值，
#     非交互终端直接用默认值）—— 同一网络所有机子必须一致
#   * 节点优先从本项目 GitHub 仓库的 uri.txt 拉取，失败回退 Gitee，再失败用内置兜底
#   * 所有 sh / 二进制统一 chmod 755 —— SMB 复制会丢执行位，这里统一补回来
#   * 注册 Batocera 服务并开机自启，装完【直接启动】
#
# 二进制来源：安装时从 GitHub API 自动识别【最新 Pre-release】并按架构下载，
# 不写死版本号；发布包本身不含 easytier-core / easytier-cli（避免体积大、版本陈旧）。
# 下载后强制用 GitHub API 提供的官方 SHA256 校验，校验不过就拒绝安装。
# 支持 x86_64 / aarch64 / armv7 / armhf / arm / mips / mipsel / riscv64 /
# ppc64le / loongarch64（与官方 Release 资产一一对应）。
# ============================================================================

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
USERDATA="/userdata"
ET_DIR="$USERDATA/system/easytier"
SVC_DIR="$USERDATA/system/services"
PORTS_DIR="$USERDATA/roms/ports"
CONF="$ET_DIR/easytier.toml"
BTC_CONF="$USERDATA/system/batocera.conf"
# 节点清单：安装时优先拉本项目 Gitee 仓库的 uri.txt（国内快），再试 GitHub 同名文件；
# 日常维护仍在 Gitee 老地址，都取不到用内置兜底。两个源内容一致，随便哪个都能用。
NODE_URLS=(
    "https://gitee.com/lhw9527/BatoTier/raw/main/uri.txt"
    "https://raw.githubusercontent.com/Maxwesmart/BatoTier/main/uri.txt"
    "https://gitee.com/lhw9527/easytiernode/raw/master/uri.txt"
)
# EasyTier 官方 releases API —— 自动识别最新 Pre-release，不写死版本号
ET_RELEASES_API="https://api.github.com/repos/EasyTier/EasyTier/releases?per_page=3"
ET_RELEASES_MIRROR="https://gh-proxy.com/https://api.github.com/repos/EasyTier/EasyTier/releases?per_page=3"
WIZARD_WAIT="${EDITNODE_WIZARD_WAIT:-100}"   # 配置向导超时秒数，超时用默认值
ET_TMP="/tmp/easytier_dl_$$"
ET_CACHE="/userdata/system/.cache/easytier"   # 校验通过的官方包缓存，重装/多台机子复用
# 内置兜底节点（Gitee 取不到时使用；与发布包 examples 一致）
FALLBACK_NODES=(
    "tcp://easytier.weiai.org.cn:11010"
    "tcp://225284.xyz:11010"
    "udp://et.basd1.de:11010"
)

# ---------- 小工具 ----------
hr() { echo "------------------------------------------------------------"; }
die() { echo "  [X] $*"; echo "安装中止，未做任何改动。"; exit 1; }

hr
echo "   EasyTier for Batocera  一键安装（DHCP / MC 组播修复版）"
hr
echo "  源目录   : $SRC_DIR"
echo "  目标目录 : $ET_DIR"
echo ""

# ---------- 0. 前置检查 ----------
[ "$(id -u)" -eq 0 ] || die "请用 root 运行（Batocera SSH 默认就是 root）"
[ -d "$USERDATA" ] || die "找不到 $USERDATA，这不像 Batocera 系统"
[ -f "$SRC_DIR/system/services/easytier" ] || die "源包缺少 system/services/easytier"
[ -f "$SRC_DIR/roms/ports/change_node.sh" ] || die "源包缺少 roms/ports/change_node.sh"

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|amd64)   ET_ARCH="x86_64" ;;
    aarch64|arm64)  ET_ARCH="aarch64" ;;
    armv7l|armv7)   ET_ARCH="armv7" ;;
    armv6l|armhf)   ET_ARCH="armhf" ;;
    arm)            ET_ARCH="arm" ;;
    mips)           ET_ARCH="mips" ;;
    mipsel)         ET_ARCH="mipsel" ;;
    riscv64)        ET_ARCH="riscv64" ;;
    ppc64le)        ET_ARCH="ppc64le" ;;
    loongarch64)    ET_ARCH="loongarch64" ;;
    *) die "未知架构 $ARCH，无法自动匹配 EasyTier 官方包。" ;;
esac
echo "  [1/9] 架构检查通过：$ARCH -> 官方包 $ET_ARCH"

# ---------- 1b. 自动识别最新 Pre-release 并下载（断点续传 + SHA256 校验）----------
mkdir -p "$ET_TMP" || die "创建临时目录失败"
echo "  正在查询 EasyTier 官方最新 Pre-release ..."
# 先把 API 结果存文件（heredoc 会占用 stdin，不能让 python3 - 直接读管道）
# 加 --compressed：API 原始 JSON 约 400~800KB，gzip 后仅 40KB 左右，慢网也能秒下
curl -sS --compressed -L -m 45 "$ET_RELEASES_API" -o "$ET_TMP/releases.json" 2>/dev/null
if ! python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "$ET_TMP/releases.json" 2>/dev/null; then
    echo "        GitHub API 直连失败/超时，尝试 gh-proxy 镜像 ..."
    curl -sS --compressed -L -m 45 "$ET_RELEASES_MIRROR" -o "$ET_TMP/releases.json" 2>/dev/null
fi
cat > "$ET_TMP/pick.py" <<'PYEOF'
import sys, json
arch = sys.argv[2]
try:
    data = json.load(open(sys.argv[1], encoding='utf-8'))
except Exception:
    sys.exit(1)
rels = [r for r in data if isinstance(r, dict) and r.get("prerelease") and not r.get("draft")]
rels.sort(key=lambda r: r.get("published_at") or "", reverse=True)
for r in rels:
    for a in r.get("assets", []):
        n = a.get("name", "")
        if n.startswith("easytier-linux-%s-" % arch) and n.endswith(".zip"):
            print("|".join([r.get("tag_name", ""), n,
                  (a.get("digest") or "").split(":")[-1], a.get("browser_download_url", "")]))
            sys.exit(0)
sys.exit(1)
PYEOF
META=$(python3 "$ET_TMP/pick.py" "$ET_TMP/releases.json" "$ET_ARCH" 2>/dev/null)
[ -n "$META" ] || die "无法从 GitHub API 取得最新 Pre-release 的 Linux 包信息。"
IFS='|' read -r ET_VERSION ET_ZIP EXPECT_SHA ET_OFFICIAL_URL <<EOF
$META
EOF
[ ${#EXPECT_SHA} -eq 64 ] && [ -n "$ET_OFFICIAL_URL" ] || die "官方包校验信息不完整，拒绝安装未校验的二进制。"
echo "        最新版本: $ET_VERSION  包: $ET_ZIP"
echo "        官方 SHA256: $EXPECT_SHA"
DL_URLS=(
    "$ET_OFFICIAL_URL"
    "https://gh-proxy.com/$ET_OFFICIAL_URL"
    "https://ghproxy.net/$ET_OFFICIAL_URL"
)
echo "  正在下载 $ET_ZIP（约 25~46MB，请耐心）..."

# 先查本地缓存（之前下载并校验通过的包）——重装或装下一台机子时免下载
DL_OK=0
mkdir -p "$ET_CACHE" 2>/dev/null
if [ -s "$ET_CACHE/$ET_ZIP" ]; then
    CACHE_SHA=$(sha256sum "$ET_CACHE/$ET_ZIP" 2>/dev/null | awk '{print $1}')
    if [ "$CACHE_SHA" = "$EXPECT_SHA" ]; then
        echo "        [OK] 本地缓存命中且校验通过，跳过下载"
        cp -f "$ET_CACHE/$ET_ZIP" "$ET_TMP/$ET_ZIP"
        DL_OK=1
    else
        echo "        缓存文件校验不符，忽略并重新下载"
    fi
fi
if [ "$DL_OK" -ne 1 ]; then
for BASE in "${DL_URLS[@]}"; do
    URL="$BASE"   # DL_URLS 里已是完整地址（含文件名），不要再拼 $ET_ZIP
    echo "        尝试下载源: $BASE"
    rm -f "$ET_TMP/$ET_ZIP"
    echo "        （下载 31MB，慢网可能要几分钟，进度见下方）"
    curl -L -m 180 -o "$ET_TMP/$ET_ZIP" "$URL" 2>/dev/null
    # 断点续传补 20 轮 x 120s（慢网 14KB/s 也能累计下满 31MB）
    for try in $(seq 1 20); do
        GOT=$(stat -c %s "$ET_TMP/$ET_ZIP" 2>/dev/null || echo 0)
        [ "$GOT" -gt 31108806 ] && break
        echo "        续传第 $try 轮，已收到 $((GOT/1048576)) MB ..."
        curl -sS -L -C - -m 120 -o "$ET_TMP/$ET_ZIP" "$URL" 2>/dev/null || true
    done
    GOT_SHA=$(sha256sum "$ET_TMP/$ET_ZIP" 2>/dev/null | awk '{print $1}')
    if [ "$GOT_SHA" = "$EXPECT_SHA" ]; then
        echo "        [OK] 下载完成且 SHA256 与官方一致（$(stat -c %s "$ET_TMP/$ET_ZIP") 字节）"
        cp -f "$ET_TMP/$ET_ZIP" "$ET_CACHE/$ET_ZIP" 2>/dev/null || true
        DL_OK=1; break
    else
        echo "        [X] 该源校验不符，换下一个源"
    fi
done
fi
[ "$DL_OK" -eq 1 ] || die "所有下载源都拿不到校验通过的二进制。请检查网络后重试。"

unzip -oq "$ET_TMP/$ET_ZIP" -d "$ET_TMP/unzip" 2>/dev/null || die "解压失败，安装包可能损坏"
ET_CORE_SRC=$(find "$ET_TMP/unzip" -type f -name easytier-core | head -1)
ET_CLI_SRC=$(find "$ET_TMP/unzip" -type f -name easytier-cli | head -1)
[ -n "$ET_CORE_SRC" ] && [ -n "$ET_CLI_SRC" ] || die "包内找不到 easytier-core / easytier-cli"
echo "        已定位二进制：$(basename "$ET_CORE_SRC") / $(basename "$ET_CLI_SRC")"

# ---------- 1. 取 hostname ----------
ET_HOST=""
if [ -f "$BTC_CONF" ]; then
    ET_HOST=$(grep -E '^[[:space:]]*system\.hostname[[:space:]]*=' "$BTC_CONF" 2>/dev/null \
        | head -1 | sed 's/^[^=]*=//; s/^[[:space:]]*//; s/[[:space:]]*$//')
fi
if [ -z "$ET_HOST" ]; then
    ET_HOST="$(hostname 2>/dev/null)"
fi
[ -z "$ET_HOST" ] && ET_HOST="BATOCERA"
echo "  [3/9] 主机名（自动读取）: $ET_HOST"

# ---------- 2. 配置向导：最多等 100 秒，超时/非交互直接用默认值 ----------
echo ""
hr
echo "   配置向导 —— 只需填写两项（${WIZARD_WAIT} 秒内不输入自动用默认值）"
hr
echo "  同一网络的所有机子必须填【完全一样】的网络名和密码，否则无法组网。"
echo "  默认值：network_name=BatoceraMC   network_secret=xxxxxxxx"
echo "  装好后可随时编辑 /userdata/system/easytier/easytier.toml 修改，无需重装。"
echo ""

NET_NAME="BatoceraMC"
NET_SECRET="xxxxxxxx"
if [ -t 0 ]; then
    echo "  网络名称 [BatoceraMC]: "
    read -t "$WIZARD_WAIT" -r IN_NAME || true
    [ -n "$IN_NAME" ] && NET_NAME="$IN_NAME"
    echo "  网络密码 [xxxxxxxx]: "
    read -t "$WIZARD_WAIT" -r IN_SECRET || true
    [ -n "$IN_SECRET" ] && NET_SECRET="$IN_SECRET"
else
    echo "  非交互终端（stdin 非 tty），直接使用默认值。"
fi
NET_NAME="$(echo "$NET_NAME" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
NET_SECRET="$(echo "$NET_SECRET" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
[ -n "$NET_NAME" ] || NET_NAME="BatoceraMC"
[ -n "$NET_SECRET" ] || NET_SECRET="xxxxxxxx"
# toml 里是双引号字符串，含引号/反斜杠会破坏语法 —— 直接拒绝，避免转义坑
case "$NET_NAME$NET_SECRET" in
    *'"'*|*'\'*) die "网络名或密码含有引号/反斜杠，会导致配置文件语法错误，请换用普通字符。" ;;
esac
echo ""
echo "  将写入：hostname=$ET_HOST  network_name=$NET_NAME  network_secret=********"
echo ""

# ---------- 3. 拉取节点 ----------
echo "  [4/9] 拉取公共节点清单 ..."
NODES=()
NODE_SRC=""
for U in "${NODE_URLS[@]}"; do
    RAW=$(curl -sS -L -m 12 -A 'Mozilla/5.0' "$U" 2>/dev/null | tr -d '\r')
    [ -z "$RAW" ] && continue
    TMP_NODES=()
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case "$line" in
            tcp://*|udp://*) TMP_NODES+=("$line") ;;
        esac
    done <<EOF
$RAW
EOF
    if [ "${#TMP_NODES[@]}" -eq 3 ]; then
        NODES=("${TMP_NODES[@]}")
        NODE_SRC="$U"
        break
    fi
done
if [ "${#NODES[@]}" -eq 3 ]; then
    echo "        从 $NODE_SRC 取到 3 个节点："
else
    echo "        在线清单取不到或不是 3 行，用内置兜底节点。"
    NODES=("${FALLBACK_NODES[@]}")
fi
for u in "${NODES[@]}"; do echo "          $u"; done

# ---------- 4. 备份旧配置 ----------
if [ -f "$CONF" ]; then
    BAK="$CONF.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CONF" "$BAK" && echo "  [5/9] 旧配置已备份: $(basename "$BAK")"
else
    echo "  [5/9] 没有旧配置（首次安装）"
fi

# ---------- 5. 复制文件 ----------
echo "  [6/9] 复制文件到 /userdata ..."
mkdir -p "$ET_DIR" "$SVC_DIR" "$PORTS_DIR/images" || die "创建目录失败"
cp -f "$ET_CORE_SRC" "$ET_DIR/easytier-core" || die "复制 easytier-core 失败"
cp -f "$ET_CLI_SRC"  "$ET_DIR/easytier-cli"  || die "复制 easytier-cli 失败"
# 固定 IP 示例配置也随包安装，方便需要静态 IP 的机子直接取用（只读，不改运行配置）
cp -f "$SRC_DIR/system/easytier/easytier.toml.ipv4" "$ET_DIR/" 2>/dev/null \
    || echo "        [!] 源包缺 easytier.toml.ipv4，跳过（不影响 DHCP 安装）"
cp -f "$SRC_DIR/system/services/easytier"      "$SVC_DIR/" || die "复制服务脚本失败"
cp -f "$SRC_DIR/roms/ports/change_node.sh"     "$PORTS_DIR/" || die "复制 change_node.sh 失败"
cp -f "$SRC_DIR/roms/ports/editnode.sh"        "$PORTS_DIR/" || die "复制 editnode.sh 失败"
# gamelist.xml 不能整体覆盖 —— 会冲掉机子上原有的几十条游戏记录！
# 幂等处理：不存在才创建；存在则只追加/更新这两条 ES 工具条目。
python3 - "$SRC_DIR/roms/ports/gamelist.xml" "$PORTS_DIR/gamelist.xml" <<'PYEOF'
import sys, os, re, shutil
src, dst = sys.argv[1], sys.argv[2]
template = open(src, encoding='utf-8').read()
def entries(text):
    out = {}
    for m in re.finditer(r'<game>.*?</game>', text, re.S):
        block = m.group(0)
        pm = re.search(r'<path>(.*?)</path>', block)
        if pm:
            out[pm.group(1)] = block
    return out
tpl = entries(template)
wanted = ['./change_node.sh', './editnode.sh']
if not os.path.exists(dst):
    shutil.copyfile(src, dst)
    print('        gamelist.xml 不存在，已按模板创建')
else:
    text = open(dst, encoding='utf-8').read()
    cur = entries(text)
    changed = False
    for key in wanted:
        block = tpl.get(key)
        if not block:
            continue
        if key in cur:
            # 已存在：只更新 desc（保留用户/ES 已有的 playcount 等统计）
            m = re.search(r'<desc>.*?</desc>', block, re.S)
            if m:
                desc = m.group(0)
                def repl(mm):
                    return desc
                new_cur, n = re.subn(r'<desc>.*?</desc>', repl, cur[key], count=1, flags=re.S)
                if n and new_cur != cur[key]:
                    text = text.replace(cur[key], new_cur); changed = True
        else:
            # 不存在：插入到 </gameList> 前
            idx = text.rfind('</gameList>')
            if idx == -1:
                print('        [!] gamelist.xml 缺 </gameList>，跳过追加')
                break
            text = text[:idx] + block + '\n' + text[idx:]
            changed = True
    if changed:
        shutil.copyfile(dst, dst + '.bak-before-addon')
        open(dst, 'w', encoding='utf-8', newline='\n').write(text)
        print('        gamelist.xml 已追加/更新两条工具条目（原文件已备份）')
    else:
        print('        gamelist.xml 两条工具条目已是最新，未改动')
PYEOF
[ $? -eq 0 ] || die "处理 gamelist.xml 失败"
cp -f "$SRC_DIR/roms/ports/images/"*.png       "$PORTS_DIR/images/" 2>/dev/null || echo "        （图片复制跳过：源目录无匹配文件）"

# ---------- 6. 赋执行权限（关键：SMB 复制会丢执行位）----------
echo "  [7/9] 赋予执行权限 ..."
chmod 755 "$ET_DIR/easytier-core" "$ET_DIR/easytier-cli" \
          "$SVC_DIR/easytier" \
          "$PORTS_DIR/change_node.sh" "$PORTS_DIR/editnode.sh" || die "chmod 失败"
chmod 644 "$CONF" "$ET_DIR/easytier.toml.ipv4" "$PORTS_DIR/gamelist.xml" "$PORTS_DIR/images/"*.png 2>/dev/null || true
# 服务脚本 start() 里也有自检 chmod，这里再兜一层，双保险

# ---------- 7. 生成 DHCP 版 toml ----------
echo "  [8/9] 生成 easytier.toml（DHCP 模式，无 ipv4 字段）..."
PEER_BLOCK=""
for u in "${NODES[@]}"; do
    PEER_BLOCK="${PEER_BLOCK}[[peer]]"$'\n'"uri = \"$u\""$'\n'$'\n'
done
cat > "$CONF" <<EOF
# EasyTier 配置 —— 由 install.sh 自动生成
# hostname 取自 Batocera 系统设置；dhcp=true 表示 IP 由网络自动分配，
# 因此没有 ipv4 字段 —— 请勿手工添加，否则 DHCP 与静态 IP 冲突。
hostname = "$ET_HOST"
dhcp = true
listeners = [
    "tcp://0.0.0.0:11010",
    "udp://0.0.0.0:11010",
]
tcp_whitelist = []
udp_whitelist = []

[network_identity]
network_name = "$NET_NAME"
network_secret = "$NET_SECRET"

$PEER_BLOCK[flags]
EOF
chmod 644 "$CONF"
echo "        节点数: ${#NODES[@]}，hostname: $ET_HOST"

# ---------- 8. 环境准备 + 注册服务 ----------
echo "  [9/9] 环境准备 + 注册服务 ..."
# /dev/net/tun：部分系统没有，EasyTier 需要它建 tun0
if [ ! -c /dev/net/tun ]; then
    mkdir -p /dev/net
    mknod /dev/net/tun c 10 200 2>/dev/null && chmod 600 /dev/net/tun \
        && echo "        已创建 /dev/net/tun" \
        || echo "        [!] 创建 /dev/net/tun 失败，若启动异常请手动处理"
else
    echo "        /dev/net/tun 已存在"
fi
# IP 转发（MC 组播需要）
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
if command -v batocera-services >/dev/null 2>&1; then
    batocera-services enable easytier >/dev/null 2>&1 || true
    echo "        已注册开机自启服务 easytier"
else
    echo "        [!] 找不到 batocera-services，服务未注册（请检查系统版本）"
fi

# ---------- 装后自检 ----------
echo ""
hr
echo "   安装自检"
hr
OK=1
for f in "$ET_DIR/easytier-core" "$ET_DIR/easytier-cli" \
         "$SVC_DIR/easytier" "$PORTS_DIR/change_node.sh" "$PORTS_DIR/editnode.sh"; do
    [ -x "$f" ] || { echo "  [X] 缺少执行权限: $f"; OK=0; }
done
[ -f "$CONF" ] || { echo "  [X] 配置文件缺失"; OK=0; }
[ -f "$ET_DIR/easytier.toml.ipv4" ] || { echo "  [X] 固定 IP 示例配置缺失"; OK=0; }
grep -q '^dhcp = true' "$CONF" || { echo "  [X] toml 里 dhcp 不是 true"; OK=0; }
grep -q '^ipv4[[:space:]]*=' "$CONF" && { echo "  [X] DHCP 模式不应有 ipv4 字段"; OK=0; }
grep -q "^network_name = \"$NET_NAME\"" "$CONF" || { echo "  [X] 网络名未写入"; OK=0; }
bash -n "$SVC_DIR/easytier" 2>/dev/null || { echo "  [X] 服务脚本语法错误"; OK=0; }
[ "$OK" -eq 1 ] && echo "  [OK] 全部自检通过" || die "自检未通过，请检查上面的输出"

# ---------- 直接启动服务（无需询问，全程自动化）----------
echo ""
echo "  正在启动 easytier 服务 ..."
if command -v batocera-services >/dev/null 2>&1; then
    batocera-services start easytier
else
    "$SVC_DIR/easytier" start
fi
sleep 3
"$SVC_DIR/easytier" status

echo ""
hr
echo "   安装完成！"
hr
echo "  在 ES 界面：系统设置 -> 服务 -> 确认 easytier 已启用"
echo "  Ports 菜单里新增了两个工具："
echo "    * EasyTier节点检测/更换   —— 自动测速换优质节点（ESC 取消）"
echo "    * 强制修改虚拟局域网节点（慎点）—— 按 Gitee 清单统一所有机子节点"
echo "  其它机子请执行同样的安装，网络名/密码保持一致即可组网。"
echo ""
echo "  玩 Java 版 Minecraft：开「对局域网开放」，同一网络的机子就能在多人列表看到房间。"
echo ""

#!/bin/bash
# ============================================================================
# editnode.sh —— 强制统一 EasyTier 公共节点 (Batocera ES Ports)
#
# 位置: /userdata/roms/ports/editnode.sh   (执行权限 755)
# 作用: 从 Gitee 人工维护的 uri.txt 读取 3 个节点地址，原样写入本机
#       easytier.toml 的 [[peer]] 段，然后重启 EasyTier 服务。
#       每台机子跑一次，节点就一致了。
#
# 纯 bash：只用 curl / tr / sed / grep / awk，不需要 Python。
# CRLF: 读取时用 tr -d '\r' 去掉行尾 \r，否则变量里会变成 tcp://xxx\r。
# 清单: 协议和端口已写死在 Gitee 上，脚本原样复制，不判断协议、
#       不拼接端口 —— 默认 Gitee 上维护的一定是对的。
# 备份: easytier.toml.YYYYMMDDbak，同日重复自动 _2 / _3 ...（与 change_node 一致）
# ============================================================================

CONF="${EDITNODE_CONF:-/userdata/system/easytier/easytier.toml}"
SERVICE="${EDITNODE_SERVICE:-/userdata/system/services/easytier}"
NODE_URL="${EDITNODE_URLS:-https://gitee.com/lhw9527/easytiernode/raw/master/uri.txt}"
WAIT_SECONDS="${EDITNODE_WAIT:-18}"            # 按 ESC 的确认窗口秒数（原地读秒）
EXIT_WAIT="${EDITNODE_EXIT_WAIT:-3}"           # 提示后关窗等待秒数（不显示逐秒）
SWITCH_DELAY="${EDITNODE_SWITCH_DELAY:-2}"    # 改完配置后等几秒再启动服务
NO_RESTART="${EDITNODE_NO_RESTART:-0}"         # =1 跳过服务启停(仅自检用)

RAW="/tmp/editnode_raw.txt"
ERR="/tmp/editnode_err.txt"
NODES="/tmp/editnode_nodes.txt"
TMP="/tmp/editnode_new.toml"
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

# ---------- 在 ES 界面弹出 xterm（与 change_node.sh 相同的已验证写法） ----------
if [ -z "$IN_EDITNODE_XTERM" ]; then
    exec </dev/tty >/dev/tty 2>&1
    export DISPLAY=:0.0
    XT=/usr/bin/xterm
    [ -x "$XT" ] || XT="$(which xterm 2>/dev/null)"
    [ -z "$XT" ] && { echo "xterm not found"; exit 1; }
    cp "$XT" /tmp/xterm_editnode 2>/dev/null && chmod 755 /tmp/xterm_editnode 2>/dev/null
    U=/tmp/xterm_editnode; [ -x "$U" ] || U="$XT"
    exec env DISPLAY=:0.0 "$U" -fs 26 -maximized -fg white -bg black \
        -fa "DejaVuSansMono" -en UTF-8 \
        -e bash -c "IN_EDITNODE_XTERM=1 bash '$SCRIPT_PATH'"
fi
export DISPLAY=:0.0

clear 2>/dev/null || true
echo "============================================================"
echo "   强制修改虚拟局域网节点   慎点！"
echo "============================================================"
echo ""

# ---------------- [1] 当前状态 ----------------
echo "[1] 当前状态"
if curl -sS -L -m 8 -o /dev/null "https://gitee.com" >/dev/null 2>&1; then
    echo "  广域网        : 通"
else
    echo "  广域网        : 不通（下面抓取清单大概率会失败）"
fi

if [ -n "${EDITNODE_SVC_RUNNING:-}" ]; then
    SVC_RUNNING="$EDITNODE_SVC_RUNNING"
elif pgrep -x easytier-core >/dev/null 2>&1; then
    SVC_RUNNING=1
else
    SVC_RUNNING=0
fi
if [ "$SVC_RUNNING" -eq 1 ]; then
    echo "  EasyTier 服务 : 运行中"
else
    echo "  EasyTier 服务 : 未运行"
fi
echo "  当前节点      :"
grep 'uri[[:space:]]*=' "$CONF" 2>/dev/null \
    | sed 's/^[[:space:]]*uri[[:space:]]*=[[:space:]]*//; s/"//g; s/^/    /' | head -6
echo ""

# ---------------- [2] 抓取清单 ----------------
echo "[2] 清单抓取结果  $NODE_URL"
rm -f "$RAW" "$ERR" "$NODES"
if [[ "$NODE_URL" =~ ^https?:// ]]; then
    CODE="$(curl -sS -L -m 15 -A 'Mozilla/5.0' -o "$RAW" -w '%{http_code}' "$NODE_URL" 2>"$ERR")"
    CRC=$?
else
    # 也允许本地清单文件，方便临时测试
    cp "$NODE_URL" "$RAW" 2>"$ERR"; CRC=$?
    [ "$CRC" -eq 0 ] && CODE=200 || CODE=000
fi
# 末尾补一个换行，保证清单最后一行(可能没有换行结尾)也能被读到；顺手去掉 CRLF
{ cat "$RAW" 2>/dev/null; printf '\n'; } | tr -d '\r' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d; /^#/d' > "$NODES"
CNT=$(wc -l < "$NODES" 2>/dev/null || echo 0)

if [ "$CRC" -ne 0 ] || [ "$CODE" != "200" ] || [ ! -s "$RAW" ]; then
    REASON="$(head -1 "$ERR" 2>/dev/null)"
    [ -z "$REASON" ] && REASON="HTTP $CODE / 返回内容为空"
    echo "  [X] 没抓取到：$REASON"
    echo "      未改动任何文件，${EXIT_WAIT} 秒后退出。"
    sleep "$EXIT_WAIT"; exit 1
fi
if [ "$CNT" -ne 3 ]; then
    echo "  [X] 清单需要正好 3 行，实际读到 ${CNT} 行："
    sed 's/^/        /' "$NODES"
    echo "      未改动任何文件，${EXIT_WAIT} 秒后退出。"
    sleep "$EXIT_WAIT"; exit 1
fi

# 原样显示并写入：不判断协议、不拼接端口，Gitee 上写什么就是什么。
# 上面已校验「抓到内容且正好 3 行」，避免网络故障时把空清单写进配置。
i=0
while IFS= read -r line; do
    i=$((i + 1))
    echo "    $i) $line"
done < "$NODES"
echo ""

# ---------------- [3] 确认（ESC 取消，原地读秒） ----------------
echo "[3] 现在要把 easytier.toml 的节点改成上面这 3 个地址"
echo "    如不需要修改，请按 [ESC] 键"
# 纯 bash 原地读秒：printf '\r' 回车回到行首覆盖同一行，数字原地递减。
# 数字用 %2d 固定宽度（18 ->  9 长度一致），尾部补空格清残留。
# 不需要 tput / ncurses / Python，也不用额外安装任何东西。
CANCEL=0
n="$WAIT_SECONDS"
while [ "$n" -gt 0 ]; do
    [ -t 1 ] && printf '\r    %2d 秒后开始替换（按 ESC 取消）   ' "$n"
    key=""
    if read -s -n 1 -t 1 key 2>/dev/null; then
        [ "$key" = $'\e' ] && { CANCEL=1; break; }
    fi
    # stdin 不是终端(自检/重定向)时 read 不等，补 1 秒保证窗口时长准确
    [ -t 0 ] || sleep 1
    n=$((n - 1))
done
echo ""
if [ "$CANCEL" -eq 1 ]; then
    echo "  >>> 已取消修改，未改动任何文件。${EXIT_WAIT} 秒后退出。"
    sleep "$EXIT_WAIT"; exit 0
fi

# ---------------- [4] 执行 ----------------
echo "[4] 执行"
echo "  正在停止服务 → 备份 → 替换节点 → 启动服务 ..."

# 停服务（已经停止就跳过）
if [ "$NO_RESTART" -ne 1 ] && [ "$SVC_RUNNING" -eq 1 ]; then
    "$SERVICE" stop >/dev/null 2>&1
    sleep 1
fi

# 备份
DAY="$(date +%Y%m%d)"
BAK="$CONF.${DAY}bak"
if [ -e "$BAK" ]; then
    n=2
    while [ -e "$CONF.${DAY}bak_$n" ]; do n=$((n + 1)); done
    BAK="$CONF.${DAY}bak_$n"
fi
if ! cp -p "$CONF" "$BAK"; then
    echo "  [X] 备份失败，已取消修改。"
    [ "$NO_RESTART" -ne 1 ] && [ "$SVC_RUNNING" -eq 1 ] && "$SERVICE" start >/dev/null 2>&1
    sleep "$EXIT_WAIT"; exit 1
fi

# 重建 [[peer]] 段：遇到第一个 [[peer]] 就输出 3 个标准块，
# 原 peer 块内的行全部跳过，遇到别的 [section] 就恢复正常输出。
# 这样无论原来有几个节点，跑完一定是清单里的 3 个、顺序一致；
# [flags] 等其它段落和其它字段一字不动。
N1="$(sed -n 1p "$NODES")"; N2="$(sed -n 2p "$NODES")"; N3="$(sed -n 3p "$NODES")"
if ! awk -v a="$N1" -v b="$N2" -v c="$N3" '
/^[[:space:]]*\[\[peer\]\][[:space:]]*$/ {
    if (!done) {
        print "[[peer]]"; print "uri = \"" a "\""; print ""
        print "[[peer]]"; print "uri = \"" b "\""; print ""
        print "[[peer]]"; print "uri = \"" c "\""; print ""
        done = 1
    }
    inpeer = 1; next
}
/^[[:space:]]*\[/ { inpeer = 0 }
inpeer { next }
{ print }
END {
    if (!done) {
        print "[[peer]]"; print "uri = \"" a "\""; print ""
        print "[[peer]]"; print "uri = \"" b "\""; print ""
        print "[[peer]]"; print "uri = \"" c "\""; print ""
    }
}
' "$CONF" > "$TMP"; then
    echo "  [X] 替换失败，已从备份恢复原配置。"
    cp -p "$BAK" "$CONF"
    [ "$NO_RESTART" -ne 1 ] && [ "$SVC_RUNNING" -eq 1 ] && "$SERVICE" start >/dev/null 2>&1
    sleep "$EXIT_WAIT"; exit 1
fi
mv "$TMP" "$CONF"

# 启动服务（按需求：改完一定启动，即使原本是关的）
if [ "$NO_RESTART" -ne 1 ]; then
    sleep "$SWITCH_DELAY"
    "$SERVICE" start >/dev/null 2>&1
fi

echo ""
echo "  >>> 修改成功，EasyTier 服务已重启。备份: $(basename "$BAK")"
echo "  ${EXIT_WAIT} 秒后关闭窗口。"
sleep "$EXIT_WAIT"
exit 0

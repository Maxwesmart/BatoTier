# BatoTier —— 异地 Batocera主机间建立虚拟局域网

> 使用EasyTier给 Batocera 游戏机装一个虚拟局域网，安装完成后各个主机都设置一样的网络名和密钥，启动服务后，异地朋友就可以像在同一个客厅一样局域网联机打游戏。比如 Minecraft进行局域网联机，可以像真正的局域网联机那样发现世界，直接联机。无需创建房间，设置验证码/密码，分享验证码/密码（以及其它只支持局域网发现的游戏）。
>
> **无需公网 IP、无需注册账号、无需中心控制台、无设备数限制。**

---

## 这是什么

Batocera 是复古游戏机系统，Java 版 Minecraft 的「多人游戏」界面靠 UDP 组播 `224.0.2.60:4445` 发现同一局域网里的世界。异地机子互相看不到房间，是因为它们根本不在同一个局域网。

本方案用 [EasyTier](https://github.com/EasyTier/EasyTier)（开源、去中心化的异地组网工具）把各地机子拉进同一个虚拟局域网，并专门修好了组播发现这一环：

- `dhcp = true`：IP 自动分配。（也可以关闭DHCP,使用手动指定各台主机的ip地址。）
- 自动读取 Batocera 系统设置里的主机名当 `hostname`，**不用手工填**
- 给 `tun0` 补上 `IFF_MULTICAST` 标志，并只加一条 `224.0.2.60/32` 专属路由指向 `tun0`
  —— **不改默认路由、不改全局 metric**，所以公网照常能用，Java 版 MC 也能看到房
- ES 菜单里两个图形化工具：自动测速换节点、按 Gitee 清单强制统一所有机子的节点

### 和同类方案的差别

|               | 本方案 (EasyTier) | [BatoZero](https://github.com/Dre-OS/BatoZero) | [batocera-tailscale](https://github.com/the-diy-daddy/batocera-tailscale) |
| ------------- | -------------- | ---------------------------------------------- | ------------------------------------------------------------------------- |
| 底层            | EasyTier（去中心化） | ZeroTier                                       | Tailscale                                                                 |
| 要注册账号         | **不需要**        | 需要，my.zerotier.com 建网络                         | 需要，Google/GitHub 账号登录                                                     |
| 设备数限制         | **无**          | 免费版 10 台 / 1 个网络                               | 免费版 6 用户                                                                  |
| 要填网络名/密码      | 安装时填一次         | 网页建网络拿 Network ID，设备 `zerotier-cli join`       | 无传统密码，靠账号登录 + 后台批准                                                        |
| 要维护节点         | 节点自动更新（见下）     | 官方根节点，用户不感知                                    | 官方协调服务器 + DERP，用户不感知                                                      |
| **MC 组播房间发现** | **专门修好**       | 未处理                                            | Tailscale 是纯 L3，天然不支持组播                                                   |

缺点：EasyTier 没有官方账号体系，所以公共节点需要关心可用性。公告节点可以社区自取，也可以使用本项目用「多源实时拉取 + 本机测速 + Gitee 清单统一」把这件事自动化了，详见下方「节点维护」，实现全过程手柄操作，无需复杂配置。

---

## 文件清单

```
install.sh                          一键安装脚本（含配置向导）
roms/ports/change_node.sh           ES 工具：检测节点 + 自动换优质节点
roms/ports/editnode.sh              ES 工具：按 Gitee 清单强制统一节点
roms/ports/gamelist.xml             ES 菜单条目模板（安装时只追加/更新这两条，不覆盖你原有的游戏列表）
roms/ports/images/change_node-*     三个封面图（image / thumb / marquee）
roms/ports/images/editnode-*        同上，警示风格封面
（安装包内【不含】二进制，安装时由 install.sh 从官方 Pre-release 自动下载并校验 SHA256）
system/easytier/easytier.toml          示例配置（DHCP，安装脚本实际会重新生成）
system/easytier/easytier.toml.ipv4     固定 IP 示例配置（需要静态 IP 时用，见下方说明）
system/services/easytier            Batocera 服务脚本（开机自启）
```

> 安装脚本会按机器架构（x86_64 / aarch64 / armv7 / armhf / arm / mips / mipsel /
> riscv64 / ppc64le / loongarch64）自动从 [EasyTier Releases](https://github.com/EasyTier/EasyTier/releases)
> 的 **最新 Pre-release** 下载对应 Linux 包，解压出 `easytier-core` / `easytier-cli`。
> 下载源优先官方直连，慢或中断时自动切换 gh-proxy 镜像并断点续传；
> 无论走哪个源，都会用 GitHub API 提供的**官方 SHA256 校验**，校验失败即中止安装，
> 因此镜像无法篡改二进制。

---

## 安装（每台机子执行一次）

### 方式 A：SSH 一行命令（推荐，无需手工下载解压）

SSH 登录 Batocera（默认 `root` / `linux`），执行这一条：

```bash
mkdir -p /userdata/easytier-package && wget -O - https://github.com/Maxwesmart/BatoTier/tarball/main | gunzip | tar x --strip-components 1 -C /userdata/easytier-package && chmod +x /userdata/easytier-package/install.sh && /userdata/easytier-package/install.sh
```

安装过程：
从 GitHub 流式下载整个仓库 tarball 并直接解压到 `/userdata/easytier-package`，
接着赋予执行权限并运行安装向导。**不需要先在电脑上下载、解压、U 盘拷贝。**

> 如果 GitHub 直连慢或中断，用 gh-proxy 镜像版（把整条 URL 的前缀换成 `https://gh-proxy.com/`）：

```bash
mkdir -p /userdata/easytier-package && wget -O - https://gh-proxy.com/https://github.com/Maxwesmart/BatoTier/tarball/main | gunzip | tar x --strip-components 1 -C /userdata/easytier-package && chmod +x /userdata/easytier-package/install.sh && /userdata/easytier-package/install.sh
```

> 下载过的官方包会缓存到 `/userdata/system/.cache/easytier/`，重装或装下一台机子时
> 校验通过就直接复用，不用每次重新下载 31MB。

> tarball 只含脚本/配置/图片，几 MB；真正的 EasyTier 二进制由 install.sh
> 从官方 Pre-release 下载并用官方 SHA256 校验（所以镜像里的 tarball 不含可执行程序，
> 不用担心被镜像替换二进制）。

### 方式 B：本地拷贝发布包后安装

1. 把整个发布包复制到 Batocera，例如放到 `/userdata/easytier-package/`（用 U 盘或网络共享都行）。
2. SSH 登录 Batocera（默认 `root` / `linux`）。
3. 执行：

```bash
cd /userdata/easytier-package
chmod +x install.sh
./install.sh
```

4. 配置向导只问两项：

```
网络名称 network_name : BatoceraMC
网络密码 network_secret: xxxxxxxx
```

**所有机子这两项必须完全一致**，否则互相看不到，注意此处==BatoceraMC==和密码==xxxxxxxx==是举例，实际安装时请填入自己设置的值，这些值只能你自己和需要一起联机的伙伴知道且对方机子设置跟你一样。

配置向导在 SSH 终端里显示（不会弹到 ES 界面），有 **100 秒输入时间**：

- 在 100 秒内输入网络名和密码 → 用你输入的值；
- 超过 100 秒没输入、或不是交互终端（例如用管道自动安装）→ 自动使用上面的默认值 `BatoceraMC` / `xxxxxxxx`，安装继续往下走，**不会卡住**。
- 装好后随时可以编辑 `/userdata/system/easytier/easytier.toml` 里的 `network_name` / `network_secret` 改掉，改完重启服务即可，不用重装。

安装过程除了这两项，**其余全部自动**：主机名读取 Batocera 系统设置、IP 走 DHCP、下载并校验二进制、注册服务、**装完直接启动服务**，无需再按键。

其余两项不需要手工填写：

- **主机名**：默认取 Batocera 的主机名（主菜单 → 网络设置 → 主机名），脚本自动读取写入，例如 `BATO-Pro5`。如果默认取值的主机名和其他联机小伙伴的主机名一样会影响联机，所以建议开始安装前就修改Batocera 的主机名成不同的值。如果已经安装，请打开system/easytier/easytier.toml（用自带的文本编辑器即可）修改hostname = 后面的值退出保存，然后重新启动batocera系统即可。
- **IP 地址**：默认开启DHCP 自动分配，无需设置。如需设置，需各机子之间协调ip末位。

**需要固定 IP 怎么办？**

发布包里附带了 `system/easytier/easytier.toml.ipv4`，内容和默认配置几乎一样，只是把 DHCP 关掉并写死了 IP：

```toml
dhcp = false
ipv4 = "10.126.126.5/24"     # 改成你给这台机子分配的地址
```

**每台机子的最后一段必须不一样**，否则 IP 冲突会导致其中一台断网。例如：

```
10.126.126.5/24    <- 第一台
10.126.126.6/24    <- 第二台
10.126.126.7/24    <- 第三台
10.126.126.11/24   <- 第四台（不一定要连号，不重复即可）
```

网段部分（示例里的 `10.126.126`）所有人保持一致，只有最后一位不同。

两种方式任选其一：

1. 把 `easytier.toml.ipv4` 的内容整段复制，覆盖本机 `easytier.toml` 的对应字段；
2. 或者把文件后缀去掉，直接改名为 `easytier.toml` 取代原文件。

改完重启服务生效：

```bash
batocera-services restart easytier
```

> 固定 IP 的**网段必须和网络里其它机子一致**（示例 `10.126.126.x/24`），末位不能重复。
> 同一网络里 DHCP 和固定 IP 可以混用，但每台机子的 `network_name` / `network_secret`
> 必须完全一致。

安装脚本会自动完成：

- 检测架构（x86_64）
- 从 `batocera.conf` 读 `system.hostname=` 作为 EasyTier 主机名
- 从 Gitee 拉取 3 个公共节点（取不到就用内置兜底）
- 备份旧 `easytier.toml`（`easytier.toml.bak-时间戳`）
- 生成 DHCP 版配置（`dhcp = true`，**没有 ipv4 字段**）
- 复制全部文件，并统一 `chmod 755`（SMB 复制会丢执行位，这一步很关键）
- 附带安装 `easytier.toml.ipv4`（固定 IP 示例，只读，不影响当前 DHCP 配置）
- **gamelist.xml 只追加/更新这两个工具条目**：不会覆盖机子上原有的几十条游戏记录；已有条目则只更新描述并保留 ES 的游玩统计
- 必要时创建 `/dev/net/tun`，打开 IP 转发
- 注册 Batocera 服务并开机自启
- 装后自检：权限、配置字段、脚本语法

---

## ES 菜单里的两个工具

在 **Ports（游戏端口）** 菜单：

### 1. EasyTier节点检测/更换

- 检测当前 3 个节点是否失效（TCP 实测握手；`udp://` 无连接，只做 DNS 校验，界面会标注）
- 首轮异常会等 8 秒二次复核，避免网络抖动误报
- **只有 2 个及以上节点失效**才触发更换：实时从多个在线源拉清单、逐个测速、挑低延迟节点
- 18 秒确认窗口，**按 ESC 取消**，屏幕原地读秒不滚屏
- 确认后：停服务 → 备份 → 只改失效的 uri → 等 3 秒 → 启服务；服务原本是关的就保持关

### 2. 强制修改虚拟局域网节点（慎点）

- 从 `https://gitee.com/lhw9527/easytiernode/raw/master/uri.txt` 读取 3 个节点
- 原样写入（不判断协议、不拼端口），`tcp://` / `udp://` 都支持
- 15 秒确认，ESC 取消；改完自动重启服务
- **用途**：当你希望所有机子连到完全相同的节点时，每台都跑一次这个工具

---

## 节点维护

公共节点可能失效，这是去中心化方案的固有代价。本项目用三层机制把维护成本降到接近零：

1. **多源实时拉取**：`change_node.sh` 每次运行都从 GitHub 社区节点表、qt-easy-tier 的 `publicservers.json`、Gitee `uri.txt` 等多个地址实时抓取，上游更新了自动拿到，**不用改脚本**。
2. **GitHub 仓库清单**：安装时优先拉 `https://raw.githubusercontent.com/Maxwesmart/BatoTier/main/uri.txt`（随发布包一起的 `uri.txt`），取不到自动回退 Gitee。
3. **Gitee 人工清单**：日常维护仍在 `https://gitee.com/lhw9527/easytiernode/raw/master/uri.txt`，只有 3 行，需要换节点时改这 3 行即可，所有机子跑一次 `editnode.sh` 就统一。
4. **保底锚点**：`tcp://225284.xyz:11010` 豁免延迟阈值，只要还通就绝不换掉，保证多台机子永远有共同会合点。

自定义源：在 `/userdata/system/easytier/node_urls.txt` 里一行写一个 URL，`change_node.sh` 会自动追加。

---

## 常见问题

**Q：装完 Java 版 MC 多人列表还是看不到房间？**
A：确认 easytier 服务在运行（`系统设置 -> 服务`），并且所有机子网络名/密码一致。服务脚本在启动时等待 `tun0` 拿到 IP 后会自动补 `IFF_MULTICAST` 标志和 `224.0.2.60/32` 专属路由。用 `/userdata/system/services/easytier status` 看 `MC LAN discovery` 是否为 `multicast=on, route=active`。如果服务启动瞬间 `tun0` 还没起来，重启一次服务即可（`batocera-services restart easytier`）。

**Q：能不能直接改全局网卡 Metric 来解决发现不了房间？**
A：**不建议**。那会影响公网路由，可能导致主机连不上外网。本方案只加 MC 组播的专属 /32 路由，不碰默认路由和 metric。如果其他局域网没装easytier的机子想要局域网联机，要不已经装的机子关掉easytier服务，要不美妆的机子都装一下且设置一样的节点地址和网络名、网络密码。easytier有Linux版，windows版，安卓版。地址见页面底部GitHub地址。

**Q：换 WiFi 后要不要禁用服务？**
A：一般不用，DHCP 会重新分配 IP。换网络后如果长时间不通，先停服务再换、换完再启动（`batocera-services restart easytier`）。

**Q：我想给某台机子固定 IP，怎么做？**
A：用发布包里的 `easytier.toml.ipv4`：把 `dhcp = false` 和 `ipv4 = "10.126.126.x/24"` 复制进本机 `easytier.toml`（或直接改名取代），末位别和别人重复、网段保持一致，然后 `batocera-services restart easytier`。

**Q：为什么没有 watchdog 自愈了？**
A：这是有意去掉的。旧版 watchdog 硬解析 toml 里的 `ipv4`，而 DHCP 模式没有这个字段，会导致守护进程直接退出——这是发布后最容易踩的坑。EasyTier core 本身在 Batocera 上很稳定，不需要常驻守护；少一个进程也避免误判重启和日志问题。万一 core 意外退出，手动 `batocera-services restart easytier` 即可。

**Q：两个工具的倒计时怎么取消？**
A：`change_node.sh` 18 秒窗口、`editnode.sh` 15 秒窗口内按 **ESC** 即可，取消后不停止服务、不备份、不修改任何文件。

---

## 许可与鸣谢

- EasyTier：https://github.com/EasyTier/EasyTier（Apache-2.0）
- Batocera：https://batocera.org/
- 本项目的脚本与文档：MIT（草稿，待确认）

> 本项目是个人使用经验整理，不隶属于 EasyTier 或 Batocera 官方。
> 公共节点由社区维护，不保证长期可用；请勿用于任何违法用途。

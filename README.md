# mihomo-sub

`docker` 部署的 `mihomo` 核心，支持多订阅管理和定时更新。

> [!WARNING]
> ## 免责声明
>
> 本项目仅供**学习研究**和**技术交流**使用。使用者应当遵守所在国家或地区的法律法规。
>
> - 本项目开发者**不提供**任何代理节点、订阅链接或翻墙服务
> - 使用者自行获取的订阅链接及其内容与开发者**无关**
> - 使用者应确保其使用行为符合当地法律法规，**自行承担**因使用本项目产生的一切后果和风险
> - **严禁**将本项目用于任何违法用途，包括但不限于传播非法信息、侵犯他人知识产权等
> - 本项目不提供任何形式的担保，使用过程中出现的任何问题开发者不承担责任
>
> **使用本项目即表示您已阅读并同意上述声明。**

## 许可

本项目基于 [MIT License](LICENSE) 开源。

## 特性

- **多订阅管理** — 通过 Web 管理页面添加/删除多个订阅链接，自动合并代理节点
- **定时刷新** — 支持每 15 分钟、每小时、每天三种调度策略
- **手动刷新** — 管理页面一键立即刷新订阅
- **配置持久化** — 所有配置保存在 `/root/.config/mihomo/` 目录，映射到宿主机后镜像更新不丢失配置
- **一键跳转** — 管理页面直接跳转 metacubexd 代理面板
- **失败回滚** — 刷新失败自动恢复上一份可用配置（`config.yaml.good`，移植自上游 3.0.0）
- **可选鉴权** — 设置 `SECRET` 后面板与 API 需要密钥，不设置则无密码（保持旧行为）
- **可选覆盖层** — `overlay.yaml` 存在时自动深合并自定义 DNS / 规则（移植自上游 3.0.0，不存在则跳过）

## 内置工具

| 组件 | 版本 | 说明 |
|------|------|------|
| `mihomo` | v1.19.32（2026-09-30） | 代理核心，`metacubex/mihomo` 基础镜像 |
| `metacubexd` | v1.273.1（2026-09-10） | Web 代理管理面板 |
| `subconverter` | v0.9.2（MetaCubeX C++ 版） | 本地订阅转换（上游 3.0.0 已切回官方版本，不再用第三方 fork） |
| `yq` | v4.44.3 | `overlay.yaml` 合并 |
| `sub.sh` | — | 订阅更新脚本 |
| 管理页面 | — | 订阅配置 Web 界面（`:9091`） |

## 服务端口

| 端口 | 用途 |
|------|------|
| `7890` | 代理 mixed 端口 |
| `9090` | mihomo API + Web 面板 (`/ui`) |
| `9091` | 订阅管理页面（可用 `MGMT_PORT` 改端口） |

> `network_mode: host` 下 Docker 的 `-p` 映射不生效：改管理页面端口用 `MGMT_PORT=18091`；
> bridge 模式则直接 `-p 18091:9091` 即可。

## 部署

### Docker Compose（推荐）

```yaml
services:
  mihomo:
    # GHCR 免注册拉取（随仓库自动推送）；Docker Hub 需自行配置 secrets 后才有
    image: ghcr.io/bamboostrip/mihomo-sub:latest
    container_name: mihomo-sub
    volumes:
      - ./mihomo-config:/root/.config/mihomo
    environment:
      - TZ=Asia/Shanghai
      # 可选：设置后面板与 API 需要鉴权，不设置则无密码（仅建议局域网）
      # - SECRET=change-me
      # 可选：管理页面(:9091)密码 + 端口（host 网络下改端口只能用 MGMT_PORT）
      # - MGR_PASSWORD=change-me
      # - MGMT_PORT=9091
    ports:
      - "7890:7890"
      - "9090:9090"
      - "9091:9091"
    restart: unless-stopped
```

> 首次启动时容器会自动在 `./mihomo-config` 目录下生成所需的初始文件。即使挂载的是空目录也不会有问题。

### 基础部署

```bash
docker run -d \
  --name mihomo-sub \
  -p 7890:7890 \
  -p 9090:9090 \
  -p 9091:9091 \
  -e TZ=Asia/Shanghai \
  ghcr.io/bamboostrip/mihomo-sub:latest
```

挂载 `./mihomo-config` 后，以下文件会持久化到宿主机，更新镜像不会丢失：

| 文件 | 用途 |
|------|------|
| `sub_urls.txt` | 订阅链接列表（一行一个；可带别名，格式 `别名<TAB>URL`，无别名即纯 URL 老格式；第三列 `off` = 停用） |
| `schedule.conf` | 定时策略 (`15min` / `hourly` / `daily`) |
| `group_mode.conf` | 多账号合并方式（`merge` 合并策略组（默认）/ `isolate` 按账号隔离） |
| `user_agent.txt` | 自定义 User-Agent（一行，可选） |
| `geoip.metadb` | GeoIP 数据库（首次启动自动复制，可选） |
| `geosite.dat` | GeoSite 数据库（首次启动自动复制，可选） |
| `config.yaml` | mihomo 代理配置（自动生成） |
| `config.yaml.good` | 上一份刷新成功的配置（失败自动回滚用） |
| `config.yaml.bad` | 重载被拒时的失败配置（排查用） |
| `overlay.yaml` | 可选自定义覆盖层（DNS / 规则，不存在则跳过） |
| `.secret` | `SECRET` 持久化文件（设置后自动生成） |
| `log.txt` | 更新日志 |
| `usage/` | 各订阅流量存档（`subscription-userinfo` 解析，管理页用量条用） |

### 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `TZ` | 推荐 | 时区，如 `Asia/Shanghai` |
| `sub_url` | 否 | 初始订阅 URL（首次启动时写入 `sub_urls.txt`，之后通过管理页面管理） |
| `SECRET` | 否 | 面板与 API 密钥；为空则无密码（默认），`off` 可显式关闭；设置后 metacubexd 面板需填入同一密钥 |
| `MGR_PASSWORD` | 否 | 管理页面（`:9091`）与 CGI 的 Basic 鉴权密码；为空则无密码（默认），`off` 可显式关闭 |
| `MGR_USER` | 否 | 管理页面用户名（默认 `admin`） |
| `MGMT_PORT` | 否 | 管理页面端口（默认 `9091`；`network_mode: host` 下改端口只能用它） |

## 使用

### 管理页面

浏览器打开 `http://<服务器IP>:9091`：

1. **添加订阅** — 粘贴订阅 URL，点击添加
2. **启用/切换** — 每条订阅有勾选框（可多选，一起合并）；点「切换」= 只用这一条（Verge 式切换，自动刷新）
3. **设置调度** — 选择刷新频率（15分钟/每小时/每天）
4. **手动刷新** — 点击「立即刷新」按钮（注意：手动刷新会重置调度计时器，可能导致下次定时刷新延后一个周期）
5. **打开面板** — 点击「打开面板」跳转到 metacubexd 代理管理

### 订阅别名（区分多账号流量）与合并方式

同一家机场开了多个账号时，给每条订阅设个别名（如 `主账号` / `备用`），
合并后节点名会变成 `主账号 | 香港01` 这种带前缀形式：重名不再冲突，
在 metacubexd 面板选节点时一眼看出走的是哪个账号的流量池。
添加时填"别名"框即可，已有订阅点「改名」可随时改（留空即清除）。

管理页「多账号合并方式」可切换（写入 `group_mode.conf`，切换后自动刷新）：

- **合并策略组（默认）** — 同名策略组合成一个公共组，多账号的节点都放在里面；规则完全相同的行只保留一份。一个账号限速/流量耗尽时，url-test/fallback 会自动切换到另一个账号的节点，配置体积也更小。
- **按账号隔离** — 策略组名与规则引用同样带 `别名 | ` 前缀，各账号的策略组和规则完全独立，适合严格区分账号用途的场景（配置约为合并模式的 1.8 倍）。

### 只用一家机场（Verge 式切换）

订阅列表里勾选框可多选（勾选的订阅一起合并）；点某条的「切换」= 停用其他订阅、只使用这一条，
配置会整体替换成该订阅的节点/策略组/规则，多机场之间彻底隔离——相当于 Clash Verge Rev 的配置切换。
底层就是 `sub_urls.txt` 第三列的 `off` 停用标记，手动编辑效果相同。

### 流量剩余额度

每次刷新时会自动解析订阅返回头的 `subscription-userinfo`，
管理页每条订阅下方会显示 Verge 式的用量条（已用 / 总量 · 到期时间），
无该返回头的机场显示"暂无"。数据缓存在 `usage/` 目录，失败时保留上次的值。

### 更新很慢？

多个订阅是串行更新的，一个死链会卡住后面所有。死链单次最多烧
`建连 10 秒 ×(1+2 次重试)`，之后自动跳过并在日志标出。长期不通的订阅
（如域名已停解析）建议直接删除，更新速度立刻恢复正常。
`docker logs` 里只在手动/启动刷新时打印逐条进度，定时任务看管理页日志即可。

### 代理面板

`http://<服务器IP>:9090/ui` — metacubexd 面板，管理代理规则、切换节点、查看连接等。
如果设置了 `SECRET`，面板会要求输入密钥（与环境变量一致）；没设置则直接进入。

### 自定义覆盖层（可选）

在挂载目录里新建 `overlay.yaml`，每次刷新后会自动深合并到 `config.yaml`，
适合放长期有效的 DNS、额外规则。`mixed-port` / `secret` / `external-controller` /
`external-ui` 仍由脚本接管，不会被覆盖。示例：

```yaml
dns:
  enable: true
  enhanced-mode: fake-ip
rules-prepend:
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
```

### 手动执行订阅更新

```bash
docker exec mihomo-sub /etc/periodic/15min/sub.sh --now
```

## 常见问题

**Q: 更新镜像后配置会丢失吗？**

不会。只要挂载了 `/root/.config/mihomo` 目录，`sub_urls.txt` 和 `schedule.conf` 都在宿主机上，更新镜像不受影响。初始文件（如 Web 面板）也会在容器启动时自动补全。

**Q: 可以直接挂载空目录吗？**

可以。容器启动时检测到缺失的文件会自动从内置模板生成，空目录挂载完全没问题。

**Q: 设置 SECRET 后面板要密码，管理页面（:9091）呢？**

设置 `MGR_PASSWORD` 后，管理页面的页面与所有 CGI 操作都会要求 Basic 鉴权（用户名默认 `admin`，可用 `MGR_USER` 改）；
不设置则无密码（保持旧行为，仅建议局域网使用）。密码持久化在数据卷的 `.mgr_password`，重启不失效；
如需关闭设 `MGR_PASSWORD=off` 后重启一次。`:9090` 的 metacubexd 面板与 API 由 `SECRET` 控制，二者互相独立。
`SECRET` 同样持久化在数据卷的 `.secret`，去掉环境变量不会自动清除旧密钥，如需关闭设 `SECRET=off` 后重启一次。

**Q: 想开 TUN 全局代理，overlay.yaml 是必须的吗？**

不是必须。`overlay.yaml` 是可选的：没有这个文件，容器照样运行（普通 7890 端口代理模式）。
如果需要 TUN，把 `tun` 段放进数据卷里的 `overlay.yaml`（`./mihomo-config/overlay.yaml`），
每次刷新会深合并进去——直接改 `config.yaml` 不行，它会被订阅刷新重写。
每台设备放一份即可（内容可复制）；`route-exclude-address` 里的 CIDR 必须是合法值（IPv4 最大 `/32`，
写错如 `/33` 会导致重载被拒并回滚），且建议按该设备 `/etc/resolv.conf` 里的 DNS 服务器 IP 调整排除项。

**Q: 刷新失败会把配置搞坏吗？**

不会。每次成功会另存 `config.yaml.good`，失败自动回滚，不会用坏配置覆盖。

## 与上游的关系

本项目 fork 自 `lsw951753/mihomo-sub` 的 Web 管理页面方案（多订阅 `:9091`），
其上游是 `pure-white-ice-cream/mihomo-sub`。上游 3.0.0（`VERSION 3.0.0`）主要变化：

- 默认密钥：留空生成随机 `SECRET`（破坏性变更，本 fork **未跟进**，留空仍为无密码）
- 定时模型：`cron` 环境变量（本 fork **未跟进**，保留管理页面的 15min/hourly/daily）
- 面板：metacubexd → Zashboard（本 fork **未跟进**，保留 metacubexd 并升级到 v1.273.1）
- 单订阅 `sub_url` 用 `|` 分隔（本 fork **未跟进**，保留 `sub_urls.txt` 多订阅文件）

已从 3.0.0 移植的 bug 修复：本机请求绕开代理（防自环）、下载重试与状态码校验、
热重载失败回滚 `config.yaml.good`、`SECRET` 鉴权支持、`overlay.yaml` 合并、
带鉴权的 HEALTHCHECK。网页多订阅功能不受影响。

## 源码和仓库

- 本仓库: `https://github.com/bamboostrip/mihomo-sub`
- 镜像: `ghcr.io/bamboostrip/mihomo-sub`（自动推送；Docker Hub 需配置 secrets 后才有同名镜像）
- 上游: `https://github.com/pure-white-ice-cream/mihomo-sub`

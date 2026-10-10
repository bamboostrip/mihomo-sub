# mihomo-sub

Docker 化的 mihomo（clash meta）代理方案，内置 Web 管理页面、多订阅合并、定时刷新和配置持久化。

## 项目结构

```
├── Dockerfile              # 镜像构建，多架构支持 (amd64/arm64/armv7/386)
├── init.sh                 # 容器 ENTRYPOINT，初始化 + 启动所有服务
├── sub.sh                  # 订阅更新脚本，cron 每 15 分钟触发
├── healthcheck.sh          # 健康检查（支持 SECRET 鉴权）
├── mgr/
│   ├── index.html          # 管理页面 (暗色主题，单文件，:9091)
│   └── cgi-bin/
│       └── api             # CGI API 后端 (busybox-extras httpd)
├── .github/workflows/
│   └── docker-image.yml    # CI/CD 多架构构建推送（GHCR 常开 + Docker Hub 可选）
└── README.md
```

## 服务端口

| 端口 | 服务 | 说明 |
|------|------|------|
| 7890 | mihomo mixed proxy | HTTP + SOCKS |
| 9090 | mihomo API / metacubexd WebUI | `/ui` 代理面板 |
| 9091 | busybox-extras httpd | 管理页面 + CGI API（`MGMT_PORT` 可改，`MGR_PASSWORD` 可加 Basic 鉴权） |

## 核心流程

### 容器启动 (init.sh)

```
初始化配置文件（空挂载自动补全）
  → 启动 mihomo → 等待就绪（最多 10s，失败 exit 1）
  → 清缓存 + 启动 subconverter → 等待就绪（最多 10s，失败 exit 1）
  → sub.sh --now 首次订阅更新（同步阻塞）
  → 启动 httpd :${MGMT_PORT:-9091}（设置 MGR_PASSWORD 则 Basic 鉴权）
  → exec crond -f（前台）
```

### 订阅更新 (sub.sh)

```
check_schedule（非 --now 时检查 last_run 时间戳）
  → 清理 subconverter 缓存
  → 读取 sub_urls.txt（去 \r、跳过空行和 # 注释——别名以 # 开头时该行含 TAB，不视为注释；支持 `别名<TAB>URL`，第三列 `off` 表示停用，跳过不下载）
  → 对每个 URL:
     ├─ curl 直接下载（UA=clash-verge/v2.5.1，可通过 user_agent.txt 覆盖）
     ├─ 检测内容含 ^proxies: → 直接当 Clash YAML 用
     ├─ 否则 → 交给 subconverter(:25500) 转换
     └─ 有别名 → 节点名加 `别名 | ` 前缀（group_mode=isolate 时策略组名/引用也加；两遍扫描保证一致）
  → 提取 proxies / rules / proxy-groups → 合并：节点同名保留首次、同名策略组合并成员、规则整行去重
  → 生成 config.yaml（tun_mode.conf=on 时写入默认 tun 段并自动排除本机 DNS）→ PUT :9090/configs 热重载
  → 记录 last_run 时间戳 → 写日志（超 1MB 自动截断末尾 50KB）
```

### 管理页面 CGI API

| action | method | 说明 |
|--------|--------|------|
| `list` | GET | 列出订阅列表 (JSON `[{url,alias}]`) |
| `add` | POST | 添加订阅 (body: url=...&alias=...，别名可选) |
| `delete` | POST | 删除订阅 (body: url=...)，按 URL 部分匹配 |
| `rename` | POST | 修改别名 (body: url=...&alias=...，留空清除) |
| `groupmode` | GET/POST | 查看/切换多账号合并方式 (`merge` 合并策略组 / `isolate` 按账号隔离) |
| `toggle` | POST | 启用/停用订阅 (body: url=...&enabled=1/0，写第三列 `off`) |
| `solo` | POST | 只启用这一条订阅 (body: url=...，其他全部停用，Verge 式切换) |
| `tunmode` | GET/POST | 查看/切换 TUN 全局代理 (`on`/`off`；GET 返回 `prereq` 权限状态与 overlay 冲突提示) |
| `usage` | GET | 各订阅流量 `[{url,alias,upload,download,total,expire}]` |
| `refresh` | GET | 后台触发 sub.sh --now |
| `schedule` | GET/POST | 查看/修改定时策略 |
| `logs` | GET | 最近 100 行日志 |
| `status` | GET | 最后刷新时间、调度、订阅数 |

## 配置文件（/root/.config/mihomo/）

| 文件 | 写方 | 说明 |
|------|------|------|
| `sub_urls.txt` | 管理页面/CGI | 订阅 URL，一行一个，支持 # 注释；可带别名 `别名<TAB>URL`，第三列 `off` 表示停用 |
| `schedule.conf` | 管理页面/CGI | `15min` / `hourly` / `daily` |
| `group_mode.conf` | 管理页面/CGI | `merge`（默认，同名策略组合并成员）/ `isolate`（按账号隔离前缀） |
| `tun_mode.conf` | 管理页面/CGI | `on`/`off`（默认 off）；on 时每次刷新在配置里写入默认 tun 段 |
| `user_agent.txt` | 手动创建 | 自定义 UA，默认 `clash-verge/v2.5.1` |
| `overlay.yaml` | 手动创建（可选） | 自定义覆盖层，不存在则跳过；受管字段不被覆盖 |
| `.secret` | init.sh（SECRET 非空时） | API 密钥持久化；SECRET 为空则无此鉴权 |
| `.mgr_password` | init.sh（MGR_PASSWORD 非空时） | 管理页面密码持久化；为空则页面无密码 |
| `httpd.conf` | init.sh | busybox httpd 的 Basic 鉴权配置（密码哈希），仅在启用页面密码时生成 |
| `geoip.metadb` | Dockerfile/init.sh | GeoIP 库，预下载避免启动时直连 GitHub |
| `geosite.dat` | Dockerfile/init.sh | 规则集，预下载避免启动时直连 GitHub |
| `config.yaml` | sub.sh | mihomo 代理配置，每次刷新重写（含 secret 行） |
| `config.yaml.good` | sub.sh | 上一份成功配置，失败回滚用 |
| `log.txt` | sub.sh | 更新日志，超 1MB 自动截断 |
| `usage/` | sub.sh | 流量存档 `usage/<md5(url)[:12]>.dat`（TAB 分隔 up/down/total/expire），失败保留旧值 |
| `last_run` | sub.sh | Unix 时间戳 |

## 依赖版本

| 组件 | 版本 | 来源 |
|------|------|------|
| mihomo | v1.19.32 | metacubex/mihomo 基础镜像 |
| metacubexd | v1.273.1 | MetaCubeX releases（compressed-dist.tgz） |
| subconverter | v0.9.2 | MetaCubeX 官方 C++ 版（上游 3.0.0 同款） |
| yq | v4.44.3 | mikefarah/yq（overlay 合并） |
| busybox-extras | Alpine | 提供 httpd CGI 服务 |

## 上游 3.0.0 取舍（pure-white-ice-cream/mihomo-sub, VERSION 3.0.0）

- 已移植：代理绕行、下载重试+状态码校验、失败回滚 good 配置、SECRET 鉴权、
  overlay.yaml 合并、带鉴权 HEALTHCHECK、MetaCubeX subconverter v0.9.2。
- 未移植（保护 `:9091` 网页多订阅）：`cron` 环境变量定时、`SECRET` 留空生成随机密钥、
  Zashboard 面板、`sub_url` 用 `|` 分隔。SECRET 留空在本 fork = 无密码。

## 注意事项

- **管理页面鉴权/端口** — `MGR_PASSWORD` 设置后 :9091 页面与 CGI 全部走 Basic 鉴权（密码哈希用 base busybox 的 `cryptpw -m md5` 生成，写入 `httpd.conf`）；`MGMT_PORT` 改监听端口（`network_mode: host` 下 `-p` 不生效，只能靠它）；两者留空 = 旧行为
- **TUN** — 管理页开关（`tun_mode.conf`）持久有效、每次刷新自动带 tun 段并排除本机 DNS；**metacubexd 自带的 TUN 开关只对当前运行生效，订阅刷新重载后会被重置关闭（实测）**，只适合临时调试；容器需 `/dev/net/tun` + `NET_ADMIN`（compose 配一次），缺权限时 CGI `tunmode` 会明确报错；overlay.yaml 的 tun 段优先级最高
- **overlay.yaml 可选** — 不存在则跳过，纯 7890 代理模式照常；TUN 等自定义配置放这里，直接改 config.yaml 会在刷新时被重写；`route-exclude-address` 的 CIDR 必须合法（IPv4 最大 /32），否则重载被拒回滚
- **合并方式** — `group_mode.conf` 为 `merge`（默认）时：别名只改节点名，同名策略组跨订阅并成员（含不同机场的同名通用组），规则整行去重；`isolate` 时策略组/规则按账号加前缀完全隔离。页面切换后需等刷新完成才生效
- **subconverter 直连优先** — sub.sh 先 curl 直接下载并正确设置 UA，内容已是 Clash YAML 则跳过转换；只有非 Clash 格式才走 subconverter 兜底。全部请求绕开代理变量，防自环
- **GeoIP/GeoSite 文件已预下载** — Dockerfile 构建时从 GitHub 下载，init.sh 复制到配置目录。避免启动时 mihomo 直连 GitHub 下载超时（国内环境常见问题）
- **手动刷新会重置 `last_run`** — 点"立即刷新"后，下次定时刷新会被推迟一个完整周期
- **`printf '%s'` 不用 `%b`** — sub.sh 的 config 生成全部用 `%s`，防止订阅数据中的字面量 `\n` 被错误转义
- **CHMOD 必须** — CGI 脚本必须有执行权限，Dockerfile 中已 `chmod +x`

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
| 9091 | busybox-extras httpd | 管理页面 + CGI API |

## 核心流程

### 容器启动 (init.sh)

```
初始化配置文件（空挂载自动补全）
  → 启动 mihomo → 等待就绪（最多 10s，失败 exit 1）
  → 清缓存 + 启动 subconverter → 等待就绪（最多 10s，失败 exit 1）
  → sub.sh --now 首次订阅更新（同步阻塞）
  → 启动 httpd :9091
  → exec crond -f（前台）
```

### 订阅更新 (sub.sh)

```
check_schedule（非 --now 时检查 last_run 时间戳）
  → 清理 subconverter 缓存
  → 读取 sub_urls.txt（去 \r、跳过空行和 # 注释，支持 `别名<TAB>URL`）
  → 对每个 URL:
     ├─ curl 直接下载（UA=clash-verge/v2.5.1，可通过 user_agent.txt 覆盖）
     ├─ 检测内容含 ^proxies: → 直接当 Clash YAML 用
     ├─ 否则 → 交给 subconverter(:25500) 转换
     └─ 有别名 → 节点名/策略组名/引用统一加 `别名 | ` 前缀（两遍扫描保证一致）
  → 提取 proxies / rules / proxy-groups → 合并多订阅（同名去重，保留首次）
  → 生成 config.yaml → PUT :9090/configs 热重载
  → 记录 last_run 时间戳 → 写日志（超 1MB 自动截断末尾 50KB）
```

### 管理页面 CGI API

| action | method | 说明 |
|--------|--------|------|
| `list` | GET | 列出订阅列表 (JSON `[{url,alias}]`) |
| `add` | POST | 添加订阅 (body: url=...&alias=...，别名可选) |
| `delete` | POST | 删除订阅 (body: url=...)，按 URL 部分匹配 |
| `rename` | POST | 修改别名 (body: url=...&alias=...，留空清除) |
| `refresh` | GET | 后台触发 sub.sh --now |
| `schedule` | GET/POST | 查看/修改定时策略 |
| `logs` | GET | 最近 100 行日志 |
| `status` | GET | 最后刷新时间、调度、订阅数 |

## 配置文件（/root/.config/mihomo/）

| 文件 | 写方 | 说明 |
|------|------|------|
| `sub_urls.txt` | 管理页面/CGI | 订阅 URL，一行一个，支持 # 注释；可带别名 `别名<TAB>URL` |
| `schedule.conf` | 管理页面/CGI | `15min` / `hourly` / `daily` |
| `user_agent.txt` | 手动创建 | 自定义 UA，默认 `clash-verge/v2.5.1` |
| `overlay.yaml` | 手动创建（可选） | 自定义覆盖层，不存在则跳过；受管字段不被覆盖 |
| `.secret` | init.sh（SECRET 非空时） | API 密钥持久化；SECRET 为空则无此鉴权 |
| `geoip.metadb` | Dockerfile/init.sh | GeoIP 库，预下载避免启动时直连 GitHub |
| `geosite.dat` | Dockerfile/init.sh | 规则集，预下载避免启动时直连 GitHub |
| `config.yaml` | sub.sh | mihomo 代理配置，每次刷新重写（含 secret 行） |
| `config.yaml.good` | sub.sh | 上一份成功配置，失败回滚用 |
| `log.txt` | sub.sh | 更新日志，超 1MB 自动截断 |
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

- **subconverter 直连优先** — sub.sh 先 curl 直接下载并正确设置 UA，内容已是 Clash YAML 则跳过转换；只有非 Clash 格式才走 subconverter 兜底。全部请求绕开代理变量，防自环
- **GeoIP/GeoSite 文件已预下载** — Dockerfile 构建时从 GitHub 下载，init.sh 复制到配置目录。避免启动时 mihomo 直连 GitHub 下载超时（国内环境常见问题）
- **手动刷新会重置 `last_run`** — 点"立即刷新"后，下次定时刷新会被推迟一个完整周期
- **`printf '%s'` 不用 `%b`** — sub.sh 的 config 生成全部用 `%s`，防止订阅数据中的字面量 `\n` 被错误转义
- **CHMOD 必须** — CGI 脚本必须有执行权限，Dockerfile 中已 `chmod +x`

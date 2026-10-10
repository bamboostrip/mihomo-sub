# Changelog

## [Unreleased]

### 新增

- **开箱即用 `docker-compose.yaml`**：仓库自带一份可直接拷贝使用的 compose 示例（host 网络 + `/dev/net/tun`
  + NET_ADMIN 已配好，TUN 开关开箱可用；`SECRET` / `MGR_PASSWORD` / `MGMT_PORT` 等均为注释示例，
  附桥接端口映射的替代写法）
- **TUN 网页开关**：管理页「TUN 全局代理」一键开关（写入 `tun_mode.conf`），开启后每次刷新自动生成
  tun 段并自动排除本机 DNS（防 host 模式劫持解析）；缺 `/dev/net/tun` 或 `NET_ADMIN` 时开关明确报错；
  overlay.yaml 里的 tun 段优先级更高可做高级覆盖
- **管理页面端口可改 + 可选密码**：`MGMT_PORT` 指定管理页面端口（默认 9091；`network_mode: host`
  下 `-p` 映射不生效时用它）；`MGR_PASSWORD` 开启 Basic 鉴权（用户名 `MGR_USER`，默认 admin），
  页面与 CGI 全部操作受保护，留空无密码（兼容旧行为），`off` 显式关闭；密码持久化在 `.mgr_password`
- **订阅启用开关 / Verge 式一键切换**：管理页每条订阅带勾选框（可多选，勾选的一起合并），
  「切换」= 停用其他订阅、只使用这一条——配置整体替换为该订阅的节点/策略组/规则，
  多机场之间彻底隔离。`sub_urls.txt` 第三列 `off` 表示停用（老两列格式默认启用，完全兼容）；
  CGI 新增 `toggle` / `solo`
- **订阅别名 + 多账号合并方式**：管理页面可为每条订阅设别名，节点名加 `别名 | ` 前缀区分流量归属；
  合并方式可在页面切换（写入 `group_mode.conf`，CGI 新增 `groupmode`，切换后自动刷新）：
  ① 合并策略组（默认）：同名策略组成员取并集，多账号的节点共用一个组，规则完全相同的行去重只留一份
  ——一个账号限速/耗尽可自动切换到另一个账号的节点；
  ② 按账号隔离：策略组名与规则引用也加前缀，各账号组/规则完全独立。
  `sub_urls.txt` 行格式为 `别名<TAB>URL`（无 TAB 即老格式纯 URL，完全兼容）。CGI 另有 `rename` 接口，页面有别名徽标 + 「改名」按钮
- **流量剩余额度**：解析 `subscription-userinfo` 存档到 `usage/`，管理页每条订阅下显示用量条（已用/总量/到期），CGI 新增 `usage` 接口
- **全量策略组合并**：不再只取第一个订阅的分组，所有订阅的分组都保留（同名去重），
  各自规则才有归属，非首订阅的节点不再是"孤儿"；完全相同的规则行去重

### 优化

- **死链快速失败**：下载建连超时 10 秒熔断（`--connect-timeout 10`，重试减到 2 次），
  死订阅不再每次吃满 30 秒×4 次；手动/启动刷新时 docker 日志打印逐条进度

### 升级

- **mihomo** `v1.19.25` → `v1.19.32`（2026-09-30）
- **metacubexd** `v1.248.7` → `v1.273.1`（2026-09-10，修复桌面端 TUN helper 启动与恢复）
- **subconverter** `asdlokj1qpi233 v0.9.9` → `MetaCubeX v0.9.2` C++ 版（跟随上游 3.0.0 切回官方版本）
- 新增 `yq v4.44.3`（用于 `overlay.yaml` 合并）

### 新增（移植自上游 3.0.0，不影响 `:9091` 网页多订阅）

- **失败回滚**：`config.yaml.good`，刷新/热重载失败自动恢复上一份可用配置
- **可选鉴权**：`SECRET` 环境变量 + 数据卷 `.secret` 持久化；设置后面板与 API 需密钥，留空仍无密码（上游 3.0.0 留空生成随机密钥的破坏性变更**未跟进**，避免老用户被锁）
- **可选覆盖层**：`overlay.yaml` 深合并（`rules-prepend` / `rules-append` 展平，受管字段不被覆盖）
- **带鉴权的 HEALTHCHECK**：新增 `healthcheck.sh`，替代裸探 9090

### 修复

- **管理页密码以 `-` 开头时静默失效**：`cryptpw` 会把 `-xxx` 当选项解析、输出空哈希，
  导致设置了 `MGR_PASSWORD` 却没有鉴权；参数前加 `--` 修复（busybox cryptpw 支持）
- **别名订阅的规则引用丢失（真实机场配置实测发现）**：`yq -P` 会把 emoji 等非 BMP 字符
  写成 `"\U0001F6D1..."`；规则整行剥掉外层双引号后未解码转义，与已解码的名字表比对失败，
  策略名不加别名前缀 → mihomo 重载 `proxy [xxx] not found` 400 并回滚。
  现在双引号规则先 `yqdec` 解码再切分重建（`sub.sh`）
- **别名以 `#` 开头被当注释跳过**：`sub_urls.txt` / CGI 仅在行首 `#` 且不含 TAB 时按注释处理，
  `#1` 这类别名可正常订阅、列表展示与用量统计
- **别名含反斜杠被 `awk -v` 转义吞掉**：前缀改经环境变量传入 awk（`ENVIRON["PRE"]`），原样保留

### 修复（移植自上游 3.0.0）

- 本机/下载请求绕开 `http_proxy` 等代理变量，防止经由自身 7890 自环
- 订阅下载加 `--retry` + 跟随跳转 + HTTP 状态码校验（原来只看 curl 退出码）
- Clash 格式检测允许行首空格
- 热重载同时接受 200/204，失败回滚而不是留下坏配置
- **就绪探测带鉴权**：设置 `SECRET` 后 `init.sh` 的无鉴权探测被 401 误判为启动超时，
  容器陷入重启循环、`:9091` 起不来；现探测带 `Authorization` 头并改用 `/version` 端点
- **多订阅同名节点去重**：合并时同名只保留第一次出现（mihomo 要求 name 唯一，
  否则重载 400）；失败配置另存 `config.yaml.bad` 并记录重载回包，便于排查
- **YAML 规范化**：每个订阅先经 `yq -P` 统一为标准块样式（flow 单行/顶格/CRLF 等手搓格式），
  再做别名前缀与去重；文本比对只认规范化后的形式，深层嵌套内容不受影响

### 刻意未跟进（保护网页多订阅功能）

- `cron` 环境变量定时模型 → 保留管理页面的 `15min` / `hourly` / `daily`
- Zashboard 面板 → 保留 metacubexd
- `sub_url` 用 `|` 分隔的单变量多订阅 → 保留 `sub_urls.txt` 文件 + 管理页面

### CI

- 镜像名硬编码 `lsw951753/mihomo-sub` → 跟随 `github.repository` 自动适配 fork
- 新增 GHCR 推送（`ghcr.io/<owner>/<repo>`，免注册）；Docker Hub 改为可选（设置 secrets 才推送 + 同步 README）

---

## [2.0.0] — 2026-05-29

### 新增

- **Web 管理页面**（`:9091`）：订阅增删、定时刷新配置、一键手动刷新、日志查看、跳转 metacubexd 面板
- **多订阅支持**：自动合并多个订阅的节点和规则
- **定时刷新**：支持每 15 分钟、每小时、每天三种调度
- **手动刷新**：管理页面一键触发，带 30 秒防重复冷却
- **配置持久化**：空挂载目录自动补全初始文件，更新镜像不丢配置
- **容器启动检测**：mihomo 和 subconverter 启动超时自动退出
- **日志自动截断**：超 1MB 只保留最新 50KB
- **HEALTHCHECK**：每 2 分钟检查 mihomo API 可用性
- **下载完整性校验**：构建时验证 tgz 压缩包完整性
- **MIT License** + 免责声明

### 修复

- `printf "%b"` 改为 `printf "%s"`，防止订阅数据中的转义序列破坏 YAML
- Windows 换行符（`\r`）自动去除
- subconverter UA 参数失效问题：curl 直接下载，按需走 subconverter 兜底
- 配置重载失败静默忽略 bug（`sub_exit_code` → `reload_exit_code`）
- 错误路径 `exit 0` → 正确传递退出码
- 多架构构建默认 case 不再静默降级

### 变更

- **Dockerfile**：新增 busybox-extras、EXPOSE 9091、架构严格匹配
- **环境变量**：移除已废弃的 `config_url`
- **CI/CD**：PR 仅构建不推送、login-action v3、README 自动同步到 Docker Hub、GHA 缓存加速

---

## [1.x] — 2026-05-28 及更早

- Docker 化 mihomo + subconverter + metacubexd
- 单订阅环境变量配置
- 每日 cron 订阅更新
- 多架构构建支持
- GitHub Actions 自动构建推送

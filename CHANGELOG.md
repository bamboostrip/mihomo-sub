# Changelog

## [Unreleased]

### 新增

- **订阅别名**：管理页面可为每条订阅设别名，合并时节点名/策略组名/引用统一加 `别名 | ` 前缀。
  同一家多账号不再重名冲突，面板选节点时可区分流量归属。`sub_urls.txt` 行格式为
  `别名<TAB>URL`（无 TAB 即老格式纯 URL，完全兼容）。CGI 新增 `rename` 接口，页面有别名徽标 + 「改名」按钮
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

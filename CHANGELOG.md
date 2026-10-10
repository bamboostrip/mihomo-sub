# Changelog

## [Unreleased]

### 新增

- **开箱即用 `docker-compose.yaml`**：仓库自带一份可直接拷贝使用的 compose 示例（host 网络 + `/dev/net/tun`
  + NET_ADMIN 已配好，TUN 开关开箱可用；`SECRET` / `MGR_PASSWORD` / `MGMT_PORT` 等均为注释示例，
  附桥接端口映射的替代写法）
- **TUN 网页开关（与 `overlay.yaml` 联动）**：管理页「TUN 全局代理」开关直接读写 `overlay.yaml` 的 tun 段——
  开启自动补齐默认字段（mixed / 1500 / auto-route / dns-hijack）并把本机 DNS 加入 `route-exclude-address`
  （防 host 模式劫持解析），不覆盖已有自定义与注释；关闭写 `tun.enable: false`。切换立即 PATCH 生效并触发
  刷新；配置持久源只有 `overlay.yaml`（`config.yaml` 为自动生成产物）；9090 metacubexd 的 TUN 开关仅临时
  生效、刷新后恢复（页面检测不一致时提示）
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

- **切换后可见进度**：订阅「切换」/ 合并方式 / TUN 开关触发刷新后，管理页轮询日志与状态（最多 30 秒）展示进度
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

- **修改/去掉 SECRET 后启动重启循环**：`init.sh` 原来只在缺少 `secret` 行时追加，改密钥后
  `config.yaml` 里的旧值与启动探测用的新值不一致 → 探测一直 401 → 重启循环，而 `sub.sh`
  要等探测通过才运行、无法自愈；现在每次启动强制同步顶层 `secret` 行（含去掉密钥的场景）
- **管理页密码以 `-` 开头时静默失效**：`cryptpw` 会把 `-xxx` 当选项解析、输出空哈希，
  导致设置了 `MGR_PASSWORD` 却没有鉴权；参数前加 `--` 修复（busybox cryptpw 支持）
- **别名订阅的规则引用丢失（真实机场配置实测发现）**：`yq -P` 会把 emoji 等非 BMP 字符
  写成 `"\U0001F6D1..."`；规则整行剥掉外层双引号后未解码转义，与已解码的名字表比对失败，
  策略名不加别名前缀 → mihomo 重载 `proxy [xxx] not found` 400 并回滚。
  现在双引号规则先 `yqdec` 解码再切分重建（`sub.sh`）
- **别名以 `#` 开头被当注释跳过**：`sub_urls.txt` / CGI 仅在行首 `#` 且不含 TAB 时按注释处理，
  `#1` 这类别名可正常订阅、列表展示与用量统计
- **别名含反斜杠被 `awk -v` 转义吞掉**：前缀改经环境变量传入 awk（`ENVIRON["PRE"]`），原样保留
- **重启死循环（数据卷留有坏配置且无 good 可回滚）**：首次运行生成的配置若被 mihomo 拒绝
  （如引用了不存在的策略），坏文件留在 `config.yaml` 原地——没有 `config.yaml.good` 可回滚，
  容器下次重启核心起不来 → 探测 10 次失败退出 → docker 无限重启，`sub.sh` 要等探测通过才运行、
  永远没机会自愈。现在两处兜底：`init.sh` 启动前用 `mihomo -t` 校验数据卷的 `config.yaml`
  （坏配置可能来自上次断电留下的半成品），失败先备份为 `config.yaml.bad` 再回退
  （good 优先，否则用内置初始配置）；`sub.sh` 生成的配置落盘前同样先过 `mihomo -t` 校验，
  失败另存 `.bad` 并保留现有配置
- **并发刷新互相写坏配置**：cron 定时、管理页手动刷新、切换订阅 / TUN 等多个入口同时触发
  `sub.sh` 时，多个实例会交叉写 `config.yaml` 与 good 文件；现在加 flock 单实例锁
  （`/tmp/mihomo_sub.lock`），已有刷新在跑时后来者记一条日志直接让路
- **CGI 并发写 `sub_urls.txt` 丢更新**：add / delete / rename / toggle / solo 并发请求时，
  后写者用读到的旧内容覆盖先写者的修改；现在对 `sub_urls.txt` 的读改写统一加锁串行化
  （busybox flock 无超时参数，改用非阻塞 + 100ms 轮询，最多等 5 秒后按「操作冲突」失败）
- **同名策略组误并非成员项**：合并同名组时，重复组里 `use:` 等非 `proxies:` 列表的序列项
  被一律当成组成员并入首个组，引用不存在的 provider 名导致 mihomo 拒绝配置；现在只收集
  位于本组 `proxies:` 键之后的真正成员行
- **provider 类订阅明确跳过（已知限制）**：订阅含 `rule-providers:` / `proxy-providers:` 段
  （`RULE-SET` 规则、组 `use:`，机场原生 clash 配置常见）时，本项目只合并
  proxies / proxy-groups / rules 三段，拼出的配置必然被拒；此前照常参与合并、生成的配置
  被拒后整次刷新失败，现在整条订阅跳过并在日志 / 管理页提示「暂不支持合并」，建议换该
  机场的其他订阅格式（base64 / 通用订阅链接经 subconverter 转换不受影响）
- **别名长度仅前端限制**：页面 `maxlength` 只是装饰，直接调 API 可提交任意长度别名；
  add / rename 后端强制上限 128 字节，超出报「别名过长」
- **删除订阅残留流量存档**：删除订阅时同步清理 `usage/` 下对应的 `.dat` 存档，不再留孤儿文件
- **管理页轮询计时器叠加**：切换订阅 / 改合并方式 / TUN 开关连点会叠加多个轮询 interval
  重复刷日志与状态；新轮询启动前先清掉旧的

### 安全加固

- **solo 误操作防护**：「切换」接口传入不存在的 URL 时，此前会先把**所有**订阅写成 `off`
  才发现「订阅不存在」——一次传错 URL 即全部停用；现在改写文件前先做只读存在性检查，
  不存在直接报错、绝不碰文件
- **subconverter 只监听 `127.0.0.1`**：其编译默认监听 `0.0.0.0:25500` 且无鉴权，host 网络下
  等于局域网可用的「任意 URL 抓取回传」服务（SSRF 面）；镜像内置 `pref.ini` 改为仅本机监听，
  容器内订阅转换不受影响
- **CGI 写操作要求 `X-Requested-With` 头（对外行为变化）**：POST 写操作必须携带该自定义头
  （HTML 表单无法设置自定义头，跨站 fetch 带自定义头会触发 CORS 预检被拦），官方管理页
  已自动携带；**直接调 CGI API 的脚本需自行加 `X-Requested-With` 请求头**，否则返回
  `{"error":"非法请求"}`。`refresh`（触发刷新）一并从 GET 改为 POST 并纳入此校验，
  堵住跨站 `<img>` 触发刷新的残留路径
- **健康探测绕开代理环境变量**：容器设置 `http_proxy`（且 `no_proxy` 不含 `127.0.0.1`）时，
  healthcheck 的裸 curl 会绕道 mihomo 自身再去探 `127.0.0.1:9090`，把健康容器误判为
  unhealthy；探测改用与 `init.sh` 同款的代理变量剥离

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

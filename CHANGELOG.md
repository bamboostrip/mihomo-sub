# Changelog

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

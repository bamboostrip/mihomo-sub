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

## 内置工具

- `mihomo` — 代理核心
- `metacubexd` — Web 代理管理面板
- `subconverter` — 本地订阅转换
- `sub.sh` — 订阅更新脚本
- 管理页面 — 订阅配置 Web 界面

## 服务端口

| 端口 | 用途 |
|------|------|
| `7890` | 代理 mixed 端口 |
| `9090` | mihomo API + Web 面板 (`/ui`) |
| `9091` | 订阅管理页面 |

## 部署

### Docker Compose（推荐）

```yaml
services:
  mihomo:
    image: lsw951753/mihomo-sub:latest
    container_name: mihomo-sub
    volumes:
      - ./mihomo-config:/root/.config/mihomo
    environment:
      - TZ=Asia/Shanghai
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
  lsw951753/mihomo-sub:latest
```

挂载 `./mihomo-config` 后，以下文件会持久化到宿主机，更新镜像不会丢失：

| 文件 | 用途 |
|------|------|
| `sub_urls.txt` | 订阅链接列表（一行一个） |
| `schedule.conf` | 定时策略 (`15min` / `hourly` / `daily`) |
| `user_agent.txt` | 自定义 User-Agent（一行，可选） |
| `config.yaml` | mihomo 代理配置（自动生成） |
| `log.txt` | 更新日志 |

### 环境变量

| 变量 | 必填 | 说明 |
|------|------|------|
| `TZ` | 推荐 | 时区，如 `Asia/Shanghai` |
| `sub_url` | 否 | 初始订阅 URL（首次启动时写入 `sub_urls.txt`，之后通过管理页面管理） |

## 使用

### 管理页面

浏览器打开 `http://<服务器IP>:9091`：

1. **添加订阅** — 粘贴订阅 URL，点击添加
2. **设置调度** — 选择刷新频率（15分钟/每小时/每天）
3. **手动刷新** — 点击「立即刷新」按钮（注意：手动刷新会重置调度计时器，可能导致下次定时刷新延后一个周期）
4. **打开面板** — 点击「打开面板」跳转到 metacubexd 代理管理

### 代理面板

`http://<服务器IP>:9090/ui` — metacubexd 面板，管理代理规则、切换节点、查看连接等。

### 手动执行订阅更新

```bash
docker exec mihomo-sub /etc/periodic/15min/sub.sh --now
```

## 常见问题

**Q: 更新镜像后配置会丢失吗？**

不会。只要挂载了 `/root/.config/mihomo` 目录，`sub_urls.txt` 和 `schedule.conf` 都在宿主机上，更新镜像不受影响。初始文件（如 Web 面板）也会在容器启动时自动补全。

**Q: 可以直接挂载空目录吗？**

可以。容器启动时检测到缺失的文件会自动从内置模板生成，空目录挂载完全没问题。

## 源码和仓库

- 源码: `https://github.com/pure-white-ice-cream/mihomo-sub`
- Docker Hub: `https://hub.docker.com/r/purewhiteicecream/mihomo-sub`

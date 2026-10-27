# deploy-kit · 服务器发布中枢

把「构建」从服务器搬到 CI，服务器只负责**取货 → 原子切换 → 健康检查 → 失败回滚**。

## 为什么

单机 2C / 1.9 GiB 内存的 VPS 上，`npm run build` 实测峰值 **1.19 GiB**，
而服务器 available 只有 1.3 GiB —— 每次发前端都在 OOM 边缘，
服务器还常驻 280 MB 用不上的 `node_modules`。

搬到 CI 之后：

| | 改造前 | 改造后 |
|---|---|---|
| 服务器构建前端 | 是（峰值 1.19 GiB） | **否** |
| 服务器 node_modules | 280 MB | **0** |
| 发版耗时 | 20s ~ 几分钟（含 swap 抖动） | 秒级（取产物 + 重启容器） |
| 前后端版本 | 可能错位 | **永远同一个 sha** |
| 内存峰值 | 1.19 GiB | ~0（只剩容器重建） |

## 组成

```text
deploy-kit/
├── .github/workflows/deploy.yml   # 通用发布流程（reusable workflow）
├── server/
│   ├── releaser.sh                # 发布器：apply / rollback / status / has
│   ├── push-incoming.sh           # 受限 SSH 入口（authorized_keys 的 command=）
│   ├── install-server.sh          # 服务器端一条命令装好
│   └── projects.d/<项目>.env      # 项目注册表
├── server/tests/releaser-rehearsal.sh   # 本地彩排（73 断言）
└── docs/部署架构方案.md
```

## 新项目接入（三步）

### ① 服务器上装一次

把 `deploy-kit/server/` 传到服务器，然后：

```bash
sudo -i
cd /root/deploy-kit/server
bash install-server.sh --project <项目名>
```

它会：
- 把 `releaser.sh` / `push-incoming.sh` / 项目配置装到 `/opt/deploy-kit`
- 建好 `incoming/`（产物落地）和 `releases/web/`（版本留存）
- 生成一把 CI 专用 SSH 密钥，写进 `/root/.ssh/authorized_keys`，
  带 `command="/opt/deploy-kit/push-incoming.sh",restrict` 限制

先看它要做什么：`bash install-server.sh --project <项目名> --dry-run`

### ② GitHub Secrets（仓库级）

| Secret | 说明 |
|---|---|
| `DEPLOY_HOST` | 服务器地址 |
| `DEPLOY_USER` | SSH 用户（装了 deploy-kit 的那个） |
| `DEPLOY_SSH_KEY` | 私钥内容（install-server.sh 打印了它在哪） |
| `DEPLOY_PORT` | 可选，默认 22 |

### ③ 项目仓加一个 workflow

```yaml
name: deploy
on:
  push:
    branches: [main]
  workflow_dispatch:

jobs:
  deploy:
    uses: fmd99833125/deploy-kit/.github/workflows/deploy.yml@v1
    with:
      project: <项目名>            # 对应服务器 projects.d/<项目名>.env
      web_dir: web                # 前端源码目录
      api_image: <项目名>-api     # 后端镜像名；留空 = 没有后端镜像
      api_dockerfile: deploy/Dockerfile.api
      image_context: .
      node_version: "22"
      skip_paths: '^(docs/|.*\.md$)'   # 只改文档时不发布
    secrets: inherit
```

完事。以后这个项目的每次 push 都会自动构建 → 上传 → 原子发布。

## 多项目怎么不打架

「打架」的本质是**三个全局命名空间**。每个项目在这三个里都得有自己独立的一套：

| 维度 | 隔离手段 | 撞了会怎样 |
|---|---|---|
| 主机端口 | 每个项目一个 compose 项目，端口只在容器内 expose | 第二个项目抢 443 |
| 容器/卷名 | compose `name:` 不同 → 卷名 `<name>_pgdata` 不同 | 🔴 **两个项目数据混进同一个卷** |
| systemd unit | `learning-deploy.timer` vs `<项目>-deploy.timer` | unit 互相覆盖 |
| 部署路径 | `/opt/learning/` vs `/opt/<项目>/` | 文件互相覆盖 |
| 环境变量前缀 | `LEARNING_*` vs `<项目>_*` | `.env` 串味 |

**统一入口 Caddy**（多项目共用 80/443）属于第二期工作，
第一期每个项目自己独占自己的端口 / 域名。

## 服务器上常用命令

```bash
/opt/deploy-kit/releaser.sh status xuexu     # 当前版本 / 可回滚版本 / 本地镜像
/opt/deploy-kit/releaser.sh rollback xuexu    # 回滚到上一个成功版本
/opt/deploy-kit/releaser.sh has xuexu <sha>   # 某版本的产物是否已就绪
```

## 回滚

- **自动**：发布后健康检查不过 → 自动回滚（前端换回旧目录 + 镜像 tag 换回 + 重建容器）
- **手动**：`releaser.sh rollback <项目>` —— 旧的前端目录和旧镜像都留着，随时能滚回去
- **保留策略**：默认留最近 3 个版本（`projects.d/<项目>.env` 里的 `KEEP_RELEASES`）

## 安全模型

CI 要往服务器推产物，就得有服务器私钥。私钥放在 GitHub Secrets，泄露风险有，但**影响面被限死**：

```
authorized_keys:
  command="/opt/deploy-kit/push-incoming.sh",restrict ssh-ed25519 AAAA... github-actions
```

`command=` 会顶掉 SSH 客户端请求的任何命令，`restrict` 禁掉 pty / 端口转发。
泄露这把密钥，攻击者最多只能「把已经推上去的产物发布一下」，拿不到 shell。

`push-incoming.sh` 只认白名单子命令，且项目名、sha、上传路径都做严格格式校验：

| 命令 | 允许 | 拒绝的例子 |
|---|---|---|
| `scp -t <path>` | `<项目产物目录>/<sha>.{web-dist,api-image}.tar.gz` | `/etc/passwd`、`../../etc/x`、`nothex.web-dist.tar.gz` |
| `apply <项目> <sha>` | 项目名 `^[a-z0-9][a-z0-9-]{0,30}$`、sha `^[0-9a-f]{7,40}$` | `apply xuexu; rm -rf /`、`apply ../../etc` |

这些都有彩排断言覆盖（`server/tests/releaser-rehearsal.sh` T7）。

## 本地彩排

```bash
bash server/tests/releaser-rehearsal.sh
```

用假服务器目录 + 假 docker / flock / scp，把整条发布链路真跑一遍：
正常发布、产物缺失、健康检查失败自动回滚、幂等、保留策略、手动回滚、
**16 条命令注入/路径穿越防护**、安装脚本。
共 73 条断言。

> 写完只做 `bash -n` 语法检查等于不知道会不会炸 ——
> 2026-10-26 在 xuexu 迁移上已经吃过一次亏（彩排揪出 5 个「上生产必炸」Bug）。
> 本仓第一批彩排也揪出 7 个（含 4 处 UTF-8 locale 下会崩的多字节变量名）。

## 相关

- [部署架构方案](./docs/部署架构方案.md)
- xuexu 的接入实例：`../xuexu/deploy/`

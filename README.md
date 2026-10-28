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

## 新项目接入（一条命令 + 两步）

### ① 一条命令生成接入物料

在 deploy-kit 仓根目录：

```bash
bash server/new-project.sh --name <项目名> \
     --project-repo ../<项目仓> \
     --api-image <项目名>-api \
     --api-dockerfile deploy/Dockerfile.api
```

它生成两个文件：

| 文件 | 内容 |
|---|---|
| `server/projects.d/<项目名>.env` | 服务器上的项目注册表（路径、镜像名、要重建哪些服务） |
| `<项目仓>/.github/workflows/deploy.yml` | 调用本仓 reusable workflow 的调用方 |

常用开关：

| 开关 | 用途 |
|---|---|
| `--no-api` | 纯前端项目（没有后端镜像） |
| `--health-services "api caddy"` | 健康检查看哪些服务 |
| `--app-services api` | 换镜像后重建哪些容器 |
| `--web-services caddy` | 换前端后重建哪些容器 |
| `--deploy-root /opt/<项目名>` | 服务器上的部署根目录 |
| `--package-manager npm\|pnpm\|yarn` | 前端包管理器（默认 npm） |
| `--workflow-ref v2` | 引用 deploy-kit 的哪个 tag（默认 v2） |
| `--dry-run` | 只看要生成什么，不落盘 |

> 多词的值（`--health-services "api caddy"`）生成时会**自动加引号** ——
> 注册表条目是被 `.`（source）进 shell 的，不加引号时 `api caddy` 会被解析成两条赋值，
> 第二个词被当成命令执行（exit 127）。

### ② 服务器上装一次

把 `deploy-kit/server/` 传到服务器，然后：

```bash
sudo -i
cd /root/deploy-kit/server
bash install-server.sh --project <项目名>
```

它会：
- 把 `releaser.sh` / `push-incoming.sh` / 项目配置装到 `/opt/deploy-kit`
- 建好 `incoming/`（产物落地）和 `releases/web/`（版本留存）
- 生成一把**本项目专属**的 CI 密钥 `/root/.ssh/deploy_ci_<项目名>_ed25519`，
  写进 `/root/.ssh/authorized_keys`，
  带 `command="/opt/deploy-kit/push-incoming.sh --project <项目名>",restrict` 限制

先看它要做什么：`bash install-server.sh --project <项目名> --dry-run`

> ⚠️ **钥匙必须按项目分**（`deploy_ci_<项目名>_ed25519`）：
> ① 同一把公钥不能当两个项目的 deploy key；
> ② OpenSSH 只认 `authorized_keys` 里**第一条**匹配公钥的授权行 →
> 两个项目共用一把钥匙，**第二个项目的授权行永远不生效**，
> 而安装脚本还会「看着成功」地退出 0（最难查的一类静默失效）。
> 所以：**装第二个项目时它会给新项目生成新钥匙**；重装同一个项目时它会
> **沿用那把已授权的旧钥匙**（不换密钥 → 你的 GitHub Secret 不用改）。

### ③ GitHub Secrets（仓库级）

| Secret | 说明 |
|---|---|
| `DEPLOY_HOST` | 服务器地址 |
| `DEPLOY_USER` | SSH 用户（装了 deploy-kit 的那个） |
| `DEPLOY_SSH_KEY` | 私钥内容（install-server.sh 打印了它在哪） |
| `DEPLOY_PORT` | 可选，默认 22 |

完事。以后这个项目的每次 push 都会自动构建 → 上传 → 原子发布。

### 生成的 workflow 长这样

```yaml
jobs:
  deploy:
    uses: fmd99833125/deploy-kit/.github/workflows/deploy.yml@v2
    with:
      project: <项目名>            # 对应服务器 projects.d/<项目名>.env
      web_dir: web                # 前端源码目录
      api_image: <项目名>-api     # 后端镜像名；留空 = 没有后端镜像
      api_dockerfile: deploy/Dockerfile.api
      image_context: .
      node_version: "22"
      package_manager: npm        # npm / pnpm / yarn
      skip_paths: '^(docs/|.*\.md$)'   # 只改文档时不发布
    secrets: inherit
```

> ⚠️ **用 `@v2`**：`v1` 只支持 npm，`v2` 才带 `package_manager` 输入
> （用 v1 又传 `package_manager` 会报 `Invalid input, package_manager is not defined`）。
> xuexu 目前还钉在 `@v1`（它用 npm，两版对它是等价的），升版见
> [`docs/未完成工作清单.md`](./docs/未完成工作清单.md)。

### 包管理器

| 值 | 装依赖 | 锁文件 | 备注 |
|---|---|---|---|
| `npm`（默认） | `npm ci` | `package-lock.json` | |
| `pnpm` | `pnpm install --frozen-lockfile` | `pnpm-lock.yaml` | **CI 里的 pnpm 大版本从项目自己的锁文件推断**（v5.4→pnpm7 / v6.0→pnpm8 / v9.0→pnpm9），不在 workflow 里另配一份，免得和项目脱节 |
| `yarn` | `yarn install --frozen-lockfile` | `yarn.lock` | |

装依赖前会先检查锁文件在不在 —— 缺了会直接报「找不到锁文件 xxx」，
而不是让 `setup-node` 的缓存步骤抛一句看不懂的错。

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
  command="/opt/deploy-kit/push-incoming.sh --project xuexu",restrict ssh-ed25519 AAAA... github-actions
```

`command=` 会顶掉 SSH 客户端请求的任何命令，`restrict` 禁掉 pty / 端口转发。
泄露这把密钥，攻击者最多只能「把已经推上去的产物发布一下」，拿不到 shell。

### ⭐ 密钥与项目绑定

`--project <项目名>` 把这把密钥**焊死在一个项目上**：

- 只能往**该项目**的产物目录里上传
- 只能发布 / 查询**该项目**
- **没绑定的密钥一律拒**（没有逃生口）

为什么必须绑：多项目共用一台服务器时，不绑就等于**kids 的 CI 密钥能往 xuexu 的产物目录里塞文件、
也能触发 xuexu 的发布** —— 一条现成的横向越权通道。这条是多项目彩排（T9）实测出来的。

> 绑定信息写在 `authorized_keys` 的强制命令里，**不靠脚本猜**：
> 同一把密钥服务多个项目时，各装一把带各自 `--project` 的密钥即可。

### 命令白名单

`push-incoming.sh` 只认白名单子命令，且项目名、sha、上传路径都做严格格式校验：

| 命令 | 允许 | 拒绝的例子 |
|---|---|---|
| `scp -t <path>` | `<本项目产物目录>/<sha>.{web-dist,api-image}.tar.gz` | `/etc/passwd`、`../../etc/x`、`nothex.web-dist.tar.gz`、**别的项目的目录** |
| `apply <项目> <sha>` | 项目名 `^[a-z0-9][a-z0-9-]{0,30}$`、sha `^[0-9a-f]{7,40}$` | `apply xuexu; rm -rf /`、`apply ../../etc`、**apply 别的项目** |

这些都有彩排断言覆盖（`server/tests/releaser-rehearsal.sh` T7 / T9）。

## 项目配置（`projects.d/<项目名>.env`）

| 键 | 说明 |
|---|---|
| `PROJECT_NAME` | 项目标识 |
| `REPO_DIR` / `DEPLOY_DIR` | 服务器上的代码仓 / 部署目录 |
| `RELEASES_DIR` / `ARTIFACT_DIR` | 版本留存 / 产物落地 |
| `WEB_SUBDIR` | 前端产物在 `deploy/` 下的子目录 |
| `API_IMAGE` | 后端镜像名。**显式留空 = 本项目没有后端镜像**（纯前端站） |
| `APP_SERVICES` | 换镜像后要重建的容器（跑业务代码的） |
| `WEB_SERVICES` | 换前端后要重建的容器（bind mount 绑着 web 目录的） |
| `HEALTH_SERVICES` | 健康检查看哪些服务：全部 running/healthy 才算发布成功 |
| `KEEP_RELEASES` | 保留最近几个版本 |

## 本地彩排

```bash
bash server/tests/releaser-rehearsal.sh
```

用假服务器目录 + 假 docker / flock / scp，把整条发布链路真跑一遍：
正常发布、产物缺失、健康检查失败自动回滚、幂等、保留策略、手动回滚、
**命令注入/路径穿越防护**、安装脚本、
**多项目接入与隔离**（T9：脚手架生成、纯前端项目、两个项目互不干涉、跨项目越权被拒）。
共 **138 条断言**。

> ⚠️ 2026-10-28 踩坑：workflow 里同一个 step 写了两条 `if`，GitHub 判
> `Invalid workflow file ... 'if' is already defined` —— 而 Python 的 `yaml.safe_load`
> 对**重复键是静默覆盖**，本地校验全绿也照样炸。
> 现已把**严格 loader 静态体检**（重复键 / step id / input 引用）加进彩排，
> 并做过**负向测试**确认它真能抓到。

> 写完只做 `bash -n` 语法检查等于不知道会不会炸 ——
> 2026-10-26 在 xuexu 迁移上已经吃过一次亏（彩排揪出 5 个「上生产必炸」Bug）。
> 本仓彩排至今揪出 **9 个**（含 4 处 UTF-8 locale 下会崩的多字节变量名、
> 「注册表多词值没加引号」这类**上服务器必炸**的问题、以及 1 条**跨项目越权**漏洞）。

## 已接入的项目

| 项目 | 状态 | 备注 |
|---|---|---|
| `xuexu` | ✅ 改造完成 | Caddy 托管前端 + 反代 api；compose 项目名 `learning`（**别改**） |
| `kids-english-copilot` | ✅ 接入物料齐备 | FastAPI 同域托管前端，单容器；compose 项目名 `kids-copilot` |

## 相关

- [部署架构方案](./docs/部署架构方案.md)
- [未完成工作清单](./docs/未完成工作清单.md) ← **接着干先看这个**
- xuexu 的接入实例：`../xuexu/deploy/`
- kids 的接入实例：`../kids-english-copilot/deploy/`

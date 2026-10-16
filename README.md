# alice

**一个 ssh 接入的远程开发容器**：Arch Linux + AUR 打底，nix 管 per-project 环境，
GNU Shepherd 管服务。可以在里面跑常驻的 AI agent 服务。

- 系统层：Arch Linux + pacman（FHS / PAM / su / sudo / npm 全部原生正常）
- AUR：paru + shepherd（服务管理）；TOTP 用官方 libpam-google-authenticator
- per-project：nix（`nix develop`，每个项目自己的 flake）
- 服务管理：GNU Shepherd（PID 1），配置文件在 `~/.config/alice/service/*.scm`
- 认证：**密码 + TOTP 双因素**，只绑 `127.0.0.1`

> **海外用户**：构建默认走中国大陆镜像源（`image/Dockerfile` 里的 TUNA / 南大 / USTC），
> 时区默认 `Asia/Shanghai`（compose.yml）——都可按需自行替换。

---

## 快速开始

### 1. 拿到项目

```sh
git clone <repo> ~/alice
```

### 2. 准备实例目录

实例目录只放配置（`compose.yml` + `.env`），和项目代码分开；
数据目录由 `.env` 的 `HOME_DIR` 单独指定，名字、位置任意：

```sh
mkdir -p ~/alice-data
cd ~/alice-data
cp ~/alice/compose.yml.example compose.yml
cp ~/alice/.env.example .env
```

### 3. 编辑配置

```sh
vim .env
```

| 变量 | 说明 |
|---|---|
| `CONTAINER_NAME` | 容器名，也用作 hostname |
| `USER_NAME` | 容器内用户名 |
| `USER_UID` / `USER_GID` | 该用户的 uid/gid，**必须与宿主侧 `HOME_DIR` 的属主一致**（否则 entrypoint 只修正家目录顶层，子目录属主不对会让 sshd 拒绝认证） |
| `SSH_PORT` | 宿主侧 sshd 端口（映射到容器内 22） |
| `HOME_DIR` | 宿主侧家目录（挂载为容器内 /home/<用户名>，名字、位置任意） |
| `PROJECT_DIR` | 本项目所在路径（用于构建镜像） |
| `IMAGE_NAME` | 镜像名 |

> **所有变量都是必填**。任何一个缺失或留空，`docker compose` 会立即报错，且不会创建任何目录。
> `HOME_DIR` 和 `PROJECT_DIR` 在示例里**故意留空**——留空即报错，避免忘改时
> 静默创建 `/home/you/...` 或从错误的路径构建镜像。

### 4. 启动

```sh
docker compose up -d
```

首次会自动构建镜像（约 3-5 分钟，含 AUR 编译）。

### 5. 初始化

```sh
# 设置登录密码
docker exec -it alice passwd <USER_NAME>

# 初始化 TOTP（显示二维码，用手机扫描）
docker exec -it -u <USER_NAME> alice google-authenticator
```

> 用户初始是 `locked` 状态，**未设密码前无法登录**。

### 6. 连接

```sh
ssh -p <SSH_PORT> <USER_NAME>@127.0.0.1
#   Password: <你的密码>
#   Verification code: <手机上的 6 位码>
```

---

## 日常使用

```sh
cd ~/alice-data    # 你的实例目录

docker compose up -d              # 启动 / 应用配置变更（改了 .env 或 compose.yml 之后）
docker compose down               # 停止
docker compose logs -f            # 看日志

# 改了项目 image/ 里的东西（Dockerfile / 服务定义 / 配置模板）后重建镜像
# （compose 发现镜像或配置变化时会自动重建容器，不用额外加 --force-recreate）
docker compose up -d --build
```

**进容器**：

```sh
docker exec -it -u <USER_NAME> alice bash
```

**容器内**：

```sh
sudo herd status                  # 服务状态（shepherd 是 root，herd 一律 sudo）
sudo -i                           # 提权（免密）
nix develop                       # 进项目的开发环境（需项目里有 flake.nix）
```

---

## 目录约定

家目录（宿主的 `$HOME_DIR`）随你怎么用，预建的只有功能目录：

```
~/.config/alice/service/    # 服务定义 *.scm（shepherd 自动加载）
~/.local/share/alice/       # alice 自身状态（ssh host key 等）
```

`service/` 里放一个 `.scm` 文件就是一个服务，加服务不用重建镜像：

```sh
# 加服务
vim ~/.config/alice/service/mytool.scm
# 然后重启容器（最省事）
docker compose restart
```

> **`docker compose restart` 只重新执行 entrypoint，不重新读 `.env`。**
> 它的适用场景只有一个：你只改了**卷内**的文件（服务定义 `.scm`）——此时
> `up -d` 反而是 **no-op**（compose 配置哈希没变，判定「up-to-date」后什么都不做，
> 服务不会被重扫；实测）。改了 `.env` / `compose.yml`（用户名、uid、端口、家目录等）请用
> `docker compose up -d` —— compose 会比较配置哈希、变了才重建容器；当前模板引用了
> 全部 `.env` 变量，所以任何变量变更都会改变哈希并触发重建。

---

## 服务管理

### 内置服务 vs 用户服务

| | 内置 | 用户 |
|---|---|---|
| **位置** | `/etc/alice/builtin/*.scm`（镜像内） | `~/.config/alice/service/*.scm`（卷内） |
| **内容** | `sshd` / `nix-daemon` / `log-rotation` | 你自己加的 |
| **改它** | 拷贝到 `~/.config/alice/service/` 再改 | 直接改 |

**加载顺序**：先内置，后用户。**同名服务时用户版本覆盖内置版本**（按服务名判断，与文件名无关），
覆盖发生时日志里会有 `NOTICE`：

```sh
sudo tail -f /var/log/shepherd/service.log
# NOTICE: service 'sshd' was overridden by /home/grimm/.config/alice/service/
```

### 加一个服务

```scheme
;; ~/.config/alice/service/mytool.scm
(use-modules (shepherd service))

(register-services
 (list (service '(mytool)
                #:start (make-forkexec-constructor
                         '("/usr/bin/mytool" "--flag")
                         #:user "grimm"           ; 降权到普通用户
                         #:group "grimm"
                         #:directory "/home/grimm/dev/project"
                         #:log-file "/var/log/mytool/service.log")
                #:stop (make-kill-destructor)
                #:respawn? #t)))
```

要点：

| 项 | 说明 |
|---|---|
| 路径 | 用**绝对路径**（shepherd 用自己进程的 PATH 查找） |
| 日志目录 | **不用先建**，shepherd 自动按 `#:log-file` 创建（文件归 root，查看用 `sudo tail`） |
| 降权 | `#:user` / `#:group`（shepherd 是 root，可以降权） |
| 环境变量 | `#:environment-variables '("HOME=/home/grimm" ...)` |
| 依赖 | 有先后要求时写 `#:requirement '(dep)`（shepherd 先并行拉起依赖再启动本服务）；启动顺序本身按服务名词典序 |
| 写错了 | 只影响这一个文件（打 `WARNING`），不影响容器启动 |

### 注册但不自动启动（按需服务）

重型 / 应急类服务可以只注册、不随启动——平时不占资源，要用时一条命令拉起：

```scheme
;; ~/.config/alice/service/ollama.scm
(use-modules (shepherd service) (alice init))

(register-services
 (list (service '(ollama)
                #:start (make-forkexec-constructor
                         '("/usr/bin/ollama" "serve")
                         #:log-file "/var/log/ollama/service.log")
                #:stop (make-kill-destructor)
                #:respawn? #t)))

(defer-start! 'ollama)   ;; 注册但不自动启动
```

```sh
sudo herd start ollama    # 想用随时开
sudo herd stop ollama     # 用完就停
```

- 声明跟着服务文件走（自包含）；重启 / 重建容器后仍保持「注册不启动」
- 变回自动启动：删掉那行 `defer-start!` 再重启
- ⚠️ 含 `defer-start!` 的文件要热加载，**文件里得自己 `(use-modules (alice init))`**
  （`herd load` 的求值环境默认看不到该绑定，不写就报 `Unbound variable: defer-start!`；
  注意此时 `register-services` 已生效，只是 defer 声明被忽略）
- ⚠️ **不要对 `sshd` 用**——会把自己锁在容器外（只能靠 `docker exec` 救）

### 增删改服务：直接重启容器

```sh
vim ~/.config/alice/service/xxx.scm   # 加 / 改 / 删文件
docker compose restart          # 完事（约 11 秒，见下）
```

重启会重新扫描目录、从零构建注册表，所以「加、改、删」三种情况一律正确。
改服务**只能**用 `restart`：此时 `up -d` 是 **no-op**（compose 配置哈希没变，
判定「up-to-date」后什么都不做，服务不会被重扫）。反过来，改了 `.env` /
`compose.yml` / `image/` 必须用 `docker compose up -d`（`--build`）——
`restart` 不重读 `.env`。

> 每次重启 / 重建都要等 ~11 秒：shepherd 作为 PID 1 收 SIGTERM 后先优雅停服务，
> 再尝试 `reboot()`（容器无 `CAP_SYS_BOOT` 会失败），最后等满 docker 的 10 秒
> 宽限被 SIGKILL。这是 shepherd 在容器里当 PID 1 的固有行为，不是配置问题。

**热加载**（不想重启时）：

| 操作 | `sudo herd load root <file>` |
|---|---|
| 加服务 | ⚠️ 注册成功，但**不会自动启动**，还要 `sudo herd start <svc>` |
| 加服务（文件含 `defer-start!`） | ⚠️ 文件里需自带 `(use-modules (alice init))`，否则报 `Unbound variable: defer-start!`（此时服务已注册，defer 声明被忽略） |
| 改服务 | ⚠️ 还要 `sudo herd restart <svc>` |
| **删服务** | ❌ **无效**（需 `sudo herd unload root <svc>` 或重启） |

---

## per-project 开发环境（nix）

在项目里放 `flake.nix`：

```nix
{
  inputs.nixpkgs.url = "tarball+https://mirror.nju.edu.cn/nix-channels/nixos-26.05/nixexprs.tar.xz";
  outputs = { self, nixpkgs }:
    let system = "x86_64-linux"; pkgs = nixpkgs.legacyPackages.${system};
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [ nodejs_22 uv ripgrep ];
        shellHook = ''echo "dev shell ready"'';
      };
    };
}
```

```sh
cd ~/dev/myproject
nix develop                    # 进环境
nix develop --command <cmd>    # 直接跑命令
```

nixpkgs 已全局指向南大 tarball，`nixpkgs#xxx` 简写可用。
想要 `cd` 进目录自动激活，自己装 direnv 并在 shell rc 里配 hook。

---

## 持久化

**唯一的卷**：`$HOME_DIR` → 容器内的家目录。

| 内容 | 位置 | 重建容器后 |
|---|---|---|
| 代码、dotfiles、服务定义 | 家目录 | ✅ 保留 |
| 全局包记录 | `~/.config/alice/packages.txt` | ✅ 保留（用来恢复下面那行） |
| ssh host key | `~/.local/share/alice/ssh`（root 持有） | ✅ 保留（客户端 known_hosts 仍有效） |
| TOTP 密钥 | `~/.google_authenticator` | ✅ 保留 |
| **登录密码** | `/etc/shadow` | ❌ **丢失，需重设** |
| nix store | `/nix` | ❌ 消失（重新下载） |
| pacman/paru 装的包 | `/usr` | ❌ 消失（镜像只含打底包；自装的按 packages.txt 恢复） |

> nix store 不做自动 gc（容器里没有 systemd timer）：store 随使用持续增长，
> 上限是本次容器的生命周期（重建即清零）。磁盘紧张时可手动 `nix store gc`，
> 或在 `~/.config/alice/service/` 自建一个定时清理服务。

**所以**：镜像只打底——全局工具直接 `pacman -S` / `paru -S` 装，**装/卸后顺手刷新包快照**：
`pacman -Qeq > ~/.config/alice/packages.txt`（纯包名；含打底包无妨，恢复时 `--needed`
自动跳过），重建后一条命令恢复：

```sh
paru -S --needed $(cat ~/.config/alice/packages.txt)
```

项目依赖写进项目的 `flake.nix`。

**重建镜像后**记得重设密码（密码在 `/etc/shadow`，不在卷里）：

```sh
docker compose up -d --build
docker exec -it alice passwd <USER_NAME>
```

---

## 目录结构

```
<项目目录>/
├── README.md              本文档
├── AGENTS.container.md    给容器内 AI agent 的说明书（拷到实例家目录即可）
├── compose.yml.example    容器定义（模板）
├── .env.example           配置示例（模板）
├── .gitignore
├── LICENSE                MIT
└── image/
    ├── Dockerfile         Arch + paru + AUR + nix
    ├── entrypoint.sh      运行期准备（建用户 / host key / 渲染配置）→ exec shepherd
    ├── init.scm           服务加载器（builtin + 用户服务）
    ├── sshd_config.in     sshd 配置模板（占位符由 entrypoint 替换）
    └── builtin/           内置服务定义

<实例目录>/                ← 只有配置（compose.yml、.env，cp 自模板）
<HOME_DIR>/                ← 持久数据（容器家目录，名字/位置任意）
```

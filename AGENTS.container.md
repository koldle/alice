# AGENTS.container.md —— 容器内 AI agent 说明书

> 本文的读者是**运行在 alice 容器里的 AI agent**（不是搭实例的用户）。
> 用法：把它拷到实例的家目录（`~/AGENTS.md`），agent 即可自动读到。
> 这里只写对任何实例都成立的通用事实；实例特有参数（端口映射、宿主侧
> 路径、用户名）定义在宿主侧的 compose.yml / .env 里，你读不到——
> 需要时向用户确认。

## 你所在的环境

alice：一个 ssh 接入的远程开发容器。

- **基底 Arch Linux**：pacman + paru（AUR），原生 FHS / PAM / sudo，sudo 免密
- **PID 1 是 GNU Shepherd**：服务一律用 `herd` 管理，**没有 systemd**
- **环境分层**：全局/系统工具走 pacman/paru（镜像只打底，全局包由
  使用方自己维护，纪律见铁律 1）；项目依赖一律走项目自己的
  `flake.nix` + `nix develop`，不要往全局塞

## 铁律

### 1. 持久化只有家目录 `~`

`~` 是唯一持久卷（bind mount 自宿主）；`/nix`、`/usr`、`/etc` 等随容器
重建**全部丢失**。推论：

- 项目依赖 → 写进项目的 `flake.nix`（可重建、可共享）
- 全局工具 → 直接 `pacman -S` / `paru -S` 装（镜像只打底，不追求全烤进
  镜像），**但装/卸后要刷新包快照**：
  `pacman -Qeq > ~/.config/alice/packages.txt`（纯包名；含打底包无妨，
  恢复时 `--needed` 会跳过）——容器重建后照它恢复：
  `paru -S --needed $(cat ~/.config/alice/packages.txt)`
- nix store 同样在丢失之列，且无自动 gc：磁盘紧张时手动 `nix store gc`

### 2. 常驻进程必须注册成 shepherd 服务

**shepherd 以 root 身份运行（PID 1），`herd` 一律加 `sudo`**：它经
root 私有的 `/run/shepherd/socket` 与 PID 1 通信，连只读的 `herd status`
也要 sudo（不加会报 `.../run/user/1000/shepherd/socket: No such file or
directory`）。服务日志（`/var/log/<name>/service.log`）同样 root 私有（640），
查看也要 sudo。

禁止 `nohup` / `&` 野生守护（无日志、不 respawn、无法管理）。
用户服务写在 `~/.config/alice/service/<name>.scm`，一个文件一个服务。
内置服务（sshd / nix-daemon / log-rotation）的权威定义在
`/etc/alice/builtin/*.scm`——**写新服务时照抄它们的 API 用法**；
想改内置**服务**，把同名文件拷到用户目录改，你的版本会覆盖内置版——
**只有 sshd 例外**：它的行为配置在镜像模板里，覆盖服务文件改不了（见下）。

- 加/改/删服务后请用户执行 `docker compose restart`（重扫服务目录，~11 秒）。
  此时**不要**用 `docker compose up -d`：compose 配置哈希没变，它判定
  「up-to-date」后什么都不做（no-op）。`up -d` 只在改了 `.env` /
  `compose.yml` / `image/` 时使用（自动重建容器，服务随重建重扫；
  而 restart 完全不重读 `.env`）。
  热加载：`sudo herd load root <file>` —— 注意**新服务不会自动启动**，
  还要 `sudo herd start <svc>`（改服务还需 `sudo herd restart <svc>`；
  删服务必须 `sudo herd unload root <svc>`，load 删不掉）
- **带 `(defer-start! ...)` 的文件热加载前，文件里要自己写**
  `(use-modules (alice init))`：`sudo herd load` 的求值环境只有
  `(shepherd service)` 的绑定，不写这行执行到 `defer-start!` 就报
  `Unbound variable: defer-start!`（此时 `register-services` 已生效，
  只是 defer 声明被忽略）。写了就能热加载成功（服务注册为 stopped）
- 重型/按需服务：文件里加 `(defer-start! '<name>)` 注册但不自动起，
  用时 `sudo herd start <name>`。**不要对 sshd 用**（会把自己锁在容器外）
- 服务日志统一在 `/var/log/<name>/service.log`（父目录不用建，
  shepherd 按 `#:log-file` 自动创建；文件归 root（640），看日志用
  `sudo tail`）；shepherd 自身日志在 `/var/log/shepherd/service.log`

**sshd 的行为配置不在服务文件里**：`/etc/alice/builtin/sshd.scm` 只管
启动参数（`-f` 指向哪份配置）。行为配置的唯一来源是镜像内模板
`/etc/alice/sshd_config.in`，entrypoint 每次启动把它渲染到
`/run/alice/sshd_config`（sshd 实际读的就是这份，`/etc/ssh/sshd_config`
从不生效）。所以改 sshd 行为需要请用户改模板并**重建镜像**；容器内直接
改渲染产物只撑到下次重启（每次启动都会重渲染）。把 `sshd.scm` 拷到
用户目录覆盖，也只能改启动参数，改不了行为配置。

服务模板（照抄改即可）：

```scheme
;; ~/.config/alice/service/mytool.scm
(use-modules (shepherd service))
;; 要用 (defer-start! ...) 的话，记得再加上这行（否则热加载会报 Unbound variable）：
(use-modules (alice init))

(register-services
 (list (service '(mytool)
                #:start (make-forkexec-constructor
                         '("/usr/bin/mytool" "--flag")
                         #:user "USER"          ; 降权到普通用户
                         #:group "USER"
                         #:directory "/home/USER/dev/project"
                         #:log-file "/var/log/mytool/service.log")
                #:stop (make-kill-destructor)
                #:respawn? #t)))
```

要点：全部用**绝对路径**；环境变量用
`#:environment-variables '("HOME=/home/USER" ...)`；服务间有先后要求时
在定义里写 `#:requirement '(dep)`（shepherd 会先并行拉起依赖；启动顺序
本身按服务名词典序）。

### 3. 网络与端口

容器在 docker NAT 后面，**只有宿主显式映射的端口外界可达**。
要给宿主/外界用的服务必须监听 `0.0.0.0`——监听容器内 `127.0.0.1`
则宿主永远摸不到。反过来，从容器访问宿主的回环服务走默认网关：
`ip route | awk '/default/{print $3}'`。

### 4. 能力边界

容器即边界：容器内 sudo 免密随便用；但容器里没有 docker，
改镜像、改端口映射、重启容器等宿主侧操作一律请用户执行。
时区 Asia/Shanghai；locale：login shell 兑底 C.UTF-8
（`docker exec` / 服务继承镜像的 ENV LANG=C.UTF-8）。

### 5. 认证已配好，别动

ssh 登录 = 密码 + TOTP（PAM 双因素）。TOTP 密钥
（`~/.google_authenticator`）与 ssh host key
（`~/.local/share/alice/ssh/`）都在持久卷里，重建容器不受影响；
唯独登录密码在 `/etc/shadow`，重建后丢失，需提醒用户重设。

## 速查

| 需求 | 命令 |
|---|---|
| 服务状态 / 启停 | `sudo herd status` / `sudo herd start\|stop\|restart <svc>` |
| 进项目开发环境 | 项目目录下 `nix develop` |
| 全局已装包实况 | `pacman -Qe`（权威清单，别猜） |
| 全局包快照 | 装/卸后跑 `pacman -Qeq > ~/.config/alice/packages.txt`，重建后用上面命令恢复 |
| nix 覆盖受保护配置 | 当前用户在 `@wheel`（trusted），可 `--option substituters ...` |

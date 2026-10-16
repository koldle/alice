#!/bin/bash
# alice entrypoint —— 运行期准备，然后交给 shepherd
#
# 镜像里【不含】普通用户；用户名 / uid / gid 由这里按环境变量创建，
# 所以同一个镜像可以服务多个实例（不同用户名、不同端口）。
#
# 需要的环境变量（由 compose.yml 从 .env 传入）：
#   ALICE_USER   容器内用户名
#   ALICE_UID    该用户的 uid
#   ALICE_GID    该用户的 gid
#
# 只做「依赖卷状态」或「依赖实例配置」的事；系统包 / PAM 等静态配置在构建期完成。
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "must run as root"

: "${ALICE_USER:?ALICE_USER 未设置（应由 compose.yml 从 .env 传入）}"
: "${ALICE_UID:?ALICE_UID 未设置}"
: "${ALICE_GID:?ALICE_GID 未设置}"

# 保留身份直接拒绝：root 被 sshd 禁止登录（PermitRootLogin no），选了只会
# 得到「密码正确却永远登不上」的谜题；uid/gid 0 同理（gid 0 还会触发下面的
# 占用改名逻辑，把 root 组改掉）。
[ "$ALICE_USER" != "root" ] || die "ALICE_USER=root 不允许（sshd 禁止 root 登录）"
[ "$ALICE_UID" != "0" ] || die "ALICE_UID=0 不允许"
[ "$ALICE_GID" != "0" ] || die "ALICE_GID=0 不允许（会把 root 组改名）"

HOME_DIR="/home/$ALICE_USER"
SSH_DIR="$HOME_DIR/.local/share/alice/ssh"
CONFIG_DIR=/etc/alice
RENDERED_CONFIG=/run/alice/sshd_config

# ── 1. 用户与组 ──────────────────────────────────────────────
if ! getent group "$ALICE_USER" > /dev/null 2>&1; then
    if getent group "$ALICE_GID" > /dev/null 2>&1; then
        # gid 已被别的组占用：改名那个组
        log "gid $ALICE_GID taken, renaming to $ALICE_USER"
        groupmod -n "$ALICE_USER" "$(getent group "$ALICE_GID" | cut -d: -f1)"
    else
        groupadd -g "$ALICE_GID" "$ALICE_USER"
    fi
fi

# 防御：组名已存在但 gid 与期望不符时（例如手工删过用户但留了组），
# 后面的 useradd -g 会糊里糊涂失败——提前给出明确报错
existing_gid=$(getent group "$ALICE_USER" | cut -d: -f3)
[ "$existing_gid" = "$ALICE_GID" ] \
    || die "group '$ALICE_USER' exists with gid $existing_gid, expected $ALICE_GID"

if ! getent passwd "$ALICE_USER" > /dev/null 2>&1; then
    # uid 可能被占（例如宿主映射进来的其它用户）——报错退出而不是硬抢
    if getent passwd "$ALICE_UID" > /dev/null 2>&1; then
        die "uid $ALICE_UID already taken by '$(getent passwd "$ALICE_UID" | cut -d: -f1)'"
    fi
    log "creating user $ALICE_USER ($ALICE_UID:$ALICE_GID)"
    useradd -u "$ALICE_UID" -g "$ALICE_GID" -d "$HOME_DIR" -s /bin/bash -M "$ALICE_USER"
else
    # restart 时用户已存在。校验 uid 与配置一致——防的是撞名镜像内系统用户
    # （如 bin/daemon）：跳过创建后 sudoers、家目录 chown 会全落到错误身份上
    existing_uid=$(getent passwd "$ALICE_USER" | cut -d: -f3)
    [ "$existing_uid" = "$ALICE_UID" ] \
        || die "user '$ALICE_USER' exists with uid $existing_uid, expected $ALICE_UID"
fi

# 免密 sudo 全权（容器即边界，容器内不设防）
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$ALICE_USER" > /etc/sudoers.d/90-alice
chmod 0440 /etc/sudoers.d/90-alice

# 加入 wheel：nix.conf 里 trusted-users = root @wheel 按组授权，
# 让普通用户能 --option 覆盖 substituters 等受保护配置。
# 幂等（restart 无副作用）；wheel 在容器内无其他授权（sudoers 的 wheel 行是注释）。
usermod -aG wheel "$ALICE_USER"

# ── 2. 目录骨架（家目录是唯一持久卷，首次可能是空目录）────────
#   注意：Docker 自动创建的 bind mount 目录属主是 root，
#   所以这里必须 chown，否则 sshd 会因权限拒绝认证。
#   只建功能目录（XDG 规范），不预设任何个人习惯目录。
install -d -m 0700 -o "$ALICE_UID" -g "$ALICE_GID" "$HOME_DIR"
install -d -m 0700 -o "$ALICE_UID" -g "$ALICE_GID" "$HOME_DIR/.ssh"
install -d -m 0755 -o "$ALICE_UID" -g "$ALICE_GID" \
    "$HOME_DIR/.config" "$HOME_DIR/.config/alice" "$HOME_DIR/.config/alice/service"
install -d -m 0700 -o "$ALICE_UID" -g "$ALICE_GID" \
    "$HOME_DIR/.local" "$HOME_DIR/.local/share" "$HOME_DIR/.local/share/alice"
# host key 目录：root 持有，普通用户读不到
install -d -m 0700 -o 0 -g 0 "$SSH_DIR"

# ── 3. ssh host key（在家目录内 → 重建容器后客户端指纹不变）──
# 逐类型补生成：卷里可能因旧版本或手工干预只剩部分 key，
# 「任一存在即全跳过」会让缺失的那种永远缺（sshd 每次启动报 Could not load host key）
if [ ! -f "$SSH_DIR/ssh_host_ed25519_key" ]; then
    log "generating ssh host key: ed25519"
    ssh-keygen -q -N '' -t ed25519 -f "$SSH_DIR/ssh_host_ed25519_key"
fi
if [ ! -f "$SSH_DIR/ssh_host_rsa_key" ]; then
    log "generating ssh host key: rsa"
    ssh-keygen -q -N '' -t rsa -b 4096 -f "$SSH_DIR/ssh_host_rsa_key"
fi

# ── 4. 渲染 sshd_config（模板里的用户/家目录）────────────────
install -d -m 0755 /run/alice
sed -e "s|@USER@|$ALICE_USER|g" \
    -e "s|@HOME@|$HOME_DIR|g" \
    "$CONFIG_DIR/sshd_config.in" > "$RENDERED_CONFIG"
chmod 0644 "$RENDERED_CONFIG"

# ── 5. 交给 shepherd ─────────────────────────────────────────
# init.scm 加载 /etc/alice/builtin/*.scm 和 ~/.config/alice/service/*.scm，然后统一启动。
# 用户名等通过环境变量传给它（Guile 用 (getenv ...) 读取）。
install -d -m 0755 /var/log/shepherd   # 防御：不依赖 shepherd 自动建 --logfile 父目录
log "starting shepherd (user=$ALICE_USER)"
exec /usr/sbin/shepherd --config "$CONFIG_DIR/init.scm" \
                        --logfile /var/log/shepherd/service.log

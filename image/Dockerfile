# ═══════════════════════════════════════════════════════════════
# alice —— 远程开发容器（Arch Linux + AUR + nix）
#
# 分层：
#   pacman  系统层（FHS / PAM / su / sudo / npm 全部原生正常）
#   AUR     shepherd（服务管理）、google-authenticator（TOTP）
#   nix     per-project 开发环境（nix develop）
#
# 注意：镜像里【不创建】普通用户。用户名 / uid / gid 由 entrypoint
#       在启动时按环境变量创建，所以同一个镜像可以服务多个实例。
# ═══════════════════════════════════════════════════════════════
FROM archlinux:latest

# ── 镜像源（全部国内）────────────────────────────────────────
# Arch 官方源直连慢且不稳，统一走 TUNA
# 顺手删掉基础镜像 pacman.conf 里裁掉 man/info 手册的 NoExtract 规则——
# 否则装的 man-pages 是空壳（man 形同虚设）。必须在任何装包之前改。
RUN printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch\n' \
      > /etc/pacman.d/mirrorlist \
 && printf '\n[archlinuxcn]\nServer = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch\n' \
      >> /etc/pacman.conf \
 && sed -i '/^NoExtract.*usr\/share\/man\/[/*].*usr\/share\/info\/[/*]$/d' /etc/pacman.conf

# ── 系统包 ───────────────────────────────────────────────────
# 每个安装层同层清空 pacman 下载缓存：docker 层不可变，跨层删只是
# whiteout，缓存仍留在安装层里。
# 不能用 pacman -Scc --noconfirm：它的「remove ALL files? [y/N]」提示
# 不受 --noconfirm 影响，默认 N —— 等于没清（实测）。
# 全量重装（-Qqn | xargs -S）：base 镜像自带的包是在 NoExtract 规则下装的，
# 手册从未落地；删掉规则后要重装一遍才补得回来。必须同层——分开层会把
# 所有文件重写一遍，新层等于全量复制，镜像体积反而翻倍。
RUN pacman-key --init && pacman-key --populate archlinux \
 && pacman -Syu --noconfirm --needed \
      base-devel git sudo openssh libpam-google-authenticator \
      procps-ng psmisc less man-db man-pages \
      ca-certificates curl wget jq unzip file which tree inetutils \
      vim gdb tcpdump \
      ripgrep fd fzf tmux htop \
      nodejs npm pnpm uv \
      guile zstd qrencode \
      nix \
 && pacman -Qqn | xargs pacman -S --noconfirm \
 && rm -rf /var/cache/pacman/pkg/*

# ── paru（AUR helper）─────────────────────────────────────────
# archlinuxcn-keyring 有鸡生蛋问题：先用 TrustAll 装上 keyring，
# 随即删掉这条放宽，之后的包一律严格验签。
RUN sed -i 's|^\[archlinuxcn\]|[archlinuxcn]\nSigLevel = Optional TrustAll|' /etc/pacman.conf \
 && pacman -Sy --noconfirm \
 && pacman -S --noconfirm archlinuxcn-keyring \
 && sed -i '/^SigLevel = Optional TrustAll$/d' /etc/pacman.conf \
 && pacman -S --noconfirm paru \
 && rm -rf /var/cache/pacman/pkg/*

# ── AUR 包（构建期烧进镜像）──────────────────────────────────
#   makepkg 不能以 root 运行 → 临时 builder 用户，用完【同层】删除：
#   让 uid/gid 1000 空出来给目标用户（跨层删不会真正缩小镜像）
#   --nocheck：shepherd 的测试套件需要完整 pid1 环境，容器里跑不过
#   google-authenticator 用官方 libpam-google-authenticator（1.11 起官方包
#   同时带 CLI 和 PAM 模块）——不走 AUR 的 -git 包（从 HEAD 构建，上游坏
#   commit 会直接卡死重建，且该包仓库 2026-06 出过一次投毒事件）。
RUN useradd -m builder \
 && printf 'builder ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/builder \
 && chmod 0440 /etc/sudoers.d/builder \
 && sudo -u builder paru -S --noconfirm --nocheck \
      guile-fibers shepherd \
 && userdel builder \
 && rm -rf /home/builder /etc/sudoers.d/builder /var/cache/pacman/pkg/* \
 && (groupdel builder 2>/dev/null || true)

# ── 校验 ─────────────────────────────────────────────────────
# builder 已在上一 RUN 同层删除：uid/gid 1000 必须都已空出来给目标用户
RUN shepherd --version \
 && google-authenticator --help > /dev/null \
 && test -f /usr/lib/security/pam_google_authenticator.so \
 && ! getent passwd 1000 \
 && ! getent group 1000

# ── shepherd 的 socket 路径修正 ──────────────────────────────
# AUR 的 PKGBUILD 没传 --runstatedir，autoconf 推出 %runstatedir=/usr/var/run，
# 于是 shepherd 和 herd 都默认找 /usr/var/run/shepherd/socket。
# 把 /usr/var/run 指向 /run，两边就自动对齐到 FHS 正确的位置。
RUN rm -rf /usr/var/run && ln -s /run /usr/var/run

# ── nix 配置 ─────────────────────────────────────────────────
#   sandbox=false —— 容器内 namespace 受限，nix 沙箱构建无法工作
#   registry 走南大 tarball —— channels.nixos.org 被墙
RUN cat > /etc/nix/nix.conf <<'EOF'
build-users-group = nixbld
sandbox = false
# 按组授权 trusted（entrypoint 会把用户加进 wheel）：普通用户才能
# --option 覆盖 substituters 等受保护配置。不增攻击面（用户本就有免密 sudo）。
trusted-users = root @wheel

experimental-features = nix-command flakes
flake-registry = /etc/nix/registry.json

substituters = https://mirror.nju.edu.cn/nix-channels/store https://mirrors.ustc.edu.cn/nix-channels/store https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
EOF

RUN cat > /etc/nix/registry.json <<'EOF'
{
  "version": 2,
  "flakes": [
    {
      "from": { "type": "indirect", "id": "nixpkgs" },
      "to": { "type": "tarball",
              "url": "https://mirror.nju.edu.cn/nix-channels/nixos-26.05/nixexprs.tar.xz" }
    }
  ]
}
EOF

RUN nix-store --init

# ── PAM：密码 + TOTP（2FA）───────────────────────────────────
# keyboard-interactive 一步走完两个因素：
#   pam_unix                 → 验密码
#   pam_google_authenticator → 验 TOTP
# 不含 nullok：空密码不可登录（用户初始为 locked，passwd 后才可用）。
# PAM 是系统级配置，与用户名无关，所以放构建期。
RUN cat > /etc/pam.d/sshd <<'EOF'
#%PAM-1.0
auth       required     pam_unix.so
auth       required     pam_google_authenticator.so
account    required     pam_permit.so
session    required     pam_permit.so
EOF

# ── locale ───────────────────────────────────────────────────
# sshd 会为登录会话重建环境，不继承守护进程的 LANG——基础镜像的
# ENV LANG=C.UTF-8 只覆盖 docker exec / 服务，ssh 会话是 ASCII（实测）。
# 这里给 login shell 兑底 C.UTF-8（glibc 自带；用户 rc 可覆盖）。
# 有意不加 AcceptEnv：客户端发来的 locale（如 zh_CN.UTF-8）镜像里没生成
# （基础镜像的 NoExtract 裁掉了非 en locale 定义），setlocale 失败连
# LC_CTYPE 都会单独踩中回退 ASCII（实测）——不如一刀切统一 C.UTF-8。
# 注意 login shell 才生效：ssh host 'cmd' 这类非 login 命令不读 profile.d
# （对 git/rsync 无影响）。
RUN cat > /etc/profile.d/zz-locale.sh <<'EOF'
# alice：ssh 会话 locale 兑底（sshd 重建会话环境，docker 的 ENV LANG 到不了这里）
export LANG="${LANG:-C.UTF-8}"
EOF

# ── 声明文件 ─────────────────────────────────────────────────
# builtin/：内置服务的权威定义。用户在 ~/.config/alice/service/ 里的同名定义会覆盖它们。
COPY init.scm       /etc/alice/init.scm
COPY builtin/       /etc/alice/builtin/
COPY sshd_config.in /etc/alice/sshd_config.in
COPY entrypoint.sh  /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

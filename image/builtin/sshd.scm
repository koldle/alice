;;; sshd — 容器唯一入口（密码 + TOTP 2FA，由 PAM 实现）
;;;
;;; 这是内置服务的权威定义。
;;; 要自定义：复制到 ~/.config/alice/service/sshd.scm 再改，重启后你的版本会覆盖这个。
;;;
;;; sshd_config 由 entrypoint 渲染到 /run/alice/sshd_config（含用户名/家目录）。

(use-modules (shepherd service))

(register-services
 (list (service '(sshd)
                #:start (make-forkexec-constructor
                         (list "/usr/sbin/sshd" "-D" "-e" "-f" "/run/alice/sshd_config")
                         #:log-file "/var/log/sshd/service.log")
                #:stop (make-kill-destructor)
                #:respawn? #t)))

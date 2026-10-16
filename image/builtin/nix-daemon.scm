;;; nix-daemon — nix 多用户模式的构建代理
;;;
;;; 用户跑 nix 命令（装包 / nix develop）都经它。
;;; 这是内置服务的权威定义；要自定义就复制到 ~/.config/alice/service/nix-daemon.scm。

(use-modules (shepherd service))

(register-services
 (list (service '(nix-daemon)
                #:start (make-forkexec-constructor
                         (list "/usr/sbin/nix-daemon")
                         #:log-file "/var/log/nix-daemon/service.log")
                #:stop (make-kill-destructor)
                #:respawn? #t)))

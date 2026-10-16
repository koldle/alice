;;; init.scm — alice 的服务加载器（GNU Shepherd）
;;;
;;; 由 entrypoint 以 root 启动；shepherd 是容器 PID 1。
;;;
;;; 职责只有三件事：
;;;   1. 加载内置服务    /etc/alice/builtin/*.scm
;;;   2. 加载用户服务    ~/.config/alice/service/*.scm
;;;   3. 启动所有已注册的服务（按服务名词典序；声明了 defer-start! 的除外，见下）
;;;
;;; 【用户优先】同名服务（按符号名判断，与文件名无关）时，后加载的覆盖先加载的，
;;; 即 ~/.config/alice/service/ 里的定义会替换 /etc/alice/builtin/ 里的，
;;; 覆盖发生时会在日志里打 NOTICE。
;;;
;;; 【容错】任何单个文件加载失败只告警，不影响其他服务和容器启动。
;;;
;;; 【增删改服务】改完重启容器即可（重跑 entrypoint + shepherd，重新扫描 +
;;; 从零构建注册表，加/改/删一律正确）：
;;;   docker compose restart        ← 只改本目录 .scm 时用它（此时 up -d 是
;;;                                   no-op：配置哈希没变，compose 什么都不做）
;;;   docker compose up -d          ← 改了 .env / compose.yml / image/ 时用它
;;;                                   （restart 不重读 .env；up -d 自动重建容器，
;;;                                    服务随重建自然重扫）
;;; 热加载只在"加服务"时生效，且新服务不会自动启动：
;;;   herd load root ~/.config/alice/service/x.scm
;;;   herd start x                  ← 别忘这步
;;; （改服务要配 herd restart <svc>；删服务需 herd unload <svc>）
;;;
;;; 【按需服务】服务文件可声明「注册但不自动启动」：
;;;   (use-modules (alice init))    ← 热加载时需要有这行，否则下方绑定不可见
;;;   (defer-start! 'mytool)
;;; 服务会注册（herd status 可见）但不随启动，之后 herd start mytool 随时拉起；
;;; 重建容器后仍保持不启动（声明跟着文件走）。
;;; ⚠ 别对 sshd 用——会把自己锁在容器外（只能靠 docker exec 救）。
;;;
;;; 环境变量（由 entrypoint 从 compose 传入）：
;;;   ALICE_USER  容器内用户名（用于拼家目录路径）

;; #:declarative? #f —— 本文件要调用 (load) 动态载入服务定义，
;; 不是纯声明式模块，必须关掉 Guile 的声明式检查（否则每次启动打 warning）。
(define-module (alice init)
  #:declarative? #f
  #:use-module (shepherd service)
  #:use-module (shepherd support)
  #:use-module (srfi srfi-1)
  #:use-module (ice-9 ftw))

(define builtin-dir "/etc/alice/builtin")

;; entrypoint 里 ALICE_USER 是必填项（缺失即 FATAL），正常流程一定拿得到；
;; 这里不兜底成 "alice"——那会静默指向 /home/alice，与「爆炸半径为零」相反。
(define user-name
  (or (getenv "ALICE_USER")
      (error "ALICE_USER is not set; shepherd was not launched by entrypoint.sh")))
(define user-home (string-append "/home/" user-name))
(define user-dir  (string-append user-home "/.config/alice/service"))

;;; ── 注册表快照：服务名(symbol) → 服务对象 ────────────────────
(define (registry-snapshot)
  (let ((tbl (make-hash-table)))
    (for-each-service (lambda (s)
                        (hash-set! tbl (service-canonical-name s) s)))
    tbl))

;;; ── 按需启动：服务文件声明「注册但不自动启动」─────────────────
;;; 这里只有机制（空集合 + 启动阶段过滤），策略分散在各服务文件里，
;;; init.scm 本身不维护任何清单（机制/策略分离：策略写在各个服务文件里）。
(define deferred (make-hash-table))

(define-public (defer-start! name)
  (hash-set! deferred name #t))

;;; ── 目录里的 .scm 文件（排序保证确定性）─────────────────────
(define (dir? path)
  (and (file-exists? path)
       (eq? (stat:type (stat path)) 'directory)))

(define (scm-files dir)
  (if (dir? dir)
      (sort (filter (lambda (f)
                      (and (string-suffix? ".scm" f)
                           (not (string-prefix? "." f))))
                    (scandir dir))
            string<?)
      '()))

;;; ── 加载一个文件；失败只告警 ─────────────────────────────────
(define (load-one path)
  (catch #t
    (lambda () (load path))
    (lambda (key . args)
      (local-output (l10n "WARNING: failed to load ~a -- ~a ~a") path key args))))

;;; ── 加载一整个目录，报告其中的覆盖 ───────────────────────────
(define (load-dir dir)
  (let ((before (registry-snapshot)))
    (for-each (lambda (f) (load-one (string-append dir "/" f)))
              (scm-files dir))
    (let ((after (registry-snapshot)))
      (hash-for-each
       (lambda (name old)
         (let ((new (hash-ref after name)))
           (when (and new (not (eq? old new)))
             (local-output (l10n "NOTICE: service '~a' was overridden by ~a/")
                           name dir))))
       before))))

;;; ══ 主流程：先全部加载，最后统一启动 ══════════════════════════
(load-dir builtin-dir)
(load-dir user-dir)

;; 按服务名词典序启动。hash-for-each 的遍历顺序是哈希表的实现细节（实测
;; 稳定但非字母序，且随 key 集合变化），不依赖它——显式排序后启动顺序确定、
;; 日志可复现。
;; 服务间有依赖时必须在服务定义里写 #:requirement '(dep)：start-service 会先
;; 并行启动全部依赖，且 shepherd 的服务循环对并发 start 做竞态去重（服务处于
;; running/starting 时重复的 start 请求被幂等合并），所以「依赖被启动两次」
;; 不可能发生；但不写 requirement 的隐式依赖不受任何保护。
(let* ((all (registry-snapshot))
       (names (sort (hash-map->list (lambda (name svc) name) all)
                    (lambda (a b) (string<? (symbol->string a)
                                            (symbol->string b))))))
  (for-each
   (lambda (name)
     (unless (or (eq? name 'root)
                 (hash-ref deferred name))
       (catch #t
         (lambda () (start-in-the-background (list name)))
         (lambda (key . args)
           (local-output (l10n "WARNING: failed to start ~a -- ~a ~a")
                         name key args)))))
   names))

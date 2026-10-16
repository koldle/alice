;;; log-rotation — 每周轮转 /var/log/<服务名>/service.log
;;;
;;; 默认日历：周日 22:00（shepherd 的 %default-calendar-event），按【容器时区】
;;; 解释（compose.yml 默认 TZ=Asia/Shanghai，改了 TZ 轮转时刻随之变化），压缩为 gzip。
;;; 要改频率：复制到 ~/.config/alice/service/log-rotation.scm，换成例如
;;;   (log-rotation-service (calendar-event #:days-of-week '(1) #:hours '(3)))
;;; 的写法（改每天 3:00）。

(use-modules (shepherd service)
             (shepherd service log-rotation))

(register-services (list (log-rotation-service)))

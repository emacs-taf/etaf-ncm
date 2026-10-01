;;; update-cost.el --- measure what one player update costs -*- lexical-binding: t; -*-

;;; Commentary:
;; An update is a ref write plus the runtime flush that publishes it, so this
;; benchmark measures both a selection write (the list repaints) and a clock
;; tick (the player bar repaints).  Run it with the framework byte-compiled,
;; which is what an installed checkout uses:
;;
;;   emacs -Q --batch -L . -L lisp -L tests -L ../../etaf -L ../../etaf-ui \
;;         -L ../../ebox -L ../../ecss -l benchmarks/update-cost.el
;;
;; A selection write still republishes the whole view, which is what keeps the
;; list highlight honest.  A clock tick does not: the elapsed label and the
;; progress meter are retained Hosts, so a playing second commits one batched
;; retained update.  A tick that crosses a lyric line republishes the view,
;; because the panel's current line moves with it.

;;; Code:
(load "tests/etaf-ncm-tests.el")

(defun etaf-ncm-benchmark-update-cost (label width height writes)
  "Mount a session at WIDTH x HEIGHT, run WRITES, and report milliseconds."
  (let* ((app (etaf-ncm-tests--session))
         (buffer (generate-new-buffer (format " *update-cost-%s*" label)))
         (etaf-ncm-tests--requests nil))
    (unwind-protect
        (progn
          (plist-put app :buffer buffer)
          (with-current-buffer buffer (setq-local truncate-lines t))
          (etaf-mount buffer (etaf-ncm-view app)
                      (list :viewport-width width :viewport-height height))
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (etaf-ncm-refresh app)
          (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
          (let ((state (etaf-ncm-state app))
                (costs nil))
            (dotimes (index (length writes))
              (let* ((kind (nth index writes))
                     (t0 (float-time)))
                (if (eq kind 'selection)
                    (etaf-ncm-move-selection app 1)
                  (etaf-ncm--publish-clock app (+ 6.2 (* index 0.2))))
                (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
                (push (round (* 1000 (- (float-time) t0))) costs)))
            (format "%-8s viewport=%sx%s rows=%s page=%s ms=%S"
                    label width height
                    (length (plist-get state :items))
                    (plist-get state :page-size)
                    (reverse costs))))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(defun etaf-ncm-benchmark-update-cost-report ()
  "Measure the update cost at three viewplaces and print one line each."
  (let ((writes '(selection selection clock clock)))
    (princ (format "%s\n" (etaf-ncm-benchmark-update-cost "wide" 1386 51 writes)))
    (princ (format "%s\n" (etaf-ncm-benchmark-update-cost "medium" 800 40 writes)))
    (princ (format "%s\n" (etaf-ncm-benchmark-update-cost "small" 600 24 writes)))))

(etaf-ncm-benchmark-update-cost-report)

(provide 'update-cost)
;;; update-cost.el ends here

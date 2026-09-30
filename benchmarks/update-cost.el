;;; update-cost.el --- measure what one player update costs -*- lexical-binding: t; -*-

;;; Commentary:
;; An update is a ref write plus the runtime flush that publishes it, so this
;; benchmark measures both: a selection write (the list repaints) and a clock
;; write (only the player bar and the lyric line repaint).  Run it with the
;; framework byte-compiled, which is what an installed checkout uses:
;;
;;   emacs -Q --batch -L . -L lisp -L tests -L ../../etaf -L ../../etaf-ui \
;;         -L ../../ebox -L ../../ecss -l benchmarks/update-cost.el
;;
;; Reference numbers (2026-09-30, Apple silicon, byte-compiled framework):
;; a selection write costs about 250 ms and a clock write about 100 ms,
;; independent of the viewport, on a twelve-row fixture.  The cost is the whole
;; tree being laid out again on every update; see `docs/architecture.md'.

;;; Code:
(load "tests/etaf-ncm-tests.el")

(defun etaf-ncm-benchmark-update-cost (label width height writes)
  "Mount a session at WIDTH x HEIGHT, run WRITES, and report milliseconds."
  (let* ((app (etaf-ncm-tests--session))
         (buffer (generate-new-buffer (format " *update-cost-%s*" label)))
         (etaf-ncm-tests--requests nil))
    (unwind-protect
        (progn
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
                  (etaf-ncm--write app :clock (+ 30 index)))
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

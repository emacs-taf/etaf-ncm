;;; update-phases.el --- where one update spends its milliseconds -*- lexical-binding: t; -*-

;;; Commentary:
;; The companion of `update-cost.el': that one times a whole update, this one
;; reports the phases inside it, so an optimization can be aimed at the part
;; that actually costs.  It instruments the framework on purpose; it is a
;; benchmark, not a test.
;;
;;   emacs -Q --batch -L . -L lisp -L tests -L ../../etaf -L ../../etaf-ui \
;;         -L ../../ebox -L ../../ecss -l benchmarks/update-phases.el
;;
;; Findings on 2026-10-01 (byte-compiled framework, twelve-row fixture):
;;
;;   A selection write republishes the view: the candidate is rebuilt and Ebox
;;   lays the whole surface out again, so the cost sits in `ebox-commit' and
;;   `ebox-surface--render-candidate'.
;;   A clock tick inside one lyric line does not take this path at all: the
;;   elapsed label and the progress meter are replaced through their retained
;;   Hosts, so only the retained update and its Ebox batch appear here.
;;
;; Use this benchmark to see which parts of the ordinary publication remain:
;; the candidate rebuild and the whole-surface layout are where a structural
;; update still pays.

;;; Code:
(load "tests/etaf-ncm-tests.el")

(defvar etaf-ncm-benchmark--counts nil
  "Alist of (SYMBOL CALLS . MILLISECONDS) for the current measurement.")

(defconst etaf-ncm-benchmark-phase-functions
  '(etaf-set-value
    etaf--runtime-component-overlay
    etaf-render-port-update
    ebox-commit
    ebox-surface-update-buffer-scoped
    ebox--pub--prepare-surface
    ebox-surface--project
    ebox-surface--render-candidate
    ebox--render-layout-in-context
    ebox-tree--children-raw
    ebox-tree-node-children
    ebox--node-children)
  "Phases and traversal entry points worth counting.")

(defun etaf-ncm-benchmark--advise (symbol)
  "Count calls and milliseconds of SYMBOL in `etaf-ncm-benchmark--counts'."
  (advice-add symbol :around
              (lambda (original &rest arguments)
                (let ((t0 (float-time)))
                  (prog1 (apply original arguments)
                    (let ((entry (assq symbol etaf-ncm-benchmark--counts)))
                      (if entry
                          (setcdr entry (list (1+ (nth 1 entry))
                                              (+ (nth 2 entry)
                                                 (* 1000 (- (float-time) t0)))))
                        (push (list symbol 1 (* 1000 (- (float-time) t0)))
                              etaf-ncm-benchmark--counts))))))
              `((name . ,(intern (format "etaf-ncm-benchmark-%s" symbol))))))

(defun etaf-ncm-benchmark--unadvise (symbol)
  "Remove the measurement advice from SYMBOL."
  (advice-remove symbol (intern (format "etaf-ncm-benchmark-%s" symbol))))

(defun etaf-ncm-benchmark-update-phases ()
  "Report the phases of one clock update."
  (unwind-protect
      (let* ((app (etaf-ncm-tests--session))
             (buffer (generate-new-buffer " *update-phases*"))
             (etaf-ncm-tests--requests nil))
        (unwind-protect
            (progn
              (with-current-buffer buffer
                (plist-put app :buffer buffer)
                (setq-local truncate-lines t))
              (etaf-mount buffer (etaf-ncm-view app)
                          (list :viewport-width 1386 :viewport-height 51))
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (etaf-ncm-refresh app)
              (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
              (dolist (symbol etaf-ncm-benchmark-phase-functions)
                (when (fboundp symbol) (etaf-ncm-benchmark--advise symbol)))
              (setq etaf-ncm-benchmark--counts nil)
              (let ((t0 (float-time)))
                (etaf-ncm--set-clock app 42)
                (etaf-runtime-flush (etaf-runtime-for-buffer buffer))
                (princ (format "one clock update: %d ms total\n"
                               (round (* 1000 (- (float-time) t0))))))
              (dolist (symbol etaf-ncm-benchmark-phase-functions)
                (when (fboundp symbol) (etaf-ncm-benchmark--unadvise symbol)))
              (dolist (entry (sort (copy-sequence etaf-ncm-benchmark--counts)
                                   (lambda (left right)
                                     (> (nth 2 left) (nth 2 right)))))
                (princ (format "  %-40s calls=%-6d ms=%.0f\n"
                               (symbol-name (car entry))
                               (nth 1 entry)
                               (nth 2 entry)))))
          (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
          (kill-buffer buffer)))
    (dolist (symbol etaf-ncm-benchmark-phase-functions)
      (when (fboundp symbol) (etaf-ncm-benchmark--unadvise symbol)))))

(etaf-ncm-benchmark-update-phases)

(provide 'update-phases)
;;; update-phases.el ends here

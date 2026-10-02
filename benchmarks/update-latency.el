;;; update-latency.el --- measure one interaction against the retained bar -*- lexical-binding: t; -*-

;;; Commentary:
;; The companion of `update-cost.el' and `update-phases.el': those time and
;; break down ordinary updates, this one reports the whole interaction
;; latency a person feels and whether it rebuilt a semantic candidate.  The
;; player bar is a retained panel, so the controls should publish prepared
;; Host updates with no candidate render; the list, aside and sidebar still
;; publish through the ordinary path and are measured as the baseline the
;; retained work is compared against.
;;
;; Run it with the framework byte-compiled, which is what an installed
;; checkout uses:
;;
;;   emacs -Q --batch -L . -L lisp -L tests -L ../../etaf -L ../../etaf-ui \
;;         -L ../../ebox -L ../../ecss -l benchmarks/update-latency.el
;;
;; The first control press builds the panel's retained scene (a one-time cost
;; of tens of milliseconds); every press after it should be a prepared update.
;; `cand' is the number of whole candidate renders, so a `perf' row that shows
;; candidate work took the fallback path and needs the layout or source change
;; that makes its Hosts addressable.

;;; Code:
(load "tests/etaf-ncm-tests.el")

(defvar etaf-ncm-benchmark-latency--candidates 0
  "Candidate renders observed since the last measurement started.")

(defun etaf-ncm-benchmark-latency--count-candidate (original state)
  "Count one candidate render of STATE and call ORIGINAL."
  (cl-incf etaf-ncm-benchmark-latency--candidates)
  (funcall original state))

(defun etaf-ncm-benchmark-latency--measure (label function)
  "Run FUNCTION once and report its latency and candidate count."
  (setq etaf-ncm-benchmark-latency--candidates 0)
  (let ((started (float-time)))
    (funcall function)
    (princ (format "  %-18s %5dms  cand=%d\n"
                   label
                   (round (* 1000 (- (float-time) started)))
                   etaf-ncm-benchmark-latency--candidates))))

(defun etaf-ncm-benchmark-update-latency ()
  "Measure the player's documented interactions on one mounted session."
  (let* ((app (etaf-ncm-tests--session))
         (buffer (generate-new-buffer " *update-latency*"))
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
          (sit-for 0.3)
          (advice-add 'ebox-surface--render-candidate :around
                      #'etaf-ncm-benchmark-latency--count-candidate)
          (unwind-protect
              (progn
                (princ "player bar (retained panel):\n")
                (etaf-ncm-benchmark-latency--measure
                 "toggle (first)" (lambda () (etaf-ncm-toggle-playback app)))
                (etaf-ncm-benchmark-latency--measure
                 "toggle (steady)" (lambda () (etaf-ncm-toggle-playback app)))
                (etaf-ncm-benchmark-latency--measure
                 "shuffle" (lambda () (etaf-ncm-set-shuffle app t)))
                (etaf-ncm-benchmark-latency--measure
                 "shuffle back" (lambda () (etaf-ncm-set-shuffle app nil)))
                (etaf-ncm-benchmark-latency--measure
                 "repeat" (lambda () (etaf-ncm-set-repeat app t)))
                (etaf-ncm-benchmark-latency--measure
                 "like" (lambda () (etaf-ncm-like app)))
                (etaf-ncm-benchmark-latency--measure
                 "unlike" (lambda () (etaf-ncm-like app t)))
                (princ "ordinary publications (remaining work):\n")
                (etaf-ncm-benchmark-latency--measure
                 "selection" (lambda () (etaf-ncm-move-selection app 1)))
                (etaf-ncm-benchmark-latency--measure
                 "aside queue" (lambda () (etaf-ncm--write app :aside 'queue)))
                (etaf-ncm-benchmark-latency--measure
                 "aside lyrics" (lambda () (etaf-ncm--write app :aside 'lyrics)))
                (etaf-ncm-benchmark-latency--measure
                 "sidebar" (lambda () (etaf-ncm-locate app :liked))))
            (advice-remove 'ebox-surface--render-candidate
                           #'etaf-ncm-benchmark-latency--count-candidate)))
      (when-let* ((runtime (etaf-runtime-for-buffer buffer))) (etaf-unmount runtime))
      (kill-buffer buffer))))

(etaf-ncm-benchmark-update-latency)

(provide 'update-latency)
;;; update-latency.el ends here

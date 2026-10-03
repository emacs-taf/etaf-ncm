;;; performance-scenarios.el --- Music library switching -*- lexical-binding: t; -*-

;;; Commentary:
;; Cached sidebar navigation, including native publication and redisplay.
;; Run with the workspace scripts/performance.py driver.  No network/player.

;;; Code:
(require 'etaf-ncm)
(declare-function taf-benchmark-register "performance-driver" (id &rest properties))

(defun etaf-ncm-benchmark--fixture (_mode)
  "Mount a deterministic player and switch between two warmed libraries."
  (let* ((etaf-ncm-buffer-name " *ncm-switch-benchmark*")
         (etaf-ncm-status-interval 3600)
         (display-buffer-overriding-action '((display-buffer-same-window)))
         (songs (cl-loop for i from 1 to 60
                         collect (list :id i :name (format "曲目 %d" i)
                                       :artist "歌手" :album "专辑" :ms 180000)))
         (warm t)
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (pcase (plist-get request :op)
                           (:browse
                            (when warm
                              (funcall callback
                                       (list :ok (list :songs (if (eq (plist-get request :resource) :daily)
                                                                  songs (reverse songs)) :total 60)))))
                           (:status (funcall callback '(:ok (:state "stopped"))))
                           (_ (funcall callback '(:ok nil)))))))
         buffer runtime (section :daily))
    (etaf-ncm-open app)
    (setq buffer (current-buffer) runtime (etaf-runtime-for-buffer buffer))
    (etaf-ncm-locate app :liked)
    (etaf-ncm-locate app :daily)
    (etaf-runtime-flush runtime)
    (setq warm nil)
    (list :buffer buffer
          :environment (lambda () (list :network :false :rows 60 :cached t))
          :ready (lambda () t)
          :prepare (lambda () (setq section (if (eq section :daily) :liked :daily)))
          :invoke (lambda (_sample)
                    (etaf-ncm-locate app section)
                    (etaf-runtime-flush runtime))
          :verify (lambda () (and (eq section (plist-get (etaf-ncm-state app) :section))
                                   (= 60 (plist-get (etaf-ncm-state app) :rows-total))))
          :outcome (lambda () (list :section (symbol-name section)))
          :cleanup (lambda () (when (buffer-live-p buffer)
                                (with-current-buffer buffer (etaf-ncm-close)))))))

(taf-benchmark-register
 "ncm.sidebar.cached" :version 1 :modes '(batch gui) :isolation 'series
 :required-providers '(etaf) :budget-ms 100 :impact 'local
 :description "Cached music library switch through native publication"
 :setup #'etaf-ncm-benchmark--fixture)

;;; performance-scenarios.el ends here

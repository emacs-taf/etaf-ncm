;;; etaf-ncm-tests.el --- Acceptance tests for etaf-ncm -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Public behaviour tests.  Every scenario drives the player through the
;; interfaces declared in `etaf-ncm.el' with a scripted client, so no test needs
;; the network, mpv or a graphical frame: the backend is a plain function that
;; answers in fixtures shaped like the real JSON.

;;; Code:

(require 'ert)
(require 'json)
(require 'cl-lib)
(require 'etaf)
(require 'etaf-ncm)

;;; ---------------------------------------------------------------------------
;;; Scripted backend
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm-tests--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory holding this test file and its fixtures.")

(defvar etaf-ncm-tests--requests nil
  "Requests received by the scripted client, newest first.")

(defvar etaf-ncm-tests--status nil
  "Playback status document the scripted client reports.")

(defvar etaf-ncm-tests--error nil
  "When non-nil, the scripted client fails every request with this message.")

(defun etaf-ncm-tests--fixture (name)
  "Return fixture NAME from tests/fixtures as a plist."
  (let ((file (expand-file-name (format "fixtures/%s.json" name)
                                etaf-ncm-tests--directory)))
    (with-temp-buffer
      (insert-file-contents file)
      (json-parse-buffer :object-type 'plist :array-type 'list
                         :null-object nil :false-object nil))))

(defun etaf-ncm-tests--reply (callback data)
  "Answer CALLBACK with DATA, or with the scripted failure."
  (funcall callback
           (if etaf-ncm-tests--error
               (list :error etaf-ncm-tests--error :hint "scripted")
             (list :ok data))))

(defun etaf-ncm-tests--client (request callback)
  "Answer REQUEST on CALLBACK from fixtures, recording it first."
  (push request etaf-ncm-tests--requests)
  (let ((resource (plist-get request :resource)))
    (etaf-ncm-tests--reply
     callback
     (pcase (plist-get request :op)
       (:browse
        (etaf-ncm-tests--fixture
         (pcase resource
           (:playlists "playlists")
           (:charts "charts")
           (:albums "albums")
           (:artists "artists")
           (:podcasts "podcasts")
           (_ "daily"))))
       (:search (etaf-ncm-tests--fixture
                 (if (eq resource :playlists) "search-playlists" "search")))
       (:lyric (etaf-ncm-tests--fixture "lyric"))
       (:session (etaf-ncm-tests--fixture "session"))
       (:status (or etaf-ncm-tests--status (etaf-ncm-tests--fixture "status")))
       (:queue (append (etaf-ncm-tests--fixture "queue")
                       (list :songs (plist-get (etaf-ncm-tests--fixture "queue-tracks")
                                               :songs))))
       (_ (list :ok t))))))

(defun etaf-ncm-tests--session (&optional client)
  "Return a player session driven by the scripted CLIENT."
  (etaf-ncm-create :client (or client #'etaf-ncm-tests--client)))

(defun etaf-ncm-tests--request (op)
  "Return the newest recorded request whose `:op' is OP."
  (seq-find (lambda (request) (eq (plist-get request :op) op))
            etaf-ncm-tests--requests))

(defun etaf-ncm-tests--rows (app)
  "Return APP's library rows."
  (plist-get (etaf-ncm-state app) :items))

(ert-deftest etaf-ncm-tests-new-session-is-headless ()
  "A new session starts on the daily library without touching the backend."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (should (eq (plist-get (etaf-ncm-state app) :section) :daily))
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))
    (should (eq (plist-get (etaf-ncm-state app) :layout) 'wide))
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 0))
    (should-not etaf-ncm-tests--requests)))

(ert-deftest etaf-ncm-tests-refresh-loads-library-and-playback ()
  "Refreshing loads the library, the account, the playback truth and the queue."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-refresh app) (etaf-ncm-state app))))
    (should (= (plist-get state :rows-total) 12))
    (should (equal (plist-get state :title) "每日推荐"))
    (should (equal (plist-get (nth 0 (plist-get state :items)) :name) "曲目 1"))
    (should (= (plist-get (nth 0 (plist-get state :items)) :id) 1))
    (should (equal (plist-get (nth 1 (plist-get state :items)) :badge) "VIP"))
    (should (equal (plist-get state :message) "每日推荐 · 12 项"))
    (should (equal (plist-get (plist-get state :account) :nick) "听众"))
    (should (eq (plist-get (plist-get state :status) :state) 'playing))
    (should (= (plist-get (plist-get state :status) :queue-pos) 2))
    (should (= (plist-get (plist-get state :status) :queue-count) 5))
    (should (= (length (plist-get state :visible))
                (min (plist-get state :page-size) (plist-get state :rows-total))))
    (should (memq :browse (mapcar (lambda (request) (plist-get request :op))
                                 etaf-ncm-tests--requests)))))

(ert-deftest etaf-ncm-tests-refresh-keeps-selection-inside-the-page ()
  "Loading a library resets the page and the selection to its first row."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 6)
    (etaf-ncm-locate app :charts)
    (let ((state (etaf-ncm-state app)))
      (should (= (plist-get state :rows-total) 10))
      (should (equal (plist-get state :title) "排行榜"))
      (should (= (plist-get state :selection) 0))
      (should (= (plist-get state :window-start) 0))
      (should (equal (plist-get (nth 0 (plist-get state :items)) :kind) :chart)))))

(ert-deftest etaf-ncm-tests-locate-rejects-unknown-library ()
  "An unknown library signals `etaf-ncm-error' and leaves the session alone."
  (let* ((app (etaf-ncm-tests--session))
         (before (plist-get (etaf-ncm-state app) :section)))
    (should-error (etaf-ncm-locate app :nowhere) :type 'etaf-ncm-error)
    (should (eq (plist-get (etaf-ncm-state app) :section) before))))

(ert-deftest etaf-ncm-tests-sections-inventory-is-navigable ()
  "Every section in `etaf-ncm-sections' is accepted by `etaf-ncm-locate'."
  (let ((app (etaf-ncm-tests--session)))
    (dolist (group etaf-ncm-sections)
      (should (symbolp (car group)))
      (dolist (entry (cdr group))
        (should (= (length entry) 3))
        (etaf-ncm-locate app (nth 0 entry))
        (should (eq (plist-get (etaf-ncm-state app) :section) (nth 0 entry)))
        (should (equal (plist-get (etaf-ncm-state app) :title) (nth 1 entry)))))))

(ert-deftest etaf-ncm-tests-search-records-keyword-and-scope ()
  "Searching shows results and sends the keyword with its scope."
  (setq etaf-ncm-tests--requests nil)
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-search app "  关键词  ") (etaf-ncm-state app)))
         (request (etaf-ncm-tests--request :search)))
    (should (equal (plist-get state :mode) 'search))
    (should (equal (plist-get state :query) "关键词"))
    (should (equal (plist-get state :title) "搜索结果"))
    (should (= (plist-get state :rows-total) 12))
    (should (equal (plist-get request :keyword) "关键词"))
    (should (eq (plist-get request :scope) 'song))
    (should-error (etaf-ncm-search app "   ") :type 'etaf-ncm-error)
    (etaf-ncm-search app "关键词" 'playlist)
    (should (eq (plist-get (etaf-ncm-tests--request :search) :scope) 'playlist))
    (should (equal (plist-get (etaf-ncm-state app) :title) "搜索结果"))))

(ert-deftest etaf-ncm-tests-play-uses-the-selected-row ()
  "Playing the selection sends its kind and id."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 2)
    (etaf-ncm-activate-selection app)
    (let ((request (etaf-ncm-tests--request :play)))
      (should (equal (plist-get request :target) (list :kind :song :id 3)))
      (should (equal (plist-get (etaf-ncm-state app) :message) "正在播放：曲目 3")))))

(ert-deftest etaf-ncm-tests-play-accepts-rows-ids-and-keywords ()
  "Play resolves library rows, song ids and search keywords."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-play app (nth 0 (etaf-ncm-tests--rows app)))
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :song :id 1)))
    (etaf-ncm-play app 42)
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :song :id 42)))
    (etaf-ncm-play app "  陈粒 ")
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :query :id "陈粒")))
    (etaf-ncm-locate app :playlists)
    (etaf-ncm-play app (nth 1 (etaf-ncm-tests--rows app)))
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :playlist :id 1002)))
    (should-error (etaf-ncm-play app '(:kind :nonsense :id 1)) :type 'etaf-ncm-error)))

(ert-deftest etaf-ncm-tests-add-to-queue-takes-songs-only ()
  "Queueing accepts a song row and rejects a playlist row."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-add-to-queue app (nth 4 (etaf-ncm-tests--rows app)))
    (should (equal (plist-get (etaf-ncm-tests--request :add) :id) 5))
    (should (equal (plist-get (nth 4 (etaf-ncm-tests--rows app)) :name) "曲目 5"))
    (should (equal (plist-get (etaf-ncm-state app) :message) "已加入队列：曲目 5"))
    (etaf-ncm-locate app :playlists)
    (should-error (etaf-ncm-add-to-queue app (nth 0 (etaf-ncm-tests--rows app)))
                  :type 'etaf-ncm-error)))

(ert-deftest etaf-ncm-tests-transport-commands-reach-the-backend ()
  "Transport, volume, seek, mode and like commands send their own request."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-toggle-playback app)
    (should (etaf-ncm-tests--request :toggle))
    (etaf-ncm-next-track app)
    (should (etaf-ncm-tests--request :next))
    (etaf-ncm-previous-track app)
    (should (etaf-ncm-tests--request :previous))
    (etaf-ncm-stop app)
    (should (etaf-ncm-tests--request :stop))
    (etaf-ncm-set-volume app 63.4)
    (should (= (plist-get (etaf-ncm-tests--request :volume) :value) 63))
    (should (equal (plist-get (etaf-ncm-state app) :message) "音量 63"))
    (should-error (etaf-ncm-set-volume app 131) :type 'etaf-ncm-error)
    (should-error (etaf-ncm-set-volume app -1) :type 'etaf-ncm-error)
    (etaf-ncm-seek app -15)
    (should (= (plist-get (etaf-ncm-tests--request :seek) :seconds) -15))
    (etaf-ncm-set-shuffle app t)
    (should (eq (plist-get (etaf-ncm-tests--request :shuffle) :on) t))
    (etaf-ncm-set-repeat app nil)
    (should (eq (plist-get (etaf-ncm-tests--request :repeat) :on) nil))
    (etaf-ncm-like app)
    (should (etaf-ncm-tests--request :like))
    (etaf-ncm-like app t)
    (should (etaf-ncm-tests--request :unlike))
    (etaf-ncm-jump-queue app 3)
    (should (= (plist-get (etaf-ncm-tests--request :jump) :index) 3))))

(ert-deftest etaf-ncm-tests-selection-keeps-its-page ()
  "Selection clamps at both ends and scrolls the page to stay visible."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app -1)
    (should (= (plist-get (etaf-ncm-state app) :selection) 0))
    (etaf-ncm-move-selection app 100)
    (let ((state (etaf-ncm-state app)))
      (should (= (plist-get state :selection) 11))
      (should (= (plist-get state :window-start)
                 (- 12 (length (plist-get state :visible)))))
      (should (memq (plist-get state :selection)
                    (cl-loop for offset from 0 below (length (plist-get state :visible))
                             collect (+ (plist-get state :window-start) offset)))))
    (let ((empty (etaf-ncm-tests--session)))
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-activate-selection empty)
      (should-not (etaf-ncm-tests--request :play)))))

(ert-deftest etaf-ncm-tests-toggle-aside-switches-panels ()
  "The side panel alternates between the lyric and the queue."
  (let ((app (etaf-ncm-tests--session)))
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
    (etaf-ncm-toggle-aside app)
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'queue))
    (etaf-ncm-toggle-aside app)
    (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))))

(ert-deftest etaf-ncm-tests-show-pane-selects-the-visible-pane ()
  "SHOW-PANE records the pane and rejects an unknown one."
  (let ((app (etaf-ncm-tests--session)))
    (should (eq (etaf-ncm-show-pane app 'aside) 'aside))
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
    (should (eq (etaf-ncm-show-pane app 'list) 'list))
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))
    (should-error (etaf-ncm-show-pane app 'queue) :type 'etaf-ncm-error)
    (should (eq (plist-get (etaf-ncm-state app) :pane) 'list))))

(ert-deftest etaf-ncm-tests-queue-and-lyric-follow-playback ()
  "The snapshot reports the queue around the playing song and the lyric line."
  (let* ((app (etaf-ncm-tests--session))
         (state (progn (etaf-ncm-refresh app) (etaf-ncm-state app)))
         (queue (plist-get state :queue))
         (lyric (plist-get state :lyric)))
    (should (= (plist-get queue :count) 5))
    (should (= (plist-get queue :pos) 2))
    (should (= (length (plist-get queue :songs)) 5))
    (should (equal (plist-get (plist-get queue :current) :name) "曲目 2"))
    (should (= (plist-get lyric :lines) 6))
    (should (= (plist-get lyric :index) 6))
    (should (equal (plist-get state :lyric-line) "第五行歌词"))))

(ert-deftest etaf-ncm-tests-parse-lyric-reads-lrc ()
  "LRC parsing keeps the tagged lines in order and ignores noise."
  (let ((lines (etaf-ncm-parse-lyric
                (concat "[al:专辑]\n"
                        "[00:05.00] 第二句\n"
                        "[00:01.50]第一句\n"
                        "[00:10.00][00:12.25] 重复句\n"
                        "没有时间戳\n"))))
    (should (equal (mapcar #'cdr lines) '("第一句" "第二句" "重复句" "重复句")))
    (should (equal (mapcar #'car lines) '(1.5 5.0 10.0 12.25)))
    (should-not (etaf-ncm-parse-lyric ""))
    (should-not (etaf-ncm-parse-lyric nil))))

(ert-deftest etaf-ncm-tests-backend-failure-is-reported-not-signaled ()
  "A failing request lands in the session error instead of raising."
  (let* ((etaf-ncm-tests--error "后端不可用")
         (app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (let ((state (etaf-ncm-state app)))
      (should (equal (plist-get state :error) "后端不可用"))
      (should-not (plist-get state :loading))
      (should (zerop (plist-get state :rows-total)))
      (should (string-prefix-p "后端不可用" (plist-get state :message))))))

(ert-deftest etaf-ncm-tests-missing-backend-is-reported-not-signaled ()
  "A backend whose scripts are absent reports an error instead of raising."
  (let ((app (etaf-ncm-create :client (etaf-ncm-make-client
                                       :skill-directory "/nonexistent-etaf-ncm-skill"))))
    (etaf-ncm-refresh app)
    (let ((state (etaf-ncm-state app)))
      (should (string-match-p "missing" (or (plist-get state :error) "")))
      (should (string-match-p "missing" (plist-get state :message)))
      (should-not (plist-get state :loading)))))

(ert-deftest etaf-ncm-tests-client-call-reaches-a-function-client ()
  "The documented client protocol works with a plain function."
  (let (seen)
    (etaf-ncm-client-call (lambda (request callback)
                            (setq seen request)
                            (funcall callback (list :ok (list :op t))))
                          (list :op :status)
                          (lambda (reply) (setq seen (list reply seen))))
    (should (equal seen '((:ok (:op t)) (:op :status))))
    (etaf-ncm-cancel (lambda (_request _callback) nil))))

(ert-deftest etaf-ncm-tests-theme-tokens-cover-both-palettes ()
  "Colours resolve per palette, and the UI defaults follow the mode."
  (unwind-protect
      (let ((etaf-ncm-theme-mode 'dark))
        (should (equal (etaf-ncm-color :accent) "#EC4141"))
        (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'" (etaf-ncm-color :bg)))
        (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'" (etaf-ncm-color :ink)))
        (should-error (etaf-ncm-color :nonsense) :type 'etaf-ncm-error)
        (let ((dark (etaf-ncm-color :bg))
              (dark-defaults (etaf-ncm-theme-defaults 'dark)))
          (should (plist-member dark-defaults :ui-accent))
          (should (equal (plist-get dark-defaults :ui-bg) dark))
          (setq etaf-ncm-theme-mode 'light)
          (should-not (equal dark (etaf-ncm-color :bg)))
          (should (equal (etaf-ncm-color :bg 'dark) dark))
          (should-not (equal (etaf-ncm-theme-defaults)
                             (etaf-ncm-theme-defaults 'dark)))))
    (setq etaf-ncm-theme-mode 'dark)))

(ert-deftest etaf-ncm-tests-mount-renders-and-revives ()
  "Mounting paints the library in a buffer and killing it releases the session."
  (let ((app (etaf-ncm-tests--session))
        (buffer (get-buffer-create " *etaf-ncm-tests-mount*")))
    (unwind-protect
        (progn
          (etaf-mount buffer (etaf-ncm-view app)
                      (list :viewport-width 1200 :viewport-height 40))
          (with-current-buffer buffer
            (should (string-match-p "曲目 1" (buffer-string)))
            (should (string-match-p "每日推荐" (buffer-string)))
            (should (string-match-p (plist-get (etaf-ncm-state app) :message)
                                    (buffer-string))))
          (kill-buffer buffer)
          (should-not (get-buffer " *etaf-ncm-tests-mount*"))
          (let ((again (get-buffer-create " *etaf-ncm-tests-mount*")))
            (etaf-mount again (etaf-ncm-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (with-current-buffer again
              (should (string-match-p "曲目 1" (buffer-string))))))
      (when (get-buffer " *etaf-ncm-tests-mount*")
        (kill-buffer " *etaf-ncm-tests-mount*")))))

(ert-deftest etaf-ncm-tests-open-and-close-own-a-buffer ()
  "Opening installs the player map and closing kills the buffer."
  (let ((etaf-ncm-buffer-name " *etaf-ncm-tests-open*")
        (app (etaf-ncm-tests--session)))
    (unwind-protect
        (let ((buffer (etaf-ncm-open app)))
          (should (buffer-live-p buffer))
          (with-current-buffer buffer
            (should (eq (current-local-map) etaf-ncm-mode-map))
            (should-not mode-line-format)
            (should (string-match-p "曲目 1" (buffer-string))))
          (etaf-ncm-close)
          (should-not (get-buffer etaf-ncm-buffer-name)))
      (when (get-buffer etaf-ncm-buffer-name)
        (kill-buffer etaf-ncm-buffer-name)))))

(provide 'etaf-ncm-tests)
;;; etaf-ncm-tests.el ends here

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
  "Playing a song selection queues its library and jumps to the selected row."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 2)
    (etaf-ncm-activate-selection app)
    (let ((request (etaf-ncm-tests--request :play)))
      (should (equal (plist-get request :target) (list :kind :daily)))
      (should (= (plist-get (etaf-ncm-tests--request :jump) :index) 3))
      (should (equal (plist-get (etaf-ncm-state app) :message) "正在播放：曲目 3")))
    (etaf-ncm-play app)
    (should (equal (plist-get (etaf-ncm-state app) :message) "正在播放：每日推荐"))))

(ert-deftest etaf-ncm-tests-play-accepts-rows-ids-and-keywords ()
  "Play resolves library rows, song ids and search keywords."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-play app (nth 0 (etaf-ncm-tests--rows app)))
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :daily)))
    (should (= (plist-get (etaf-ncm-tests--request :jump) :index) 1))
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
    (should (equal (plist-get (etaf-ncm-state app) :message) "列表循环：关"))
    (etaf-ncm-set-repeat app t)
    (should (eq (plist-get (etaf-ncm-tests--request :repeat) :on) t))
    (should (equal (plist-get (etaf-ncm-state app) :message) "列表循环：开"))
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

(ert-deftest etaf-ncm-tests-default-client-runs-the-skill-command ()
  "The default client calls the skill script with the arguments of the request.
A stub skill records the command line, so a request that translates into the
wrong argument (a keyword instead of the song id, say) fails here instead of
silently doing nothing against the real backend."
  (let* ((directory (make-temp-file "etaf-ncm-skill" t))
         (scripts (expand-file-name "scripts" directory))
         (script (expand-file-name "netease-music.sh" scripts))
         (log (expand-file-name "calls.log" directory))
         reply)
    (unwind-protect
        (progn
          (make-directory scripts t)
          (with-temp-file script
            (insert "#!/bin/sh\n"
                    (format "printf '%%s\\n' \"$*\" >> %s\n" (shell-quote-argument log))
                    "printf '{\"ok\": true, \"state\": \"playing\"}\\n'\n"))
          (set-file-modes script #o755)
          (let* ((client (etaf-ncm-make-client :skill-directory directory :timeout 10))
                 (deadline (+ (float-time) 10)))
            (etaf-ncm-client-call
             client (list :op :play :target (list :kind :song :id 4242))
             (lambda (result) (setq reply result)))
            (while (and (null reply) (< (float-time) deadline))
              (accept-process-output nil 0.05))
            (should (eq (car-safe reply) :ok))
            (should (with-temp-buffer
                      (insert-file-contents log)
                      (string-match-p "play 4242" (buffer-string))))))
      (delete-directory directory t))))

(ert-deftest etaf-ncm-tests-theme-tokens-cover-both-palettes ()
  "Colours resolve per palette, and the UI defaults follow the mode."
  (unwind-protect
      (let ((etaf-ncm-theme-mode 'dark))
        (should (equal (etaf-ncm-color :accent) "#EC4141"))
        (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'" (etaf-ncm-color :bg)))
        (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\'" (etaf-ncm-color :ink)))
        (should-error (etaf-ncm-color :nonsense) :type 'etaf-ncm-error)
        ;; Every documented key must resolve in both palettes: the error banner
        ;; once used `:danger-bg' while the palette could not answer it.
        (dolist (key '(:bg :panel :panel2 :panel3 :line :ink :muted :dim
                           :accent :accent-soft :gold :ok :danger :danger-bg
                           :playing :selected :meter :cover))
          (dolist (mode '(dark light))
            (should (string-match-p "\\`#[0-9A-Fa-f]\\{6\\}\\\'"
                                    (etaf-ncm-color key mode)))))
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
            (should (string-match-p "曲目 1" (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p "每日推荐" (buffer-substring-no-properties (point-min) (point-max))))
            (should (string-match-p (plist-get (etaf-ncm-state app) :message)
                                    (buffer-substring-no-properties (point-min) (point-max)))))
          (kill-buffer buffer)
          (should-not (get-buffer " *etaf-ncm-tests-mount*"))
          (let ((again (get-buffer-create " *etaf-ncm-tests-mount*")))
            (etaf-mount again (etaf-ncm-view app)
                        (list :viewport-width 1200 :viewport-height 40))
            (with-current-buffer again
              (should (string-match-p "曲目 1" (buffer-substring-no-properties (point-min) (point-max)))))))
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
            (should (eq (key-binding [wheel-down])
                        (lookup-key etaf-ncm-mode-map [wheel-down])))
            (should-not mode-line-format)
            (should (string-match-p "曲目 1" (buffer-substring-no-properties (point-min) (point-max)))))
          (etaf-ncm-close)
          (should-not (get-buffer etaf-ncm-buffer-name)))
      (when (get-buffer etaf-ncm-buffer-name)
        (kill-buffer etaf-ncm-buffer-name)))))

(ert-deftest etaf-ncm-tests-press-on-the-selected-row-plays-it ()
  "A press on the already selected row starts playback.
The gesture must not depend on a second press arriving inside a timing window:
publishing a selection can delay it past any fixed window."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-move-selection app 2)
    (should-not (etaf-ncm-tests--request :play))
    (etaf-ncm-press-row app 3)
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :daily)))
    (should (= (plist-get (etaf-ncm-tests--request :jump) :index) 3))))

(ert-deftest etaf-ncm-tests-press-selects-another-row-before-playing ()
  "A press on a different row selects it; the next press plays it."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-refresh app)
    (etaf-ncm-press-row app 4)
    (should (= (plist-get (etaf-ncm-state app) :selection) 3))
    (should-not (etaf-ncm-tests--request :play))
    (should (string-match-p "再点一次播放"
                            (or (plist-get (etaf-ncm-state app) :message) "")))
    (etaf-ncm-press-row app 4)
    (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                   '(:kind :daily)))
    (should (= (plist-get (etaf-ncm-tests--request :jump) :index) 4))))

(ert-deftest etaf-ncm-tests-transport-effect-is-visible-before-the-reply ()
  "Pausing flips the displayed state before the backend answers."
  (setq etaf-ncm-tests--requests nil)
  (let* (app
         seen
         (client (lambda (request callback)
                   (when (eq (plist-get request :op) :toggle)
                     (push (plist-get (plist-get (etaf-ncm-state app) :status) :state)
                           seen))
                   (etaf-ncm-tests--client request callback))))
    (setq app (etaf-ncm-tests--session client))
    (etaf-ncm-refresh app)
    (should (eq (plist-get (plist-get (etaf-ncm-state app) :status) :state) 'playing))
    (etaf-ncm-toggle-playback app)
    (should (equal seen '(paused)))))

(ert-deftest etaf-ncm-tests-locate-shows-cached-rows-before-the-refresh ()
  "Revisiting a library shows its cached rows and refreshes in the background.
The background reply must not move the reader's selection."
  (setq etaf-ncm-tests--requests nil)
  (let* (app
         deferred
         defer-p
         (client (lambda (request callback)
                   (if defer-p
                       (push (cons request callback) deferred)
                     (etaf-ncm-tests--client request callback)))))
    (setq app (etaf-ncm-tests--session client))
    (etaf-ncm-refresh app)
    (etaf-ncm-locate app :playlists)
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 36))
    (setq defer-p t)
    (etaf-ncm-locate app :daily)
    (let ((state (etaf-ncm-state app)))
      (should (= (plist-get state :rows-total) 12))
      (should-not (plist-get state :loading))
      (should (equal (plist-get state :title) "每日推荐")))
    (etaf-ncm-move-selection app 4)
    (funcall (cdr (car deferred))
             (list :ok (etaf-ncm-tests--fixture "daily")))
    (should (= (plist-get (etaf-ncm-state app) :selection) 4))
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 12))))

;;; ---------------------------------------------------------------------------
;;; Long libraries and panel interaction
;;; ---------------------------------------------------------------------------

(defun etaf-ncm-tests--songs (count &optional prefix)
  "Return COUNT backend songs with a distinct PREFIX."
  (cl-loop for index from 1 to count
           collect (list :id index :name (format "%s%03d" (or prefix "长列表") index)
                         :artist "歌手" :album "专辑" :ms 180000)))

(defvar etaf-ncm-tests--poll-interval 3600
  "Playback polling interval used by mounted acceptance sessions.")

(defmacro etaf-ncm-tests--with-player (app &rest body)
  "Open APP in an isolated buffer and a roomy window while running BODY."
  (declare (indent 1) (debug t))
  `(let ((etaf-ncm-buffer-name (generate-new-buffer-name " *ncm-acceptance*"))
         (etaf-ncm-status-interval etaf-ncm-tests--poll-interval)
         (display-buffer-overriding-action '((display-buffer-same-window)))
         (frame (selected-frame))
         (width (frame-width))
         (height (frame-height)))
     (unwind-protect
         (save-window-excursion
           (delete-other-windows)
           (set-frame-size frame 180 48)
           (etaf-ncm-open ,app)
           ,@body)
       (etaf-ncm-close)
       (set-frame-size frame width height))))

(defun etaf-ncm-tests--rendered-text ()
  "Flush the current mounted player and read its text without properties."
  (etaf-runtime-flush (etaf-runtime-for-buffer (current-buffer)))
  (buffer-substring-no-properties (point-min) (point-max)))

(defun etaf-ncm-tests--key (key)
  "Invoke KEY through the player's published keymap."
  (call-interactively (lookup-key etaf-ncm-mode-map (kbd key))))

(defun etaf-ncm-tests--wheel (window direction column row)
  "Send DIRECTION at COLUMN and ROW through WINDOW's active wheel binding.
The synthetic wheel event carries pixels, just like an Emacs mouse event."
  (funcall (with-current-buffer (window-buffer window)
             (key-binding (vector direction)))
           (list direction
                 (list window (window-start window)
                       (cons (* column (window-font-width window))
                             (* row (window-font-height window))) 0))))

(ert-deftest etaf-ncm-tests-browse-limit-covers-long-libraries ()
  "Browse loads 500 rows and respects the new limit, old limit and page floor."
  (dolist (limits '((1000 100 24 1000) (1000 1500 24 1500) (100 50 80 240)))
    (let* ((etaf-ncm-list-limit (nth 0 limits))
           (etaf-ncm-fetch-limit (nth 1 limits))
           (etaf-ncm-page-size (nth 2 limits))
           seen
           (app (etaf-ncm-create
                 :client (lambda (request callback)
                           (setq seen request)
                           (funcall callback
                                    (list :ok (list :total 500 :songs
                                                    (etaf-ncm-tests--songs
                                                     (min 500 (plist-get request :limit))))))))))
      (etaf-ncm-locate app :liked)
      (should (= (plist-get seen :limit) (nth 3 limits)))
      (should (= (plist-get (etaf-ncm-state app) :rows-total)
                 (min 500 (nth 3 limits))))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 500)))))

(ert-deftest etaf-ncm-tests-library-total-survives-cache-and-refresh ()
  "Partial totals survive cache hits, change without new rows, and clear on error."
  (let* ((songs (etaf-ncm-tests--songs 100))
         pending defer
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (if (eq (plist-get request :op) :browse)
                             (if defer
                                 (setq pending callback)
                               (funcall callback (list :ok (list :songs songs :total "500"))))
                           (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-locate app :liked)
      (should (= (plist-get (etaf-ncm-state app) :rows-total) 100))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 500))
      (should (string-match-p "已加载 100 / 共 500 首"
                              (etaf-ncm-tests--rendered-text)))
      (etaf-ncm-locate app :daily)
      (setq defer t)
      (etaf-ncm-locate app :liked)
      (should-not (plist-get (etaf-ncm-state app) :loading))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 500))
      (etaf-ncm-move-selection app 99)
      (funcall pending (list :ok (list :songs songs :total 501)))
      (should (= (plist-get (etaf-ncm-state app) :selection) 99))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 501))
      (should (string-match-p "已加载 100 / 共 501 首"
                              (etaf-ncm-tests--rendered-text)))
      (etaf-ncm-refresh app)
      (funcall pending (list :ok (list :songs nil :total 501)))
      (should (string-match-p "第 0-0 首 / 共 501 首"
                              (etaf-ncm-tests--rendered-text)))
      (should (string-match-p "已加载 0 / 共 501 首"
                              (etaf-ncm-tests--rendered-text)))
      (etaf-ncm-refresh app)
      (funcall pending '(:error "加载失败"))
      (should (= (plist-get (etaf-ncm-state app) :list-total) 0))
      (should (= (plist-get (etaf-ncm-state app) :rows-total) 0)))))

(ert-deftest etaf-ncm-tests-long-library-keys-show-one-based-ranges ()
  "Home, End and page keys navigate every loaded row and display one-based ranges."
  (let ((app (etaf-ncm-create
              :client (lambda (request callback)
                        (if (eq (plist-get request :op) :browse)
                            (funcall callback (list :ok (list :songs (etaf-ncm-tests--songs 500)
                                                             :total 500)))
                          (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (let ((size (plist-get (etaf-ncm-state app) :page-size)))
        (should (string-match-p (format "第 1-%d 首 / 共 500 首" size)
                                (etaf-ncm-tests--rendered-text)))
        (etaf-ncm-tests--key "<end>")
        (let ((state (etaf-ncm-state app)))
          (should (= (plist-get state :selection) 499))
          (should (= (plist-get state :window-start) (- 500 size)))
          (should (= (plist-get (car (last (plist-get state :visible))) :id) 500)))
        (should (string-match-p (format "第 %d-500 首 / 共 500 首" (- 501 size))
                                (etaf-ncm-tests--rendered-text)))
        (etaf-ncm-tests--key "<prior>")
        (should (= (plist-get (etaf-ncm-state app) :selection) (- 499 size)))
        (etaf-ncm-tests--key "<next>")
        (should (= (plist-get (etaf-ncm-state app) :selection) 499))
        (etaf-ncm-tests--key "<home>")
        (should (= (plist-get (etaf-ncm-state app) :selection) 0))
        (should (= (plist-get (etaf-ncm-state app) :window-start) 0))))))

(ert-deftest etaf-ncm-tests-superseded-library-keeps-visible-total ()
  "A late foreground reply cannot overwrite a revisited cached library or total."
  (let* (defer pending
         (app (etaf-ncm-create
               :client (lambda (_request callback)
                         (if defer
                             (push callback pending)
                           (funcall callback
                                    (list :ok (list :songs (etaf-ncm-tests--songs 100)
                                                    :total 500))))))))
    (etaf-ncm-locate app :liked)
    (setq defer t)
    (etaf-ncm-locate app :daily)
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 0))
    (should (= (plist-get (etaf-ncm-state app) :list-total) 0))
    (etaf-ncm-locate app :liked)
    (funcall (cadr pending) (list :ok (list :songs (etaf-ncm-tests--songs 3) :total 3)))
    (should (= (plist-get (etaf-ncm-state app) :rows-total) 100))
    (should (= (plist-get (etaf-ncm-state app) :list-total) 500))
    (should (eq (plist-get (etaf-ncm-state app) :section) :liked))))

(ert-deftest etaf-ncm-tests-song-row-waits-for-library-before-jump ()
  "A song in each playable library waits for play, then jumps by its full-list index."
  (dolist (section '(:daily :liked :fm))
    (let* ((etaf-ncm-page-size 8)
           (songs (etaf-ncm-tests--songs 200))
           requests play-reply jump-reply
           (app (etaf-ncm-create
                 :client (lambda (request callback)
                           (push request requests)
                           (pcase (plist-get request :op)
                             (:browse (funcall callback (list :ok (list :songs songs))))
                             (:play (setq play-reply callback))
                             (:jump (setq jump-reply callback))
                             (:queue (funcall callback
                                              (list :ok (list :songs songs :count 200 :pos 137))))
                             (_ (etaf-ncm-tests--client request callback)))))))
      (etaf-ncm-locate app section)
      (etaf-ncm-press-row app 137)
      (should (= (plist-get (etaf-ncm-state app) :selection) 136))
      (setq requests nil)
      (etaf-ncm-press-row app 137)
      (should (equal requests (list (list :op :play :target (list :kind section)))))
      ;; Navigation while the request is in flight must not change the jump.
      (etaf-ncm-move-selection app 10)
      (funcall play-reply '(:ok (:ok t)))
      (should (equal (mapcar (lambda (request) (plist-get request :op))
                            (reverse requests)) '(:play :jump)))
      (should (= (plist-get (car requests) :index) 137))
      (funcall jump-reply '(:ok (:ok t)))
      (should (= (plist-get (plist-get (etaf-ncm-state app) :queue) :count) 200))
      (should (= (plist-get (plist-get (etaf-ncm-state app) :queue) :pos) 137))
      (should (equal (plist-get (etaf-ncm-state app) :message) "正在播放：长列表137")))))

(ert-deftest etaf-ncm-tests-song-row-failure-and-supersession ()
  "Failed or superseded list play never jumps over another playback request."
  (let* (pending jumps
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (pcase (plist-get request :op)
                           (:play (push callback pending))
                           (:jump (push request jumps)
                                  (funcall callback '(:error "跳转失败")))
                           (_ (etaf-ncm-tests--client request callback)))))))
    (etaf-ncm-locate app :daily)
    (etaf-ncm-activate-selection app)
    (funcall (pop pending) '(:error "播放失败"))
    (should-not jumps)
    (should (equal (plist-get (etaf-ncm-state app) :error) "播放失败"))
    (etaf-ncm-activate-selection app)
    (etaf-ncm-play app 999)
    (funcall (cadr pending) '(:ok (:ok t)))
    (should-not jumps)
    (funcall (car pending) '(:ok (:ok t)))
    (etaf-ncm-activate-selection app)
    (etaf-ncm-stop app)
    (funcall (car pending) '(:ok (:ok t)))
    (should-not jumps)
    (etaf-ncm-activate-selection app)
    (funcall (car pending) '(:ok (:ok t)))
    (should (= (plist-get (car jumps) :index) 1))
    (should (equal (plist-get (etaf-ncm-state app) :error) "跳转失败"))))

(ert-deftest etaf-ncm-tests-other-libraries-play-rows-directly ()
  "Recent, search and list-of-lists rows keep their individual play targets."
  (let ((app (etaf-ncm-tests--session)))
    (dolist (entry '((:recent :song) (:playlists :playlist) (:albums :album)
                     (:artists :artist) (:charts :chart) (:podcasts :podcast)
                     (:search :song)))
      (if (eq (car entry) :search)
          (etaf-ncm-search app "曲目")
        (etaf-ncm-locate app (car entry)))
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-activate-selection app)
      (should (equal (plist-get (etaf-ncm-tests--request :play) :target)
                     (list :kind (cadr entry) :id (plist-get (car (etaf-ncm-tests--rows app)) :id))))
      (should-not (etaf-ncm-tests--request :jump)))))

(ert-deftest etaf-ncm-tests-play-all-only-for-supported-origins ()
  "Both header layouts offer play-all only for daily, liked and FM libraries."
  (dolist (wide '(1 1000))
    (let ((etaf-ncm-wide-columns wide)
          (app (etaf-ncm-tests--session)))
      (etaf-ncm-tests--with-player app
        (dolist (section '(:daily :liked :fm :playlists :albums :artists :charts
                           :podcasts :recent :search))
          (if (eq section :search)
              (etaf-ncm-search app "曲目")
            (etaf-ncm-locate app section))
          (should (eq (and (string-match-p "播放全部" (etaf-ncm-tests--rendered-text)) t)
                      (and (memq section '(:daily :liked :fm)) t))))))))

(ert-deftest etaf-ncm-tests-queue-wheel-scrolls-only-the-event-panel ()
  "Wheel events reach the entire queue, preserve selection and follow a new track."
  (dolist (layout '(wide medium narrow))
    (let* ((etaf-ncm-wide-columns (if (eq layout 'wide) 1 1000))
           (etaf-ncm-medium-columns (if (eq layout 'narrow) 1000 1))
           (songs (etaf-ncm-tests--songs 80 "队列"))
           (pos 40)
           (app (etaf-ncm-create
                 :client (lambda (request callback)
                           (if (eq (plist-get request :op) :queue)
                               (funcall callback (list :ok (list :count 90 :pos pos :songs songs)))
                             (etaf-ncm-tests--client request callback))))))
      (etaf-ncm-tests--with-player app
        (etaf-ncm-toggle-aside app)
        (should (eq (plist-get (etaf-ncm-state app) :layout) layout))
        (let* ((window (selected-window))
               (right (- (window-body-width window) 4))
               (size (plist-get (etaf-ncm-state app) :queue-rows))
               (start (plist-get (etaf-ncm-state app) :queue-start)))
          (should (> size 12))
          (should (string-match-p (format "第 %d-%d 首 / 共 90 首" (1+ start) (+ start size))
                                  (etaf-ncm-tests--rendered-text)))
          ;; Current buffer and point need not belong to the event window.
          (with-temp-buffer
            (etaf-batch
              (dotimes (_ 100) (etaf-ncm-tests--wheel window 'wheel-down right 8))))
          (should (= (plist-get (etaf-ncm-state app) :selection) 0))
          (should (= (plist-get (etaf-ncm-state app) :queue-start) (- 80 size)))
          (should (string-match-p "队列080" (etaf-ncm-tests--rendered-text)))
          (etaf-batch
            (dotimes (_ 100) (etaf-ncm-tests--wheel window 'wheel-up right 8)))
          (should (= (plist-get (etaf-ncm-state app) :queue-start) 0))
          (should (string-match-p "队列001" (etaf-ncm-tests--rendered-text)))
          (etaf-ncm-refresh app)
          (unless (eq layout 'wide) (etaf-ncm-show-pane app 'aside))
          (should (= (plist-get (etaf-ncm-state app) :queue-start) 0))
          (setq pos 60)
          (etaf-ncm-refresh app)
          (unless (eq layout 'wide) (etaf-ncm-show-pane app 'aside))
          (should (= (plist-get (etaf-ncm-state app) :queue-start)
                     (min (- 59 (/ size 2)) (- 80 size))))
          ;; The player bar and the library/rail retain selection scrolling.
          (etaf-ncm-tests--wheel window 'wheel-down right (1- (window-body-height window)))
          (should (= (plist-get (etaf-ncm-state app) :selection) 1))
          (if (eq layout 'wide)
              (etaf-ncm-tests--wheel window 'wheel-down 2 8)
            (etaf-ncm-show-pane app 'list)
            (etaf-ncm-tests--wheel window 'wheel-down right 8))
          (should (= (plist-get (etaf-ncm-state app) :selection) 2))
          (etaf-ncm-toggle-aside app)
          (etaf-ncm-tests--wheel window 'wheel-down right 8)
          (should (= (plist-get (etaf-ncm-state app) :selection) 3)))))))

(ert-deftest etaf-ncm-tests-panel-budgets-fit-resized-windows ()
  "Queue and translated lyric windows shrink with their own panel height."
  (let* ((lyric (mapconcat (lambda (index) (format "[00:%02d.00]歌词%02d" index index))
                          (number-sequence 0 59) "\n"))
         (trans (replace-regexp-in-string "歌词" "译文" lyric))
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (if (eq (plist-get request :op) :lyric)
                             (funcall callback (list :ok (list :lyric lyric :trans trans)))
                           (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (let* ((before (etaf-ncm-state app))
             (text (etaf-ncm-tests--rendered-text)))
        (should (string-match-p "歌词42" text))
        (should (string-match-p "译文42" text))
        (set-frame-height (selected-frame) 32)
        (etaf-ncm-refresh app)
        (let* ((after (etaf-ncm-state app))
               (text (etaf-ncm-tests--rendered-text))
               (count 0) (start 0))
          (should (< (plist-get after :queue-rows) (plist-get before :queue-rows)))
          (should (< (plist-get after :lyric-rows) (plist-get before :lyric-rows)))
          (should (string-match-p "歌词42" text))
          (should (string-match-p "译文42" text))
          (while (string-match "\\(?:歌词\\|译文\\)[0-9][0-9]" text start)
            (cl-incf count)
            (setq start (match-end 0)))
          (should (<= count (plist-get after :lyric-rows))))))))

(ert-deftest etaf-ncm-tests-queue-entries-click-and-tab-activate ()
  "Scrolled queue entries still jump on mouse activation and TAB/RET."
  (let* ((songs (etaf-ncm-tests--songs 45 "队列"))
         (app (etaf-ncm-create
               :client (lambda (request callback)
                         (if (eq (plist-get request :op) :queue)
                             (funcall callback (list :ok (list :songs songs :count 45 :pos 2)))
                           (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-toggle-aside app)
      (let* ((window (selected-window))
             (right (- (window-body-width window) 4)))
        (etaf-batch
          (dotimes (_ 50) (etaf-ncm-tests--wheel window 'wheel-down right 8)))
        (etaf-ncm-tests--rendered-text)
        (goto-char (point-min))
        (search-forward "队列045")
        (backward-char 1)
        (let ((event (list 'mouse-1 (list window (point) (cons right 8) 0))))
          (setq etaf-ncm-tests--requests nil)
          (funcall (key-binding [mouse-1]) event)
          (should (= (plist-get (etaf-ncm-tests--request :jump) :index) 45)))
        (etaf-ncm-tests--rendered-text)
        (let (index)
          (dotimes (_ 150)
            (unless index
              (call-interactively (key-binding (kbd "TAB")))
              (let ((help (get-char-property (point) 'help-echo)))
                (when (and (stringp help)
                           (string-match "播放队列第 \\([0-9]+\\) 首" help))
                  (setq index (string-to-number (match-string 1 help)))))))
          (should index)
          (should (> index 10))
          (setq etaf-ncm-tests--requests nil)
          (call-interactively (key-binding (kbd "RET")))
          (should (= (plist-get (etaf-ncm-tests--request :jump) :index) index))
          (should (= (plist-get (etaf-ncm-state app) :selection) 0)))))))


(defun etaf-ncm-tests--background (position)
  "Return POSITION's effective face background, honoring Ebox's face list."
  (let ((face (get-char-property position 'face)))
    (cond ((and (consp face) (keywordp (car face))) (plist-get face :background))
          ((listp face)
           (cl-loop for spec in face
                    when (and (consp spec) (plist-get spec :background))
                    return (plist-get spec :background))))))

(defun etaf-ncm-tests--sidebar-label-position (label)
  "Return the sidebar position of LABEL in the mounted player, or nil.
The sidebar's own items start at the line's left edge; the header repeats the
current library's name further right, so only the first twelve characters of a
line can hold a sidebar label."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (search-forward label nil t))
        (when (< (- (match-beginning 0) (line-beginning-position)) 12)
          (setq found (match-beginning 0))))
      found)))

(defun etaf-ncm-tests--sidebar-spacer-position (position)
  "Return the sidebar cell below its label at POSITION, or nil.
Stretch spaces occupy one character regardless of their display width, so
locate the entry by its help text instead of a character offset."
  (save-excursion
    (goto-char position)
    (let ((help (get-char-property position 'help-echo)))
      (forward-line 1)
      (let ((end (line-end-position)))
        (while (and (< (point) end)
                    (not (equal (get-char-property (point) 'help-echo) help)))
          (goto-char (next-single-property-change (point) 'help-echo nil end)))
        (and (< (point) end) (point))))))

(ert-deftest etaf-ncm-tests-sidebar-selection-highlights-one-line ()
  "The selected library entry paints its text row, not its whole two-line cell."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((label (etaf-ncm-tests--sidebar-label-position "每日推荐")))
        (should label)
        (should (equal (etaf-ncm-tests--background label)
                       (etaf-ncm-color :accent-soft)))
        (let ((spacer (etaf-ncm-tests--sidebar-spacer-position label)))
          (should spacer)
          (should (= (char-after spacer) ?\s))
          (should-not (equal (etaf-ncm-tests--background spacer)
                             (etaf-ncm-color :accent-soft))))))))

(ert-deftest etaf-ncm-tests-sidebar-group-labels-leave-a-gap ()
  "A group label is separated from its first entry by a blank line."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((label-line (progn (goto-char (point-min))
                               (search-forward "我的音乐" nil t)
                               (line-number-at-pos)))
            (item-line (progn (goto-char (point-min))
                              (search-forward "我的歌单" nil t)
                              (line-number-at-pos))))
        (should label-line)
        (should item-line)
        (should (= 2 (- item-line label-line)))))))

(ert-deftest etaf-ncm-tests-viewport-width-uses-pixels ()
  "The mounted canvas is the window body width in pixels, not whole cells."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (should (= (plist-get (etaf-ncm-state app) :viewport-width)
                 (window-body-width (selected-window) t))))))


(ert-deftest etaf-ncm-tests-sidebar-entry-click-switches-library ()
  "Sidebar text and spacer clicks switch libraries, as does TAB/RET."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((label (etaf-ncm-tests--sidebar-label-position "私人 FM")))
        (should label)
        (goto-char label)
        (let* ((window (selected-window))
               (event (list 'mouse-1 (list window label '(1 . 1) 0)))
               (command (key-binding (vector event))))
          (should (commandp command))
          (funcall command event)
          (etaf-ncm-tests--rendered-text)
          (should (eq (plist-get (etaf-ncm-state app) :section) :fm))))
      ;; Exercise the native press/release route on both lines of the cell.
      (dolist (target '(("每日推荐" :daily nil) ("私人 FM" :fm t)))
        (let ((position (etaf-ncm-tests--sidebar-label-position (car target))))
          (should position)
          (when (nth 2 target)
            (setq position (etaf-ncm-tests--sidebar-spacer-position position))
            (should position))
          (goto-char position)
          (let* ((window (selected-window))
                 (press (list 'down-mouse-1 (list window position '(1 . 1) 0)))
                 (release (list 'mouse-1 (list window position '(1 . 1) 1)))
                 (command (key-binding (vector press)))
                 (unread-command-events (list release)))
            (should (commandp command))
            (should (eq command (lookup-key (get-text-property position 'keymap)
                                           [down-mouse-1])))
            (funcall command press)
            (etaf-ncm-tests--rendered-text)
            (should (eq (plist-get (etaf-ncm-state app) :section) (nth 1 target))))))
      (goto-char (point-min))
      (let (found)
        (dotimes (_ 100)
          (unless found
            (call-interactively (key-binding (kbd "TAB")))
            (setq found (equal (get-char-property (point) 'help-echo) "每日推荐"))))
        (should found)
        (call-interactively (key-binding (kbd "RET")))
        (etaf-ncm-tests--rendered-text)
        (should (eq (plist-get (etaf-ncm-state app) :section) :daily))))))

(defun etaf-ncm-tests--host-pixels (host)
  "Return HOST's painted (LEFT WIDTH) through the public retained bounds."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (bounds (etaf-host-ref-bounds runtime host)))
    (should bounds)
    (let ((start (car bounds)) (end (cdr bounds)))
      (list (ebox-string-pixel-width
             (buffer-substring (save-excursion (goto-char start) (line-beginning-position)) start))
            (ebox-string-pixel-width (buffer-substring start end))))))

(defun etaf-ncm-tests--host-text (host)
  "Return HOST's painted text in the mounted player."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (bounds (etaf-host-ref-bounds runtime host)))
    (should bounds)
    (buffer-substring-no-properties (car bounds) (cdr bounds))))

(defun etaf-ncm-tests--slider-gesture (host phase ratio)
  "Dispatch a slider PHASE at RATIO of HOST's travel in the mounted player."
  (pcase-let* ((`(,left ,width) (etaf-ncm-tests--host-pixels host))
               (x (+ left (* ratio width))))
    (etaf-dispatch-event
     (etaf-runtime-for-buffer (current-buffer)) host 'drag
     (list :phase phase :host-ref host :window (selected-window)
           :buffer (current-buffer) :position (cons x 0)) t)))

(defun etaf-ncm-tests--press-help (help)
  "Activate the mounted control whose help text is HELP."
  (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
         (entry (cl-find-if
                 (lambda (entry) (equal (plist-get (cdr entry) :help-echo) help))
                 (etaf-runtime-host-props-entries runtime))))
    (should entry)
    (etaf-dispatch-event runtime (car entry) 'press)))

(ert-deftest etaf-ncm-tests-player-volume-drag-and-reply ()
  "Click/drag sets the pointed volume optimistically and reconciles its reply."
  (let* ((etaf-ncm-tests--requests nil)
         pending
         (app (etaf-ncm-tests--session
               (lambda (request callback)
                 (if (eq (plist-get request :op) :volume)
                     (progn (push request etaf-ncm-tests--requests)
                            (setq pending callback))
                   (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (dolist (sample '((0.5 50) (0.8 80) (-1 0) (2 100)))
        (setq etaf-ncm-tests--requests nil)
        (etaf-ncm-tests--slider-gesture 'ncm-volume 'start 0.1)
        (etaf-ncm-tests--slider-gesture 'ncm-volume 'move (car sample))
        (should-not (etaf-ncm-tests--request :volume))
        (etaf-ncm-tests--slider-gesture 'ncm-volume 'end (car sample))
        (should (= (plist-get (etaf-ncm-tests--request :volume) :value) (cadr sample)))
        (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :volume) (cadr sample)))
        (etaf-ncm-tests--rendered-text)
        (funcall pending '(:ok (:ok t)))
        (etaf-ncm-tests--rendered-text)
        (should (= (plist-get (plist-get (etaf-ncm-state app) :status) :volume) 55)))
      (setq etaf-ncm-tests--requests nil)
      (etaf-ncm-tests--slider-gesture 'ncm-volume 'start 0.8)
      (etaf-ncm-tests--slider-gesture 'ncm-volume 'cancel 0.8)
      (should-not (etaf-ncm-tests--request :volume)))))

(ert-deftest etaf-ncm-tests-player-progress-range-seeks-by-pointer ()
  "The progress range follows status and seeks to the pointed position."
  (let* ((etaf-ncm-tests--status (etaf-ncm-tests--fixture "status"))
         (app (etaf-ncm-tests--session)))
    (setq etaf-ncm-tests--status (plist-put etaf-ncm-tests--status :duration "100"))
    (etaf-ncm-tests--with-player app
      (dolist (elapsed '(0 25 75 100))
        (setq etaf-ncm-tests--status (plist-put etaf-ncm-tests--status :elapsed elapsed))
        (etaf-ncm-refresh app)
        (etaf-ncm-tests--rendered-text)
        (should (etaf-host-ref-bounds (etaf-runtime-for-buffer (current-buffer))
                                      'ncm-seek)))
      (let ((etaf-ncm-tests--requests nil))
        (etaf-ncm-tests--slider-gesture 'ncm-seek 'end 0.5)
        (should (= (plist-get (etaf-ncm-tests--request :seek) :seconds) -50))))))

(ert-deftest etaf-ncm-tests-player-quality-and-compact-layouts ()
  "Only reported quality is badged; compact bars retain transport without it."
  (let* ((base (etaf-ncm-tests--fixture "status"))
         (etaf-ncm-tests--status base)
         (app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let ((runtime (etaf-runtime-for-buffer (current-buffer))))
        (should-not (etaf-host-ref-bounds runtime 'ncm-quality))
        (dolist (sample '(((:lossless t :vip t) "无损")
                          ((:quality "lossless") "无损")
                          ((:bitrate "320000") "320 kbps")
                          ((:vip_hint "VIP 专享") "VIP 专享")))
          (setq etaf-ncm-tests--status (append (car sample) base))
          (etaf-ncm-refresh app)
          (etaf-ncm-tests--rendered-text)
          (let ((bounds (etaf-host-ref-bounds runtime 'ncm-quality)))
            (should bounds)
            (should (string-match-p (regexp-quote (cadr sample))
                                    (buffer-substring-no-properties (car bounds) (cdr bounds))))))
        (dolist (sample '((90 medium) (64 narrow) (180 wide)))
          (set-frame-size (selected-frame) (car sample) 48)
          (etaf-ncm-refresh app)
          (etaf-ncm-tests--rendered-text)
          (should (eq (plist-get (etaf-ncm-state app) :layout) (cadr sample)))
          (should (etaf-host-ref-bounds runtime 'ncm-play))
          (should (etaf-host-ref-bounds runtime 'ncm-seek))
          (should (etaf-host-ref-bounds runtime 'ncm-volume))
          (should (eq (and (etaf-host-ref-bounds runtime 'ncm-cover) t)
                      (eq (cadr sample) 'wide)))
          (should (eq (and (etaf-host-ref-bounds runtime 'ncm-quality) t)
                      (eq (cadr sample) 'wide))))))))

(ert-deftest etaf-ncm-tests-player-pane-buttons-preserve-state ()
  "Cover, lyric and queue controls reveal their pane without resetting selection."
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-move-selection app 3)
      (etaf-ncm-tests--rendered-text)
      (let ((selected (plist-get (etaf-ncm-state app) :selection)))
        (should (= selected 3))
        (etaf-ncm-tests--press-help "显示播放列表")
        (should (eq (plist-get (etaf-ncm-state app) :aside) 'queue))
        (etaf-dispatch-event (etaf-runtime-for-buffer (current-buffer)) 'ncm-cover 'press)
        (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
        (set-frame-size (selected-frame) 64 48)
        (etaf-ncm-refresh app)
        (etaf-ncm-tests--rendered-text)
        (etaf-ncm-tests--press-help "显示播放列表")
        (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
        (etaf-ncm-tests--rendered-text)
        (etaf-ncm-tests--press-help "显示歌词 (l)")
        (should (eq (plist-get (etaf-ncm-state app) :aside) 'lyrics))
        (should (eq (plist-get (etaf-ncm-state app) :pane) 'aside))
        (should (equal (plist-get (etaf-ncm-state app) :selection) selected))))))

(ert-deftest etaf-ncm-tests-player-clock-moves-the-elapsed-label-and-meter ()
  "Playing seconds move the elapsed label and the progress meter in place.
The meter is the shared range's fill overlay, so its painted span grows
through a retained width update without publishing a new View."
  (let* ((etaf-ncm-tests--poll-interval 1)
         (calls 0)
         (app (etaf-ncm-tests--session
               (lambda (request callback)
                 (if (eq (plist-get request :op) :status)
                     (funcall callback
                              (list :ok (append (list :elapsed (number-to-string (+ 80 (* 10 (cl-incf calls)))))
                                                (etaf-ncm-tests--fixture "status"))))
                   (etaf-ncm-tests--client request callback))))))
    (etaf-ncm-tests--with-player app
      (etaf-ncm-tests--rendered-text)
      (let* ((runtime (etaf-runtime-for-buffer (current-buffer)))
             (before (etaf-ncm-tests--host-text 'ncm-elapsed))
             (meter-before (etaf-host-ref-bounds runtime 'ncm-meter)))
        (with-timeout (5 (ert-fail "Playback polling did not complete"))
          (while (< calls 3) (sleep-for 0.06)))
        (etaf-ncm-tests--rendered-text)
        (should-not (equal (etaf-ncm-tests--host-text 'ncm-elapsed) before))
        (let ((meter-after (etaf-host-ref-bounds runtime 'ncm-meter)))
          (should (and meter-before meter-after
                       (> (- (cdr meter-after) (car meter-after))
                          (- (cdr meter-before) (car meter-before))))))))))

(ert-deftest etaf-ncm-tests-keys-reach-the-player-around-the-renderer-map ()
  "The documented keys reach the player in a mounted buffer.
The renderer installs its own minor-mode map, which outranks the major-mode
map; the player overrides the colliding commands, so the real command loop,
not just `etaf-ncm-mode-map', must find the player command."
  (setq etaf-ncm-tests--requests nil)
  (let ((app (etaf-ncm-tests--session)))
    (etaf-ncm-tests--with-player app
      (execute-kbd-macro (kbd "<next>"))
      (let ((state (etaf-ncm-state app)))
        (should (= (plist-get state :selection)
                   (min (plist-get state :page-size)
                        (1- (plist-get state :rows-total))))))
      (execute-kbd-macro (kbd "<prior>"))
      (should (zerop (plist-get (etaf-ncm-state app) :selection)))
      (execute-kbd-macro (kbd "n"))
      (should (etaf-ncm-tests--request :next))
      (execute-kbd-macro (kbd "p"))
      (should (etaf-ncm-tests--request :previous))
      (execute-kbd-macro (kbd "SPC"))
      (should (etaf-ncm-tests--request :toggle))
      ;; RET prefers the renderer's focused Host and still plays the row the
      ;; selection points at when point carries none.
      (execute-kbd-macro (kbd "j"))
      (setq etaf-ncm-tests--requests nil)
      (execute-kbd-macro (kbd "RET"))
      (should (or (etaf-ncm-tests--request :play)
                  (etaf-ncm-tests--request :jump))))))

(provide 'etaf-ncm-tests)
;;; etaf-ncm-tests.el ends here

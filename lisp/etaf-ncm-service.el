;;; etaf-ncm-service.el --- NetEase Cloud Music backend client -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The player does not re-implement the NetEase protocol.  It drives the
;; `netease-music' Pi skill through its two documented entry points:
;;
;;   node <skill>/scripts/netease-api.mjs COMMAND ...   reading API data
;;   bash <skill>/scripts/netease-music.sh COMMAND ...  playback and state
;;
;; Both print JSON.  Requests are plists such as (:op :browse :resource :daily)
;; and every call is asynchronous: CALLBACK runs later in the Emacs event loop
;; with (:ok DATA) or (:error MESSAGE :hint HINT).  Nothing here blocks, so the
;; interface keeps repainting while a request is in flight.
;;
;; Tests replace the transport by binding `etaf-ncm-client-factory' to a
;; function returning a fake client, so no scenario needs the network, mpv or a
;; login.  `etaf-ncm-parse-lyric' is transport independent and directly tested.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)

(define-error 'etaf-ncm-error "NetEase Cloud Music player error")

(defcustom etaf-ncm-skill-directory
  (expand-file-name "~/.pi/agent/shared/skills/netease-music")
  "Directory holding the netease-music skill scripts.
`etaf-ncm-make-client' uses it to locate `scripts/netease-api.mjs' and
`scripts/netease-music.sh'."
  :type 'directory
  :group 'etaf-ncm)

(defcustom etaf-ncm-state-directory
  (expand-file-name "~/.pi/agent/local/skills/netease-music")
  "Directory holding the netease-music skill state files.
The queue panel reads the documented `queue.json' track list from it; the
playback truth for the current index still comes from the skill command."
  :type 'directory
  :group 'etaf-ncm)

(defcustom etaf-ncm-node-program "node"
  "Node executable used to run the skill's API client."
  :type 'string
  :group 'etaf-ncm)

(defcustom etaf-ncm-request-timeout 30
  "Seconds before a backend request is abandoned.
The timer kills the child process, so a hung `mpv' interaction cannot pin a
pending callback forever.  Callers see (:error MESSAGE)."
  :type 'number
  :group 'etaf-ncm)

(defvar etaf-ncm-client-factory nil
  "Function returning the backend client used by new players.
It is called with no arguments and must return a client built by
`etaf-ncm-make-client', or any function accepting (REQUEST CALLBACK) as
`etaf-ncm-client-call' documents.  Nil selects the default subprocess client;
tests bind this to a fake client.")

(cl-defstruct (etaf-ncm--client (:constructor etaf-ncm--client-create))
  "Backend client that runs the netease-music skill as child processes."
  skill-directory state-directory node-program timeout (pending nil))

(cl-defstruct (etaf-ncm--pending (:constructor etaf-ncm--pending-create))
  "One in-flight backend request."
  process timer cancelled stdout stderr)

(cl-defun etaf-ncm-make-client (&key skill-directory state-directory node-program timeout)
  "Create a client that runs the netease-music skill as child processes.
SKILL-DIRECTORY, STATE-DIRECTORY, NODE-PROGRAM and TIMEOUT default to
`etaf-ncm-skill-directory', `etaf-ncm-state-directory', `etaf-ncm-node-program'
and `etaf-ncm-request-timeout'."
  (etaf-ncm--client-create
   :skill-directory (or skill-directory etaf-ncm-skill-directory)
   :state-directory (or state-directory etaf-ncm-state-directory)
   :node-program (or node-program etaf-ncm-node-program)
   :timeout (or timeout etaf-ncm-request-timeout)))

(defun etaf-ncm-client-call (client request callback)
  "Send REQUEST through CLIENT and deliver the reply to CALLBACK.
CLIENT is a client from `etaf-ncm-make-client' or a function of two arguments
(REQUEST CALLBACK), which is how tests inject a fake.

REQUEST is a plist whose `:op' selects one backend operation:

  :browse       (:op :browse :resource daily)  read one library list
  :search       (:op :search :keyword \"陈粒\" :scope song)
  :lyric        (:op :lyric :id 5231190)       fetch LRC text
  :session      (:op :session)                 account of the stored login
  :status       (:op :status)                  playback truth from mpv
  :queue        (:op :queue)                   queue count, index and tracks
  :play         (:op :play :target (:kind chart :id 19723756))
  :add          (:op :add :id 5231190)         append one song to the queue
  :jump         (:op :jump :index 12)          play queue entry by index
  :volume       (:op :volume :value 60)        read the volume when VALUE is nil
  :seek         (:op :seek :seconds -10)       relative seek
  :pause :resume :toggle :next :previous :stop :like :unlike
  :shuffle      (:op :shuffle :on t)
  :repeat       (:op :repeat :on nil)
  :queue-save   (:op :queue-save :name \"晚上\")
  :queue-load   (:op :queue-load :name \"晚上\")

CALLBACK receives exactly one of (:ok DATA), where DATA is the decoded JSON
plist, or (:error MESSAGE :hint HINT) when the command failed, timed out or
returned a backend error.  Requests run in the background, so CALLBACK may run
long after the call returns."
  (if (etaf-ncm--client-p client)
      (etaf-ncm--client-request client request callback)
    (if (functionp client)
        (funcall client request callback)
      (signal 'etaf-ncm-error (list (format "Not a backend client: %S" client))))))

(defun etaf-ncm-cancel (client)
  "Abandon every in-flight request of CLIENT.
Cancelled requests never run their callbacks.  Return the number of cancelled
requests, or 0 when CLIENT is not a subprocess client."
  (let ((count 0))
    (when (etaf-ncm--client-p client)
      (dolist (pending (etaf-ncm--client-pending client))
        (setf (etaf-ncm--pending-cancelled pending) t)
        (when-let* ((timer (etaf-ncm--pending-timer pending)))
          (cancel-timer timer))
        (when-let* ((process (etaf-ncm--pending-process pending)))
          (when (process-live-p process)
            (cl-incf count)
            (delete-process process))))
      (setf (etaf-ncm--client-pending client) nil))
    count))

(defun etaf-ncm-parse-lyric (text)
  "Parse LRC TEXT into a list of (SECONDS . LINE) ordered by SECONDS.
Lines without a timestamp are dropped, empty ones are kept so pauses in the
song stay visible.  TEXT may be nil."
  (let (entries)
    (dolist (line (split-string (or text "") "\n"))
      (when (string-match
             "\\`\\(?:\\[[0-9]+:[0-9]+\\(?:[.:][0-9]+\\)?\\]\\)+\\(.*\\)\\'" line)
        (let ((body (string-trim (match-string 1 line)))
              (start 0))
          (while (string-match "\\[\\([0-9]+\\):\\([0-9]+\\)\\(?:[.:]\\([0-9]+\\)\\)?\\]" line start)
            (setq start (match-end 0))
            (let* ((minutes (string-to-number (match-string 1 line)))
                   (seconds (string-to-number (match-string 2 line)))
                   (fraction (match-string 3 line))
                   (millis (if fraction
                               (/ (string-to-number fraction)
                                  (expt 10.0 (length fraction)))
                             0)))
              (push (cons (+ (* minutes 60) seconds millis) body) entries))))))
    (sort (nreverse entries) (lambda (a b) (< (car a) (car b))))))

;;; ---------------------------------------------------------------------------
;;; Request translation
;;; ---------------------------------------------------------------------------

(defconst etaf-ncm--browse-resources
  '((:daily . "daily") (:liked . "liked") (:fm . "fm") (:recent . "recent")
    (:playlists . "myplaylists") (:charts . "charts") (:albums . "myalbums")
    (:artists . "myartists") (:podcasts . "podcasts"))
  "Library resources served by `netease-api.mjs'.")

(defconst etaf-ncm--play-commands
  '((daily . "daily") (liked . "liked") (fm . "fm") (playlist . "playlist")
    (album . "album") (artist . "artist") (chart . "chart")
    (podcast . "podcast") (episode . "episode") (song . "play")
    (query . "play"))
  "Playback contexts accepted by `netease-music.sh'.")

(defun etaf-ncm--client-request (client request callback)
  "Run REQUEST through the skill processes of CLIENT, then call CALLBACK."
  (let* ((command (condition-case error
                      (etaf-ncm--client-command client request)
                    (error (funcall callback
                                    (list :error (error-message-string error)))
                           nil)))
         (transform (pcase (plist-get request :op)
                      (:queue (lambda (data)
                                (plist-put data :songs
                                           (etaf-ncm--queue-tracks client))))
                      (_ #'identity))))
    (when command
      (etaf-ncm--spawn client (car command) (cdr command)
                       (lambda (result)
                         (funcall callback
                                  (if (eq (car result) :ok)
                                      (list :ok (funcall transform (cadr result)))
                                    result)))))))

(defun etaf-ncm--client-command (client request)
  "Return the command line for REQUEST as (PROGRAM . ARGUMENTS).
The result is ready for `make-process': its first element is the program and
the rest are the arguments.  Signal `etaf-ncm-error' for an unknown request."
  (let* ((skill (etaf-ncm--client-skill-directory client))
         (api (expand-file-name "scripts/netease-api.mjs" skill))
         (music (expand-file-name "scripts/netease-music.sh" skill))
         (node (etaf-ncm--client-node-program client))
         (op (plist-get request :op)))
    (pcase op
      ((or :browse :search :lyric :session)
       (cons (etaf-ncm--program node api)
             (cons api (etaf-ncm--api-arguments request))))
      (:status
       (cons (etaf-ncm--script music) (list music "status" "--json" "--quiet")))
      ((or :queue :play :add :jump :volume :seek :pause :resume :toggle
           :next :previous :stop :like :unlike :shuffle :repeat
           :queue-save :queue-load)
       (cons (etaf-ncm--script music)
             (append (list music) (etaf-ncm--script-arguments request)
                     (list "--json" "--quiet"))))
      (_ (signal 'etaf-ncm-error (list (format "Unknown request: %S" request)))))))

(defun etaf-ncm--program (program script)
  "Return PROGRAM to run SCRIPT, verifying both exist."
  (unless (file-readable-p script)
    (signal 'etaf-ncm-error
            (list (format "netease-music skill script is missing: %s" script))))
  (or (executable-find program)
      (signal 'etaf-ncm-error (list (format "Executable is missing: %s" program)))))

(defun etaf-ncm--script (script)
  "Return the shell program used to run SCRIPT."
  (unless (file-readable-p script)
    (signal 'etaf-ncm-error
            (list (format "netease-music skill script is missing: %s" script))))
  (or (executable-find "bash") "/bin/bash"))

(defun etaf-ncm--limit (request fallback)
  "Return the `:limit' of REQUEST, or FALLBACK."
  (or (plist-get request :limit) fallback))

(defun etaf-ncm--api-arguments (request)
  "Return the netease-api.mjs arguments for REQUEST."
  (pcase (plist-get request :op)
    (:browse
     (let* ((resource (plist-get request :resource))
            (command (cdr (assq resource etaf-ncm--browse-resources))))
       (unless command
         (signal 'etaf-ncm-error (list (format "Unknown library: %S" resource))))
       (append (list command)
               (when (memq resource '(:daily :liked :fm :recent :playlists :albums
                                              :artists :podcasts))
                 (list "--limit" (number-to-string (etaf-ncm--limit request 50)))))))
    (:search
     (let ((keyword (or (plist-get request :keyword) "")))
       (when (string-empty-p (string-trim keyword))
         (signal 'etaf-ncm-error '("Search needs a keyword")))
       (if (eq (plist-get request :scope) 'playlist)
           (list "playlists" keyword "--limit"
                 (number-to-string (etaf-ncm--limit request 20)))
         (list "search" keyword "--limit"
               (number-to-string (etaf-ncm--limit request 30))))))
    (:lyric
     (let ((id (plist-get request :id)))
       (unless id (signal 'etaf-ncm-error '("Lyric needs a song id")))
       (list "lyric" (etaf-ncm--id id) "--trans")))
    (:session (list "session"))
    (_ (signal 'etaf-ncm-error (list (format "Unknown request: %S" request))))))

(defun etaf-ncm--script-arguments (request)
  "Return the netease-music.sh arguments for REQUEST."
  (pcase (plist-get request :op)
    (:queue (list "queue" "--limit" (number-to-string (etaf-ncm--limit request 200))))
    (:play
     (let* ((target (plist-get request :target))
            (kind (car target))
            (command (cdr (assq kind etaf-ncm--play-commands))))
       (unless command
         (signal 'etaf-ncm-error (list (format "Cannot play: %S" target))))
       (let ((argument (plist-get target :id)))
         (when (memq kind '(song query playlist album artist chart podcast episode))
           (unless (and argument (not (string-empty-p (format "%s" argument))))
             (signal 'etaf-ncm-error (list (format "Cannot play: %S" target)))))
         (append (list command)
                 (when (memq kind '(song query playlist album artist chart podcast episode))
                   (list (etaf-ncm--id argument)))))))
    (:add
     (let ((id (plist-get request :id)))
       (unless id (signal 'etaf-ncm-error '("Add needs a song id")))
       (list "add" (etaf-ncm--id id))))
    (:jump
     (let ((index (plist-get request :index)))
       (unless (and (integerp index) (> index 0))
         (signal 'etaf-ncm-error (list (format "Invalid queue index: %S" index))))
       (list "jump" (number-to-string index))))
    (:volume
     (if-let* ((value (plist-get request :value)))
         (progn
           (unless (and (numberp value) (<= 0 value 130))
             (signal 'etaf-ncm-error (list (format "Invalid volume: %S" value))))
           (list "volume" (number-to-string (round value))))
       (list "volume")))
    (:seek
     (let ((seconds (plist-get request :seconds)))
       (unless (numberp seconds)
         (signal 'etaf-ncm-error (list (format "Invalid seek: %S" seconds))))
       (list "seek" (if (>= seconds 0)
                        (number-to-string (round seconds))
                      (format "-%d" (abs (round seconds)))))))
    (:shuffle (list "shuffle" (if (plist-get request :on) "on" "off")))
    (:repeat (list "repeat" (if (plist-get request :on) "on" "off")))
    (:pause '("pause"))
    (:resume '("resume"))
    (:toggle '("toggle"))
    (:next '("next"))
    (:previous '("prev"))
    (:stop '("stop"))
    (:like '("like"))
    (:unlike '("unlike"))
    (:queue-save
     (append (list "queue-save") (when-let* ((name (plist-get request :name)))
                                   (list (format "%s" name)))))
    (:queue-load
     (let ((name (plist-get request :name)))
       (unless (and name (not (string-empty-p (format "%s" name))))
         (signal 'etaf-ncm-error '("queue-load needs a saved name")))
       (list "queue-load" (format "%s" name))))
    (_ (signal 'etaf-ncm-error (list (format "Unknown request: %S" request))))))

(defun etaf-ncm--id (value)
  "Return VALUE as a command argument string."
  (if (numberp value) (number-to-string value) (format "%s" value)))

;;; ---------------------------------------------------------------------------
;;; Child processes
;;; ---------------------------------------------------------------------------

(cl-defun etaf-ncm--spawn (client program arguments callback)
  "Run PROGRAM with ARGUMENTS for CLIENT; deliver its decoded JSON to CALLBACK."
  (let* ((stdout (generate-new-buffer " *etaf-ncm-stdout*"))
         (stderr (generate-new-buffer " *etaf-ncm-stderr*"))
         (pending (etaf-ncm--pending-create :stdout stdout :stderr stderr))
         (timeout (etaf-ncm--client-timeout client)))
    (condition-case error
        (setf (etaf-ncm--pending-process pending)
              ;; `make-process' has no :environment keyword, so the child's
              ;; environment comes from a binding around the call.
              (let ((process-environment (etaf-ncm--environment client)))
                (make-process
                 :name "etaf-ncm"
                 :buffer stdout
                 :stderr stderr
                 :command (cons program arguments)
                 :connection-type 'pipe
                 :noquery t
                 :coding 'utf-8-unix)))
      (error
       (kill-buffer stdout)
       (kill-buffer stderr)
       (funcall callback (list :error (error-message-string error)))
       (cl-return-from etaf-ncm--spawn nil)))
    (push pending (etaf-ncm--client-pending client))
    (setf (etaf-ncm--pending-timer pending)
          (run-at-time
           timeout nil
           (lambda ()
             (setf (etaf-ncm--pending-cancelled pending) t)
             (when-let* ((process (etaf-ncm--pending-process pending)))
               (when (process-live-p process) (delete-process process)))
             (setf (etaf-ncm--client-pending client)
                   (delq pending (etaf-ncm--client-pending client)))
             (funcall callback
                      (list :error (format "Backend request timed out after %ss" timeout)
                            :hint (mapconcat #'identity (cons program arguments) " "))))))
    (set-process-sentinel
     (etaf-ncm--pending-process pending)
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal failed))
         (etaf-ncm--settle client pending process callback))))
    nil))

(defun etaf-ncm--settle (client pending process callback)
  "Collect the result of PROCESS and finish PENDING for CLIENT.
The callback is skipped when the request was cancelled."
  (let ((stdout (etaf-ncm--pending-stdout pending))
        (stderr (etaf-ncm--pending-stderr pending))
        (cancelled (etaf-ncm--pending-cancelled pending)))
    (when-let* ((timer (etaf-ncm--pending-timer pending)))
      (cancel-timer timer))
    (setf (etaf-ncm--client-pending client)
          (delq pending (etaf-ncm--client-pending client)))
    (let ((output (with-current-buffer stdout (buffer-string)))
          (errors (with-current-buffer stderr (buffer-string)))
          (status (process-exit-status process)))
      (kill-buffer stdout)
      (kill-buffer stderr)
      (unless cancelled
        (funcall callback
                 (if (and (eq (process-status process) 'exit) (zerop status))
                     (let ((data (etaf-ncm--decode output)))
                       (cond ((null data) (list :error "Backend returned no data"
                                                :hint (string-trim errors)))
                             ((eq (plist-get data :ok) :false)
                              (etaf-ncm--failure data errors))
                             (t (list :ok data))))
                   (let ((data (etaf-ncm--decode output)))
                     (if data
                         (etaf-ncm--failure data errors)
                       (list :error (format "Backend command failed (exit %s)" status)
                             :hint (string-trim errors))))))))))

(defun etaf-ncm--failure (data errors)
  "Return an (:error ...) result built from backend DATA and ERRORS."
  (let ((message (or (plist-get data :error)
                     (plist-get data :conclusion)
                     (plist-get data :message)
                     "Backend request failed"))
        (hint (or (plist-get data :hint) (string-trim errors))))
    (append (list :error (if (stringp message) message (format "%s" message)))
            (when (and hint (not (string-empty-p hint))) (list :hint hint)))))

(defun etaf-ncm--decode (output)
  "Decode the first JSON object in OUTPUT, or nil."
  (when (and output (not (string-empty-p (string-trim output))))
    (condition-case nil
        (json-parse-string (string-trim output)
                           :object-type 'plist
                           :array-type 'list
                           :null-object nil
                           :false-object :false)
      (error nil))))

(defun etaf-ncm--environment (client)
  "Return the process environment for CLIENT's child processes.
The stored login cookie is exported in the names the skill reads, so the skill
also works when only the shell environment was configured."
  (let ((cookie (etaf-ncm--cookie client)))
    (append
     (seq-remove (lambda (entry)
                   (string-prefix-p "NETEASE_COOKIE=" entry))
                 process-environment)
     (when (and cookie (not (string-empty-p cookie)))
       (list (concat "NETEASE_COOKIE=" cookie)
             (concat "PI_SKILL_NETEASE_MUSIC_COOKIE=" cookie))))))

(defun etaf-ncm--cookie (client)
  "Return the NetEase login cookie known to CLIENT, or nil.
The skill environment wins over its state file, matching the skill's own
resolution order; a missing cookie is not an error here, because the backend
reports the login failure with its own message."
  (or (getenv "PI_SKILL_NETEASE_MUSIC_COOKIE")
      (getenv "NETEASE_COOKIE")
      (let ((file (expand-file-name
                   "config.json" (etaf-ncm--client-state-directory client))))
        (when (file-readable-p file)
          (let ((data (etaf-ncm--decode
                       (with-temp-buffer
                         (insert-file-contents file)
                         (buffer-string)))))
            (let ((cookie (plist-get data :cookie)))
              (and (stringp cookie) (not (string-empty-p cookie)) cookie)))))))

(defun etaf-ncm--queue-tracks (client)
  "Return the queue track list recorded by the skill for CLIENT.
The list comes from the skill's documented `queue.json' state file; the current
index always comes from the skill command, so a stale file cannot invent a
playing position."
  (let ((file (expand-file-name "queue.json" (etaf-ncm--client-state-directory client))))
    (when (file-readable-p file)
      (let ((data (etaf-ncm--decode
                   (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))))
        (delq nil (mapcar #'etaf-ncm--normalize-track (plist-get data :songs)))))))

(defun etaf-ncm--normalize-track (track)
  "Return TRACK with numeric id, duration and a real VIP flag."
  (when (listp track)
    (list :id (etaf-ncm--number (plist-get track :id))
          :name (etaf-ncm--string (plist-get track :name))
          :artist (etaf-ncm--string (plist-get track :artist))
          :album (etaf-ncm--string (plist-get track :album))
          :ms (etaf-ncm--number (plist-get track :ms))
          :vip (eq t (plist-get track :vip)))))

(defun etaf-ncm--list (value)
  "Return VALUE as a proper list of elements.
JSON arrays decode to vectors, so every sequence a view or a model walks goes
through here: accept lists, vectors, and nothing else."
  (cond ((null value) nil)
        ((listp value) value)
        ((vectorp value) (append value nil))
        (t nil)))

(defun etaf-ncm--number (value)
  "Return VALUE as a number, or nil."
  (cond ((numberp value) value)
        ((and (stringp value) (string-match-p "\\`[0-9]+\\'" (string-trim value)))
         (string-to-number (string-trim value)))
        ((eq value t) nil)
        ((and value (not (string-empty-p (string-trim (format "%s" value)))))
         (string-to-number (format "%s" value)))
        (t nil)))

(defun etaf-ncm--string (value)
  "Return VALUE as a string; `:false' and nil become the empty string."
  (cond ((null value) "")
        ((eq value :false) "")
        ((stringp value) value)
        ((numberp value) (number-to-string value))
        (t (format "%s" value))))

(provide 'etaf-ncm-service)
;;; etaf-ncm-service.el ends here

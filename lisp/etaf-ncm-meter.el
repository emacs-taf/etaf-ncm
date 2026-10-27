;;; etaf-ncm-meter.el --- Audio levels for the now-playing spectrum -*- lexical-binding: t; -*-

;; Copyright (C) 2026 ETAF contributors
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;;
;; The now-playing page's spectrum follows the audio that is actually playing.
;; A second decoder reads the same source mpv plays, starting at the reported
;; position, and hands back mono samples; `etaf-ncm-meter-levels' turns the
;; newest block into one level per column with a Goertzel pass, so the bars move
;; with the music instead of a canned loop.
;;
;; The meter is optional everywhere.  Without ffmpeg, without a source, or after
;; the decoder dies, `etaf-ncm-meter-levels' returns quiet levels and the page
;; keeps rendering; `etaf-ncm-meter-live-p' tells the page which of the two it
;; is showing.

;;; Code:

(require 'cl-lib)

(defcustom etaf-ncm-meter-program "ffmpeg"
  "Program that decodes the playing source for the spectrum."
  :type 'string
  :group 'etaf-ncm)

(defcustom etaf-ncm-meter-rate 8000
  "Sample rate the meter decodes at, in hertz.
Four kilohertz of bandwidth is enough for a spectrum whose bars top out at
3.6 kHz, and it keeps the pipe at sixteen kilobytes a second."
  :type 'integer
  :group 'etaf-ncm)

(defcustom etaf-ncm-meter-window 512
  "Samples one analysis block holds.
At the meter rate this spans 64 milliseconds: short enough that a bar lands on
the beat it belongs to, long enough for the low bands to resolve."
  :type 'integer
  :group 'etaf-ncm)

(defconst etaf-ncm-meter--bands '(60 3600)
  "Lowest and highest band centre the spectrum covers, in hertz.")

(defconst etaf-ncm-meter--floor -60.0
  "Decibels a bar treats as silence.
A mastered mix spreads its bands between about -20 and -55 dB, so the floor
sits below the quiet end and a bar keeps its whole height for the loud ones
instead of pinning every band to the top.")

(defconst etaf-ncm-meter--curve 1.15
  "Exponent shaping a bar's rise from silence to full.
Above one, quiet bands fall away faster than loud ones, which is how a
spectrum reads at a glance instead of as a wall of equal columns.")

(defconst etaf-ncm-meter--decay 0.80
  "Share of the previous level a falling bar keeps.
Bars drop smoothly and rise at once, which is how a level meter reads." )

(defvar etaf-ncm-meter--process nil
  "Decoder process feeding the meter, or nil.")

(defvar etaf-ncm-meter--pending nil
  "Unread sample bytes, newest last.")

(defvar etaf-ncm-meter--levels nil
  "Smoothed levels of the last analysis, one per column.")

(defvar etaf-ncm-meter--source nil
  "Source the running decoder reads.")

(defvar etaf-ncm-meter--position 0
  "Playback position, in seconds, the running decoder was started at.")

(defvar etaf-ncm-meter--bytes 0
  "Sample bytes the running decoder has produced.")

(defvar etaf-ncm-meter--seen nil
  "Last playback position this meter judged, so only real moves count.")

(defvar etaf-ncm-meter--started-at nil
  "`float-time' when the running decoder was started.
A decoder that has just started has produced no samples yet, and judging its
drift during that moment would restart it forever.")

(defconst etaf-ncm-meter--lead 1.1
  "Seconds a fresh decoder starts past the music.
Opening a stream and filling the pipe costs about this long; seeking past it
means the first samples that come out belong to the moment being heard.")

(defconst etaf-ncm-meter--drift 3.0
  "Seconds the player may differ from the decoded audio before a restart.
Starting a decoder on a stream costs a moment, and from then on it reads at
playback speed, so the bars would trail the music by that moment forever.  A
difference larger than this restarts it from where the music is now.")

(defun etaf-ncm-meter-live-p ()
  "Return non-nil when a decoder is feeding the meter."
  (and etaf-ncm-meter--process (process-live-p etaf-ncm-meter--process)))

(defun etaf-ncm-meter-stop ()
  "Stop the decoder and forget its samples."
  (when (process-live-p etaf-ncm-meter--process)
    (delete-process etaf-ncm-meter--process))
  (setq etaf-ncm-meter--process nil
        etaf-ncm-meter--pending nil
        etaf-ncm-meter--levels nil
        etaf-ncm-meter--source nil
        etaf-ncm-meter--position 0
        etaf-ncm-meter--bytes 0
        etaf-ncm-meter--seen nil
        etaf-ncm-meter--started-at nil))

(defun etaf-ncm-meter--decoded ()
  "Return how many seconds of audio the running decoder has produced."
  (/ (float etaf-ncm-meter--bytes)
     (* 2.0 etaf-ncm-meter-rate)))

(defun etaf-ncm-meter--collect (process chunk)
  "Append CHUNK from PROCESS to the pending samples, keeping one window."
  (when (eq process etaf-ncm-meter--process)
    (setq etaf-ncm-meter--bytes (+ etaf-ncm-meter--bytes (length chunk)))
    (let ((keep (* 2 etaf-ncm-meter-window)))
      (setq etaf-ncm-meter--pending
            (concat (and (> (length etaf-ncm-meter--pending) keep)
                         (substring etaf-ncm-meter--pending
                                    (- (length etaf-ncm-meter--pending) keep)))
                    chunk)))))

(defun etaf-ncm-meter-start (source position)
  "Decode SOURCE from POSITION seconds and feed the meter; return non-nil.
SOURCE is the file or stream URL the backend is playing.  A request for what is
already decoding keeps it running, so a status tick never restarts the pipe; a
seek restarts it from the new position, because audio the listener jumped away
from would otherwise keep driving the bars."
  (let* ((position (float (max 0 (or position 0))))
         (live (and (etaf-ncm-meter-live-p)
                    (equal source etaf-ncm-meter--source)))
         ;; Only a clock that moved can mean a seek.  A tick that repeats the
         ;; same second (a stalled poll, a paused player) must not look like
         ;; one, or the decoder would restart before it produces any samples.
         (moved (and etaf-ncm-meter--seen
                     (/= position etaf-ncm-meter--seen)))
         (trail (- position (+ etaf-ncm-meter--position
                               (etaf-ncm-meter--decoded))))
         ;; Restart only for a real jump: a decoder trails by the lead-in for a
         ;; moment and that is not a seek.
         (behind (> (abs trail) etaf-ncm-meter--drift)))
    (when (and (stringp source) (not (string-empty-p source))
               (executable-find etaf-ncm-meter-program))
      (if (and live (not (and moved behind)))
          (setq etaf-ncm-meter--seen position)
        (etaf-ncm-meter-stop)
        ;; Starting a decoder on a stream costs about this long, and the
        ;; decoder then reads at playback speed, so beginning that much further
        ;; on puts the samples on the beat.  Measuring it instead fought with
        ;; the restarts it caused.
        (setq position (+ position etaf-ncm-meter--lead))
        (setq etaf-ncm-meter--source source
              etaf-ncm-meter--position position
              etaf-ncm-meter--seen position
              etaf-ncm-meter--started-at (float-time)
              etaf-ncm-meter--pending nil
              etaf-ncm-meter--levels nil)
        (condition-case nil
            (setq etaf-ncm-meter--process
                  (make-process
                   :name "etaf-ncm-meter"
                   :command (list etaf-ncm-meter-program
                                  "-v" "error"
                                  ;; `-re' paces the read at playback speed;
                                  ;; without it ffmpeg decodes the rest of the
                                  ;; track at once and the bars freeze.
                                  "-re"
                                  "-ss" (format "%.2f" position)
                                  "-i" source
                                  "-vn" "-ac" "1"
                                  "-ar" (number-to-string etaf-ncm-meter-rate)
                                  "-f" "s16le" "-")
                   :connection-type 'pipe
                   :coding 'no-conversion
                   :noquery t
                   :stderr (generate-new-buffer " *etaf-ncm meter*")
                   :filter #'etaf-ncm-meter--collect))
          (error nil)))
      (etaf-ncm-meter-live-p))))

(defun etaf-ncm-meter--samples ()
  "Return the newest analysis window of pending samples as numbers in -1..1."
  (let* ((window (* 2 etaf-ncm-meter-window))
         (raw etaf-ncm-meter--pending)
         (start (max 0 (- (length raw) window)))
         (count (/ (- (length raw) start) 2))
         (samples (make-vector count 0.0)))
    (dotimes (index count)
      (let ((value (+ (aref raw (+ start (* 2 index)))
                      (* 256 (aref raw (+ start (* 2 index) 1))))))
        (when (>= value 32768) (setq value (- value 65536)))
        (aset samples index (/ value 32768.0))))
    samples))

(defun etaf-ncm-meter--window (samples)
  "Return SAMPLES with a Hann window applied, as a vector."
  (let* ((n (length samples))
         (out (make-vector n 0.0)))
    (dotimes (index n)
      (let ((scale (* 0.5 (- 1 (cos (/ (* 2 pi index) (max 1 (1- n))))))))
        (aset out index (* scale (aref samples index)))))
    out))

(defun etaf-ncm-meter--goertzel (samples frequency)
  "Return SAMPLES' magnitude at FREQUENCY in hertz."
  (let* ((n (length samples))
         (omega (/ (* 2 pi frequency) etaf-ncm-meter-rate))
         (coefficient (* 2 (cos omega)))
         (s1 0.0) (s2 0.0))
    (dotimes (index n)
      (let ((s0 (+ (aref samples index) (* coefficient s1) (- s2))))
        (setq s2 s1 s1 s0)))
    (sqrt (max 0 (- (+ (* s1 s1) (* s2 s2)) (* coefficient s1 s2))))))

(defun etaf-ncm-meter--band-centres (bars)
  "Return BARS logarithmically spaced band centres between the meter's limits."
  (let ((low (log (float (car etaf-ncm-meter--bands))))
        (high (log (float (cadr etaf-ncm-meter--bands)))))
    (cl-loop for index below bars
             collect (exp (+ low (* (- high low)
                                     (/ (float index) (max 1 (1- bars)))))))))

(defun etaf-ncm-meter--decibels (magnitude samples)
  "Return MAGNITUDE in decibels, relative to SAMPLES' length.
The analysis window halves a signal's coherent gain, so recovering the
amplitude of the tone behind a magnitude divides by a quarter of the block
rather than a half; otherwise every bar reads six decibels too low."
  (let* ((n (max 1 (length samples)))
         (amplitude (/ magnitude n 0.25)))
    (if (<= amplitude 1.0e-6)
        -120.0
      (* 20 (log10 amplitude)))))

(defun etaf-ncm-meter-levels (bars)
  "Return BARS audio levels in 0..1 for the newest samples.
A bar rises immediately and falls at `etaf-ncm-meter--decay' per reading, so a
beat reads as a hit rather than a swell.  With no live decoder every bar sits
near silence, which lets the page keep one drawing path."
  (let* ((samples (if (etaf-ncm-meter-live-p) (etaf-ncm-meter--samples) []))
         (enough (>= (length samples) 128))
         (window (and enough (etaf-ncm-meter--window samples)))
         (previous (or etaf-ncm-meter--levels (make-list bars 0.0)))
         (levels
          (cl-loop for centre in (etaf-ncm-meter--band-centres bars)
                   for index from 0
                   for previous-level = (or (nth index previous) 0.0)
                   for magnitude = (and window (etaf-ncm-meter--goertzel window centre))
                   for decibels = (if magnitude
                                      (etaf-ncm-meter--decibels magnitude window)
                                    -120.0)
                   for raw = (expt (max 0.0 (min 1.0
                                              (/ (+ decibels (- etaf-ncm-meter--floor))
                                                 (- etaf-ncm-meter--floor))))
                                   etaf-ncm-meter--curve)
                   collect (max raw (* previous-level etaf-ncm-meter--decay)))))
    (setq etaf-ncm-meter--levels levels)
    levels))

(provide 'etaf-ncm-meter)
;;; etaf-ncm-meter.el ends here

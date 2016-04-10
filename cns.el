;;; cns.el --- Chinese word segmentation library based on cjieba.  -*- lexical-binding: t; -*-

;; Copyright (C) 2016  KANG

;; Author: KANG <kanglmf AT 126 DOT com>
;; Keywords: tools, extensions

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This library uses cjieba (<https://github.com/yanyiwu/cjieba/>)
;; with simple modification.
;;
;; To compile the Chinese word segmentation program, do:
;;
;; $ cd /path/to/this-library
;; $ make
;;
;; This will generate the chinese-word-segmentation executable.
;;
;; Usage example:
;;
;; (add-to-list 'load-path "/path/to/this-library")
;; (setq cns-prog "/path/to/this-library/chinese-word-segmentation")
;; (setq cns-dict-directory "/path/to/this-library/dict")
;; (setq cns-recent-segmentation-limit 20) ; default is 10
;; (setq cns-debug nil) ; disable debug output, default is t
;; (require 'cns nil t)
;;
;; To turn on this minor mode, type: M-x cns-mode RET.  You can also
;; turn on global-cns-mode if you like.
;;
;; NOTE:
;;
;; The `cns-mode', if enabled, changes the following key bindings:
;; +---------------+----------------------+--------------------------+
;; | key binding   | default command      | cns-mode command         |
;; +---------------+----------------------+--------------------------+
;; | M-b           | (backward-word)      | (cns-backward-word)      |
;; | M-f           | (forward-word)       | (cns-forward-word)       |
;; | C-<backspace> | (backward-kill-word) | (cns-backward-kill-word) |
;; | M-DEL         | (backward-kill-word) | (cns-backward-kill-word) |
;; | C-<delete>    | (kill-word)          | (cns-kill-word)          |
;; | M-d           | (kill-word)          | (cns-kill-word)          |
;; +---------------+----------------------+--------------------------+
;;
;; Similar to `backward-word' and `forward-word', prefix argument for
;; all cns-mode commands listed above is also supported.
;;
;; Keep in mind that, Chinese characters include HànZì (汉字) and
;; Chinese punctuation characters.  HànZì needs word segmentation,
;; while Chinese punctuation characters does not.
;;
;; Implementation detail:
;;
;; There are 8 situations for word movement, as illustrated below.
;; Arrow ("<-" or "->") indicates the next movement direction, ",."
;; represents non-word characters, and "I" is the cursor postion.
;;
;; Group 1: Word segmentation is probably necessary.  This means that
;; if it is the first time we met Chinese characters or the surronding
;; Chinese characters are changed, word segmentation is necessary.
;; Otherwise, recent word segmentation is used in order to speed up
;; the movement.
;;
;; +-----------+-------------+-------------------------+------------------+
;; | Situation | example     | next movement direction | desired movement |
;; +-----------+-------------+-------------------------+------------------+
;; | 1a        | 中文I分词   | <-                      | I中文分词        |
;; | 1b        | 中I文分词   | <-                      | I中文分词        |
;; | 2         | 中文分词,.I | <-                      | 中文I分词,.      |
;; | 3a        | 中文I分词   | ->                      | 中文分词I        |
;; | 3b        | 中文分I词   | ->                      | 中文分词I        |
;; | 4         | I,.中文分词 | ->                      | ,.中文I分词      |
;; +-----------+-------------+-------------------------+------------------+
;;
;; Group 2: Word segmentation is not necessary.  This means that if we
;; do normal word movement (i.e. `backward-word' or `forward-word'),
;; there is no HànZì in the region from current point to the point
;; after word movement.  Note that Chinese punctuation character is
;; not HànZì.)
;;
;; +-----------+-------------+-------------------------+------------------+
;; | Situation | example     | next movement direction | desired movement |
;; +-----------+-------------+-------------------------+------------------+
;; | 5         | xxxxIxxxx   | <-                      | Ixxxxxxxx        |
;; | 6         | xxxxxxxx,.I | <-                      | Ixxxxxxxx,.      |
;; | 7         | xxxxIxxxx   | ->                      | xxxxxxxxI        |
;; | 8         | I,.xxxxxxxx | ->                      | ,.xxxxxxxxI      |
;; +-----------+-------------+-------------------------+------------------+

;;; Code:

(defvar cns-process nil "The word segmentation process object.")

(defvar cns-process-name "cns" "The word segmentation process name.")

(defvar cns-process-buffer "*Chinese-word-segmentation*"
  "The word segmentation process buffer.")

(defvar cns-segmentation nil
  "Segmentation data processed from cjieba.
The value is a list that contains all positions of the
segmentation.  For example, the word segmentation data for the
word '中文分词' should be '(2 2), indicating that the word should
be divided into two basic Chinese words: '中文' and '分词'.  This
value is set by the process filter function
`cns-segmentation-filter'.")

(defvar cns-recent-segmentation nil
  "List of the recent word segmentation results.
Each element in the list is also a list that has two elements,
whose `car' is a Chinese word, and `cdr' is the word segmentation
data.  See `cns-segmentation' for more information.")

(defvar cns-buffer-list nil "List of buffers where `cns-mode' is enabled.")

(defgroup cns nil
  "Customization group for cns."
  :group 'emacs
  :prefix "cns-")

(defcustom cns-prog "chinese-word-segmentation"
  "Path of the chinese word segmentation program.
It may be the full path of the executable or just the executable
filename, if Emacs can find it in `process-environment'."
  :type 'string
  :group 'cns)

(defcustom cns-dict-directory nil
  "Directory of dictionary files used by cjieba.
There should be three files in the directory:
\"jieba.dict.utf8\", \"hmm_model.utf8\" and \"user.dict.utf8\"."
  :type 'string
  :group 'cns)

(defcustom cns-recent-segmentation-limit 10
  "Limit of recent word segmentation stored in `cns-recent-segmentation'."
  :type 'integer
  :group 'cns)

(defcustom cns-debug t
  "If non-nil, show word segmentation output in `cns-process-buffer'."
  :type 'boolean
  :group 'cns)

(defun cns-segmentation-filter (proc output)
  "Get word segmentation result and set `cns-segmentation'.
PROC is the word segmentation process, and OUTPUT is the word
segmentation output."
  (let ((string (replace-regexp-in-string "\n" "" output)))
    (when (buffer-live-p (process-buffer proc))
      (with-current-buffer (process-buffer proc)
        (goto-char (process-mark proc))
        (if cns-debug
            (insert output))
        (set-marker (process-mark proc) (point))))
    (setq cns-segmentation
          (mapcar 'string-to-number (split-string string " " t)))))

(defun cns-send-string (string proc)
  "Send STRING to the word segmentation process PROC."
  (process-send-string proc (format "%s\n" string)))

(defun cns-get-word-position (direction)
  "Return the position after word movement towards DIRECTION."
  (save-excursion
    (if (eq direction 'forward)
        (progn (forward-word)
               (point))
      (backward-word)
      (point))))

(defun cns-get-word (direction)
  "Return the word towards DIRECTION."
  (let ((pos (point)))
    (if (eq direction 'forward)
        (buffer-substring-no-properties pos (cns-get-word-position 'forward))
      (buffer-substring-no-properties (cns-get-word-position 'backward) pos))))

(defun cns-separate-chinese-word (direction &optional word)
  "Separete HànZì and non-HànZì characters.
DIRECTION may be 'backward or 'forward.  Optional argument WORD
is the word to be processed.  If WORD is omitted, use
`cns-get-word' to obtain it."
  (let ((word (or word (cns-get-word direction))))
    (cond
     ((and (string-match "^\\(\\cC+\\)\\(\\CC*\\)$" word)
           (eq direction 'backward))
      (list (match-string-no-properties 1 word)
            (length (match-string-no-properties 2 word))))
     ((and (string-match "^\\(\\CC*\\)\\(\\cC+\\)$" word)
           (eq direction 'forward))
      (list (length (match-string-no-properties 1 word))
            (match-string-no-properties 2 word)))
     (t nil))))

(defun cns-within-chinese-p nil
  "Return t if current position is surrounded by HànZì or nil otherwise."
  (cond
   ((= (point) (point-min)) nil)
   ((= (point) (point-max)) nil)
   ((and (string-match "^\\cC$" (char-to-string (char-before)))
         (string-match "^\\cC$" (char-to-string (char-after))))
    t)
   (t nil)))

(defun cns-get-chinese-sentence (&optional with-position)
  "Return the whole sentence of chinese text around cursor.
Optional argument WITH-POSITION is non-nil, also return start and
end positions."
  (let ((sentence
         (if (cns-within-chinese-p)
             (concat (cns-get-word 'backward) (cns-get-word 'forward))
           nil)))
    (if with-position
        (list sentence
              (cns-get-word-position 'backward)
              (cns-get-word-position 'forward))
      sentence)))

(defun cns-move-to-point (cursor segmentation pos1 pos2 direction)
  "Return the point of the next movement.
CURSOR is the cursor position before word movement.  SEGMENTATION
is the word segmentation data.  POS1 and POS2 are the start and end
position of SEGMENTATION, respectively.  DIRECTION may be
'backward or 'forward."
  (let* ((pos cursor)
         (seg segmentation)
         (stop nil)
         sum
         (i 0)
         mark)
    (if (eq direction 'backward)
        (progn
          (setq sum pos1)
          (while (not stop)
            (setq sum (+ sum (nth i seg)))
            (if (>= sum pos)
                (setq mark (- sum (nth i seg))
                      stop t))
            (setq i (1+ i))))
      (let ((rseg (reverse seg)))
        (setq sum pos2)                 ; |--|-|---|--|-|---|
        (while (not stop)
          (setq sum (- sum (nth i rseg)))
          (if (<= sum pos)
              (setq mark (+ sum (nth i rseg))
                    stop t))
          (setq i (1+ i)))))
    mark))

(defun cns-store-recent-segmentation (word segmentation)
  "Store WORD and SEGMENTATION results up to `cns-recent-segmentation-limit'.
WORD is the input string of word segmentation, and SEGMENTATION
is the word segmentation result."
  (let ((limit cns-recent-segmentation-limit))
    (cond
     ((= 0 (length cns-recent-segmentation)) ; initialize
      (setq cns-recent-segmentation (list `(,word ,segmentation))))
     ((and (< (length cns-recent-segmentation) limit)
           (not (assoc word cns-recent-segmentation)))
      (setq cns-recent-segmentation (append cns-recent-segmentation
                                            (list `(,word ,segmentation)))))
     ((and (= (length cns-recent-segmentation) limit)
           (not (assoc word cns-recent-segmentation)))
      (setq cns-recent-segmentation (append (cdr cns-recent-segmentation)
                                            (list `(,word ,segmentation))))))))

(defun cns-segmentation-handler (word)
  "Set recent word segmentation and return current word segmentation.
WORD is the input string of word segmentation."
  (let (seg)
    (if (assoc word cns-recent-segmentation)
        (setq seg (cadr (assoc word cns-recent-segmentation)))
      (cns-send-string word cns-process)
      (accept-process-output cns-process)
      (setq seg cns-segmentation))
    (cns-store-recent-segmentation word cns-segmentation)
    seg))

(defun cns-move-distance
    (cursor word-and-pos direction &optional within-chinese-p) ;; "2 1 3 2 1 3"
  "Return the total distance of the next movement.
CURSOR is the cursor position before word movement, WORD-AND-POS
is HànZì associated with its start and end positions, and
DIRECTION is the next movement direction.  Optional argument
WITHIN-CHINESE-P should be t if CURSOR is within HànZì or nil
otherwise."
  (if (not (process-live-p cns-process))
      (error "Chinese word segmentation process is not running, \
enable `cns-mode' first"))
  (let ((pos cursor)
        (word (nth 0 word-and-pos))
        (pos1 (nth 1 word-and-pos))
        (pos2 (nth 2 word-and-pos)))
    (if within-chinese-p
        (let* ((seg (cns-segmentation-handler word))
               (mark (cns-move-to-point pos seg pos1 pos2 direction)))
          (if (eq direction 'backward)
              (- pos mark)
            (- mark pos)))
      (cond
       ((eq direction 'backward)
        (let* ((word-and-len (cns-separate-chinese-word 'backward word))
               (word1 (nth 0 word-and-len))
               (len (nth 1 word-and-len))
               (seg (cns-segmentation-handler word1)))
          (+ (car (last seg)) len)))
       ((eq direction 'forward)
        (let* ((len-and-word (cns-separate-chinese-word 'forward word))
               (len (nth 0 len-and-word))
               (word1 (nth 1 len-and-word))
               (seg (cns-segmentation-handler word1)))
          (+ len (car seg))))))))

(defun cns-move (direction)
  "Perform the actual movement towards DIRECTION."
  (let* ((pos (point))
         (within-chinese-p (cns-within-chinese-p))
         distance)
    (setq distance
          (if within-chinese-p
              (let ((word-and-pos (cns-get-chinese-sentence t)))
                (cns-move-distance pos word-and-pos direction t))
            (cns-move-distance pos
                               (list (cns-get-word direction)
                                     (cns-get-word-position direction)
                                     pos)
                               direction)))
    (if (eq direction 'backward)
        (backward-char distance)
      (forward-char distance))))

(defun cns-backward-word-1 nil
  "Move backward a word just once."
  (if (not (string-match "\\cC" (cns-get-word 'backward)))
      (backward-word)
    (cns-move 'backward)))

(defun cns-backward-word (&optional arg)
  "Move backward a word ARG times."
  (interactive "p")
  (let ((arg (or arg 1))
        (i 0))
    (while (< i arg)
      (cns-backward-word-1)
      (setq i (1+ i)))))

(defun cns-backward-kill-word (&optional arg)
  "Kill characters backward until encountering the beginning of a word.
With argument ARG, do this that many times.  Word may be any
combination of Chinese characters and non-Chinese characters."
  (interactive "p")
  (kill-region (point) (progn (cns-backward-word arg) (point))))

(defun cns-forward-word-1 nil
  "Move forward a word just once."
  (if (not (string-match "\\cC" (cns-get-word 'forward)))
      (forward-word)
    (cns-move 'forward)))

(defun cns-forward-word (&optional arg)
  "Move forward a word ARG times."
  (interactive "p")
  (let ((arg (or arg 1))
        (i 0))
    (while (< i arg)
      (cns-forward-word-1)
      (setq i (1+ i)))))

(defun cns-kill-word (&optional arg)
  "Kill characters forward until encountering the end of a word.
With argument ARG, do this that many times.  Word may be any
combination of Chinese characters and non-Chinese characters."
  (interactive "p")
  (kill-region (point) (progn (cns-forward-word arg) (point))))

(defvar cns-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "M-b") 'cns-backward-word)
    (define-key m (kbd "M-f") 'cns-forward-word)
    (define-key m (kbd "C-<backspace>") 'cns-backward-kill-word)
    (define-key m (kbd "M-DEL") 'cns-backward-kill-word)
    (define-key m (kbd "C-<delete>") 'cns-kill-word)
    (define-key m (kbd "M-d") 'cns-kill-word)
    m))

(defun cns-start-process nil
  "Start the word segmentation process.
Ensure that `cns-dict-directory' is set properly."
  (if (not cns-dict-directory)
      (error "`cns-dict-directory' is not set"))
  (if (not (file-exists-p cns-dict-directory))
      (error "`cns-dict-directory' is not a valid path"))
  (unless (process-live-p cns-process)
    (let* ((dir cns-dict-directory)
           (dict-jieba (concat (file-name-as-directory dir) "jieba.dict.utf8"))
           (dict-hmm (concat (file-name-as-directory dir) "hmm_model.utf8"))
           (dict-user (concat (file-name-as-directory dir) "user.dict.utf8"))
           (cmd (format "%s -j %s -h %s -u %s"
                        cns-prog dict-jieba dict-hmm dict-user)))
      (setq cns-process (start-process-shell-command cns-process-name
                                                     cns-process-buffer
                                                     cmd))))
  ;; wait until cns-process has been initialized
  (accept-process-output cns-process)
  ;; do not query on exit
  (set-process-query-on-exit-flag cns-process nil))

(defun cns-stop-process nil
  "Stop the word segmentation process."
  (cns-send-string "EOF" cns-process))

(defun cns-handle-buffer-list (operation)
  "Maintain a list of buffers where function `cns-mode' is enabled.
If OPERATION is 'enable, put current buffer to the list
`cns-buffer-list'.  Otherwise, delete current buffer from the
list.  When `cns-buffer-list' is nil, disabling function `cns-mode' will
stop the word segmentation process `cns-process'."
  (let ((buffer (current-buffer)))
    (if (eq operation 'enable)
        (if (not (member buffer cns-buffer-list))
            (setq cns-buffer-list `(,@cns-buffer-list ,buffer)))
      (when (member buffer cns-buffer-list)
        (setq cns-buffer-list (delete buffer cns-buffer-list))))))

(defun cns-mode-enable nil
  "Enable `cns-mode'."
  (unless (process-live-p cns-process)
    (cns-start-process)
    (set-process-filter cns-process 'cns-segmentation-filter))
  (cns-handle-buffer-list 'enable))

(defun cns-mode-disable nil
  "Disable `cns-mode'."
  (cns-handle-buffer-list 'disable)
  (if (and (process-live-p cns-process) (= 0 (length cns-buffer-list)))
      (cns-stop-process)))

;;;###autoload
(define-minor-mode cns-mode
  "Toggle Chinese word segmentation mode in current buffer (Cns mode).
With prefix ARG, enable Chinese word segmentation mode if ARG is
positive; otherwise, disable it.  If called from Lisp, enable the
mode if ARG is omitted or nil.

This library simply processes Chinese word segmentation result
generated by a modified version of
cjieba (<https://github.com/yanyiwu/cjieba/>), if necessary.  See
the comments at the top of this library for further information.

This is an minor mode in current buffer.  To toggle the mode in
all buffers, use `global-cns-mode'.
"              ;; doc
  nil          ;; init-value
  nil          ;; lighter
  cns-mode-map ;; keymap
  (if cns-mode (cns-mode-enable) (cns-mode-disable)))

;;;###autoload
(define-globalized-minor-mode global-cns-mode cns-mode
  (lambda nil (cns-mode 1)))

(provide 'cns)
;;; cns.el ends here
;;; emacs-agent-compaction-test.el --- Pure compaction tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-agent-compaction)

(ert-deftest emacs-agent-compaction-config-boundaries ()
  (should (equal (emacs-agent-compaction-config)
                 '(:window 262144 :reserve 16384 :keep 20000 :automatic t)))
  (dolist (window '(1024 10000000))
    (let* ((config (list :window window :reserve 1 :keep (- window 2) :automatic nil))
           (copy (copy-tree config)))
      (should (equal (emacs-agent-compaction-config config) copy))
      (should (equal config copy))))
  (dolist (config '((:window 1023 :reserve 1 :keep 1)
                    (:window 10000001 :reserve 1 :keep 1)
                    (:window 1024 :reserve 0 :keep 1)
                    (:window 1024 :reserve 1 :keep 0)
                    (:window 1024 :reserve 1 :keep 1023)
                    (:window 1024 :reserve -1 :keep 1)
                    (:window 1024 :reserve 1.5 :keep 1)
                    (:window 1024 :reserve 1 :keep 1 :automatic yes)))
    (should-error (emacs-agent-compaction-config
                   (if (plist-member config :automatic) config
                     (append config '(:automatic t))))))
  (dolist (config '((:window 1024 :reserve 1 :keep 1)
                    (:window 1024 :reserve 1 :keep 1 :automatic t :extra 1)
                    (:window 1024 :reserve 1 :keep 1 :automatic t :keep 2)
                    (:window 1024 :reserve 1 :keep 1 :keep 2)
                    (:window 1024 :reserve 1 :keep 1 :automatic . t)))
    (should-error (emacs-agent-compaction-config config))))

(ert-deftest emacs-agent-compaction-estimate-unicode-and-anchor ()
  (let ((data '(:model "m" :messages [(:role "user" :content "世界世界")]
               :tools [] :usage (:total_tokens 999999) :temperature 100)))
    ;; Ten Unicode characters, not their UTF-8 byte lengths.
    (should (= (emacs-agent-compaction-estimate data) (+ 3 32)))
    (should (= (emacs-agent-compaction-estimate data '(:tokens 100 :estimate 35)) 100))
    (should (= (emacs-agent-compaction-estimate data '(:tokens 1 :estimate 1000)) 1))
    (should (= (emacs-agent-compaction-estimate data '(:tokens 0 :estimate 35)) 35))
    (should (= (emacs-agent-compaction-estimate data '(:tokens 1.0 :estimate 35)) 35))
    (should (= (emacs-agent-compaction-estimate
                '(:model "m" :messages [(:role "user" :content "abcd")] :tools []))
               (emacs-agent-compaction-estimate data)))))

(ert-deftest emacs-agent-compaction-estimate-tool-fields-once ()
  (let* ((data '(:messages
                [(:role "assistant" :content :null :reasoning "think"
                  :tool_calls [(:id "id" :type "function" :index 999
                                :function (:name "eval" :arguments "{}"))])
                 (:role "tool" :tool_call_id "id" :content "ok")]
                :tools [(:type "function" :function
                         (:name "eval" :description "desc" :parameters (:type "object")))]))
         (chars (+ 9 5 2 4 2 4 2 2 4 4 (length "{\"type\":\"object\"}"))))
    (should (= (emacs-agent-compaction-estimate data)
               (+ (/ (+ chars 3) 4) (* 16 4))))
    (should (> (emacs-agent-compaction-estimate data)
               (emacs-agent-compaction-estimate '(:messages [] :tools []))))))

(ert-deftest emacs-agent-compaction-json-native-sentinels-and-keys ()
  (let* ((value '(:one :false :two :json-false :empty :null
                  :json-false "key remains" :nested [(:additionalProperties :json-false)]))
         (original (copy-tree value t)))
    (should (equal (emacs-agent-compaction--text value)
                   "{\"one\":false,\"two\":false,\"empty\":null,\"json-false\":\"key remains\",\"nested\":[{\"additionalProperties\":false}]}"))
    (should (equal value original))))

(defun emacs-agent-compaction-test--records ()
  "Return a fresh canonical fixture."
  (copy-tree '((:role user :run-id "1" :text "goal" :context (:buffer "世界"))
               (:role tool :run-id "1" :id "id" :name "eval_elisp"
                :args (:expression "(+ 1 2)") :result "3"
                :protocol (:reasoning "calculate"))
               (:role assistant :run-id "1" :text "done")
               (:role user :run-id "2" :text "next")
               (:role assistant :run-id "2" :text "pending"))))

(ert-deftest emacs-agent-compaction-plan-zero-and-repeated ()
  (let* ((records (emacs-agent-compaction-test--records))
         (copy (copy-tree records))
         (previous '(:cut 2 :summary "Earlier goal and effects"))
         (plan (emacs-agent-compaction-plan records previous 0)))
    (should (= (plist-get plan :cut) 5))
    (should (equal (plist-get plan :records) (nthcdr 2 records)))
    (should (equal (plist-get plan :summary) (plist-get previous :summary)))
    (should (= (plist-get (emacs-agent-compaction-plan records nil 0) :cut) 5))
    (should (equal records copy))
    (should (equal previous '(:cut 2 :summary "Earlier goal and effects")))
    ;; Even returned records can be modified without changing the originals.
    (setf (plist-get (car (plist-get plan :records)) :text) "changed")
    (should (equal records copy))
    (should-error (emacs-agent-compaction-plan records '(:cut 5 :summary "all") 0))))

(ert-deftest emacs-agent-compaction-plan-reject-noops ()
  (dolist (keep '(0 100))
    (should-error (emacs-agent-compaction-plan nil nil keep)))
  (let ((records (emacs-agent-compaction-test--records)))
    (should-error (emacs-agent-compaction-plan records nil -1))
    (should-error (emacs-agent-compaction-plan records nil 100000))
    (should-error (emacs-agent-compaction-plan records '(:cut 3 :summary "old") 100000))
    ;; Boundary preference can consume an assistant fragment before the next user.
    (should (= (plist-get (emacs-agent-compaction-plan
                          records '(:cut 2 :summary "old") 100000) :cut) 3))
    (should-error (emacs-agent-compaction-plan records '(:cut 6 :summary "old") 0))
    (should-error (emacs-agent-compaction-plan records '(:cut 2 :summary " \n") 0))))

(ert-deftest emacs-agent-compaction-plan-user-boundary-and-atomic-pair ()
  (let* ((records (emacs-agent-compaction-test--records))
         (keep (apply #'+ (mapcar #'emacs-agent-compaction--record-cost (cdr records))))
         (plan (emacs-agent-compaction-plan records nil keep)))
    ;; Tentative tool boundary advances to the next user.
    (should (= (plist-get plan :cut) 3)))
  (let* ((records (cl-subseq (emacs-agent-compaction-test--records) 0 3))
         (keep (apply #'+ (mapcar #'emacs-agent-compaction--record-cost (cdr records))))
         (plan (emacs-agent-compaction-plan records nil keep)))
    ;; Without a later user, a paired tool is itself a safe retained boundary.
    (should (= (plist-get plan :cut) 1))
    (should (eq (plist-get (nth (plist-get plan :cut) records) :role) 'tool))
    (should (> (emacs-agent-compaction--record-cost (nth 1 records)) 48))))

(ert-deftest emacs-agent-compaction-clip-utf8 ()
  (should (equal (emacs-agent-compaction-clip "世界a" 7) "世界a"))
  (should (equal (emacs-agent-compaction-clip "世界a" 4) "世 [truncated 4 bytes]"))
  (should (equal (emacs-agent-compaction-clip "世" 0) " [truncated 3 bytes]"))
  (should-error (emacs-agent-compaction-clip "a" -1)))

(ert-deftest emacs-agent-compaction-transcript-protocol ()
  (let* ((messages [(:role "assistant" :reasoning "reason" :content "answer"
                    :tool_calls [(:id "id" :function (:name "eval_elisp" :arguments "{}"))])
                   (:role "tool" :tool_call_id "id" :content "result")])
         (copy (copy-tree messages t))
         (text (emacs-agent-compaction-transcript messages 262144)))
    (dolist (part '("[assistant]" "reason" "answer" "[tool call id eval_elisp] {}"
                    "[tool]" "[tool result id]" "result"))
      (should (string-match-p (regexp-quote part) text)))
    (should (equal messages copy))))

(ert-deftest emacs-agent-compaction-transcript-bounded-head-and-tail ()
  (let ((messages (append (list '(:role "user" :content "HEAD"))
                          (cl-loop repeat 100 collect
                                   (list :role "assistant" :content (make-string 3000 ?世)))
                          (list '(:role "assistant" :content "TAIL")))))
    (dolist (context '(1024 1025 3000 262144 10000000))
      (let* ((text (emacs-agent-compaction-transcript messages context))
             (bytes (encode-coding-string text 'utf-8-unix)))
        (should (<= (length bytes) (min (* 128 1024) (/ context 3))))
        (should (string-prefix-p "[user]\nHEAD\n" text))
        (should (string-suffix-p "TAIL\n" text))
        (should (string-match-p "Middle of transcript omitted" text))
        (should (equal text (decode-coding-string bytes 'utf-8-unix))))))
  (should-error (emacs-agent-compaction-transcript [] 1023)))

(ert-deftest emacs-agent-compaction-transcript-per-block-limit ()
  (let ((text (emacs-agent-compaction-transcript
               (list (list :role "user" :content (make-string 3000 ?x))) 262144)))
    (should (string-match-p "truncated 1000 bytes" text))
    (should (< (length text) 2100))))

;;; emacs-agent-compaction-test.el ends here

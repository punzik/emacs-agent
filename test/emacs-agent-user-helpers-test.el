;;; emacs-agent-user-helpers-test.el --- User helper metadata tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'bytecomp)
(require 'emacs-agent-user-helpers)
(require 'emacs-agent-resources)

(defmacro emacs-agent-user-helpers-test--isolated (&rest body)
  "Run BODY with an isolated registry and disposable interned functions.
The local `new-helper' function installs a definition and returns its symbol."
  (declare (indent 0) (debug t))
  `(let ((emacs-agent-user-helpers--registry (make-hash-table :test #'eq))
         (symbols nil))
     (unwind-protect
         (cl-labels ((new-helper (definition)
                       (let ((symbol (intern (make-temp-name "agent-helper-test-"))))
                         (push symbol symbols)
                         (fset symbol definition)
                         symbol)))
           ,@body)
       (dolist (symbol symbols)
         (fmakunbound symbol)
         (unintern symbol)))))

(ert-deftest emacs-agent-user-helpers-empty-and-registration-lifecycle ()
  (emacs-agent-user-helpers-test--isolated
    (let ((helper (new-helper '(lambda () nil))))
      (should (eq (hash-table-test emacs-agent-user-helpers--registry) 'eq))
      (should-not (emacs-agent-user-helpers--capture))
      (should-not (emacs-agent-unregister-helper helper))
      (should (eq (emacs-agent-register-helper helper :description "Read." :returns "Nil.")
                  helper))
      (should (stringp (gethash helper emacs-agent-user-helpers--registry)))
      (should (equal (emacs-agent-user-helpers--capture)
                     (format "User helpers (via eval_elisp):\n(%s)\n  Read.\n  Returns: Nil." helper)))
      (should (eq (emacs-agent-unregister-helper helper) t))
      (should-not (emacs-agent-unregister-helper helper))
      (should (fboundp helper))
      (should-not (emacs-agent-user-helpers--capture)))))

(ert-deftest emacs-agent-user-helpers-exact-optional-fields-and-whitespace ()
  (emacs-agent-user-helpers-test--isolated
    (let* ((helper (new-helper '(lambda (buffer &optional start &rest options) nil)))
           (description (propertize " \nRead\t buffer.\r\n " 'face 'bold))
           (returns (propertize " List\n of\titems. " 'face 'italic))
           (constraints (propertize " No\n saves. " 'face 'bold))
           (example (propertize "  (example \"a  b\"\n  :x 'literal)  " 'face 'bold))
           (prefix (format "(%s buffer &optional start &rest options)\n  Read buffer.\n  Returns: List of items."
                           helper)))
      (dolist (fields (list nil (list :constraints constraints) (list :example example)
                           (list :constraints constraints :example example)))
        (apply #'emacs-agent-register-helper helper
               :description description :returns returns fields)
        (let ((entry (gethash helper emacs-agent-user-helpers--registry)))
          (should (equal entry
                         (concat prefix
                                 (when (plist-member fields :constraints) "\n  Constraints: No saves.")
                                 (when (plist-member fields :example)
                                   "\n  Example: (example \"a  b\"\n  :x 'literal)"))))
          (should (equal-including-properties entry (substring-no-properties entry)))))
      ;; Caller-owned metadata must not remain shared with the registry.
      (aset description 2 ?X)
      (aset returns 1 ?X)
      (aset constraints 1 ?X)
      (aset example 2 ?X)
      (should (equal (gethash helper emacs-agent-user-helpers--registry)
                     (concat prefix "\n  Constraints: No saves.\n  Example: (example \"a  b\"\n  :x 'literal)"))))))

(ert-deftest emacs-agent-user-helpers-invalid-options-are-atomic ()
  (emacs-agent-user-helpers-test--isolated
    (let* ((helper (new-helper '(lambda () nil)))
           (valid '(:description "Original." :returns "Value.")))
      (apply #'emacs-agent-register-helper helper valid)
      (let ((entry (gethash helper emacs-agent-user-helpers--registry)))
        (dolist (options
                 (append
                  '(nil (:description "Only.") (:returns "Only.")
                    (:description "New." :returns "New." :unknown "Bad")
                    (:description "New." :returns "New." :allow-other-keys t)
                    (:description "New." :returns "New." :example)
                    (:description "New." :returns "New." "not-a-key" "Bad"))
                  (cl-loop for key in '(:description :returns :constraints :example)
                           append
                           (append
                            (cl-loop for value in '(nil "" " \t\r\n " 7 symbol)
                                     collect (append (cl-loop for (k v) on valid by #'cddr
                                                              unless (eq k key) append (list k v))
                                                     (list key value)))
                            (list (append valid (list key "One." key "Two.")))))))
          (should-error (apply #'emacs-agent-register-helper helper options))
          (should (eq entry (gethash helper emacs-agent-user-helpers--registry)))
          (should (= (hash-table-count emacs-agent-user-helpers--registry) 1)))))))

(ert-deftest emacs-agent-user-helpers-only-loaded-ordinary-interned-symbols ()
  (emacs-agent-user-helpers-test--isolated
    (let* ((ordinary (new-helper '(lambda () nil)))
           (unloaded (new-helper '(autoload "agent-helper-must-not-load" nil nil)))
           (alias (new-helper unloaded))
           (chain (new-helper alias))
           (macro-helper (new-helper '(macro lambda (&rest body) body)))
           (undefined (new-helper nil))
           (uninterned (make-symbol "agent-helper-uninterned"))
           (comp-enable-subr-trampolines nil))
      (unwind-protect
          (progn
            (fset uninterned '(lambda () nil))
            (cl-letf (((symbol-function 'load)
                       (lambda (&rest _) (ert-fail "Registration must not load code"))))
              (dolist (helper (list nil t :keyword "message" '(lambda () nil)
                                    uninterned undefined unloaded alias chain macro-helper 'if))
                (should-error (emacs-agent-register-helper helper :description "Read." :returns "Nil."))
                (should (= (hash-table-count emacs-agent-user-helpers--registry) 0))))
            (fset alias ordinary)
            (should (eq (emacs-agent-register-helper alias :description "Alias." :returns "Nil.") alias))
            (should (equal (gethash alias emacs-agent-user-helpers--registry)
                           (format "(%s)\n  Alias.\n  Returns: Nil." alias))))
        (fmakunbound uninterned)))))

(ert-deftest emacs-agent-user-helpers-never-execute-helper-or-example ()
  (emacs-agent-user-helpers-test--isolated
    (let* ((called nil)
           (helper (new-helper (lambda () (setq called t) (error "Executed helper"))))
           ;; Deliberately malformed Lisp is accepted as literal example data.
           (example "(setq called t)\n#.(error \"read-time execution\") ("))
      (emacs-agent-register-helper helper :description "Read." :returns "Nil." :example example)
      (should (string-suffix-p example (emacs-agent-user-helpers--capture)))
      (should-not called))))

(ert-deftest emacs-agent-user-helpers-real-cl-signatures-including-byte-code ()
  (emacs-agent-user-helpers-test--isolated
    (dolist (compiled '(nil t))
      (let ((helper (new-helper nil)))
        (eval `(cl-defun ,helper (buffer &optional start &key (limit 7) (mode 'brief))
                 "Secret full docstring, never included in the prompt."
                 (list buffer start limit mode)) t)
        (when compiled (fset helper (byte-compile (symbol-function helper))))
        (when compiled (should (byte-code-function-p (symbol-function helper))))
        (let* ((usage (help-split-fundoc (documentation helper t) helper 'usage))
               (comp-enable-subr-trampolines nil))
          (should (stringp usage))
          (should (string-match-p "&key" usage))
          (should (string-match-p "(limit 7)" usage))
          ;; Raw help usage may escape the quote as \\='brief.
          (should (string-match-p "(mode .*brief)" usage))
          (cl-letf (((symbol-function 'help-function-arglist)
                     (lambda (&rest _) (ert-fail "Declared usage must take priority"))))
            (emacs-agent-register-helper helper :description "Read." :returns "List."))
          (should (equal (gethash helper emacs-agent-user-helpers--registry)
                         (concat usage "\n  Read.\n  Returns: List.")))
          (should-not (string-match-p "Secret full docstring" (emacs-agent-user-helpers--capture))))))))

(ert-deftest emacs-agent-user-helpers-fallback-unknown-signature-and-redefinition ()
  (emacs-agent-user-helpers-test--isolated
    (let ((helper (new-helper '(lambda (buffer &optional start &rest options) nil))))
      (emacs-agent-register-helper helper :description "Read." :returns "Nil.")
      (let ((original (gethash helper emacs-agent-user-helpers--registry))
            (comp-enable-subr-trampolines nil))
        (fset helper '(lambda (changed) nil))
        (should (eq original (gethash helper emacs-agent-user-helpers--registry)))
        (cl-letf (((symbol-function 'help-function-arglist)
                   (lambda (function preserve-names)
                     (should (eq function (indirect-function helper)))
                     (should (eq preserve-names t))
                     t)))
          (let ((err (should-error (emacs-agent-register-helper helper :description "New." :returns "New."))))
            (should (string-match-p "wrapper" (error-message-string err))))
          (should (eq original (gethash helper emacs-agent-user-helpers--registry))))
        (emacs-agent-register-helper helper :description "New." :returns "New.")
        (should (equal (gethash helper emacs-agent-user-helpers--registry)
                       (format "(%s changed)\n  New.\n  Returns: New." helper)))
        (fmakunbound helper)
        (let ((updated (gethash helper emacs-agent-user-helpers--registry)))
          (should-error (emacs-agent-register-helper helper :description "Invalid." :returns "Invalid."))
          (should (eq updated (gethash helper emacs-agent-user-helpers--registry))))))))

(ert-deftest emacs-agent-user-helpers-sorted-fresh-independent-captures ()
  (emacs-agent-user-helpers-test--isolated
    (let* ((a (new-helper '(lambda () nil)))
           (b (new-helper '(lambda () nil)))
           (ordered (sort (list a b) (lambda (x y) (string-lessp (symbol-name x) (symbol-name y))))))
      (dolist (helper (reverse ordered))
        (emacs-agent-register-helper helper :description "Read." :returns "Nil."))
      (let* ((first (emacs-agent-user-helpers--capture))
             (second (emacs-agent-user-helpers--capture))
             (saved (copy-sequence second)))
        (should (equal first second))
        (should-not (eq first second))
        (should (equal second
                       (concat "User helpers (via eval_elisp):\n"
                               (mapconcat (lambda (helper) (gethash helper emacs-agent-user-helpers--registry))
                                          ordered "\n"))))
        (aset first 0 ?X)
        (should (equal second saved))
        (should (equal (emacs-agent-user-helpers--capture) saved))
        (emacs-agent-register-helper a :description "Changed." :returns "New.")
        (emacs-agent-unregister-helper b)
        (should (equal second saved))
        (should-not (equal (emacs-agent-user-helpers--capture) saved))
        (fmakunbound a)
        (cl-letf (((symbol-function 'emacs-agent-user-helpers--signature)
                   (lambda (&rest _) (ert-fail "Capture must not introspect"))))
          (should (stringp (emacs-agent-user-helpers--capture))))))))

(ert-deftest emacs-agent-user-helpers-resources-capture-independent-of-project-files ()
  (emacs-agent-user-helpers-test--isolated
    (let ((helper (new-helper '(lambda () nil)))
          (comp-enable-subr-trampolines nil))
      (emacs-agent-register-helper helper :description "Read." :returns "Nil.")
      (cl-letf (((symbol-function 'file-exists-p) (lambda (&rest _) (ert-fail "Unexpected file I/O")))
                ((symbol-function 'file-symlink-p) (lambda (&rest _) (ert-fail "Unexpected file I/O"))))
        (dolist (enabled '(nil t))
          (let* ((emacs-agent-project-instructions enabled)
                 (snapshot (emacs-agent-resources-capture (when (not enabled) "/unused/")))
                 (frozen (copy-sequence (plist-get snapshot :helpers))))
            (should (eq (plist-get snapshot :status) (if enabled 'no-project 'disabled)))
            (should (equal frozen (emacs-agent-user-helpers--capture)))
            (emacs-agent-register-helper helper :description "Changed." :returns "New.")
            (should (equal (emacs-agent-resources-system "BASE" snapshot) (concat "BASE\n\n" frozen)))
            (should (string-match-p "User helpers" (emacs-agent-resources-summary snapshot)))
            (emacs-agent-unregister-helper helper)
            (should (equal (plist-get snapshot :helpers) frozen))
            (should-not (plist-member (emacs-agent-resources-capture nil) :helpers))
            (emacs-agent-register-helper helper :description "Read." :returns "Nil.")))))))

(ert-deftest emacs-agent-user-helpers-resources-order-and-frozen-only-rendering ()
  (emacs-agent-user-helpers-test--isolated
    (let* ((root (make-temp-file "agent-helper-resources-" t))
           (emacs-agent-project-instructions t)
           (helper (new-helper '(lambda () nil))))
      (unwind-protect
          (progn
            (with-temp-file (expand-file-name "AGENTS.md" root) (insert "COMMON"))
            (with-temp-file (expand-file-name "EMACSAGENT.md" root) (insert "AGENT"))
            (emacs-agent-register-helper helper :description "Read." :returns "Nil.")
            (let* ((snapshot (emacs-agent-resources-capture root))
                   (helpers (plist-get snapshot :helpers))
                   (expected (concat "BASE\n\nProject instructions from "
                                     (format "%S" (expand-file-name "AGENTS.md" root)) ":\nCOMMON"
                                     "\n\nProject instructions from "
                                     (format "%S" (expand-file-name "EMACSAGENT.md" root)) ":\nAGENT"
                                     "\n\n" helpers)))
              (should-not (plist-member (plist-get snapshot :emacsagent) :helpers))
              (emacs-agent-unregister-helper helper)
              (cl-letf (((symbol-function 'emacs-agent-user-helpers--capture)
                         (lambda () (ert-fail "Rendering must use the frozen snapshot"))))
                (should (equal (emacs-agent-resources-system "BASE" snapshot) expected))
                (should (string-match-p "User helpers" (emacs-agent-resources-summary snapshot))))))
        (delete-directory root t)))))

(ert-deftest emacs-agent-user-helpers-never-evaluate-symbol-documentation ()
  (emacs-agent-user-helpers-test--isolated
    (let* ((helper (new-helper '(lambda (buffer) nil)))
           (alias (new-helper helper))
           (chain (new-helper alias)))
      (dolist (symbol (list helper alias chain))
        (put symbol 'function-documentation
             '(ert-fail "Registration evaluated a symbol documentation override")))
      ;; Neither direct registration, aliases nor arglist fallback may use
      ;; symbol documentation, which can contain executable Lisp.
      (dolist (symbol (list helper alias chain))
        (emacs-agent-register-helper symbol :description "Read." :returns "Nil.")
        (should (string-prefix-p (format "(%s buffer)" symbol)
                                 (gethash symbol emacs-agent-user-helpers--registry)))
        (should-error (emacs-agent-register-helper symbol :description nil :returns "Nil.")))
      (fmakunbound helper)
      (should-error (emacs-agent-register-helper alias :description "Read." :returns "Nil.")))))

(provide 'emacs-agent-user-helpers-test)
;;; emacs-agent-user-helpers-test.el ends here

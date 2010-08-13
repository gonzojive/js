(in-package :js)

(defun default-value (val &optional (hint :string))
  (block nil
    (unless (obj-p val) (return val))
    (when (vobj-p val) (return (vobj-value val)))
    (let ((first "toString") (second "valueOf"))
      (when (eq hint :number) (rotatef first second))
      (let ((method (lookup val first)))
        (when (obj-p method)
          (let ((res (jscall* method val)))
            (unless (obj-p res) (return res)))))
      (let ((method (lookup val second)))
        (when (obj-p method)
          (let ((res (jscall* method val)))
            (unless (obj-p res) (return res)))))
      (js-error :type-error "Can't convert object to ~a." (symbol-name hint)))))

(deftype js-number ()
  (if *float-traps*
      '(or number (member :Inf :-Inf :NaN))
      'number))

;; TODO these might be much faster as methods (profile)
(defun to-string (val)
  (etypecase val
    (string val)
    (js-number (cond ((is-nan val) "NaN")
                     ((eq val (infinity)) "Infinity")
                     ((eq val (-infinity)) "-Infinity")
                     ((integerp val) (princ-to-string val))
                     (t (format nil "~,,,,,,'eE" val))))
    (boolean (if val "true" "false"))
    (symbol (ecase val (:undefined "undefined") (:null "null")))
    (obj (to-string (default-value val)))))

(defun to-number (val)
  (etypecase val
    (js-number val)
    (string (cond ((string= val "Infinity") (infinity))
                  ((string= val "-Infinity") (-infinity))
                  (t (or (read-js-number val) (nan)))))
    (boolean (if val 1 0))
    (symbol (ecase val (:undefined (nan)) (:null 0)))
    (obj (to-number (default-value val :number)))))

(defun to-integer (val)
  (etypecase val
    (integer val)
    (js-number (cond ((is-nan val) 0)
                     ((eq val (infinity)) most-positive-fixnum)
                     ((eq val (-infinity)) most-negative-fixnum)
                     (t (floor val))))
    (string (let ((read (read-js-number val)))
              (etypecase read (null 0) (integer read) (number (floor read)))))
    (boolean (if val 1 0))
    (symbol 0)
    (obj (to-integer (default-value val :number)))))

(defun to-integer32 (val)
  "The operator ToInt32 converts its argument to one of 232 integer values in the range −2 31 through 2 31−1,
inclusive. This operator functions as follows:

1. Call ToNumber on the input argument.

2. If Result(1) is NaN, +0, −0, +∞, or −∞, return +0.

3. Compute sign(Result(1)) * floor(abs(Result(1))).

4. Compute Result(3) modulo 2^32; that is, a finite integer value k of
Number type with positive sign and less than 2^32 in magnitude such
the mathematical difference of Result(3) and k is mathematically an
integer multiple of 2^32.

5. If Result(4) is greater than or equal to 2^31, return Result(4)−
2^32, otherwise return Result(4).
"
  (let ((num (to-number val)))
    (if (or (eql num (nan))
            (= 0 num)
            (eql (infinity) val)
            (eql (-infinity) val))
        0
        (let* ((int (* (if (> num 0) 1 -1)
                       (floor (abs num))))
               (int32-pos (mod int (expt 2 32))))
          (if (>= int32-pos (expt 2 31))
              (- int32-pos (expt 2 32))
              int32-pos)))))
          
        
(defun to-boolean (val)
  (etypecase val
    (boolean val)
    (number (not (or (is-nan val) (zerop val))))
    (string (not (string= val "")))
    (symbol (case val (:Inf t) (:-Inf t) (t nil)))
    (obj t))) ;; TODO check standard

(defun fvector (&rest elements)
  (let ((len (length elements)))
    (make-array len :fill-pointer len :initial-contents elements :adjustable t)))
(defun empty-fvector (len)
  (make-array len :fill-pointer len :initial-element :undefined :adjustable t))
(defun build-array (vector)
  (make-aobj (find-cls :array) vector))

(defun build-func (lambda)
  (make-fobj (find-cls :function) lambda nil))

(defun lexical-eval (str scope)
  (let* ((str (to-string str))
         (parsed (parse/err str))
         (*scope* (list scope))
         (env-obj (car (captured-scope-objs scope)))
         (captured-locals (captured-scope-local-vars scope))
         (new-locals (and (not (eq captured-locals :null))
                          (set-difference (mapcar '->usersym (find-locals (second parsed)))
                                          captured-locals))))
    (declare (special *scope*))
    (dolist (local new-locals) (setf (lookup env-obj (symbol-name local)) :undefined))
    (compile-eval (translate-ast parsed))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Ensures safe and predictable redefinitions
  (defun update-set (set name val)
    (let ((prev nil))
      (loop :for cons :on set :do
         (when (equal (caar cons) name)
           (setf (cdar cons) val)
           (return set))
         (setf prev cons)
         :finally (let ((cell (list (cons name val))))
                    (if prev
                        (progn (setf (cdr prev) cell) (return set))
                        (return cell))))))
  (defun slot-flags (props)
    (let ((base (if (member :enum props) 0 +slot-noenum+)))
      (dolist (prop props)
        (case prop (:active (setf base (logior base +slot-active+)))
                   (:ro (setf base (logior base +slot-ro+)))
                   (:nodel (setf base (logior base +slot-nodel+)))))
      base)))

(defun make-js-error (type message &rest args)
  (let ((err (make-obj (or (find-cls type) (error "Bad JS-error type: ~a" type)))))
    (cached-set err "message" (if args (apply #'format nil message args) message))
    err))
(defun js-error (type message &rest args)
  (error 'js-condition :value (apply #'make-js-error type message args)))

;; List of name->func pairs, where func initializes the value.
(defvar *stdenv-props* ())
(defun addstdprop (name value)
  (setf *stdenv-props* (update-set *stdenv-props* name value)))

(defmacro defobj (proto &body props)
  `(obj-from-props ,proto (list ,@props)))
;; Mostly there to help emacs indent definition bodies
(defmacro mth (name args &body body)
  (multiple-value-bind (name flags)
      (if (consp name) (values (car name) (slot-flags (cdr name))) (values name +slot-noenum+))
    `(list* ,name (build-func ,(wrap-js-lambda args body)) ,flags)))
(defmacro pr (name value &rest flags) `(list* ,name ,value ,(slot-flags flags)))

(defparameter *std-prototypes* ())
(defmacro stdproto ((id parent) &body props)
  `(setf *std-prototypes* (update-set *std-prototypes* ,id (lambda () (list ,parent ,@props)))))

(defun init-env ()
  ;; Check whether proto definitions and offset vector are in sync
  (assert (equal (coerce *proto-offsets* 'list) (mapcar #'car *std-prototypes*)))
  (let* ((bootstrap (make-array (length *std-prototypes*) :initial-contents
                                (loop :repeat (length *proto-offsets*) :collect (make-obj nil nil))))
         (objproto (svref bootstrap (proto-offset :object)))
         (clss (make-array (length *common-classes*) :initial-contents
                           (loop :for id :across *common-classes* :collect
                              (let ((off (proto-offset id)))
                                (make-scls () (if off (svref bootstrap off) objproto))))))
         (*env* (make-gobj (make-hcls objproto) (make-hash-table :test 'eq) bootstrap clss)))
    (loop :for shell :across bootstrap :for (nil . create) :in *std-prototypes* :do
       (destructuring-bind (proto-id . props) (funcall create)
         (obj-from-props (and proto-id (find-proto proto-id)) props
                         (lambda (cls vals) (setf (obj-vals shell) vals (obj-cls shell) cls)))))
    (loop :for (name . func) :in *stdenv-props* :do
       (setf (lookup *env* name) (funcall func)))
    *env*))

(defmacro stdprop (name value)
  `(addstdprop ,name (lambda () ,value)))
(defmacro stdfunc (name args &body body)
  `(addstdprop ,name (lambda () (build-func ,(wrap-js-lambda args body)))))

(addstdprop "this" (lambda () *env*))
(stdprop "undefined" :undefined)
(stdprop "Infinity" (infinity))
(stdprop "NaN" (nan))

(stdfunc "print" (val)
  (format t "~a~%" (to-string val)))
(stdfunc "parseInt" (val (radix 10))
  (or (parse-integer (to-string val) :junk-allowed t :radix (to-integer radix))
      (nan)))
(stdfunc "parseFloat" (val)
  (let ((val (to-string val)))
    (cond ((string= val "Infinity") (infinity))
          ((string= val "-Infinity") (-infinity))
          (t (or (read-js-number val) (nan))))))
(stdfunc "isNaN" (val)
  (is-nan (to-number val)))
(stdfunc "eval" (str)
  (compile-eval (translate (parse/err (to-string str)))))

;; TODO URI encoding/decoding functions

(defun ensure-proto (spec)
  (cond ((keywordp spec) (find-proto spec))
        ((eq (car spec) :clone)
         (obj-from-props (find-proto (second spec)) (list (pr "constructor" nil))))
        (t (obj-from-props (find-proto :object) (cons (pr "constructor" nil) spec)))))

(defun build-constructor (self proto props constr)
  (obj-from-props (find-proto :function)
                  (cons (pr "prototype" proto) props)
                  (lambda (cls vals)
                    (setf (fobj-cls self) cls (fobj-vals self) vals (fobj-proc self) constr)))
  (setf (lookup proto "constructor") self)
  self)

;; TODO prevent bogus this objects from being created for many of these
(defmacro stdconstructor (name args &body body/rest)
  (destructuring-bind (body proto &rest props) body/rest
    `(addstdprop ,name (lambda ()
                         (let ((-self- (make-fobj nil nil nil nil)))
                           (build-constructor
                            -self-
                            (ensure-proto ,(if (keywordp proto) proto `(list ,@proto)))
                            (list ,@props)
                            ,(wrap-js-lambda args (list body))))))))

(defmacro stdobject (name &body props)
  `(addstdprop ,name (lambda ()
                       (obj-from-props (find-proto :object) (list ,@props)))))

(stdconstructor "Object" (&rest args)
  (if args
      (make-vobj (ensure-fobj-cls -self-) (car args))
      this)
  :object)

(stdproto (:object nil)
  (mth "toString" () "[object Object]")
  (mth "toLocaleString" () (jsmethod this "toString"))
  (mth "valueOf" () this)

  (mth "hasOwnProperty" (prop) (and (obj-p this) (find-slot this (to-string prop)) t))
  (mth "propertyIsEnumerable" (prop) (and (obj-p this) (let ((slot (find-slot this (to-string prop))))
                                                         (and slot (not (logtest (cdr slot) +slot-noenum+)))))))

(stdconstructor "Function" (&rest args)
  (let ((body (format nil "(function (~{~a~^, ~}) {~A});"
                      (butlast args) (car (last args)))))
    (compile-eval (translate (parse/err body))))
  :function)

(defun vec-apply (func this vec)
  (macrolet ((vapply (n)
               `(case (length vec)
                  ,@(loop :for i :below n :collect
                       `(,i (funcall func this ,@(loop :for j :below i :collect `(aref vec ,j)))))
                  (t (apply func this (coerce vec 'list))))))
    (vapply 7)))

(stdproto (:function :object)
  (pr "prototype" (cons (js-lambda () (setf (lookup this "prototype") (simple-obj)))
                        (js-lambda (val) (ensure-slot this "prototype" val +slot-noenum+))) :active)

  (mth "apply" (self args)
    (typecase args
      (aobj (vec-apply (proc this) self (aobj-arr args)))
      (argobj (apply (proc this) self (argobj-list args)))
      (t (js-error :type-error "Second argument to Function.prototype.apply must be an array."))))
  (mth "call" (self &rest args)
    (apply (proc this) self args)))

(stdconstructor "Array" (&rest args)
  (let* ((len (length args))
         (arr (if (and (= len 1) (integerp (car args)))
                  (empty-fvector (car args))
                  (make-array len :initial-contents args :fill-pointer len :adjustable t))))
    (make-aobj (ensure-fobj-cls -self-) arr))
  :array)

(defmacro unless-array (default &body body)
  `(if (aobj-p this) (progn ,@body) ,default))

(stdproto (:array :object)
  (pr "length" (cons (js-lambda () (if (aobj-p this) (length (aobj-arr this)) 0)) nil) :active)

  (mth "toString" ()
    (jsmethod this "join"))

  (mth "concat" (&rest others)
    (let* ((elements (loop :for elt :in (cons this others) :collect
                        (if (aobj-p elt) (aobj-arr elt) (vector elt))))
           (size (reduce #'+ elements :key #'length))
           (arr (empty-fvector size))
           (pos 0))
      (dolist (elt elements)
        (loop :for val :across elt :do
           (setf (aref arr pos) val)
           (incf pos)))
      (build-array arr)))
  (mth "join" ((sep ","))
    (unless-array ""
      (let ((sep (to-string sep)))
        (with-output-to-string (out)
          (loop :for val :across (aobj-arr this) :for first := t :then nil :do
             (unless first (write-string sep out))
             (write-string (to-string val) out))))))

  (mth "splice" (index howmany &rest elems)
    (unless-array (build-array (fvector))
      (let* ((vec (aobj-arr this))
             (index (clip-index (to-integer index) (length vec)))
             (removed (clip-index (to-integer howmany) (- (length vec) index)))
             (added (length elems))
             (diff (- added removed))
             (new-len (- (+ (length vec) added) removed))
             (result (empty-fvector removed)))
        (replace result vec :start2 index :end2 (+ index removed))
        (cond ((< diff 0) ;; shrink
               (replace vec vec :start1 (+ index added) :start2 (+ index removed))
               (setf (fill-pointer vec) new-len))
              ((> diff 0) ;; grow
               (adjust-array vec new-len :fill-pointer new-len)
               (replace vec vec :start1 (+ index added) :start2 (+ index removed))))
        (replace vec elems :start1 index)
        (build-array result))))

  (mth "pop" ()
    (unless-array :undefined
      (let ((vec (aobj-arr this)))
        (if (= (length vec) 0)
            :undefined
            (vector-pop vec)))))
  (mth "push" (val)
    (unless-array 0
      (let ((vec (aobj-arr this)))
        (vector-push-extend val vec)
        (length vec))))

  (mth "shift" ()
    (unless-array :undefined
      (let* ((vec (aobj-arr this)) (len (length vec)))
        (if (> len 0)
            (let ((result (aref vec 0)))
              (replace vec vec :start2 1)
              (setf (fill-pointer vec) (1- len))
              result)
            :undefined))))
  (mth "unshift" (val)
    (unless-array 0
      (let ((vec (aobj-arr this)))
        (setf (fill-pointer vec) (1+ (length vec)))
        (replace vec vec :start1 1)
        (setf (aref vec 0) val)
        (length vec))))

  (mth "reverse" ()
    (unless-array (build-array (fvector this))
      (setf (aobj-arr this) (nreverse (aobj-arr this)))
      this))
  (mth "sort" (compare)
    (unless-array (build-array (fvector this))
      (let ((func (if (eq compare :undefined)
                      (lambda (a b) (string< (to-string a) (to-string b))) ;; TODO less wasteful
                      (let ((proc (proc compare)))
                        (lambda (a b) (funcall proc *env* a b))))))
        (sort (aobj-arr this) func)
        this))))

(stdproto (:arguments :object)
  (pr "length" (cons (js-lambda () (argobj-length this)) nil) :active)
  (pr "callee" (cons (js-lambda () (argobj-callee this)) nil) :active))

(stdconstructor "String" (value)
  (if (eq this *env*)
      (to-string value)
      (make-vobj (ensure-fobj-cls -self-) (to-string value)))
  :string
  (mth "fromCharCode" (code)
    (string (code-char (to-integer code)))))

(defun clip-index (index len)
  (setf index (to-integer index))
  (cond ((< index 0) 0)
        ((> index len) len)
        (t index)))

(defun careful-substr (str from to)
  (let* ((len (length str))
         (from (clip-index from len)))
    (if (eq to :undefined)
        (subseq str from)
        (subseq str from (max from (clip-index to len))))))

(defun really-string (val)
  (if (stringp val) val (and (vobj-p val) (stringp (vobj-value val)) (vobj-value val))))

(defun string-replace (me pattern replacement)
  (let* ((parts ()) (pos 0) (me (to-string me))
         (replace
          (if (fobj-p replacement)
              (lambda (start end gstart gend)
                (push (to-string (apply (fobj-proc replacement) *env* (subseq me start end)
                                        (loop :for gs :across gstart :for ge :across gend :for i :from 1
                                           :collect (if start (subseq me gs ge) :undefined)
                                           :when (eql i (length gstart)) :append (list start me))))
                      parts))
              (let ((repl-str (to-string replacement)))
                (if (ppcre:scan "\\\\\\d" repl-str)
                    (let ((tmpl (ppcre:split "\\\\(\\d)" repl-str :with-registers-p t)))
                      (loop :for cons :on (cdr tmpl) :by #'cddr :do
                         (setf (car cons) (1- (parse-integer (car cons)))))
                      (lambda (start end gstart gend)
                        (declare (ignore start end))
                        (loop :for piece :in tmpl :do
                           (if (stringp piece)
                               (when (> (length piece) 0) (push piece parts))
                               (let ((start (aref gstart piece)))
                                 (when start (push (subseq me start (aref gend piece)) parts)))))))
                    (lambda (start end gstart gend)
                      (declare (ignore start end gstart gend))
                      (push repl-str parts)))))))
    (flet ((replace-occurrence (start end gstart gend)
             (unless (eql start pos)
               (push (subseq me pos start) parts))
             (funcall replace start end gstart gend)
             (setf pos end)))
      (cond ((not (reobj-p pattern))
             (let ((pattern (to-string pattern))
                   (index (search (to-string pattern) me)))
               (when index (replace-occurrence index (+ index (length pattern)) #.#() #.#()))))
            ((not (reobj-global pattern))
             (multiple-value-bind (start end gstart gend) (regexp-exec pattern me t)
               (unless (eq start :null) (replace-occurrence start end gstart gend))))
            (t (cached-set pattern "lastIndex" 0)
               (loop
                  (multiple-value-bind (start end gstart gend) (regexp-exec pattern me t)
                    (when (eq start :null) (return))
                    (when (eql start end) (cached-set pattern "lastIndex" (1+ start)))
                    (replace-occurrence start end gstart gend)))))
      (if (or parts (> pos 0))
          (progn (when (< pos (length me))
                   (push (subseq me pos) parts))
                 (apply #'concatenate 'string (nreverse parts)))
          me))))

(stdproto (:string :object)
  (pr "length" (cons (js-lambda () (let ((str (really-string this))) (if str (length str) 0))) nil) :active)

  (mth "toString" () (or (really-string this) (js-error :type-error "Incompatible type.")))
  (mth "valueOf" () (or (really-string this) (js-error :type-error "Incompatible type.")))

  (mth "charAt" (index)
    (let ((str (to-string this)) (idx (to-integer index)))
      (if (< -1 idx (length str)) (string (char str idx)) "")))
  (mth "charCodeAt" (index)
    (let ((str (to-string this)) (idx (to-integer index)))
      (if (< -1 idx (length str)) (char-code (char str idx)) (nan))))

  (mth "indexOf" (substr (start 0))
    (or (search (to-string substr) (to-string this) :start2 (to-integer start)) -1))
  (mth "lastIndexOf" (substr start)
    (let* ((str (to-string this))
           (start (if (eq start :undefined) (length str) (to-integer start))))
      (or (search (to-string substr) str :from-end t :end2 start))))

  (mth "substring" ((from 0) to)
    (careful-substr (to-string this) from to))
  (mth "substr" ((from 0) len)
    (careful-substr (to-string this) from
                    (if (eq len :undefined) len (+ (to-integer from) (to-integer len)))))
  (mth "slice" ((from 0) to)
    (let* ((from (to-integer from)) (str (to-string this))
           (to (if (eq to :undefined) (length str) (to-integer to))))
      (when (< from 0) (setf from (+ (length str) from)))
      (when (< to 0) (setf to (+ (length str) to)))
      (careful-substr str from to)))

  (mth "toUpperCase" ()
    (string-upcase (to-string this)))
  (mth "toLowerCase" ()
    (string-downcase (to-string this)))
  (mth "toLocaleUpperCase" ()
    (string-upcase (to-string this)))
  (mth "toLocaleLowerCase" ()
    (string-downcase (to-string this)))

  (mth "split" (delim)
    (let ((str (to-string this)))
      (build-array
       (if (reobj-p delim)
           (coerce (ppcre:split (reobj-scanner delim) str :sharedp t) 'simple-vector)
           (let ((delim (to-string delim)))
             (if (equal delim "")
                 (fvector str)
                 (coerce (loop :with step := (length delim) :for beg := 0 :then (+ pos step)
                            :for pos := (search delim str :start2 beg)
                            :collect (subseq str beg pos) :while pos) 'simple-vector)))))))

  (mth "concat" (&rest values) ;; TODO 'The length property of the concat method is 1', whatever sense that makes
    (apply #'concatenate 'string (cons (to-string this) (mapcar 'to-string values))))

  (mth "localeCompare" (that)
    (let ((a (to-string this)) (b (to-string that)))
      (cond ((string< a b) -1)
            ((string> a b) 1)
            (t 0))))

  (mth "match" (regexp)
    (unless (reobj-p regexp) (setf regexp (new-regexp regexp :undefined)))
    (let ((str (to-string this)))
      (if (reobj-global regexp)
          (let ((matches ()))
            (cached-set regexp "lastIndex" 0)
            (loop
               (multiple-value-bind (start end) (regexp-exec regexp str t)
                 (when (eq start :null) (return))
                 (when (eql start end) (cached-set regexp "lastIndex" (1+ start)))
                 (push (subseq str start end) matches)))
            (build-array (apply 'fvector (nreverse matches))))
          (regexp-exec regexp str))))

  (mth "replace" (pattern replacement)
    (string-replace this pattern replacement))
  (mth "search" (pattern)
    (unless (reobj-p pattern) (setf pattern (new-regexp (to-string pattern) :undefined)))
    (values (regexp-exec pattern (to-string this) t t))))

(declare-primitive-prototype string :string)

(stdconstructor "Number" (value)
  (if (eq this *env*)
      (to-number value)
      (make-vobj (ensure-fobj-cls -self-) (to-number value)))
  :number
  (pr "MAX_VALUE" most-positive-double-float)
  (pr "MIN_VALUE" most-negative-double-float)
  (pr "POSITIVE_INFINITY" (infinity))
  (pr "NEGATIVE_INFINITY" (-infinity)))

(defun typed-value-of (obj type)
  (if (and (vobj-p obj) (typep (vobj-value obj) type))
      (vobj-value obj)
      (js-error :type-error "Incompatible type.")))

(stdproto (:number :object)
  (mth "toString" ((radix 10))
    (let ((num (typed-value-of this 'js-number)))
      (if (= radix 10)
          (to-string num)
          (let ((*print-radix* (to-integer radix))) (princ-to-string (floor num))))))
  (mth "valueOf" () (typed-value-of this 'js-number)))

(declare-primitive-prototype number :number)

(stdconstructor "Boolean" (value)
  (if (eq this *env*)
      (to-boolean value)
      (make-vobj (ensure-fobj-cls -self-) (to-boolean value)))
  :boolean)

(stdproto (:boolean :object)
  (mth "toString" () (if (typed-value-of this 'boolean) "true" "false"))
  (mth "valueOf" () (typed-value-of this 'boolean)))

(declare-primitive-prototype (eql t) :boolean)
(declare-primitive-prototype (eql nil) :boolean)

(defun new-regexp (pattern flags)
  (init-reobj (make-reobj (find-cls :regexp) nil nil nil) pattern flags))
(defun init-reobj (obj pattern flags)
  (let* ((flags (if (eq flags :undefined) "" (to-string flags)))
         (pattern (to-string pattern))
         (multiline (and (position #\m flags) t))
         (ignore-case (and (position #\i flags) t))
         (global (and (position #\g flags) t))
         (scanner (handler-case (ppcre:create-scanner pattern :case-insensitive-mode ignore-case
                                                      :multi-line-mode multiline)
                    (ppcre:ppcre-syntax-error (e)
                      (js-error :syntax-error (princ-to-string e))))))
    (unless (every (lambda (ch) (position ch "igm")) flags)
      (js-error :syntax-error "Invalid regular expression flags: ~a" flags))
    (setf (reobj-proc obj) (js-lambda (str) (regexp-exec obj str))
          (reobj-scanner obj) scanner
          (reobj-global obj) global)
    (cached-set obj "global" global)
    (cached-set obj "ignoreCase" ignore-case)
    (cached-set obj "multiline" multiline)
    (cached-set obj "source" pattern)
    (cached-set obj "lastIndex" 0)
    obj))

(defun regexp-exec (re str &optional raw no-global)
  (let ((start 0) (str (to-string str)) (global (and (not no-global) (reobj-global re))))
    (when global
      (setf start (cached-lookup re "lastIndex"))
      (when (> -1 start (length str))
        (cached-set re "lastIndex" 0)
        (return-from regexp-exec :null)))
    (multiple-value-bind (mstart mend gstart gend)
        (ppcre:scan (reobj-scanner re) (to-string str) :start start)
      (when global
        (cached-set re "lastIndex" (if mend mend (1+ start))))
      (cond ((not mstart) :null)
            (raw (values mstart mend gstart gend))
            (t (let ((result (empty-fvector (1+ (length gstart)))))
                 (setf (aref result 0) (subseq str mstart mend))
                 (loop :for st :across gstart :for end :across gend :for i :from 1 :do
                    (when st (setf (aref result i) (subseq str st end))))
                 (build-array result)))))))

(defun regexp-args (re)
  (values (cached-lookup re "source")
          (format nil "~:[~;i~]~:[~;g~]~:[~;m~]" (cached-lookup re "ignoreCase")
                  (cached-lookup re "global") (cached-lookup re "multiline"))))

(stdconstructor "RegExp" (pattern flags)
  (if (and (eq flags :undefined) (reobj-p pattern))
      (if (eq this *env*)
          pattern
          (multiple-value-bind (source flags) (regexp-args pattern)
            (new-regexp source flags)))
      (new-regexp pattern flags))
  :regexp
  (pr "length" 2)) ;; Because the standard says so

(stdproto (:regexp :object)
  (mth "toString" ()
    (if (reobj-p this)
        (multiple-value-bind (source flags) (regexp-args this)
          (format nil "/~a/~a" source flags))
        (to-string this)))

  (mth "exec" (str)
    (if (reobj-p this) (regexp-exec this str) nil))
  (mth "compile" (expr flags)
    (when (reobj-p this) (init-reobj this expr flags))
    this)
  (mth "test" (str)
    (if (reobj-p this)
        (not (eq (regexp-exec this (to-string str) t) :null))
        nil)))

(stdconstructor "Error" (message)
  (if (eq this *env*)
      (js-new -self- message)
      (unless (eq message :undefined)
        (cached-set this "message" message)))
  :error)

(stdproto (:error :object)
  (pr "name" "Error" :enum)
  (pr "message" "Error" :enum)
  (mth "toString" ()
    (concatenate 'string "Error: " (to-string (cached-lookup this "message")))))

(macrolet ((deferror (name id)
             `(progn (stdconstructor ,name (message)
                       (if (eq this *env*)
                           (js-new -self- message)
                           (unless (eq message :undefined)
                             (cached-set this "message" message)))
                       ,id)
                     (stdproto (,id :error)
                       (mth "toString" ()
                         (concatenate 'string ,(format nil "~a: " name)
                                      (to-string (cached-lookup this "message"))))))))
  (deferror "SyntaxError" :syntax-error)
  (deferror "ReferenceError" :reference-error)
  (deferror "TypeError" :type-error)
  (deferror "URIError" :uri-error)
  (deferror "EvalError" :eval-error)
  (deferror "RangeError" :range-error))

(defmacro with-overflow (&body body)
  `(handler-case (progn ,@body)
     (floating-point-overflow () (infinity)) ;; TODO -infinity?
     (floating-point-underflow () 0d0)))

(defmacro math-case (var &body cases)
  (flet ((find-case (id)
           (or (cdr (assoc id cases)) '((nan)))))
    `(let ((,var (to-number ,var)))
       (with-overflow
         (cond ((is-nan ,var) ,@(find-case :NaN))
               ((eq ,var (infinity)) ,@(find-case :Inf))
               ((eq ,var (-infinity)) ,@(find-case :-Inf))
               (t ,@(find-case t)))))))

(defun my-atan (arg)
  (math-case arg (:-Inf (- (/ pi 2))) (:Inf (/ pi 2)) (t (atan arg))))

(defmacro compare-num (a b gt lt cmp)
  `(let ((ls ,a) (rs ,b))
     (cond ((or (is-nan ls) (is-nan rs)) (nan))
           ((or (eq ls ,gt) (eq rs ,gt)) ,gt)
           ((eq ls ,lt) rs)
           ((eq rs ,lt) ls)
           (t (,cmp ls rs)))))

(stdobject "Math"
  (mth "toString" () "[object Math]")

  (pr "E" (exp 1))
  (pr "LN2" (log 2))
  (pr "LN10" (log 10))
  (pr "LOG2E" (log (exp 1) 2))
  (pr "LOG10E" (log (exp 1) 10))
  (pr "SQRT1_2" (sqrt .5))
  (pr "SQRT1_2" (sqrt 2))
  (pr "PI" pi)

  (mth "abs" (arg)
    (math-case arg (:-Inf (infinity)) (:Inf (infinity)) (t (abs arg))))

  (mth "cos" (arg)
    (math-case arg (t (cos arg))))
  (mth "sin" (arg)
    (math-case arg (t (sin arg))))
  (mth "tan" (arg)
    (math-case arg (t (tan arg))))

  (mth "acos" (arg)
    (math-case arg (t (let ((res (acos arg))) (if (realp res) res (nan))))))
  (mth "asin" (arg)
    (math-case arg (t (let ((res (asin arg))) (if (realp res) res (nan))))))
  (mth "atan" (arg)
    (my-atan arg))
  (mth "atan2" (x y)
    (my-atan (js/ x y)))

  (mth "ceil" (arg)
    (math-case arg (:-Inf (-infinity)) (:Inf (infinity)) (t (ceiling arg))))
  (mth "floor" (arg)
    (math-case arg (:-Inf (-infinity)) (:Inf (infinity)) (t (floor arg))))
  (mth "round" (arg)
    (math-case arg (:-Inf (-infinity)) (:Inf (infinity)) (t (round arg))))

  (mth "exp" (arg)
    (math-case arg (:-Inf 0) (:Inf (infinity)) (t (exp arg))))
  (mth "log" (arg)
    (math-case arg
      (:Inf (infinity))
      (t (cond ((zerop arg) (-infinity))
               ((minusp arg) (nan))
               (t (log arg))))))
  (mth "sqrt" (arg)
    (math-case arg (:Inf (infinity))
               (t (let ((res (sqrt arg))) (if (realp res) res (nan))))))
  (mth "pow" (base exp)
    (let ((base (to-number base)) (exp (to-number exp)))
      (cond ((or (is-nan base) (is-nan exp)) (nan))
            ((eq exp (-infinity)) (nan))
            ((and (realp exp) (zerop exp)) 1)
            ((or (eq base (infinity)) (eq exp (infinity))) (infinity))
            ((eq base (-infinity)) (-infinity))
            (t (coerce (with-overflow (expt base exp)) 'double-float)))))

  (mth "max" (&rest args)
    (let ((cur (-infinity)))
      (dolist (arg args)
        (setf cur (compare-num cur (to-number arg) (infinity) (-infinity) max)))
      cur))
  (mth "min" (&rest args)
    (let ((cur (infinity)))
      (dolist (arg args)
        (setf cur (compare-num cur (to-number arg) (-infinity) (infinity) min)))
      cur))

  (mth "random" ()
    (random 1.0)))

(defun reset ()
  (setf *env* (init-env)))
(reset)

(defmacro with-js-env (&body body)
  `(let ((*env* (init-env))) ,@body))

(defun tests ()
  (with-js-env
    (js-load-file (asdf:system-relative-pathname :js "test.js"))))

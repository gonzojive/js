(in-package :js)

(defparameter *label-name* nil)

(defun traverse-form (form)
  (cond ((null form) nil)
	((atom form)
	 (if (keywordp form)
	     (js-intern form) form))
	(t
	 (case (car form)
	   ((:var)
	      (cons (js-intern (car form))
		    (list (mapcar
			   (lambda (var-desc)
			     (let ((var-sym (->sym (car var-desc))))
			       (set-add env var-sym)
			       (set-add locals var-sym)
			       (cons (->sym (car var-desc))
				     (traverse-form (cdr var-desc)))))
			   (second form)))))
	   ((:label)
	      (let ((*label-name* (->sym (second form))))
		(format t "label: ~A~%" *label-name*)
		(traverse-form (third form))))
	   ((:for)
	      (format t "for: ~A~%" *label-name*)
	      (let* ((label *label-name*)
		     (*label-name* nil))
		(list (js-intern (car form)) ;for
		      (traverse-form (second form)) ;init
		      (traverse-form (third form))  ;cond
		      (traverse-form (fourth form)) ;step
		      (traverse-form (fifth form)) ;body
		      label)))
	   ((:while) (traverse-form
		      (list (js-intern :for)
			    nil (second form)
			    nil (third form) *label-name*)))
	   ((:do)
	      (format t "do: ~A~%" *label-name*)
	      (let* ((label *label-name*)
		     (*label-name* nil))
		(list (js-intern (car form))
		      (traverse-form (second form))
		      (traverse-form (third form))
		      label)))
;;;todo: think about removing interning from :dot and :name to macro expander (see :label)
	   ((:name) (list (js-intern (car form)) (->sym (second form))))
	   ((:dot) (list (js-intern (car form)) (traverse-form (second form))
			 (->sym (third form))))
	   ((:function :defun)
	      (when (and (eq (car form) :defun)
			 (second form))
		(let ((fun-name (->sym (second form))))
		  (set-add env fun-name)
		  (set-add locals fun-name)))
	      (let ((placeholder (list (car form))))
		(queue-enqueue lmbd-forms (list form env placeholder))
		placeholder))
	   (t (mapcar #'traverse-form form))))))

(defun shallow-process-toplevel-form (form)
  (let ((env (set-make))
	(locals (set-make)))
    (declare (special env locals))
    (traverse-form form)))

(defun lift-defuns (form)
  (let (defuns oth)
    (loop for el in form do
      (if (eq (car el) :defun) (push el defuns)
	  (push el oth)))
    ;(format t ">>>>>>>>>>>defuns: ~A ~A~%" (reverse defuns) (reverse oth))
    (append (reverse defuns) (reverse oth))))

(defun shallow-process-function-form (form old-env)
  (let* ((env (set-copy old-env))
	 (locals (set-make))
	 (arglist (mapcar #'->sym (third form)))
	 (new-form (traverse-form (fourth form)))
	 (name (and (second form) (->sym (second form)))))
    (declare (special env locals))
    (format t "envs fo ~A: old: ~A new: ~A~%" name (set-elems old-env) (set-elems env))
    (mapc (lambda (arg) (set-add env arg)) arglist)
    (list (js-intern (first form)) ;;defun or function
	  (set-elems (set-add env name)) ;;inject function name (if any)
                                         ;;into local lexical environment
	  name arglist (set-elems locals) (lift-defuns new-form))))

(defun process-ast (ast)
  (assert (eq :toplevel (car ast)))
  (let ((lmbd-forms (queue-make)))
    (declare (special lmbd-forms))
    (let ((toplevel (shallow-process-toplevel-form ast)))
      (loop until (queue-empty? lmbd-forms)
	    for (form env position) = (queue-dequeue lmbd-forms) do
	      (let ((funct-form (shallow-process-function-form form env)))
		(setf (car position) (car funct-form)
		      (cdr position) (cdr funct-form))))
      toplevel)))

(defpackage :capstone/clos
  (:use :gt :cffi :static-vectors :capstone)
  (:export :version
           ;; CAPSTONE-ENGINE class and accessors
           :capstone-engine
           :architecture
           :mode
           ;; CAPSTONE-INSTRUCTION class and accessors
           :capstone-instruction
           :id
           :address
           :bytes
           :mnemonic
           :operands
           :disasm))
(in-package :capstone/clos)
(in-readtable :curry-compose-reader-macros)
#+debug (declaim (optimize (debug 3)))

(defun version ()
  "Return the CAPSTONE version as two values MAJOR and MINOR."
  (let* ((encoded-version (cs-version 0 0))
         (major (ash encoded-version -8)))
    (values major (- encoded-version (ash major 8)))))

(defclass capstone-engine ()
  ((architecture :initarg :architecture :reader architecture :type keyword
                 :initform (required-argument :architecture))
   (mode :initarg :mode :reader mode :type keyword
         :initform (required-argument :mode))
   (handle)))

(defmethod initialize-instance :after ((engine capstone-engine) &key)
  (with-slots (architecture mode handle) engine
    (setf handle (foreign-alloc 'cs-handle))
    (assert (eql :ok (cs-open architecture mode handle))
            (architecture mode)
            "Capstone Engine initialization with `cs-open' failed with ~S."
            (cs-strerror (cs-errno handle))))
  #+sbcl (sb-impl::finalize engine
                            (lambda ()
                              (with-slots (handle) engine
                                (cs-close handle)))))

(defmethod print-object ((obj capstone-engine) stream)
  (print-unreadable-object (obj stream :type t :identity t)
    (format stream "~a ~a" (architecture obj) (mode obj))))

(defclass capstone-instruction ()
  ((id :initarg :id :reader id :type integer)
   (address :initarg :address :reader address :type unsigned-integer)
   (size :initarg :size :reader size :type fixnum)
   (bytes :initarg :bytes :reader bytes :type '(simple-array (unsigned-byte 8)))
   (mnemonic :initarg :mnemonic :reader mnemonic :type :keyword)
   (operands :initarg :operands :reader operands :type list)))

(defmethod print-object ((obj capstone-instruction) stream)
  (print-unreadable-object (obj stream :type t)
    (write (cons (mnemonic obj) (operands obj)) :stream stream)))

;;; Taken from a patch by _death.
(defun parse-capstone-operand (string &aux p)
  (cond ((starts-with-subseq "0x" string)
         (parse-integer string :radix 16 :start 2))
        ((starts-with-subseq "[" string)
         (list :deref (parse-capstone-operand (subseq string 1 (1- (length string))))))
        ((starts-with-subseq "byte ptr " string)
         (list :byte (parse-capstone-operand (subseq string 9))))
        ((starts-with-subseq "word ptr " string)
         (list :word (parse-capstone-operand (subseq string 9))))
        ((starts-with-subseq "dword ptr " string)
         (list :dword (parse-capstone-operand (subseq string 10))))
        ((starts-with-subseq "qword ptr " string)
         (list :qword (parse-capstone-operand (subseq string 10))))
        ((starts-with-subseq "tbyte ptr " string)
         (list :tbyte (parse-capstone-operand (subseq string 10))))
        ((starts-with-subseq "cs:" string)
         (list (list :seg :cs) (parse-capstone-operand (subseq string 3))))
        ((starts-with-subseq "ds:" string)
         (list (list :seg :ds) (parse-capstone-operand (subseq string 3))))
        ((starts-with-subseq "es:" string)
         (list (list :seg :es) (parse-capstone-operand (subseq string 3))))
        ((starts-with-subseq "fs:" string)
         (list (list :seg :fs) (parse-capstone-operand (subseq string 3))))
        ((starts-with-subseq "gs:" string)
         (list (list :seg :gs) (parse-capstone-operand (subseq string 3))))
        ((setq p (search " + " string))
         (list :+
               (parse-capstone-operand (subseq string 0 p))
               (parse-capstone-operand (subseq string (+ p 3)))))
        ((setq p (search " - " string))
         (list :-
               (parse-capstone-operand (subseq string 0 p))
               (parse-capstone-operand (subseq string (+ p 3)))))
        ((setq p (search "*" string))
         (list :*
               (parse-capstone-operand (subseq string 0 p))
               (parse-capstone-operand (subseq string (1+ p)))))
        ((every #'digit-char-p string)
         (parse-integer string))
        (t
         (make-keyword (string-upcase string)))))

;;; Adapted from a patch by _death.
(defun parse-capstone-operands (operands)
  (if (equal operands "")
      nil
      (mapcar (lambda (s) (parse-capstone-operand (trim-whitespace s)))
              (split-sequence #\, operands))))

(defgeneric disasm (engine bytes &key address count)
  (:documentation
   "Disassemble BYTES with ENGINE using starting address ADDRESS.
Optional argument COUNT may be supplied to limit the number of
instructions disassembled.")
  (:method ((engine capstone-engine) (bytes vector)
            &key (address 0) (count 0 count-p))
    (when count-p
      (check-type count integer)
      (when (zerop count) (return-from disasm)))
    (setf bytes (make-array (length bytes)
                            :element-type '(unsigned-byte 8)
                            :initial-contents bytes))
    (nest
     (with-slots (handle) engine)
     (with-static-vector (code (length bytes)
                               :element-type '(unsigned-byte 8)
                               :initial-contents bytes))
     (with-foreign-object (instr** '(:pointer (:pointer (:struct cs-insn)))))
     (let ((count (cs-disasm (mem-ref handle 'cs-handle)
                             (static-vector-pointer code)
                             (length bytes) address 0 instr**)))
       (assert (and (numberp count) (> count 0)) (code handle)
               "Disassembly failed with ~S." (cs-strerror (cs-errno handle))))
     (let ((result (make-array count))))
     (flet ((bytes (p)
              (let ((r (make-array 16 :element-type '(unsigned-byte 8))))
                (dotimes (n 16 r)
                  (setf (aref r n) (mem-aref p :uint8 n)))))))
     (dotimes (n count result))
     (let ((insn (inc-pointer (mem-ref instr** :pointer)
                              (* n (foreign-type-size
                                    '(:struct cs-insn)))))))
     (setf (aref result n))
     (make-instance 'capstone-instruction
       :id (foreign-slot-value insn '(:struct cs-insn) 'id)
       :address (foreign-slot-value insn '(:struct cs-insn) 'address)
       :size (foreign-slot-value insn '(:struct cs-insn) 'insn-size)
       :bytes (bytes (foreign-slot-value insn '(:struct cs-insn) 'bytes))
       :mnemonic (nest (make-keyword)
                       (string-upcase)
                       (foreign-string-to-lisp)
                       (foreign-slot-value insn '(:struct cs-insn) 'mnemonic))
       :operands (nest (parse-capstone-operands)
                       (foreign-string-to-lisp)
                       (foreign-slot-value insn '(:struct cs-insn) 'op-str))))))
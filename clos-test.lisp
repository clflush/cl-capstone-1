(defpackage :capstone/clos-test
  (:use :gt :cffi :capstone :capstone/clos :stefil)
  (:export :test))
(in-package :capstone/clos-test)
(in-readtable :curry-compose-reader-macros)

(defsuite test)
(in-suite test)

(deftest version-returns-two-numbers ()
  (is (multiple-value-call [{every #'numberp} #'list] (version))))

(deftest simple-disasm ()
  (let ((engine (make-instance 'capstone-engine :architecture :x86 :mode :64)))
    (is (every «and [{eql :NOP} #'mnemonic] {typep _ 'capstone-instruction}»
               (disasm engine #(#x90 #x90))))
    (nest (is)
          (equalp '((:PUSH :RBP)
                    (:MOV :RAX (:QWORD (:DEREF (:+ :RIP 5048))))))
          (map 'list «cons #'mnemonic #'operands»
               (disasm engine #(#x55 #x48 #x8b #x05 #xb8 #x13 #x00 #x00))))))
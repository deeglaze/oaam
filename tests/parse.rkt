#lang racket
(require rackunit)
(require "../code/ast.rkt"
         "../code/parse.rkt")

(define (exp=/lab e0 e1)
  (match* (e0 e1)
    [((var _ x) (var _ x)) #t]
    [((num _ n) (num _ n)) #t]     
    [((bln _ b) (bln _ b)) #t]     
    [((lrc _ xs es e)
      (lrc _ xs fs f))
     (and (exp=/lab e f)
          (andmap exp=/lab es fs))]
    [((lam _ x e) (lam _ x f))
     (exp=/lab e f)]
    [((app _ e es)
      (app _ f fs))
     (and (exp=/lab e f)
          (andmap exp=/lab es fs))]
    ;rec -- should go away
    [((ife _ e0 e1 e2)
      (ife _ f0 f1 f2))
     (and (exp=/lab e0 f0)
          (exp=/lab e1 f1)
          (exp=/lab e2 f2))]
    [((1op _ o e) (1op _ o f))
     (exp=/lab e f)]
    [((2op _ o e0 e1) (2op _ o f0 f1))
     (and (exp=/lab e0 f0)
          (exp=/lab e1 f1))]
    [((st! _ x e) (st! _ x f))
     (exp=/lab e f)]      
    [(_ _) #f]))
       

(check exp=/lab (parse '5) (num '_ '5))
(check exp=/lab (parse 'x) (var '_ 'x))
(check exp=/lab (parse '(let () 5)) (num '_ 5))
(check exp=/lab (parse '(let* () x)) (var '_ 'x))
(check exp=/lab (parse '(lambda (x) x)) (lam '_ '(x) (var '_ 'x)))
(check exp=/lab (parse '(f x)) (app '_ (var '_ 'f) (list (var '_ 'x))))
(check exp=/lab (parse '(set! x 1)) (st! '_ 'x (num '_ 1)))

(check exp=/lab
       (parse '(let ((x 1) (y 2)) x))
       (parse '((lambda (x y) x) 1 2)))

;; Can't write this test because of the stupid fresh name thing.
#;
(check exp=/lab
       (parse '(let () 1 2))
       (parse '(begin 1 2)))

(check exp=/lab
       (parse-prog
        '[(define (fact n)
            (if (zero? n)
                1
                (* n (fact (sub1 n)))))
          (fact 5)])              
       (parse 
        '(letrec ((fact (lambda (n)
                          (if (zero? n)
                              1
                              (* n (fact (sub1 n)))))))
           (fact 5))))

;; parse really shouln't pick fresh names
#;
(check exp=/lab
       (parse-prog '[1 2])
       (parse '(begin 1 2)))

#lang racket
(provide aval^)
(require "ast.rkt"
	 "data.rkt")

;; 0CFA in the AAM style on some hairy Church numeral churning

;; + compilation phase
;; + lazy non-determinism
;; + specialized step & iterator 0m34.248s vs 0m16.339s
;; + compute store ∆s 0m16.339s vs 0m1.065s (!!!)

;; State  = (cons Conf Store)
;; State^ = (cons (Set Conf) Store)

;; Comp = Store Env Cont -> State^

;; A Cont is one of:
;; - 'mt
;; - (ar Comp Env Cont)
;; - (fn Val Cont)
;; - (ifk Comp Comp Env Cont)
;; - (1opk Opr Cont)
;; - (2opak Opr Comp Env Cont)
;; - (2opfk Opr Val Cont)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; "Compiled" Machine

;; Compile away interpretive overhead of "ev" states

;; Expr -> Comp
(define (compile e)
  (match e
    [(var l x)
     (λ (∆ ρ k)
       (cons ∆ (set (co^ k (addr (lookup-env ρ x))))))]
    [(num l n)   (λ (∆ ρ k) (cons ∆ (set (co^ k n))))]
    [(bln l b)   (λ (∆ ρ k) (cons ∆ (set (co^ k b))))]
    [(lam l x e)
     (define c (compile e))
     (λ (∆ ρ k) (cons ∆ (set (co^ k (clos l x c ρ)))))]
    [(rec f (lam l x e))
     (define c (compile e))
     (λ (∆ ρ k) (cons ∆ (set (co^ k (rlos l f x c ρ)))))]
    [(app l e0 e1)
     (define c0 (compile e0))
     (define c1 (compile e1))
     (λ (∆ ρ k)
       (define-values (∆* a) (push∆ ∆ l ρ k))
       (c0 ∆* ρ (ar c1 ρ a)))]
    [(ife l e0 e1 e2)
     (define c0 (compile e0))
     (define c1 (compile e1))
     (define c2 (compile e2))
     (λ (∆ ρ k)
       (define-values (∆* a) (push∆ ∆ l ρ k))
       (c0 ∆* ρ (ifk c1 c2 ρ a)))]
    [(1op l o e)
     (define c (compile e))
     (λ (∆ ρ k)
       (define-values (∆* a) (push∆ ∆ l ρ k))
       (c ∆* ρ (1opk o a)))]
    [(2op l o e0 e1)
     (define c0 (compile e0))
     (define c1 (compile e1))
     (λ (∆ ρ k)
       (define-values (∆* a) (push∆ ∆ l ρ k))
       (c0 ∆* ρ (2opak o c1 ρ a)))]))

;; Store (Addr + Val) -> Set Val
(define (get-val σ v)
  (match v
    [(addr loc) (hash-ref σ loc (λ () (error "~a ~a" loc σ)))]
    [_ (set v)]))


;; "Bytecode" interpreter
;; State -> State^
;; State -> (cons [Listof (cons Addr (Setof Storable))] (Setof Conf))
(define (step-compiled^ s)
  (match s
    [(cons σ (co^ k v))
     (match k
       ['mt (cons '()
                  (for*/set ((v (get-val σ v)))
                            (ans^ v)))]
       [(ar c ρ l) (c '() ρ (fn v l))]
       [(fn f l)
        (cons '()
              (for*/set ([k (get-cont σ l)]
                         [f (get-val σ f)])
                        (ap^ f v k)))]
       [(ifk c a ρ l)
        (define res^
          (for*/set ([k (get-cont σ l)]
                     [v (get-val σ v)])
                    ((if v c a) '() ρ k)))

        (define-values (∆* cs*)
          (for/fold ([∆ '()] [cs (set)])
            ([s res^])
            (match s
              [(cons ∆* cs*)
               (values (append ∆* ∆)
                       (set-union cs* cs))])))
        (cons ∆* cs*)]

       [(1opk o l)
        (cons '()
              (for*/set ([k (get-cont σ l)]
                         [v (get-val σ v)])
                        (ap-op^ o (list v) k)))]
       [(2opak o c ρ l)
        (c '() ρ (2opfk o v l))]
       [(2opfk o u l)
        (cons '()
              (for*/set ([k (get-cont σ l)]
                         [v (get-val σ v)]
                         [u (get-val σ u)])
                        (ap-op^ o (list v u) k)))])]

    [(cons σ (ap^ fun a k))
     (match fun
       [(clos l x c ρ)
        (define-values (ρ* ∆*) (bind s))
        (c ∆* ρ* k)]
       [(rlos l f x c ρ)
        (define-values (ρ* ∆*) (bind s))
        (c ∆* ρ* k)]
       ;; Anything else is stuck
       [_ (cons '() (set))])]

    [(cons σ (ap-op^ o vs k))
     (match* (o vs)
       [('zero? (list (? number? n))) (cons '() (set (co^ k (zero? n))))]
       [('sub1 (list (? number? n)))  (cons '() (set (co^ k (widen (sub1 n)))))]
       [('add1 (list (? number? n)))  (cons '() (set (co^ k (widen (add1 n)))))]
       [('not (list #t)) (cons '() (set (co σ k #f)))]
       [('not (list #f)) (cons '() (set (co σ k #t)))]
       [('zero? (list 'number))
        (cons '() (set (co^ k #t)
                       (co^ k #f)))]
       [('sub1 (list 'number)) (cons '() (set (co^ k 'number)))]
       [('* (list (? number? n) (? number? m)))
        (cons '() (set (co^ k (widen (* m n)))))]
       [('* (list (? number? n) 'number))
        (cons '() (set (co^ k 'number)))]
       [('* (list 'number 'number))
        (cons '() (set (co^ k 'number)))]
       ;; Anything else is stuck
       [(_ _) (cons '() (set))])]

    [(cons σ c)
     (cons '() (set))]))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 0CFA-style Abstract semantics
(define (widen b)
  (cond [(number? b) 'number]
        [else (error "Unknown base value" b)]))

(define (bind s)
  (match s
    [(cons σ (ap^ (clos l x e ρ) v k))
     (values (extend ρ x x)
             (list (cons x (get-val σ v))))]
    [(cons σ (ap^ (rlos l f x e ρ) v k))
     (values (extend (extend ρ x x) f f)
             (list (cons f (set (rlos l f x e ρ)))
                   (cons x (get-val σ v))))]))

(define (push∆ ∆ l ρ k)
  (values (cons (cons l (set k)) ∆)
          l))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Exp -> Set Val
;; 0CFA with store widening and specialized iteration
(define (aval^ e)
  (define fst (inj e))
  (define snd (wide-step-specialized fst))
  ;; wide-step-specialized is monotonic so we only need to check the current
  ;; state against it's predecessor to see if we have reached a fixpoint.
  (let loop ((next snd) (prev fst))
    (if (equal? next prev)
        (for/set ([c (cdr prev)]
                  #:when (ans^? c))
                 (ans^-v c))
        (loop (wide-step-specialized next) next))))

;; Exp -> Set State
(define (inj e)
  (match ((compile e) '() (hash) 'mt)
    [(cons ∆ cs)
     (cons (update ∆ (hash)) cs)]))

(define (update ∆ σ)
  (match ∆
    ['() σ]
    [(cons (cons a xs) ∆)
     (update ∆ (join σ a xs))]))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Widening State to State^

;; State^ -> State^
;; Specialized from wide-step : State^ -> { State^ } ≈ State^ -> State^
(define (wide-step-specialized state)
  (match state
    [(cons σ cs)
     (define-values (cs* ∆)
       (for/fold ([cs* (set)] [∆* '()])
         ([c cs])
         (match (step-compiled^ (cons σ c))
           [(cons ∆** cs**)
            (values (set-union cs* cs**) (append ∆** ∆*))])))
     (cons (update ∆ σ) (set-union cs cs*))]))

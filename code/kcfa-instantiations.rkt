#lang racket
(require (rename-in racket/generator [yield real-yield]))
(require "kcfa.rkt" "data.rkt" "parse.rkt" "notation.rkt"
         "primitives.rkt" "fix.rkt" "env.rkt" "do.rkt" "add-lib.rkt"
         (for-syntax syntax/parse
                     syntax/srcloc)
         racket/stxparam
         racket/splicing)

;; Utility function for combining multiple σ-∆s
(define (map2-append f acc ls0 ls1)
  (let loop ([ls0 ls0] [ls1 ls1])
    (match* (ls0 ls1)
      [((cons h0 t0) (cons h1 t1))
       (cons (f h0 h1) (loop t0 t1))]
      [('() '()) acc]
      [(_ _)
       (error 'map2-append "Expected same length lists. Finished at ~a ~a"
              ls0 ls1)])))

(define-for-syntax do-body-transform-σ/cs
  (syntax-rules () [(_ e) (let-values ([(σ* cs) e])
                            (values σ* (∪ target-cs cs)))]))
(define-for-syntax do-body-transform-cs
  (syntax-rules () [(_ e) (let ([cs e]) (∪ target-cs cs))]))

(define-for-syntax (bind-rest inner-σ body)
  #`(syntax-parameterize ([target-σ (make-rename-transformer #'#,inner-σ)])
      #,body))
(define-simple-macro* (bind-join-whole (σjoin sσ a vs) body)
  (let ([σjoin (join sσ a vs)]) #,(bind-rest #'σjoin #'body)))
(define-simple-macro* (bind-join*-whole (σjoin* sσ as vss) body)
  (let ([σjoin* (join* sσ as vss)]) #,(bind-rest #'σjoin* #'body)))
(define-simple-macro* (bind-join-∆s (∆s* ∆s a vs) body)
  (let ([∆s* (cons (cons a vs) ∆s)]) #,(bind-rest #'∆s* #'body)))
(define-simple-macro* (bind-join*-∆s (∆s* ∆s as vss) body)
  (let ([∆s* (map2-append cons ∆s as vss)]) #,(bind-rest #'∆s* #'body)))

(define-for-syntax ((mk-bind-rest K) stx)
  (syntax-parse stx
    [(_ (ρ* σ* δ*) (ρ iσ l δ xs r v-addrs) body)
     (define (bind-args wrap as r-meaning)
       (wrap
        (quasisyntax/loc stx
          (let-syntax ([add-r (syntax-rules ()
                                [(_ (νσ νρ sσ sρ sr sδ* vrest) body*)
                                 #,r-meaning])])
            (define-values (xs-vs vrest)
              (let loop ([xs* xs] [vs v-addrs] [xs-acc '()])
                (cond [(null? xs*)
                       (values (reverse xs-acc) vs)]
                      [else
                       (loop (cdr xs*) (cdr vs)
                             (cons (getter iσ (car vs)) xs-acc))])))
            (add-r (σ* ρ* iσ ρ* r δ* vrest)
             (bind-join* (σ* σ* #,as xs-vs) body))))))
     ;; Abstractly, rest-arg is an infinite list.
     (define abs-r
       #`(let*-values
             ([(ra) sr]
              [(rA) (make-var-contour `(A . ,sr) sδ*)]
              [(rvs rAs)
               (if (null? vrest)
                   (values snull ∅)
                   (values (∪1 snull (consv rA ra))
                           (for/union ([a (in-list vrest)])
                             (getter sσ a))))]
              #,@(if (zero? K) #'() #'([(νρ) (extend sρ r rA)])))
           (bind-join (νσ sσ ra rvs)
                      (bind-join (νσ νσ rA rAs) body*))))
     ;; Concretely, rest-arg is a finite list.
     (define conc-r
       #'(let*-values ([(ra) (cons sr sδ*)]
                       [(ras rvs)
                        (let loop ([as vrest] [last ra] [rras '()] [rrvs '()] [count 0])
                          (match as
                            ['() (values (cons last (reverse rras))
                                         (cons snull (reverse rrvs)))]
                            [(cons a as)
                             (define rnextA `((,sr A . ,count) . ,sδ*))
                             (define rnextD `((,sr D . ,count) . ,sδ*))
                             (loop as rnextD
                                   (list* rnextA last rras)
                                   (list* (getter sσ a) (set (consv rnextA rnextD)) rrvs)
                                   (add1 count))]))]
                       [(νρ) (extend sρ r ra)])
           (bind-join* (νσ sσ ras rvs) body*)))
     (cond [(zero? K)
            (bind-args values #'xs abs-r)]
           [(< K +inf.0)
            (bind-args (λ (body)
                          #`(let* ([δ* (truncate (cons l δ) #,K)]
                                   [as (map (λ (x) (cons x δ*)) xs)]
                                   [ρ* (extend* ρ xs as)])
                              #,body))
                       #'as abs-r)]
           [else
            (bind-args (λ (body) #`(let* ([δ* (cons l δ)]
                                          [as (map (λ (x) (cons x δ*)) xs)]
                                          [ρ* (extend* ρ xs as)])
                                     #,body))
                       #'as conc-r)])]))

(define-for-syntax ((mk-bind K) stx)
  (syntax-parse stx
    [(_ (ρ* σ* δ*) (ρ bσ l δ xs v-addrs) body)
     (define vs
       (quasisyntax/loc stx
         (map (λ (v) (getter bσ v)) v-addrs)))
     (if (zero? K)
         (quasisyntax/loc stx
           (bind-join* (σ* bσ xs #,vs) body))
         (quasisyntax/loc stx
           (let* ([δ* (truncate (cons l δ) #,K)]
                  [as (map (λ (x) (cons x δ*)) xs)]
                  [ρ* (extend* ρ xs as)])
             (bind-join* (σ* bσ as #,vs) body))))]))
(define-syntax-rule (make-var-contour-0 x δ) x)
(define-syntax-rule (make-var-contour-k x δ) (cons x δ))

(define-syntax bind-0 (mk-bind 0))
(define-syntax bind-1 (mk-bind 1))
(define-syntax bind-∞ (mk-bind +inf.0))
(define-syntax bind-rest-0 (mk-bind-rest 0))
(define-syntax bind-rest-1 (mk-bind-rest 1))
(define-syntax bind-rest-∞ (mk-bind-rest +inf.0))

(define-syntax-rule (mk-fix name ans? ans-v)
  (define (name step fst)
    (define ss (fix step fst))
    (for/set ([s ss] #:when (ans? s)) (ans-v s))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Widen set-monad fixpoint
(define-syntax-rule (wide-step step)
  (λ (state)
     (match state
       [(cons wsσ cs)
        (define-values (σ* cs*)
          (for/fold ([σ* wsσ] [cs ∅]) ([c (in-set cs)])
            (define-values (σ** cs*) (step (cons wsσ c)))
            (values (join-store σ* σ**) (∪ cs* cs))))
        (set (cons σ* cs*))]
       [_ (error 'wide-step "bad output ~a~%" state)])))

(define-syntax-rule (mk-set-fixpoint^ fix name ans^?)
 (define-syntax-rule (name step fst)
   (let ()
     (define-values (f^σ cs) fst)
     (define s (fix (wide-step step) (set (cons f^σ cs))))
     (for/fold ([last-σ (hash)] [final-cs ∅]) ([s s])
       (match s
         [(cons fsσ cs)
          (define-values (σ* cs*)
            (values (join-store last-σ fsσ)
                    (for/set #:initial final-cs ([c (in-set cs)]
                                                 #:when (ans^? c))
                             c)))
          (values σ* cs*)]
         [_ (error 'name "bad output ~a~%" s)])))))

(define-syntax-rule (pull gen ∆-base cs-base)
  (let*-values ([(cs ∆)
                 (for/fold ([cs cs-base] [last #f])
                     ([c (in-producer gen (λ (x) (eq? 'done x)))])
                   (cond [(list? c) (values cs (if last (append c last) c))]
                         [else (values (set-add cs c) last)]))]
                [(∆*) (if (list? ∆) (append ∆ ∆-base) ∆-base)])
    (values cs ∆*)))

(define-syntax-rule (σ-∆s/generator/wide-step-specialized step ans?)
  (λ (state)
     (match state
       [(cons gσ cs)
        (define-values (cs* ∆)
          (for/fold ([cs* ∅] [∆* '()])
              ([c cs] #:unless (ans? c))
            (pull (step (cons gσ c)) ∆* cs*)))
        (cons (update ∆ gσ) (set-union cs cs*))])))

(define-syntax-rule (mk-generator/wide/σ-∆s-fixpoint name ans?)
  (define-syntax-rule (name step fst)
    (let ()
      (define wide-step (σ-∆s/generator/wide-step-specialized step ans?))
      (define-values (cs ∆) (pull fst '() ∅))
      (define fst-s (cons (update ∆ (hash)) cs))
      (define snd (wide-step fst-s))
      (let loop ((next snd) (prev fst-s))
        (cond [(equal? next prev)
               (for/set ([c (cdr prev)]
                         #:when (ans? c))
                 c)]
              [else (loop (wide-step next) next)])))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Wide fixpoint for σ-∆s

(define-syntax-rule (mk-∆-fix^ name ans^?)
  (define-syntax-rule (name stepper fst)
    (let-values ([(∆ cs) fst])
     (define seen (make-hash))
     (define todo (set (cons (update ∆ (hash)) cs)))
     (let loop ()
       (cond [(∅? todo) (for/set ([(c δσ) (in-hash seen)]
                                  #:when (ans^? c))
                          (cons δσ c))]
             [else (define old-todo todo)
                   (set! todo ∅)
                   (for* ([σ×cs (in-set old-todo)]
                          [σp (in-value (car σ×cs))]
                          [c (in-set (cdr σ×cs))]
                          [last-σ (in-value (hash-ref seen c (hash)))]
                          #:unless (equal? last-σ σp))
                     ;; This state's store monotonically increases
                     (hash-set! seen c (join-store σp last-σ))
                     ;; Add the updated store with next steps to workset
                     (define-values (∆ cs*) (stepper (cons σp c)))
                     (set! todo (∪1 todo (cons (update ∆ σp) cs*))))
                   (loop)])))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Mutable pre-allocated store / mutable worklist
(define global-σ #f)
(define todo #f)
(define unions 0)
(define seen #f)
(define next-loc #f)
(define contour-table #f)

(define (ensure-σ-size)
  (when (= next-loc (vector-length global-σ))
    (set! global-σ
          (for/vector #:length (* 2 next-loc) #:fill ∅ ;; ∅ → '()
                      ([v (in-vector global-σ)]
                       [i (in-naturals)]
                       #:when (< i next-loc))
                      v))))

(define-syntax-rule (get-contour-index!-0 c)
  (or (hash-ref contour-table c #f)
      (begin0 next-loc
              (ensure-σ-size)
              (hash-set! contour-table c next-loc)
              (set! next-loc (add1 next-loc)))))

(define-for-syntax yield!
  (syntax-parser [(_ e) #'(let ([c e])
                            (unless (= unions (hash-ref seen c -1))
                              (hash-set! seen c unions)
                              (set! todo (∪1 todo c))))])) ;; ∪1 → cons

(define-syntax-rule (make-var-contour-0-prealloc x δ)
  (cond [(exact-nonnegative-integer? x) x]
        [else (get-contour-index!-0 x)]))

(define (prepare-prealloc parser sexp)
  (define nlabels 0)
  (define (fresh-label!) (begin0 nlabels (set! nlabels (add1 nlabels))))
  (define (fresh-variable! x) (begin0 nlabels (set! nlabels (add1 nlabels))))
  (define-values (e renaming) (parser sexp fresh-label! fresh-variable!))
  (define e* (add-lib e renaming fresh-label! fresh-variable!))
  ;; Start with a constant factor larger store since we are likely to
  ;; allocate some composite data. This way we don't incur a reallocation
  ;; right up front.
  (set! global-σ (make-vector (* 2 nlabels) ∅)) ;; ∅ → '()
  (set! next-loc nlabels)
  (set! contour-table (make-hash))
  (set! unions 0)
  (set! todo ∅)
  (set! seen (make-hash))
  e*)

(define (join! a vs)
  (define prev (vector-ref global-σ a))
  (define added? (not (subset? vs prev)))
  (when added?
    (vector-set! global-σ a (∪ vs prev))
    (set! unions (add1 unions))))

(define (join*! as vss)
  (for ([a (in-list as)]
        [vs (in-list vss)])
    (join! a vs)))

(define-syntax-rule (bind-join! (σ* j!σ a vs) body)
  (begin (join! a vs) body))
(define-syntax-rule (bind-join*! (σ* j*!σ as vss) body)
  (begin (join*! as vss) body))

(define-syntax-rule (global-vector-getter σ* a)
  (vector-ref global-σ a))

(define-syntax-rule (mk-prealloc^-fixpoint name ans^? ans^-v touches)
  (define (name step fst)
    (define clean-σ (restrict-to-reachable/vector touches))
    (let loop ()
      (cond [(∅? todo) ;; → null?
             (define vs
               (for*/set ([(c at-unions) (in-hash seen)]
                          #:when (ans^? c))
                 (ans^-v c)))
             (cons (clean-σ global-σ vs)
                   vs)]
            [else
             (define todo-old todo)
             (set! todo ∅)                        ;; → '()
             (for ([c (in-set todo-old)]) (step c)) ;; → in-list
             (loop)]))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Mutable global store
(define (join-h! a vs)
  (define prev (hash-ref global-σ a ∅))
  (define added? (not (subset? vs prev)))
  (when added?
    (hash-set! global-σ a (∪ vs prev))
    (set! unions (add1 unions))))

(define (join*-h! as vss)
  (for ([a (in-list as)]
        [vs (in-list vss)])
    (join-h! a vs)))

(define-syntax-rule (global-hash-getter σ* a)
  (hash-ref global-σ a (λ () (error 'global-hash-getter "Unbound address ~a" a))))

(define-syntax-rule (bind-join-h! (σ* jhσ a vs) body)
  (begin (join-h! a vs) body))
(define-syntax-rule (bind-join*-h! (σ* jh*σ as vss) body)
  (begin (join*-h! as vss) body))


(define-syntax-rule (pull-global gen cs-base)
  (for/set #:initial cs-base
      ([c (in-producer gen (λ (x) (eq? 'done x)))])
    c))

(define-syntax-rule (imperative/generator/wide-step-specialized step ans?)
  (match-lambda
   [(cons σ-count cs)
    (define cs*
      (for/fold ([cs* ∅])
          ([c cs] #:unless (ans? c))
        (pull-global (step c) cs*)))
    (cons unions (set-union cs cs*))]))

(define-syntax-rule (mk-generator/wide/imperative-fixpoint name ans? ans-v touches)
  (define-syntax-rule (name step fst)
    (let ()
      (define wide-step (imperative/generator/wide-step-specialized step ans?))
      (define clean-σ (restrict-to-reachable touches))
      (set! global-σ (make-hash))
      (set! unions 0)
      (define cs (pull-global fst ∅))
      (define fst-s (cons unions cs))
      (define snd (wide-step fst-s))
      (let loop ((next snd) (prev fst-s))
        (cond [(equal? next prev)
               (define answers (for/set ([c (cdr prev)]
                                         #:when (ans? c))
                                 (ans-v c)))
               (cons (clean-σ global-σ answers)
                     answers)]
              [else
               (loop (wide-step next) next)])))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Concrete semantics

(define (eval-widen b)
  (cond [(atomic? b) b]
        [else (error "Unknown base value" b)]))

(define (hash-getter hgσ a)
  (hash-ref hgσ a (λ () (error 'getter "Unbound address ~a in store ~a" a hgσ))))

(define-syntax-rule (top-hash-getter thgσ a)
  (hash-ref top-σ a (λ () (error 'top-hash-getter "Unbound address ~a in store ~a" a top-σ))))

(define-syntax-rule (lazy-force lfσ x)
  (match x
    [(addr a) (getter lfσ a)]
    [v (set v)]))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; 0CFA-style Abstract semantics

(define ε '())
(define (truncate δ k)
  (cond [(zero? k) '()]
        [(empty? δ) '()]
        [else
         (cons (first δ) (truncate (rest δ) (sub1 k)))]))

(define (widen^ b)
  (match b
    [(? number?) 'number]
    [(? string?) 'string]
    [(? symbol?) 'symbol]
    [(? char?) 'char]
    [(? boolean?) b]
    [(or 'number 'string 'symbol 'char) b]
    [else (error "Unknown base value" b)]))

(define-syntax-rule (lazy-delay ldσ a) (set (addr a)))
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Potpourris of common parameterizations

(define-syntax-rule (with-concrete body)
  (splicing-syntax-parameterize
   ([widen (make-rename-transformer #'eval-widen)])
   body))

(define-syntax-rule (with-abstract body)
  (splicing-syntax-parameterize
   ([widen (make-rename-transformer #'widen^)])
   body))

(define-syntax-rule (with-narrow-set-monad body)
  (splicing-syntax-parameterize
   ([yield-meaning (syntax-rules () [(_ e) (∪1 target-cs e)])]
    [do-body-transformer do-body-transform-cs])
   body))

(define-syntax-rule (with-σ-passing-set-monad body)
  (splicing-syntax-parameterize
   ([yield-meaning (syntax-rules () [(_ e) (values target-σ (∪1 target-cs e))])]
    [do-body-transformer do-body-transform-σ/cs])
   body))

(define-syntax-rule (with-σ-passing-generators body)
  (splicing-syntax-parameterize
   ([yield-meaning (syntax-rules () [(_ e) (begin (real-yield e) target-σ)])])
   body))

(define-syntax-rule (with-global-σ-generators body)
  (splicing-syntax-parameterize
   ([yield-meaning (syntax-rules () [(_ e) (real-yield e)])])
   body))

(define-syntax-rule (with-mutable-worklist body)
  (splicing-syntax-parameterize
   ([yield-meaning yield!])
   body))

(define-syntax-rule (with-lazy body)
  (splicing-syntax-parameterize
   ([delay (make-rename-transformer #'lazy-delay)]
    [force (make-rename-transformer #'lazy-force)])
   body))

(define-syntax-rule (with-0-ctx body)
  (splicing-syntax-parameterize
   ([bind (make-rename-transformer #'bind-0)]
    [bind-rest (make-rename-transformer #'bind-rest-0)]
    [make-var-contour (make-rename-transformer #'make-var-contour-0)])
   body))

(define-syntax-rule (with-0-ctx/prealloc body)
  (splicing-syntax-parameterize
   ([bind (make-rename-transformer #'bind-0)]
    [bind-rest (make-rename-transformer #'bind-rest-0)]
    [make-var-contour (make-rename-transformer #'make-var-contour-0-prealloc)])
   body))

(define-syntax-rule (with-∞-ctx body)
  (splicing-syntax-parameterize
   ([bind (make-rename-transformer #'bind-∞)]
    [bind-rest (make-rename-transformer #'bind-rest-∞)]
    [make-var-contour (make-rename-transformer #'make-var-contour-k)])
   body))

(define-syntax-rule (with-1-ctx body)
  (splicing-syntax-parameterize
   ([bind (make-rename-transformer #'bind-1)]
    [bind-rest (make-rename-transformer #'bind-rest-1)]
    [make-var-contour (make-rename-transformer #'make-var-contour-k)])
   body))

(define-syntax-rule (with-whole-σ body)
  (splicing-syntax-parameterize
   ([bind-join (make-rename-transformer #'bind-join-whole)]
    [bind-join* (make-rename-transformer #'bind-join*-whole)]
    [getter (make-rename-transformer #'hash-getter)])
   body))

(define-syntax-rule (with-prealloc-store body)
  (splicing-syntax-parameterize
   ([bind-join (make-rename-transformer #'bind-join!)]
    [bind-join* (make-rename-transformer #'bind-join*!)]
    [getter (make-rename-transformer #'global-vector-getter)])
   body))

(define-syntax-rule (with-mutable-store body)
  (splicing-syntax-parameterize
   ([bind-join (make-rename-transformer #'bind-join-h!)]
    [bind-join* (make-rename-transformer #'bind-join*-h!)]
    [getter (make-rename-transformer #'global-hash-getter)])
   body))

(define-syntax-rule (with-σ-∆s body)
  (splicing-syntax-parameterize
   ([bind-join (make-rename-transformer #'bind-join-∆s)]
    [bind-join* (make-rename-transformer #'bind-join*-∆s)]
    [getter (make-rename-transformer #'top-hash-getter)])
   body))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Potpourris of evaluators

;; Compiled wide concrete store-passing set monad
 (with-lazy
 (with-∞-ctx
  (with-whole-σ
   (with-narrow-set-monad
    (with-concrete
      (mk-analysis #:aval lazy-eval/c #:ans ans/c
                   #:σ-passing #:set-monad #:kcfa +inf.0
                   #:compiled))))))
 (provide lazy-eval/c)

 (with-lazy
 (with-∞-ctx
  (with-whole-σ
   (with-narrow-set-monad
    (with-concrete
      (mk-analysis #:aval lazy-eval #:ans ans
                   #:σ-passing #:set-monad #:kcfa +inf.0))))))
 (provide lazy-eval)

 (mk-set-fixpoint^ fix eval-set-fixpoint^ ans^?)
 (with-lazy
 (with-∞-ctx
  (with-whole-σ
   (with-σ-passing-set-monad
    (with-concrete
      (mk-analysis #:aval lazy-eval^/c #:ans ans^
                   #:fixpoint eval-set-fixpoint^
                   #:compiled #:set-monad #:wide #:σ-passing
                   #:kcfa +inf.0))))))
 (provide lazy-eval^/c)

(mk-set-fixpoint^ fix 0cfa-set-fixpoint^/c 0cfa-ans^/c?)
(with-lazy
 (with-0-ctx
  (with-whole-σ
   (with-σ-passing-set-monad
    (with-abstract
     (mk-analysis #:aval lazy-0cfa^/c #:ans 0cfa-ans^/c
                  #:fixpoint 0cfa-set-fixpoint^/c
                  #:σ-passing
                  #:compiled #:wide #:set-monad))))))
 (provide lazy-0cfa^/c)

(mk-set-fixpoint^ fix 0cfa-set-fixpoint^ 0cfa-ans^?)
(with-lazy
 (with-0-ctx
  (with-whole-σ
   (with-σ-passing-set-monad
    (with-abstract
      (mk-analysis #:aval lazy-0cfa^ #:ans 0cfa-ans^
                   #:fixpoint 0cfa-set-fixpoint^
                   #:σ-passing #:wide #:set-monad))))))
(provide lazy-0cfa^)

(mk-fix fix-filtered 0cfa-ans? 0cfa-ans-v)
(with-lazy
 (with-0-ctx
  (with-whole-σ
   (with-narrow-set-monad
    (with-abstract
      (mk-analysis #:aval lazy-0cfa #:ans 0cfa-ans #:set-monad #:fixpoint fix-filtered
                   #:σ-passing))))))
(provide lazy-0cfa)


(with-lazy
 (with-0-ctx
  (with-whole-σ
   (with-narrow-set-monad
    (with-abstract
      (mk-analysis #:aval lazy-0cfa/c #:ans 0cfa-ans/c #:compiled
                   #:σ-passing
                   #:set-monad))))))
(provide lazy-0cfa/c)

(mk-generator/wide/σ-∆s-fixpoint lazy-0cfa-gen^-fix gen-ans^?)
(with-lazy
 (with-0-ctx
  (with-σ-∆s
   (with-σ-passing-generators
    (with-abstract
      (mk-analysis #:aval lazy-0cfa^-gen-σ-∆s #:ans gen-ans^
                   #:fixpoint lazy-0cfa-gen^-fix
                   #:σ-∆s
                   #:wide #:generators))))))
(provide lazy-0cfa^-gen-σ-∆s)


(mk-∆-fix^ lazy-0cfa∆^-fixpoint 0cfa∆-ans^?)
(with-lazy
 (with-0-ctx
  (with-σ-∆s
   (with-σ-passing-set-monad
    (with-abstract
      (mk-analysis #:aval lazy-0cfa∆/c #:ans 0cfa∆-ans^
                   #:fixpoint lazy-0cfa∆^-fixpoint
                   #:wide #:σ-∆s #:set-monad
                   #:compiled))))))
(provide lazy-0cfa∆/c)


(mk-generator/wide/σ-∆s-fixpoint lazy-0cfa-σ-∆s-gen^-fix/c gen-ans^-σ-∆s/c?)
(with-lazy
 (with-0-ctx
  (with-σ-∆s
   (with-σ-passing-generators
    (with-abstract
      (mk-analysis #:aval lazy-0cfa-gen-σ-∆s^/c #:ans gen-ans^-σ-∆s/c
                   #:fixpoint lazy-0cfa-σ-∆s-gen^-fix/c
                   #:σ-∆s
                   #:compiled #:wide #:generators))))))
(provide lazy-0cfa-gen-σ-∆s^/c)

(mk-generator/wide/imperative-fixpoint lazy-0cfa-gen^-fix/c gen-ans^/c? gen-ans^/c-v global-gen-touches-0)
(with-lazy
 (with-0-ctx
  (with-mutable-store
  (with-global-σ-generators
    (with-abstract
      (mk-analysis #:aval lazy-0cfa-gen^/c #:ans gen-ans^/c
                   #:touches global-gen-touches-0
                   #:fixpoint lazy-0cfa-gen^-fix/c
                   #:compiled #:global-σ #:wide #:generators))))))
(provide lazy-0cfa-gen^/c)

(mk-prealloc^-fixpoint prealloc/imperative-fixpoint prealloc-ans? prealloc-ans-v prealloc-touches-0)
(with-lazy
 (with-0-ctx/prealloc
  (with-prealloc-store
   (with-mutable-worklist
    (with-abstract
      (mk-analysis #:aval lazy-0cfa^/c!
                   #:prepare (λ (sexp) (prepare-prealloc parse-prog sexp))
                   #:ans prealloc-ans
                   #:touches prealloc-touches-0
                   #:fixpoint prealloc/imperative-fixpoint
                   #:global-σ #:compiled #:wide))))))
(provide lazy-0cfa^/c!)
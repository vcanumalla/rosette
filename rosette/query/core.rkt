#lang racket

(require 
  racket/generator
  "eval.rkt" "finitize.rkt"
  (only-in "../base/core/term.rkt" constant? term-type get-type term? term-cache clear-terms! term<? solvable-default)
  (only-in "../base/core/equality.rkt" @equal?)
  (only-in "../base/core/bool.rkt" ! || && => with-asserts-only @boolean?)
  (only-in "../base/core/function.rkt" fv)
  (only-in "../base/core/real.rkt" @integer? @real?)
  (only-in "../base/core/bitvector.rkt" bv bitvector?)
  "../solver/solver.rkt"
  (only-in "../solver/solution.rkt" model core sat unsat sat? unsat?)
  (only-in "../solver/smt/z3.rkt" z3))

(provide current-solver ∃-solve ∃-solve+ ∃∀-solve ∃-debug eval/asserts 
         all-true? some-false? unfinitize)

; Current solver instance that is used for queries and kept alive for performance.
(define current-solver
  (make-parameter (z3)
                  (lambda (s)
                    (unless (solver? s)
                      (error 'current-solver "expected a solver?, given ~s" s))
                    (solver-shutdown (current-solver))
                    s)))

; Returns true if evaluating all given formulas against 
; the provided solution returns the constant #t.
(define (all-true? φs sol)  
  (and (sat? sol) (for/and ([φ φs]) (equal? #t (evaluate φ sol)))))

; Returns true if evaluating at least one of the given 
; formulas against the provided solution returns the constant #f.
(define (some-false? φs sol)
  (and (sat? sol) (for/or ([φ φs]) (false? (evaluate φ sol)))))

(define return-#f (const '(#f)))

; Returns the list of assertions generated by evaluating the given thunk. 
; If the evaluation of the thunk results in an exn:fail? exception, returns 
; the list '(#f).
(define (eval/asserts closure)
  (with-handlers ([exn:fail? return-#f])
    (with-asserts-only (closure))))


  

; Searches for a model, if any, for the conjunction 
; of the given formulas, using the provided solver and 
; bitwidth.  The solver and the bitwidth are, by default, 
; current-solver and current-bitwidth.  Returns an unsat 
; solution if the given formulas don't have a model with 
; the specified bitwidth that is also correct under the 
; precise semantics. This procedure clears the solver's state 
; before and after use.
(define (∃-solve φs
                 #:minimize [mins '()]
                 #:maximize [maxs '()]
                 #:solver [solver (current-solver)]
                 #:bitwidth [bw (current-bitwidth)])
  (solver-clear solver)
  (begin0  
    (with-handlers ([exn? (lambda (e) (solver-shutdown solver) (raise e))])
      (cond 
        [bw 
         (parameterize ([term-cache (hash-copy (term-cache))])
           (define fmap (finitize (append φs mins maxs) bw))
           (solver-assert solver (for/list ([φ φs]) (hash-ref fmap φ)))
           (solver-minimize solver (for/list ([m mins]) (hash-ref fmap m)))
           (solver-maximize solver (for/list ([m maxs]) (hash-ref fmap m)))
           (let loop ()
             (define fsol (complete (solver-check solver) fmap))
             (define sol (unfinitize fsol fmap)) 
             (cond 
               [(or (unsat? sol) (all-true? φs sol)) sol]
               [else (solver-assert solver (list (¬solution fsol)))
                     (loop)])))]
        [else 
         (solver-assert solver φs)
         (solver-minimize solver mins)
         (solver-maximize solver maxs)
         (solver-check solver)]))
    (solver-clear solver)))

; Returns a generator that uses the solver of the given type, with the given 
; bitwidth setting, to incrementally solve a series of constraints.  The generator 
; consumes lists of constraints (i.e., boolean values and terms), and produces a 
; sequence of solutions.  Specifically, the ith returned solution is a solution for 
; all constraints added to the generator in the preceding i-1 calls.
(define (∃-solve+ #:solver [solver-type z3] #:bitwidth [bw (current-bitwidth)])
  (define cust (make-custodian))
  (define solver (parameterize ([current-custodian cust]
                                [current-subprocess-custodian-mode 'kill])
                   (solver-type)))
  (define handler (lambda (e) (solver-shutdown solver) (custodian-shutdown-all cust) (raise e)))
  (if bw
      (generator (ψs)
       (let ([fmap (make-hash)]
             [φs '()])
         (let outer ([δs ψs])
           (with-handlers ([exn? handler])
             (finitize δs bw fmap)
             (solver-assert solver (for/list ([δ δs]) (hash-ref fmap δ)))
             (set! φs (append δs φs)) 
             (let inner ()
               (define fsol (complete (solver-check solver) fmap))
               (define sol (unfinitize fsol fmap))
               (cond [(unsat? sol)
                      (solver-shutdown solver) 
                      (custodian-shutdown-all cust) 
                      (clear-terms! ; Purge finitization terms from the cache
                       (for/list ([(t ft) fmap] #:when (and (term? ft) (not (eq? t ft)))) ft))
                      sol]
                     [(all-true? φs sol) (outer (yield sol))]
                     [else  
                      (solver-assert solver (list (¬solution fsol)))
                      (inner)]))))))                      
      (generator (φs)
       (let loop ([φs φs])
         (with-handlers ([exn? handler])
           (solver-assert solver φs)
           (define sol (solver-check solver))
           (cond [(unsat? sol) (solver-shutdown solver) (custodian-shutdown-all cust) sol]
                 [else (loop (yield sol))]))))))

  
; Extracts an unsatisfiable core for the conjunction 
; of the given formulas, using the provided solver and 
; bitwidth.  The solver and the bitwidth are, by default, 
; current-solver and current-bitwidth.  This procedure assumes 
; that the formulas are unsatisfiable.  If not, an error is thrown. 
; The procedure clears the solver's state before and after use.
(define (∃-debug φs #:solver [solver (current-solver)] #:bitwidth [bw (current-bitwidth)] #:muc [muc? #t])
  (solver-clear solver)
  (begin0
    (with-handlers ([exn? (lambda (e) (solver-shutdown solver) (raise e))])
      (cond 
        [bw 
         (parameterize ([term-cache (hash-copy (term-cache))])
           (define fmap (finitize φs bw))
           (solver-assert solver (for/list ([φ φs]) (hash-ref fmap φ)))
           (define sol (solver-debug solver)) 
           (unfinitize (if muc? (minimize-core solver sol) sol) fmap))]
        [else 
         (solver-assert solver φs)
         (define sol (solver-debug solver))
         (if muc? (minimize-core solver sol) sol)]))
    (solver-clear solver)))

(define (minimize-core solver sol)
  (match (core sol)
    [(list _) sol]
    [k       
     (let loop ([k k][m (set)])
       (define u (for/or ([u k] #:unless (set-member? m u)) u))
       (cond
         [u 
          (solver-clear solver)
          (solver-assert solver (remove u k))
          (define s (with-handlers ([exn? (lambda (e) (sat))]) (solver-debug solver)))
          (if (unsat? s)
              (loop (core s) (set-union m (list->set (remove* (core s) k))))
              (loop k (set-add m u)))]
         [else (unsat k)]))]))

; Solves the exists-forall problem for the provided list of inputs, assumptions and assertions. 
; That is, if I is the set of all input symbolic constants, 
; and H is the set of the remaining (non-input) constants appearing 
; in the assumptions and the assertions, 
; this procedure solves the following constraint: 
; ∃H . ∀I . assumes => asserts.
; Note, however, that the procedure will *not* produce models that satisfy the above 
; formula by making assumes evaluate to false.
(define (∃∀-solve inputs assumes asserts #:solver [solver z3] #:bitwidth [bw (current-bitwidth)])
  (parameterize ([current-custodian (make-custodian)]
                 [current-subprocess-custodian-mode 'kill]
                 [term-cache (hash-copy (term-cache))])
    (with-handlers ([exn? (lambda (e) (custodian-shutdown-all (current-custodian)) (raise e))])
      (begin0 
        (cond 
          [bw
           (define fmap (finitize (append inputs assumes asserts) bw))
           (define fsol (cegis (for/list ([i inputs])  (hash-ref fmap i))
                               (for/list ([φ assumes]) (hash-ref fmap φ))
                               (for/list ([φ asserts]) (hash-ref fmap φ))
                               (solver) (solver)))
           (unfinitize fsol fmap)]
          [else 
           (cegis inputs assumes asserts (solver) (solver))])
        (custodian-shutdown-all (current-custodian))))))
         

; Uses the given solvers to solve the exists-forall problem 
; for the provided list of inputs, assumptions and assertions. 
; That is, if I is the set of all input symbolic constants, 
; and H is the set of the remaining (non-input) constants appearing 
; in the assumptions and the assertions, 
; this procedure solves the following constraint: 
; ∃H . ∀I . assumes => asserts.
; Note, however, that the procedure will *not* produce models that satisfy the above 
; formula by making assumes evaluate to false.
(define (cegis inputs assumes asserts guesser checker)
  
  (define φ   (append assumes asserts))
  
  (define ¬φ `(,@assumes ,(apply || (map ! asserts))))
   
  (define trial 0)
  
  (define (guess sol)
    (solver-assert guesser (evaluate φ sol))
    (match (solver-check guesser)
      [(model m) (sat (for/hash ([(c v) m] #:unless (member c inputs)) (values c v)))]
      [other other]))
  
  (define (check sol)
    (solver-clear checker)
    (solver-assert checker (evaluate ¬φ sol))
    (match (solver-check checker)
      [(? sat? m) (sat (for/hash ([i inputs])
                         (values i (let ([v (m i)])
                                     (if (eq? v i)
                                         (solvable-default (term-type i))
                                         v)))))]
      [other other]))
    
  (let loop ([candidate (begin0 (guess (sat)) (solver-clear guesser))])
    (cond 
      [(unsat? candidate) candidate]
      [else
        (let ([cex (check candidate)])
          (cond 
            [(unsat? cex) candidate]
            [else (set! trial (add1 trial))
                  (loop (guess cex))]))])))

(define (¬solution sol)
  (apply ||
         (for/list ([(c v) (model sol)])
           (match v
             [(fv ios o type)
              ; TODO:  introduce skolems to negate the else case
              (apply || (for/list ([io ios]) (! (@equal? (apply c (car io)) (cdr io)))))]
             [_ (! (@equal? c v))]))))

             
        
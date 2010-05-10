(*
 * SICP in SML/NJ
 * by Kenji Nozawa (hz7k-nzw@asahi-net.or.jp)
 *
 * Dependency: util.sml, chap1_2.sml, chap4_1.sml;
 *)

structure U = Util;
structure I = Util.Int;
structure R = Util.Real;

(* 4  Metalinguistic Abstraction *)
(* 4.3  Variations on a Scheme -- Nondeterministic Computing *)
(* 4.3.1  Amb and Search *)

(* 4.3.2  Examples of Nondeterministic Programs *)

(* 4.3.3  Implementing the Amb Evaluator *)

functor AmbEvaluatorFn (structure Obj: LISP_OBJECT
                        and Syntax: LISP_SYNTAX
                        sharing type Syntax.obj = Obj.t)
        : LISP_EVALUATOR =
struct
  type obj = Obj.t

  fun analyze exp : obj * obj * obj -> obj =
      if Syntax.isSelfEvaluating exp then
        analyzeSelfEvaluating exp
      else if Syntax.isVariable exp then
        analyzeVariable exp
      else if Syntax.isQuoted exp then
        analyzeQuoted exp
      else if Syntax.isAssignment exp then
        analyzeAssignment exp
      else if Syntax.isDefinition exp then
        analyzeDefinition exp
      else if Syntax.isIf exp then
        analyzeIf exp
      else if Syntax.isLambda exp then
        analyzeLambda exp
      else if Syntax.isBegin exp then
        analyzeSequence (Syntax.beginActions exp)
      else if Syntax.isDerived exp then
        analyze (Syntax.expandDerived exp)
      else if Syntax.isAmb exp then
        analyzeAmb exp
      else if Syntax.isApplication exp then
        analyzeApplication exp
      else
        raise Obj.Error ("Unknown expression type -- analyze: ~S",
                         [exp])

  and analyzeSelfEvaluating exp =
      (fn (env, succeed, fail) =>
          Obj.applySubr succeed [exp, fail])

  and analyzeVariable exp =
      (fn (env, succeed, fail) =>
          Obj.applySubr succeed [Obj.lookupEnv env exp, fail])

  and analyzeQuoted exp =
      let
        val qval = Syntax.textOfQuotation exp
      in
        (fn (env, succeed, fail) =>
            Obj.applySubr succeed [qval, fail])
      end

  and analyzeAssignment exp =
      let
        val var = Syntax.assignmentVariable exp
        val vproc = analyze (Syntax.assignmentValue exp)
      in
        (fn (env, succeed, fail) =>
            vproc (env,
                   (*
                    * saves the old value of the variable before
                    * assigning the new value to the variable and
                    * proceeding from the assignment.
                    *)
                   toSuccessCont
                       (fn (newVal, fail') =>
                           let
                             val oldVal = Obj.lookupEnv env var
                           in
                             Obj.setEnv env (var, newVal);
                             Obj.applySubr
                                 succeed
                                 [var,
                                  (*
                                   * restores the old value of the variable
                                   * before continuing the failure.
                                   *)
                                  toFailureCont
                                      (fn () =>
                                          (Obj.setEnv env (var, oldVal);
                                           Obj.applySubr fail' []))]
                           end),
                   fail))
      end

  and analyzeDefinition exp =
      let
        val var = Syntax.definitionVariable exp
        val vproc = analyze (Syntax.definitionValue exp)
      in
        (fn (env, succeed, fail) =>
            vproc (env,
                   toSuccessCont
                       (fn (newVal, fail') =>
                           (Obj.defineEnv env (var, newVal);
                            Obj.applySubr succeed [var, fail'])),
                   fail))
      end

  and analyzeIf exp =
      let
        val pproc = analyze (Syntax.ifPredicate exp)
        val cproc = analyze (Syntax.ifConsequent exp)
        val aproc = analyze (Syntax.ifAlternative exp)
      in
        (fn (env, succeed, fail) =>
            pproc (env,
                   (*
                    * success continuation for evaluating the predicate
                    * to obtain pred-value
                    *)
                   toSuccessCont
                       (fn (predVal, fail') =>
                           if Obj.isTrue predVal then
                             cproc (env, succeed, fail')
                           else
                             aproc (env, succeed, fail')),
                   (* failure continuation for evaluating the predicate *)
                   fail))
      end

  and analyzeLambda exp =
      let
        val vars = Syntax.lambdaParameters exp
        val proc = analyzeSequence (Syntax.lambdaBody exp)
        val body = toBody proc
      in
        (fn (env, succeed, fail) =>
            Obj.applySubr succeed [Obj.expr (vars, body, env), fail])
      end

  and analyzeSequence exps =
      let
        fun sequentially (p1, p2) =
            (fn (env, succeed, fail) =>
                (p1 (env,
                     (* success continuation for calling p1 *)
                     toSuccessCont
                         (fn (p1Val, fail') =>
                             p2 (env, succeed, fail')),
                     (* failure continuation for calling p1 *)
                     fail)))
        fun loop (first, nil) =
            first
          | loop (first, second::rest) =
            loop (sequentially (first, second), rest)
      in
        case toProcs exps of
          nil => raise Obj.Error ("Empty sequence -- analyzeSequence",
                                  nil)
        | (p::ps) => loop (p, ps)
      end

  and analyzeApplication exp =
      let
        val fproc = analyze (Syntax.operator exp)
        val aprocs = toProcs (Syntax.operands exp)
      in
        (fn (env, succeed, fail) =>
            fproc (env,
                   toSuccessCont
                       (fn (proc, fail') =>
                           getArgs aprocs
                                   (env,
                                    toSuccessCont
                                        (fn (args, fail'') =>
                                            executeApplication
                                                proc
                                                (Obj.toList args)
                                                (succeed, fail'')),
                                    fail')),
                   fail))
      end

  and getArgs nil (env, succeed, fail) =
      Obj.applySubr succeed [Obj.null, fail]
    | getArgs (aproc::aprocs) (env, succeed, fail) =
      aproc (env,
             (* success continuation for this aproc *)
             toSuccessCont
                 (fn (arg, fail') =>
                     getArgs aprocs
                             (env,
                              (*
                               * success continuation for recursive
                               * call to getArgs
                               *)
                              toSuccessCont
                                  (fn (args, fail'') =>
                                      Obj.applySubr
                                          succeed
                                          [Obj.cons (arg, args), fail'']),
                              fail')),
             fail)

  and executeApplication proc args (succeed, fail) =
      if Obj.isSubr proc then
        Obj.applySubr succeed [Obj.applySubr proc args, fail]
      else if Obj.isExpr proc then
        let
          (* params *)
          val params = Obj.toList (Obj.exprParams proc)
          (* body: represented as procedure (env * succeed * fail) -> obj) *)
          val body = Obj.exprBody proc
          (* env: environment to which body is applied *)
          val env = Obj.extendEnv (Obj.exprEnv proc) (params, args)
        in
          Obj.applySubr body [env, succeed, fail]
        end
      else
        raise Obj.Error ("Not a procedure -- executeApplication: ~S",
                         [proc])

  and analyzeAmb exp =
      let
        val cprocs = toProcs (Syntax.ambChoices exp)
      in
        (fn (env, succeed, fail) =>
            let
              fun tryNext nil =
                  Obj.applySubr fail []
                | tryNext (choice::choices) =
                  choice (env,
                          succeed,
                          toFailureCont (fn () => tryNext choices))
            in
              tryNext cprocs
            end)
      end

  and toBody p = Obj.subr3 ("body", p)

  and toSuccessCont p = Obj.subr2 ("succeed", p)

  and toFailureCont p = Obj.subr0 ("fail", p)

  and toProcs exps =
      if Obj.isNull exps then
        nil
      else if Obj.isCons exps then
        (analyze (Obj.car exps)) :: (toProcs (Obj.cdr exps))
      else
        raise Obj.Error ("Improper sequence: ~S", [exps])

  (* declared in LISP_EVALUATOR signature *)
  fun eval exp env =
      let
        val proc = analyze exp
        val params = (Obj.car env, (* (real) env *)
                      Obj.cadr env, (* success cont *)
                      Obj.caddr env) (* failuer cont *)
      in
        proc params
      end

  (* declared in LISP_EVALUATOR signature *)
  fun apply _ _ =
      raise Obj.Error ("Not supported: apply", nil)
end;

functor AmbInterpreterFn (Runtime : LISP_RUNTIME)
        : INTERPRETER =
struct
  open Runtime

  exception Test (* not used *)

  val stdIn = Obj.stdIn
  val stdOut = Obj.stdOut
  val stdErr = Obj.stdErr
  val quit = Obj.sym ":q"
  val again = Obj.sym ":a"

  fun hello () =
      ignore (Printer.format (stdOut, "Hello!~%"^
                                      "Type '~S' to exit~%"^
                                      "Type '~S' to try again~%",
                              [quit, again]))

  fun bye () =
      ignore (Printer.format (stdOut, "Bye!~%", nil))

  fun onError (Obj.Error (ctrlstr,args), cont) =
      let
        val msg = "Runtime error: " ^ ctrlstr ^ "~%"
      in
        Printer.format (stdErr, msg, args);
        cont ()
      end
    | onError (IO.Io {name,function,cause}, cont) =
      let
        val msg = "IO error: " ^ name ^ " -- " ^ function ^
                  " (cause: " ^ exnMessage cause ^ ")~%"
      in
        Printer.format (stdErr, msg, nil);
        cont ()
      end
    | onError (e, _) = raise e

  fun repl () =
      let
        val env = setupEnv ()
        fun toSuccessCont p = Obj.subr2 ("succeed", p)
        fun toFailureCont p = Obj.subr0 ("fail", p)
        fun loop () =
            let
              fun loop' tryAgain =
                  let
                    val obj = (Printer.format (stdOut, "~%> ", nil);
                               Reader.read stdIn)
                  in
                    if Obj.isEof obj orelse
                       Obj.eq (obj, quit) then
                      Obj.undef
                    else if Obj.eq (obj, again) then
                      Obj.applySubr tryAgain []
                    else
                      let
                        val succeed =
                            toSuccessCont
                                (fn (obj', nextAlternative) =>
                                    let
                                      val msg = "Success: ~S"
                                    in
                                      Printer.format (stdOut,msg,[obj']);
                                      loop' nextAlternative
                                    end)
                        (* ambeval failure *)
                        val fail =
                            toFailureCont
                                (fn () =>
                                    let
                                      val msg = "Fail: No more values of ~S"
                                    in
                                      Printer.format (stdOut,msg,[obj]);
                                      loop ()
                                    end)
                        val msg = "Eval: Starting a new problem~%"
                      in
                        Printer.format (stdOut, msg, []);
                        Evaluator.eval obj (Obj.fromList [env, succeed, fail])
                      end
                  end
              val noCurrentProblem =
                  toFailureCont
                      (fn () =>
                          let
                            val msg = "Try again: No current problem"
                          in
                            Printer.format (stdOut,msg,[]);
                            loop ()
                          end)
            in
              loop' noCurrentProblem
            end
            handle e => onError (e, loop)
      in
        loop ()
      end

  fun go () = (hello (); repl (); bye ())

  fun ut () = (* not used *)
      raise Obj.Error ("Not supported: ut", nil)

  fun test () = (* not used *)
      raise Obj.Error ("Not supported: test", nil)
end;

local
  structure Lisp : LISP =
  struct
    structure Obj
      = LispObjectFn (structure Env = Env)
    structure Syntax
      = LispSyntaxFn (structure Obj = Obj)
    structure Reader
      = LispReaderFn (structure Obj = Obj and Syntax = Syntax)
    structure Printer
      = LispPrinterFn (structure Obj = Obj and Syntax = Syntax)
    structure Evaluator
      = AmbEvaluatorFn (structure Obj = Obj and Syntax = Syntax)
  end
  structure Runtime = LispRuntimeFn (Lisp)
in
structure AI = AmbInterpreterFn (Runtime)
end;

(*
 * AI.go (); (* => activates top-level *)
 *)

(*
;;; example session
(list (amb 1 2 3) (amb 'a 'b))

(define (require p)
  (if (not p) (amb)))

(define (an-element-of items)
  (require (not (null? items)))
  (amb (car items) (an-element-of (cdr items))))

(define (prime-sum-pair list1 list2)
  (let ((a (an-element-of list1))
        (b (an-element-of list2)))
    (require (prime? (+ a b)))
    (list a b)))

(prime-sum-pair '(1 3 5 8) '(20 35 110))

(prime-sum-pair '(19 27 30) '(11 36 58))

 *)

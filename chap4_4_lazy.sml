(*
 * SICP in SML/NJ
 * by Kenji Nozawa (hz7k-nzw@asahi-net.or.jp)
 *
 * Dependency: util.sml, chap4_1.sml;
 *
 * Notice: the following code requires the lazy evaluation,
 * which is a non-standard feature of ML provided by SML/NJ.
 * The lazy evaluation features must be enabled by executing
 * the following at the top level:
 *  Control.lazysml := true;
 *
 * For more information, please see the following:
 *  Chapter 15 (Lazy Data Structures)
 *  of
 *  Programming in Standard ML
 *  (WORKING DRAFT OF AUGUST 20, 2009.)
 *  Robert Harper
 *  Carnegie Mellon University
 *  Spring Semester, 2005
 *  -> available online: http://www.cs.cmu.edu/~rwh/smlbook/
 *)

structure U = Util;
structure I = Util.Int;
structure R = Util.Real;

(* 4  Metalinguistic Abstraction *)
(* 4.4  Logic Programming *)
(* 4.4.1  Deductive Information Retrieval *)
(* 4.4.2  How the Query System Works *)
(* 4.4.3  Is Logic Programming Mathematical Logic? *)
(* 4.4.4  Implementing the Query System *)

(*
 * helper modules for query language
 *)

structure Stream =
struct
  open Lazy;

  datatype lazy 'a t = Nil | Cons of 'a * 'a t

  fun nth n =
      if n < 0 then raise Subscript
      else
        let
          fun f 0 (Cons (x, s)) = x
            | f k (Cons (_, s)) = f (k-1) s
            | f _ Nil = raise Subscript
        in
          f n
        end

  fun take n =
      if n < 0 then raise Subscript
      else
        let
          fun f 0 _ = nil
            | f k (Cons (x, s)) = x :: f (k-1) s
            | f _ Nil = raise Subscript
        in
          f n
        end

  fun map proc =
      let
        fun lazy f (Cons (x, s)) = (U.log "map";Cons (proc x, f s))
          | f Nil = Nil
      in
        f
      end

  fun app proc =
      let
        fun f (Cons (x, s)) = (U.log "app"; proc x; f s)
          | f Nil = ()
      in
        f
      end

  fun filter pred =
      let
        fun lazy f (Cons (x, s)) =
            if pred x then Cons (x, f s)
            else f s
          | f Nil = Nil
      in
        f
      end

  fun lazy append (Cons (x1, s1), s2) =
      (U.log "append"; Cons (x1, append (s1, s2)))
    | append (Nil, s2) = s2

  fun lazy interleave (Cons (x1, s1), s2) =
      (U.log "interleave"; Cons (x1, interleave (s2, s1)))
    | interleave (Nil, s2) = s2

  fun lazy flatten (Cons (x, s)) = interleave (x, flatten s)
    | flatten Nil = Nil

  fun flatmap proc s = flatten (map proc s)

  fun singleton x = Cons (x, Nil)
end;
(*
structure S = Stream;
val rec lazy ones = S.Cons (1, ones);
val rec lazy twos = S.Cons (2, twos);
val x = S.interleave (ones, twos);
val y = S.Cons (ones, S.Cons (twos, S.Nil));
val z = S.flatten y;
val u = S.map ~ ones;
val v = S.map (S.singleton o ~) ones;
val w = S.flatmap (S.singleton o ~) ones;
S.take 10 ones; (* [1,1,1,1,1,1,1,1,1,1] : int list *)
S.take 10 twos; (* [2,2,2,2,2,2,2,2,2,2] : int list *)
S.take 10 x;    (* [1,2,1,2,1,2,1,2,1,2] : int list *)
S.take 2 y;     (* [$$,$$] : int Stream.t! ?.susp list *)
S.take 10 z;    (* [1,2,1,2,1,2,1,2,1,2] : int list *)
S.take 10 u;    (* [~1,~1,~1,~1,~1,~1,~1,~1,~1,~1] : int list *)
S.take 10 v;    (* [$$,$$,$$,$$,$$,$$,$$,$$,$$,$$] : int Stream.t! ?.susp list *)
S.take 10 w;    (* [~1,~1,~1,~1,~1,~1,~1,~1,~1,~1] : int list *)
*)

structure Frame :>
sig
  type ('a,'b) t
  val make : ('a * 'a -> bool) -> ('a,'b) t
  val bindingIn : ('a,'b) t -> 'a -> ('a * 'b) option
  val extend : ('a,'b) t -> ('a * 'b) ->  ('a,'b) t
end =
struct
  type ('a,'b) t = ('a * 'b) list * ('a * 'a -> bool)

  fun make eq = (nil, eq)

  fun bindingIn (nil, _) _ = NONE
    | bindingIn ((bind as (var', _))::binds, eq) var =
      if eq (var', var) then SOME bind
      else bindingIn (binds, eq) var

  fun extend (binds, eq) bind = (bind::binds, eq)
end;

structure Table :>
sig
  type ('a,'b) t
  val make : ('a * 'a -> bool) -> ('a,'b) t
  val lookup : ('a,'b) t -> 'a -> 'b option
  val insert : ('a,'b) t -> 'a -> 'b -> unit
end =
struct
  type ('a,'b) t = ('a * 'b ref) list ref * ('a * 'a -> bool)

  fun make eq = (ref nil, eq)

  fun assoc key nil _ = NONE
    | assoc key ((p as (key', _))::ps) eq =
      if eq (key, key') then SOME p
      else assoc key ps eq

  fun lookup (table, eq) key =
      case assoc key (!table) eq of
        SOME (_, vref) => SOME (!vref)
      | NONE => NONE

  fun insert (table, eq) key newValue =
      case assoc key (!table) eq of
        SOME (_, vref) =>
        (vref := newValue;
         U.log "vref updated!")
      | NONE =>
        (table := (key, ref newValue) :: (!table);
         U.log "vref inserted!")
end;

(*
 * signatures for query language
 *)

signature QUERY =
sig
  type obj (* type of query expressions *)
  type prt (* type of runtime context for predicate evaluator *)
  type qrt = (* type of runtime context for query language *)
       {PRED_RUNTIME : prt,
        THE_ASSERTIONS : obj Stream.t ref,
        THE_RULES : obj Stream.t ref,
        THE_TABLE : ((obj * obj), obj Stream.t) Table.t}

  (* predefined symbols *)
  val ALWAYS_TRUE : obj
  val ASSERT : obj
  val ASSERTION_STREAM : obj
  val CONJUNCT : obj
  val DISJUNCT : obj
  val NEGATE : obj
  val PREDICATE : obj
  val QUESTION : obj
  val RULE : obj
  val RULE_STREAM : obj

  (* null streams *)
  val NULL_OBJ_STREAM : obj Stream.t
  val NULL_FRAME_STREAM : (obj,obj) Frame.t Stream.t

  (* for composite expressions *)
  val typeOf : obj -> obj
  val contentsOf : obj -> obj

  (* for add-assertion *)
  val isAssertionToBeAdded : obj -> bool
  val addAssertionBody : obj -> obj

  (* for conjunction (and) *)
  val isConjunction : obj -> bool
  val conjunctionBody : obj -> obj
  val isEmptyConjunction : obj -> bool
  val firstConjunct : obj -> obj
  val restConjuncts : obj -> obj

  (* for disjunction (or) *)
  val isDisjunction : obj -> bool
  val disjunctionBody : obj -> obj
  val isEmptyDisjunction : obj -> bool
  val firstDisjunct : obj -> obj
  val restDisjuncts : obj -> obj

  (* for negation (not) *)
  val isNegation : obj -> bool
  val negatedQuery : obj -> obj

  (* for predicate (lisp-value) *)
  val isPredicate : obj -> bool
  val predicateBody : obj -> obj
  val predicate : obj -> obj
  val args : obj -> obj

  (* for always-true *)
  val isAlwaysTrue : obj -> bool

  (* for rule *)
  val isRule : obj -> bool
  val conclusion : obj -> obj
  val ruleBody : obj -> obj

  (* for variables and constant-symbols *)
  val querySyntaxProcess : obj -> obj
  val isVar : obj -> bool
  val isConstantSymbol : obj -> bool
  val contractQuestionMark : obj -> obj

  (* for instantiation *)
  val instantiate : obj -> (obj,obj) Frame.t
                    -> (obj -> (obj,obj) Frame.t -> obj)
                    -> obj

  (* for pattern matching and unification *)
  val patternMatch : obj -> obj
                     -> (obj,obj) Frame.t option
                     -> (obj,obj) Frame.t option
  val renameVariablesIn : obj -> obj
  val unifyMatch : obj -> obj
                   -> (obj,obj) Frame.t option
                   -> (obj,obj) Frame.t option

  (* for others *)
  val makeQueryRuntime : unit -> qrt
  val makeNewFrame : unit -> (obj,obj) Frame.t
  val executePredicate : qrt -> obj -> bool
  val error : string * obj list -> 'a
  val log : string * obj list -> unit
  val debug : bool ref
end;

signature QUERY_DATA_BASE =
sig
  structure Q : QUERY

  val addRuleOrAssertion : Q.qrt -> Q.obj -> unit
  val fetchAssertions : Q.qrt
                        -> Q.obj * (Q.obj,Q.obj) Frame.t
                        -> Q.obj Stream.t
  val fetchRules : Q.qrt
                   -> Q.obj * (Q.obj,Q.obj) Frame.t
                   -> Q.obj Stream.t
end;

signature QUERY_EVALUATOR =
sig
  structure Q : QUERY
  structure QDB : QUERY_DATA_BASE

  val eval : Q.qrt -> Q.obj
             -> (Q.obj,Q.obj) Frame.t Stream.t
             -> (Q.obj,Q.obj) Frame.t Stream.t
end;

(*
 * implementations for query language
 *)

functor QueryFn (LispRuntime : LISP_RUNTIME) : QUERY =
struct
  structure Obj = LispRuntime.Obj
  structure Evaluator = LispRuntime.Evaluator
  structure Printer = LispRuntime.Printer

  type obj = Obj.t
  type prt = LispRuntime.rt
  type qrt =
       {PRED_RUNTIME : prt,
        THE_ASSERTIONS : obj Stream.t ref,
        THE_RULES : obj Stream.t ref,
        THE_TABLE : ((obj * obj), obj Stream.t) Table.t}

  val ALWAYS_TRUE = Obj.sym "always-true"
  val ASSERT = Obj.sym "assert!"
  val ASSERTION_STREAM = Obj.sym "assertion-stream"
  val CONJUNCT = Obj.sym "and"
  val DISJUNCT = Obj.sym "or"
  val NEGATE = Obj.sym "not"
  val PREDICATE = Obj.sym "lisp-value"
  val QUESTION = Obj.sym "?"
  val RULE = Obj.sym "rule"
  val RULE_STREAM = Obj.sym "rule-stream"

  val NULL_OBJ_STREAM : obj Stream.t = Stream.Nil
  val NULL_FRAME_STREAM : (obj,obj) Frame.t Stream.t = Stream.Nil

  val debug = ref false

  fun error (ctrlstr, args) = raise Obj.Error (ctrlstr, args)

  fun log (ctrlstr, args) =
      if !debug then
        let
          val msg = "DEBUG: "^ctrlstr^"~%"
        in
          ignore (Printer.format (Obj.stdErr, msg, args))
        end
      else
        ()

  fun isTaggedList tag exp =
      Obj.isCons exp andalso
      Obj.eq (Obj.car exp, tag)

  fun typeOf exp =
      if Obj.isCons exp then Obj.car exp
      else error ("Unknown expression: ~S", [exp])

  fun contentsOf exp =
      if Obj.isCons exp then Obj.cdr exp
      else error ("Unknown expression: ~S", [exp])

  (*fun isAssertionToBeAdded exp = Obj.eq (typeOf exp, ASSERT)*)
  val isAssertionToBeAdded = isTaggedList ASSERT
  val addAssertionBody = Obj.car o contentsOf

  val isConjunction = isTaggedList CONJUNCT
  val conjunctionBody = contentsOf
  val isEmptyConjunction = Obj.isNull
  val firstConjunct = Obj.car
  val restConjuncts = Obj.cdr

  val isDisjunction = isTaggedList DISJUNCT
  val disjunctionBody = contentsOf
  val isEmptyDisjunction = Obj.isNull
  val firstDisjunct = Obj.car
  val restDisjuncts = Obj.cdr

  val isNegation = isTaggedList NEGATE
  (*fun negatedQuery exps = Obj.car exps*)
  val negatedQuery = Obj.car o contentsOf

  val isPredicate = isTaggedList PREDICATE
  val predicateBody = contentsOf
  val predicate = Obj.car
  val args = Obj.cdr

  val isAlwaysTrue = isTaggedList ALWAYS_TRUE

  val isRule = isTaggedList RULE
  val conclusion = Obj.cadr
  fun ruleBody rule =
      if Obj.isNull (Obj.cddr rule) then
        Obj.fromList [ALWAYS_TRUE]
      else Obj.caddr rule

  fun querySyntaxProcess exp =
      let
        fun mapOverSymbols proc exp =
            if Obj.isCons exp then
              Obj.cons (mapOverSymbols proc (Obj.car exp),
                        mapOverSymbols proc (Obj.cdr exp))
            else if Obj.isSym exp then
              proc exp
            else
              exp
        fun expandQuestionMark sym =
            let
              val str = Obj.pname sym
            in
              log ("expandQuestionMark: ~S", [sym]);
              if String.isPrefix "?" str then
                Obj.fromList [QUESTION,
                              Obj.sym (String.extract (str,1,NONE))]
              else sym
            end
      in
        mapOverSymbols expandQuestionMark exp
      end

  val isVar = isTaggedList QUESTION
  val isConstantSymbol = Obj.isSym

  fun contractQuestionMark var =
      let
        val str = "?" ^
                  (if Obj.isNum (Obj.cadr var) then
                     (Obj.pname o Obj.caddr) var ^
                     "-" ^
                     (Int.toString o Obj.toInt o Obj.cadr) var
                   else
                     (Obj.pname o Obj.cadr) var)
      in
        Obj.sym str
      end

  fun instantiate exp frame unboundVarHandler =
      let
        fun copy exp =
            if isVar exp then
              case Frame.bindingIn frame exp of
                SOME (_, dat) => copy dat
              | NONE => unboundVarHandler exp frame
            else if Obj.isCons exp then
              Obj.cons (copy (Obj.car exp), copy (Obj.cdr exp))
            else
              exp
      in
        copy exp
      end

  fun patternMatch pat dat frameOpt =
      (log ("patternMatch: pat=~S dat=~S", [pat,dat]);
      case frameOpt of
        NONE => (log ("patternMatch: frameOpt is NONE",nil); NONE)
      | SOME frame =>
        if Obj.equal (pat, dat) then
          (log ("patternMatch: pat = dat",nil); SOME frame)
        else if isVar pat then
          (log ("patternMatch: pat is var",nil);
           extendIfConsistent pat dat frame)
        else if Obj.isCons pat andalso Obj.isCons dat then
          (log ("patternMatch: both pat and dat are cons",nil);
          patternMatch (Obj.cdr pat)
                       (Obj.cdr dat)
                       (patternMatch (Obj.car pat)
                                     (Obj.car dat)
                                     (SOME frame))
          )
        else
          (log ("patternMatch: pat is NONE",nil); NONE)
      )

  and extendIfConsistent var dat frame =
      (log ("extendIfConsistent: var=~S dat=~S", [var,dat]);
      case Frame.bindingIn frame var of
        SOME (_, dat') =>
        (log ("extendIfConsistent: binding found: ~S", [dat']);
         patternMatch dat' dat (SOME frame))
      | NONE =>
        (log ("extendIfConsistent: binding not found",nil);
         SOME (Frame.extend frame (var, dat)))
      )

  local
    val ruleCounter = ref 0
  in
  fun renameVariablesIn rule =
      let
        val ruleApplicationId = newRuleApplicationId ()
        fun treeWalk exp =
            if isVar exp then
              makeNewVariable (exp, ruleApplicationId)
            else if Obj.isCons exp then
              Obj.cons (treeWalk (Obj.car exp),
                        treeWalk (Obj.cdr exp))
            else
              exp
      in
        treeWalk rule
      end
  and newRuleApplicationId () =
      !ruleCounter before ruleCounter := !ruleCounter + 1
  and makeNewVariable (var, ruleApplicationId) =
      Obj.cons (QUESTION,
                  Obj.cons (Obj.int ruleApplicationId, Obj.cdr var))
  end

  fun unifyMatch p1 p2 frameOpt =
      (log ("unifyMatch: p1=~S p2=~S", [p1,p2]);
      case frameOpt of
        NONE => (log ("unifyMatch: frameOpt is NONE",nil); NONE)
      | SOME frame =>
        if Obj.equal (p1, p2) then
          (log ("unifyMatch: p1 = p2",nil); SOME frame)
        else if isVar p1 then
          (log ("unifyMatch: p1 is var",nil);
           extendIfPossible p1 p2 frame)
        else if isVar p2 then
          (log ("unifyMatch: p2 is var",nil);
           extendIfPossible p2 p1 frame)
        else if Obj.isCons p1 andalso Obj.isCons p2 then
          (log ("unifyMatch: both p1 and p2 are cons",nil);
          unifyMatch (Obj.cdr p1)
                     (Obj.cdr p2)
                     (unifyMatch (Obj.car p1)
                                 (Obj.car p2)
                                 (SOME frame))
          )
        else
          (log ("unifyMatch: both p1 and p2 are NONE",nil); NONE)
      )

  and extendIfPossible var dat frame =
      (log ("extendIfPossible: var=~S dat=~S", [var,dat]);
      case Frame.bindingIn frame var of
        SOME (_, dat') =>
        (log ("extendIfPossible: binding for var found: ~S", [dat']);
         unifyMatch dat' dat (SOME frame))
      | NONE =>
        if isVar dat then
          case Frame.bindingIn frame dat of
            SOME (_, dat') =>
            (log ("extendIfPossible: binding for dat found: ~S", [dat']);
             unifyMatch var dat' (SOME frame))
          | NONE =>
            (log ("extendIfPossible: binding for dat not found",nil);
             SOME (Frame.extend frame (var, dat)))
        else if dependsOn dat var frame then
          (log ("extendIfPossible: dat depends on var",nil); NONE)
        else
          (log ("extendIfPossible: binding for var not found",nil);
           SOME (Frame.extend frame (var, dat)))
      )

  and dependsOn exp var frame =
      let
        fun treeWalk exp =
            if isVar exp then
              if Obj.equal (var, exp) then
                true
              else
                case Frame.bindingIn frame exp of
                  SOME (_, dat) => treeWalk dat
                | NONE => false
            else if Obj.isCons exp then
              treeWalk (Obj.car exp) orelse
              treeWalk (Obj.cdr exp)
            else
              false
      in
        treeWalk exp
      end

  fun tableEq ((x1,y1),(x2,y2)) =
      Obj.eq (x1,x2) andalso Obj.eq (y1,y2)

  fun makeQueryRuntime () =
      {PRED_RUNTIME = LispRuntime.makeRuntime (),
       THE_ASSERTIONS = ref NULL_OBJ_STREAM,
       THE_RULES = ref NULL_OBJ_STREAM,
       THE_TABLE = Table.make tableEq}

  fun makeNewFrame () = Frame.make Obj.equal

  fun executePredicate ({PRED_RUNTIME,...}:qrt) exp =
      let
        val env = LispRuntime.env PRED_RUNTIME
        val pred = Evaluator.eval (predicate exp) env
        val args = Obj.toList (args exp)
      in
        Obj.isTrue (Evaluator.apply pred args)
      end
end;

functor QueryDataBaseFn (structure Query : QUERY)
        : QUERY_DATA_BASE =
struct
  structure Q = Query

  (*val isUseIndex = Q.isConstantSymbol o Obj.car*)
  val isUseIndex = Q.isConstantSymbol o Q.typeOf

  fun indexKeyOf pat =
      let
        (*val key = Obj.car pat*)
        val key = Q.typeOf pat
      in
        if Q.isVar key then Q.QUESTION
        else if Q.isConstantSymbol key then key
        else Q.error ("Unexpected pattern: ~S", [pat])
      end

  (*
  fun isIndexable pat =
      (Q.isConstantSymbol o Obj.car) pat orelse
      (Q.isVar o Obj.car) pat
   *)
  fun isIndexable pat =
      let
        (*val key = Obj.car pat*)
        val key = Q.typeOf pat
      in
        Q.isConstantSymbol key orelse
        Q.isVar key
      end

  fun get ({THE_TABLE,...}:Q.qrt) = Table.lookup THE_TABLE
  fun put ({THE_TABLE,...}:Q.qrt) = Table.insert THE_TABLE

  fun getStream (qrt:Q.qrt) (key1, key2) =
      (Q.log ("getStream: ~S ~S", [key1,key2]);
      case get qrt (key1, key2) of
        SOME s => s
      | NONE => Q.NULL_OBJ_STREAM
      )

  fun storeAssertionInIndex (qrt:Q.qrt) assertion =
      (Q.log ("storeAssertionInIndex: ~S", [assertion]);
      if isIndexable assertion then
        let
          val key = indexKeyOf assertion
          val currentAssertionStream =
              getStream qrt (key, Q.ASSERTION_STREAM)
          val lazy stream =
              Stream.Cons (assertion, currentAssertionStream)
        in
          put qrt (key, Q.ASSERTION_STREAM) stream
        end
      else
        ()
      )

  fun storeRuleInIndex (qrt:Q.qrt) rule =
      (Q.log ("storeRuleInIndex: ~S", [rule]);
      let
        val pattern = Q.conclusion rule
      in
        if isIndexable pattern then
          let
            val key = indexKeyOf pattern
            val currentRuleStream =
                getStream qrt (key, Q.RULE_STREAM)
            val lazy stream =
                Stream.Cons (rule, currentRuleStream)
          in
            put qrt (key, Q.RULE_STREAM) stream
          end
        else
          ()
      end
      )

  fun addRuleOrAssertion (qrt:Q.qrt) assertion =
      (Q.log ("addRuleOrAssertion: ~S", [assertion]);
      if Q.isRule assertion then addRule qrt assertion
      else addAssertion qrt assertion
      )

  and addAssertion (qrt as {THE_ASSERTIONS,...}:Q.qrt) assertion =
      (Q.log ("addAssertion: ~S", [assertion]);
      (storeAssertionInIndex qrt assertion;
       let
         val oldAssertions = !THE_ASSERTIONS
         val lazy stream = Stream.Cons (assertion, oldAssertions)
       in
         THE_ASSERTIONS := stream
       end)
      )

  and addRule (qrt as {THE_RULES,...}:Q.qrt) rule =
      (Q.log ("addRule: ~S", [rule]);
      (storeRuleInIndex qrt rule;
       let
         val oldRules = !THE_RULES
         val lazy stream = Stream.Cons (rule, oldRules)
       in
         THE_RULES := stream
       end)
      )

  fun fetchAssertions (qrt:Q.qrt) (pattern, frame) =
      (Q.log ("fetchAssertions: ~S", [pattern]);
      if isUseIndex pattern then getIndexedAssertions qrt pattern
      else getAllAssertions qrt
      )

  and getIndexedAssertions (qrt:Q.qrt) pattern =
      getStream qrt (indexKeyOf pattern, Q.ASSERTION_STREAM)

  and getAllAssertions ({THE_ASSERTIONS,...}:Q.qrt) =
      !THE_ASSERTIONS

  fun fetchRules (qrt:Q.qrt) (pattern, frame) =
      (Q.log ("fetchRules: ~S", [pattern]);
      if isUseIndex pattern then getIndexedRules qrt pattern
      else getAllRules qrt
      )

  and getIndexedRules (qrt:Q.qrt) pattern =
      Stream.append (getStream qrt (indexKeyOf pattern, Q.RULE_STREAM),
                     getStream qrt (Q.QUESTION, Q.RULE_STREAM))

  and getAllRules ({THE_RULES,...}:Q.qrt) =
      !THE_RULES
end;

functor QueryEvaluatorFn (structure Query : QUERY
                          structure DataBase : QUERY_DATA_BASE
                          sharing Query = DataBase.Q)
        : QUERY_EVALUATOR =
struct
  structure Q = Query
  structure QDB = DataBase

  fun eval (qrt:Q.qrt) query frameStream =
      (Q.log ("eval: ~S", [query]);
      if Q.isConjunction query then
        conjoin qrt (Q.conjunctionBody query) frameStream
      else if Q.isDisjunction query then
        disjoin qrt (Q.disjunctionBody query) frameStream
      else if Q.isNegation query then
        negate qrt (Q.negatedQuery query) frameStream
      else if Q.isPredicate query then
        lispValue qrt (Q.predicateBody query) frameStream
      else if Q.isAlwaysTrue query then
        frameStream
      else
        simpleQuery qrt query frameStream
      )

  and simpleQuery (qrt:Q.qrt) queryPattern =
      (Q.log ("simpleQuery: ~S", [queryPattern]);
      Stream.flatmap
          (fn frame =>
              Stream.append (findAssertion qrt queryPattern frame,
                             (*delay*)applyRules qrt queryPattern frame))
      )

  and conjoin (qrt:Q.qrt) conjuncts frameStream =
      (Q.log ("conjoin: ~S", [conjuncts]);
      if Q.isEmptyConjunction conjuncts then
        frameStream
      else
        conjoin qrt
                (Q.restConjuncts conjuncts)
                (eval qrt (Q.firstConjunct conjuncts) frameStream)
      )

  and disjoin (qrt:Q.qrt) disjuncts frameStream =
      (Q.log ("disjoin: ~S", [disjuncts]);
      if Q.isEmptyDisjunction disjuncts then
        Q.NULL_FRAME_STREAM
      else
        Stream.interleave
            (eval qrt (Q.firstDisjunct disjuncts) frameStream,
             (*delay*)disjoin qrt (Q.restDisjuncts disjuncts) frameStream)
      )

  and negate (qrt:Q.qrt) query =
      (Q.log ("negate: ~S", [query]);
      Stream.flatmap
          (fn frame =>
              let
                val frameStream' = Stream.singleton frame
              in
                case eval qrt query frameStream' of
                  Stream.Nil => frameStream'
                | _ => Q.NULL_FRAME_STREAM
              end)
      )

  and lispValue (qrt:Q.qrt) call =
      (Q.log ("lispValue: ~S", [call]);
      Stream.flatmap
          (fn frame =>
              let
                fun handler exp frame =
                    Q.error ("Unknown pat var -- lispValue: ~S", [exp])
                val exp = Q.instantiate call frame handler
              in
                if Q.executePredicate qrt exp then
                  Stream.singleton frame
                else
                  Q.NULL_FRAME_STREAM
              end)
      )

  and findAssertion (qrt:Q.qrt) pattern frame =
      (Q.log ("findAssertion: ~S", [pattern]);
      Stream.flatmap
          (fn datum => checkOneAssertion datum pattern frame)
          (QDB.fetchAssertions qrt (pattern, frame))
      )

  and checkOneAssertion assertion queryPat queryFrame =
      (Q.log ("checkOneAssertion: ~S ~S", [assertion, queryPat]);
      case Q.patternMatch queryPat assertion (SOME queryFrame) of
        SOME matchResult => (Q.log ("checkOneAssertion: BINGO",nil);
                             Stream.singleton matchResult)
      | NONE => (Q.log ("checkOneAssertion: NONE",nil);
                 Q.NULL_FRAME_STREAM)
      )

  and applyRules (qrt:Q.qrt) pattern frame =
      (Q.log ("applyRules: ~S", [pattern]);
      Stream.flatmap
          (fn rule => applyOneRule qrt rule pattern frame)
          (QDB.fetchRules qrt (pattern, frame))
      )

  and applyOneRule (qrt:Q.qrt) rule queryPat queryFrame =
      (Q.log ("applyOneRule: ~S ~S", [rule, queryPat]);
      let
        val cleanRule = Q.renameVariablesIn rule
      in
        case Q.unifyMatch queryPat
                          (Q.conclusion cleanRule)
                          (SOME queryFrame) of
          SOME unifyResult => (Q.log ("applyOneRule: BINGO",nil);
                               eval qrt
                                    (Q.ruleBody cleanRule)
                                    (Stream.singleton unifyResult))
        | NONE => (Q.log ("applyOneRule: NONE",nil);
                   Q.NULL_FRAME_STREAM)
      end
      )
end;

structure QueryInterpreter : INTERPRETER =
struct
  structure Q = QueryFn (DefaultLispRuntime)
  structure QDB = QueryDataBaseFn (structure Query = Q)
  structure QE = QueryEvaluatorFn (structure Query = Q and DataBase = QDB)

  open DefaultLispRuntime

  val quit = Obj.sym ":q"
  val eval = Obj.sym ":e"
  val debug = Obj.sym ":d"

  fun makeQueryRuntime () =
      let
        val qrt = Q.makeQueryRuntime ()
        val lrt = #PRED_RUNTIME qrt
        (* load *)
        val fnLoad = (fn file => (load (qrt, Obj.toString file); Obj.undef))
        val subrLoad = Obj.subr1 ("load", fnLoad)
        val symLoad = Obj.sym (Obj.subrName subrLoad)
        val _ = Obj.defineEnv (env lrt) (symLoad, subrLoad)
      in
        qrt
      end

  and hello (qrt:Q.qrt) =
      let
        val lrt = #PRED_RUNTIME qrt
      in
        ignore (Printer.format (stdOut lrt,
                                "Hello!~%"^
                                "Type '~S' to exit~%"^
                                "Type '~S' to eval lisp expression~%"^
                                "Type '~S' to toggle debug flag~%",
                                [quit, eval, debug]))
      end

  and bye (qrt:Q.qrt) =
      let
        val lrt = #PRED_RUNTIME qrt
      in
        ignore (Printer.format (stdOut lrt,
                                "Bye!~%",
                                nil))
      end

  and repl (qrt:Q.qrt, prompt) =
      let
        val lrt = #PRED_RUNTIME qrt
        val counter = ref 0
        fun inc () = (Obj.int (!counter)) before counter := !counter + 1
        fun count () = Obj.int (!counter)
        fun reset () = counter := 0
        fun loop () =
            let
              val obj = (Printer.format (stdOut lrt, prompt, nil);
                         (Q.querySyntaxProcess o Reader.read) (stdIn lrt))
            in
              if Obj.isEof obj orelse Obj.eq (obj, quit) then
                ()
              else if Obj.eq (obj, eval) then (* eval lisp exp *)
                let
                  val obj' = Reader.read (stdIn lrt)
                  val obj'' = Evaluator.eval obj' (env lrt)
                in
                  Printer.format (stdOut lrt, "Eval: ~S.~%", [obj'']);
                  loop ()
                end
              else if Obj.eq (obj, debug) then (* toggle debug flag *)
                (Q.debug := not (!Q.debug);
                 Printer.format (stdOut lrt, "Debug: ~S.~%",
                                 [Obj.bool (!Q.debug)]);
                 loop ())
              else if Q.isAssertionToBeAdded obj then
                let
                  val body = Q.addAssertionBody obj
                in
                  QDB.addRuleOrAssertion qrt body;
                  Printer.format (stdOut lrt, "Added to DB: ~S.~%", [body]);
                  loop ()
                end
              else
                let
                  val frameStream = Stream.singleton (Q.makeNewFrame ())
                  fun handler exp frame = Q.contractQuestionMark exp
                in
                  reset ();
                  Stream.app
                      (fn exp => (inc ();
                                  Printer.format (stdOut lrt, "~S~%", [exp])))
                      (Stream.map
                           (fn frame => Q.instantiate obj frame handler)
                           (QE.eval qrt obj frameStream));
                  Printer.format (stdOut lrt, "Query: ~S result(s) found.~%",
                                  [count ()]);
                  loop ()
                end
            end
            handle e => (Printer.printException (stdErr lrt, e);
                         loop ())
      in
        loop ()
      end

  and load (qrt:Q.qrt, file) =
      let
        val lrt = #PRED_RUNTIME qrt
        val oldIn = stdIn lrt
        fun body () =
            let
              val newIn = Obj.openIn file
              fun body' () = (setStdIn lrt newIn; repl (qrt,"~%"))
              fun cleanup' () = ignore (Obj.closeIn newIn)
            in
              U.unwindProtect body' cleanup'
            end
        fun cleanup () = setStdIn lrt oldIn
      in
        U.unwindProtect body cleanup
      end

  and go () =
      let
        val qrt = makeQueryRuntime ()
      in
        hello qrt; repl (qrt,"~%> "); bye qrt
      end
end;

structure QI = QueryInterpreter;

(*
 * QI.go (); (* => activates top-level *)
 *)

(*
 * sample data base can be loaded by executing
 * the following at the lisp top-level:
 * :e (load "chap4_4_example.scm")
 *)

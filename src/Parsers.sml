signature PARSERS_ARGS = sig
    structure Grammar: GRAMMAR
    structure Lookahead: LEXEME where type t = Grammar.Token.t option
    structure Analysis: GRAMMAR_ANALYSIS
        where type LookaheadSet.item = Lookahead.t
        where type Grammar.productee = Grammar.productee
end

signature PARSERS = sig
    structure Grammar: GRAMMAR
    structure Analyzed: ANALYZED_GRAMMAR where type productee = Grammar.productee
    structure FirstSet: TOKEN_SET
    structure LookaheadSet: TOKEN_SET where type item = Grammar.Token.t option

    val matchCode: string
    val matchPredCode: string
    val recognizerRulesCode: Grammar.grammar -> string -> string
    val rulesCode: FirstSet.set StringMap.map -> LookaheadSet.set StringMap.map
                -> LookaheadSet.set Analyzed.branch list StringMap.map -> string
end

functor NipoParsers(Args: PARSERS_ARGS) :> PARSERS
    where type Grammar.productee = Args.Grammar.productee
    where type FirstSet.set = Args.Analysis.FirstSet.set
    where type LookaheadSet.set = Args.Analysis.LookaheadSet.set
= struct
    open BranchCond
    open Matcher
    structure Grammar = Args.Grammar
    datatype productee = datatype Grammar.productee
    structure Analysis = Args.Analysis
    val predictionSet = Analysis.predictionSet
    val firstSet = Analysis.firstSet
    structure Analyzed = Analysis.Analyzed
    structure Lookahead = Args.Lookahead
    structure FirstSet = Analysis.FirstSet
    structure LookaheadSet = Analysis.LookaheadSet
    
    (* FIXME: Error messages in these match routines give position after token: *)

    val matchCode =
        "    fun match token input =\n" ^
        "        case Input.pop input\n" ^
        "        of SOME token' =>\n" ^
        "            if token' = token\n" ^
        "            then token'\n" ^
        "            else raise Fail ( \"expected \" ^ Input.Token.toString token\n" ^
        "                            ^ \", got \" ^ Input.Token.toString token'\n" ^
        "                            ^ \" at \" ^ Input.Pos.toString (Input.pos input) )\n" ^
        "         | NONE =>\n" ^
        "            raise Fail ( \"expected \" ^ Input.Token.toString token\n" ^
        "                       ^ \", got \" ^ Input.Token.lookaheadToString NONE\n" ^
        "                       ^ \" at \" ^ Input.Pos.toString (Input.pos input) )\n"

    val matchPredCode =
        "    fun matchPred pred input =\n" ^
        "        case Input.pop input\n" ^
        "        of SOME token' =>\n" ^
        "            if pred token'\n" ^
        "            then token'\n" ^
        "            else raise Fail ( \"unexpected \" ^ Input.Token.toString token'\n" ^
        "                            ^ \" at \" ^ Input.Pos.toString (Input.pos input) )\n" ^
        "         | NONE =>\n" ^
        "            raise Fail ( \"unexpected \" ^ Input.Token.lookaheadToString NONE" ^
        "                       ^ \" at \" ^ Input.Pos.toString (Input.pos input) )\n"

    val isPatternBranch =
        fn {lookaheads = Pattern _, ...} => true
         | {lookaheads = Predicate _, ...} => false
         | {lookaheads = Default, ...} => false

    val isPredicateBranch =
        fn {lookaheads = Pattern _, ...} => false
         | {lookaheads = Predicate _, ...} => true
         | {lookaheads = Default, ...} => false

    datatype stmt = Val of string * string
                  | Expr of string

    val stmtToString =
        fn Val (name, expr) => "val " ^ name ^ " = " ^ expr
         | Expr expr => "val _ = " ^ expr

    fun indent depth = String.concat (List.tabulate (depth, (fn _ => " ")))

    fun deeper depth = depth + 4

    fun rulesCode fiSets foSets grammar =
        let fun ntError name =
                "raise Fail (\"unexpected \" ^ Input.Token.lookaheadToString lookahead ^ \" in " ^ name ^
                " at \" ^ Input.Pos.toString (Input.pos input))"

            fun producteeCode depth name followSet =
                fn Alt alts =>
                    [Expr (branchesCode depth name followSet
                                              (List.map (fn clause as {productee, action = _} =>
                                                             { lookaheads = predictionSet (firstSet fiSets productee) followSet
                                                             , productees = [clause] })
                                                        alts))]
                 | Seq seq => seqCode depth name followSet seq
                 | productee as Named _ => #2 (namedCode depth name followSet productee)
                 | NonTerminal name => [Expr (name ^ " input")]
                 | Terminal lookahead =>
                    [Expr (case Lookahead.matchCode lookahead
                           of SOME (Matcher.ByValue const) => "match (" ^ const ^ ") input"
                            | SOME (Matcher.ByPred pred) => "matchPred (fn lookahead => " ^ pred "lookahead" ^ ") input"
                            | SOME Matcher.EOF => "matchEOF input"
                            | NONE => "()")]

            and seqCode depth name followSet seq =
                let fun step (productee, (stmts, followSet)) =
                        let val stmts' = producteeCode depth name followSet productee
                            val firsts = firstSet fiSets productee
                        in ( stmts @ stmts'
                           , predictionSet firsts followSet )
                        end
                in #1 (List.foldr step ([], followSet) seq)
                end

            and namedCode depth ntName followSet =
                fn Named (name, productee) =>
                    ( SOME name
                    , case namedCode depth ntName followSet productee
                      of (SOME name', stmts) => Val (name, name') :: stmts
                       | (NONE, Expr expr :: stmts) => Val (name, expr) :: stmts )
                 | productee => (NONE, producteeCode depth ntName followSet productee)

            and clauseCode depth name followSet {productee, action} =
                let val stmts = List.map stmtToString (List.rev (producteeCode depth name followSet productee))
                    val expr = case action
                               of SOME action => action
                                | NONE => "()"
                in case stmts
                   of [] => expr
                    | _ =>
                       "let " ^ String.concatWith ("\n" ^ indent (deeper depth)) stmts ^ "\n" ^
                       indent depth ^ "in " ^ expr ^ "\n" ^
                       indent depth ^ "end"
                end

            and branchCode depth name followSet {lookaheads = Pattern pat, productees = [productee]} =
                pat ^ " =>\n" ^ indent depth ^ clauseCode depth name followSet productee

            and predicateBranchesCode depth name followSet predBranches errorBody =
                case predBranches
                of {lookaheads = Predicate pred, productees = [productee]} :: predBranches =>
                    "if " ^ pred "lookahead" ^ " then\n" ^
                    indent (deeper depth) ^ clauseCode (deeper depth) name followSet productee ^ "\n" ^
                    indent depth ^ "else\n" ^
                    indent (deeper depth) ^ predicateBranchesCode (deeper depth) name followSet predBranches errorBody
                 | [] => errorBody

            (* FIXME: Detect conflicts *)
            and branchesCode depth name followSet branches =
                let val branches = List.map (fn {lookaheads, productees} =>
                                                 {lookaheads = LookaheadSet.patternCode lookaheads, productees})
                                            branches
                    val (patternBranches, predBranches) = List.partition isPatternBranch branches
                    val (predBranches, defaultBranches) = List.partition isPredicateBranch predBranches
                    val defaultBranch =
                        case defaultBranches
                        of [] => ntError name
                         | [{productees = [productee], ...}] => clauseCode (deeper depth) name followSet productee
                in case patternBranches
                   of [] =>
                       "let val lookahead = Input.peek input\n" ^
                       indent depth ^ "in  " ^ predicateBranchesCode (deeper depth) name followSet predBranches defaultBranch ^ "\n" ^
                       indent depth ^ "end"
                    | _ =>
                       "case Input.peek input\n" ^
                       indent depth ^ "of " ^ String.concatWith ("\n" ^ indent depth ^ " | ")
                                                                (List.map (branchCode (deeper depth) name followSet) patternBranches) ^ "\n" ^
                       indent depth ^ " | lookahead =>\n" ^
                       indent (deeper depth) ^ predicateBranchesCode (deeper depth) name followSet predBranches defaultBranch
                end

            fun ntCode depth name followSet branches =
                indent depth ^ "and " ^ name ^ " input =\n" ^
                indent (deeper depth) ^ branchesCode (deeper depth) name followSet branches
        in  StringMap.foldli (fn (name, branches, acc) =>
                                  let val followSet = StringMap.lookup (foSets, name)
                                  in acc ^ "\n\n" ^ ntCode (deeper 0) name followSet branches
                                  end)
                             "" grammar
        end

    fun recognizerRulesCode grammar startRule =
        let val (grammar, fiSets, foSets) = Analysis.analyze grammar startRule NONE
        in rulesCode fiSets foSets grammar
        end
end

functor ProperParsers(Args: PARSERS_ARGS where type Analysis.Analyzed.productee = ParserGrammar.productee) = struct
    datatype in_productee = datatype InputGrammar.productee
    datatype productee = datatype ParserGrammar.productee
    structure Analysis = Args.Analysis
    structure Parsers = NipoParsers(Args)
    open Parsers

    fun addTerminalTranslation ((canon, alias), terminals) =
        if StringMap.inDomain (terminals, canon)
        then raise Fail ("duplicate token " ^ canon)
        else let val terminals = StringMap.insert (terminals, canon, canon)
             in case alias
                of SOME alias =>
                    if StringMap.inDomain (terminals, alias)
                    then raise Fail ("duplicate token alias " ^ alias)
                    else StringMap.insert (StringMap.insert (terminals, canon, canon), alias, canon)
                 | NONE => terminals
             end

    fun terminalTranslation tokenCtors =
        List.foldl addTerminalTranslation StringMap.empty tokenCtors

    fun tParsedName canonName = "tok" ^ canonName

    fun ntParserName resName = "parse" ^ String.capitalize resName

    fun nameToAtom terminals name =
        case StringMap.find (terminals, name)
        of SOME canonName => Named (tParsedName canonName, Terminal (SOME canonName))
         | NONE => Named (name, NonTerminal (ntParserName name))

    fun convertAtoms terminals rules =
        let val rec convertProductee =
                fn InAlt alts => Alt (List.map convertClause alts)
                 | InSeq seq => Seq (List.map convertProductee seq)
                 | InNamed (name, productee) => Named (name, convertProductee productee)
                 | Var name =>
                    if Char.isUpper (String.sub (name, 0))
                    then nameToAtom terminals name
                    else Named (name, NonTerminal (ntParserName name))
                 | Lit name => nameToAtom terminals name

            and convertClause = fn {productee, action} =>
                {productee = convertProductee productee, action}

            fun convertNt (name, clauses) =
                (ntParserName name, List.map convertClause clauses)
        in List.map convertNt rules
        end

    fun ctorPredicateDef (ctor, _) =
        "val is" ^ ctor ^ " = fn " ^ ctor ^ " _ => true | _ => false"

    fun ctorPredicates tokenCtors =
        "    " ^ String.concatWith "\n    " (List.map ctorPredicateDef tokenCtors)

    val matchEOFCode =
        "    fun matchEOF input =\n" ^
        "        case Input.pop input\n" ^
        "        of NONE => ()\n" ^
        "         | SOME token' =>\n" ^
        "            raise Fail ( \"expected \" ^ Input.Token.lookaheadToString NONE\n" ^
        "                       ^ \", got \" ^ Input.Token.toString token'" ^
        "                       ^ \" at \" ^ Input.Pos.toString (Input.pos input) )\n"

    fun parserCode ({parserName, tokenType, tokenCtors, support, rules, startRule}: InputGrammar.parser) =
        let val internalStartName = "start__" ^ startRule
            val rules = convertAtoms (terminalTranslation tokenCtors) rules
            val (grammar, fiSets, foSets) = Analysis.analyze rules (ntParserName startRule) (SOME internalStartName)
        in "functor " ^ parserName ^ "(Input: NIPO_PARSER_INPUT where type Token.t = " ^ tokenType ^ ") = struct\n" ^
           "    " ^ support ^ "\n\n" ^
           ctorPredicates tokenCtors ^ "\n\n" ^
           matchPredCode ^ "\n\n" ^
           matchEOFCode ^
           rulesCode fiSets foSets grammar ^
           "end"
        end
end


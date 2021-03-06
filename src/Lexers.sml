signature LEXERS = sig
    structure Token: LEXEME
    structure Grammar: GRAMMAR where type Token.t = Token.t

    val lexerCode: InputGrammar.lexer -> string
end

functor NipoLexers(Args: sig
    structure Token: LEXEME where type t = CharClass.t
    structure Grammar: GRAMMAR
        where type Token.t = Token.t
        where type productee = LexerGrammar.productee
    structure Parsers: PARSERS where type Grammar.productee = Grammar.productee
end) :> LEXERS
    where type Token.t = Args.Token.t
    where type Grammar.productee = Args.Grammar.productee
= struct
    datatype in_productee = datatype InputGrammar.productee
    datatype productee = datatype LexerGrammar.productee
    
    structure Token = Args.Token
    structure Grammar = Args.Grammar
    structure Parsers = Args.Parsers

    fun convertAtoms grammar =
        let fun convertProductee {pos, v} =
                { pos
                , v = case v
                      of InAlt alts => Alt (List.map convertClause alts)
                       | InSeq seq => Seq (List.map convertProductee seq)
                       | InOpt inner => Opt (convertProductee inner)
                       | InMany inner => Many (convertProductee inner)
                       | InMany1 inner => Many1 (convertProductee inner)
                       | Var name => NonTerminal name
                       | Lit name =>
                          let val c = case Char.fromString name
                                      of SOME c => c
                                       | NONE => raise Fail ("Bad char literal '" ^ name ^ "'") (* HACK *)
                          in Terminal (SOME (CharClass.Singleton c))
                          end
                       | Posix "alpha" => Terminal (SOME (CharClass.Posix CharClass.Alpha))
                       | Posix "digit" => Terminal (SOME (CharClass.Posix CharClass.Digit))
                       | Posix "space" => Terminal (SOME (CharClass.Posix CharClass.Space))
                       | Complement atom =>
                          (case convertProductee atom
                           of {pos, v = Terminal (SOME cc)} => Terminal (SOME (CharClass.Not cc)))
                       | InNamed (name, atom) => Named (name, convertProductee atom)
                       | InPos => Pos }
            
            and convertClause {productee, action} =
                {productee = convertProductee productee, action}

            fun convertNt (name, clauses) =
                (name, List.map convertClause clauses)
        in List.map convertNt grammar
        end

    fun extractActions grammar startRule =
        let val actions = ref []
            val actionCount = ref 0
            fun extractPredicteeActions name (predictee as {productee, action}) =
                case action
                of SOME action =>
                    let do if name <> startRule
                           then raise Fail ( "Action code in non-start lexer rule " ^ name
                                           ^ ": " ^ action )
                           else ()
                        val actionIndex = !actionCount
                    in actions := action :: !actions
                     ; actionCount := actionIndex + 1
                     ; {productee, action = SOME (Int.toString actionIndex)}
                    end
                 | NONE => predictee
            val grammar = List.map (fn (name, predictees) =>
                                        (name, List.map (extractPredicteeActions name) predictees))
                                   grammar
        in {grammar, actions = List.rev (!actions)}
        end

    fun actionTableCode actions =
        "    val actions =\n" ^
        "        Vector.fromList [ " ^ String.concatWith "\n                        , " actions ^ " ]\n"

    fun driverCode startName whitespaceRule =
        "    fun next input =\n" ^
        "        ( " ^ whitespaceRule ^ " input\n" ^
        "        ; Option.map (fn _ =>\n" ^
        "                          let val startPos = Input.pos input\n" ^
        "                              val startMark = Input.checkpoint input\n" ^
        "                              val actionIndex = " ^ startName ^ " input\n" ^
        "                              val endPos = Input.pos input\n" ^
        "                              val endMark = Input.checkpoint input\n" ^
        "                              val _ = Input.reset (input, startMark)\n" ^
        "                              val len = #index endPos - #index startPos\n" ^
        "                              (* Slightly breach abstraction to avoid recomputing `endPos`: *)\n" ^
        "                             val recognizedPrefix = Input.Inner.inputN (Input.toInner input, len)\n" ^
        "                             val _ = Input.reset (input, endMark)\n" ^
        "                          in Vector.sub (actions, actionIndex) (startPos, recognizedPrefix, endPos)\n" ^
        "                          end)\n" ^
        "                     (Input.peek input) )\n"

    fun lexerCode {lexerName, tokenType, support, rules, startRule, whitespaceRule} =
        let val rules = convertAtoms rules
            val {grammar, actions} = extractActions rules startRule
        in  "functor " ^ lexerName ^ "(Args: sig\n" ^
            "    structure Input: NIPO_LEXER_INPUT\n" ^
            "    structure Token: NIPO_POSITIONED_TOKEN where type t = " ^ tokenType ^ "\n" ^
            "end) :> NIPO_LEXER\n" ^
            "    where type Input.stream = Args.Input.stream\n" ^
            "    where type Input.checkpoint = Args.Input.checkpoint\n" ^
            "    where type Token.t = " ^ tokenType ^ "\n" ^
            "= struct\n" ^
            "    structure Input = Args.Input\n" ^
            "    structure Token = Args.Token\n\n" ^
            "    " ^ support ^ "\n\n" ^
            Parsers.matchCode ^ "\n\n" ^
            Parsers.matchPredCode ^
            Parsers.recognizerRulesCode grammar startRule (SOME whitespaceRule) ^ "\n\n" ^
            actionTableCode actions ^ "\n" ^
            driverCode startRule whitespaceRule ^
            "end\n"
        end
end


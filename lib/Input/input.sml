signature NIPO_TOKEN = sig
    type t
    type vector

    val toString: t -> string
end

signature NIPO_INPUT = sig
    type stream

    structure Token: NIPO_TOKEN

    val peek: stream -> Token.t option
    val pop: stream -> Token.t option
    val inputN: stream * int -> Token.vector
end

signature RESETABLE_NIPO_INPUT = sig
    include NIPO_INPUT

    type checkpoint

    val checkpoint: stream -> checkpoint
    val reset: stream * checkpoint -> unit
end

signature NIPO_LEXER_INPUT = RESETABLE_NIPO_INPUT
    where type Token.t = char


structure NipoStringInput :> RESETABLE_NIPO_INPUT
    where type stream = char VectorSlice.slice ref
    where type Token.t = char
    where type Token.vector = string
= struct
    type stream = char VectorSlice.slice ref
    type checkpoint = int

    structure Token = struct
        type t = char
        type vector = string
        
        val compare = Char.compare
        fun toString c = Char.toString c
    end

    fun peek (ref cs) =
        Option.map #1 (VectorSlice.getItem cs)

    fun pop (input as ref cs) =
        Option.map (fn (c, cs) => (input := cs; c))
                   (VectorSlice.getItem cs)

    fun inputN (input as ref cs, n) =
        let val len = VectorSlice.length cs
        in if n <= len
           then ( input := VectorSlice.subslice (cs, n, NONE)
                ; VectorSlice.vector (VectorSlice.subslice (cs, 0, SOME n)) )
           else ( input := VectorSlice.subslice (cs, len, NONE)
                ; VectorSlice.vector (VectorSlice.subslice (cs, 0, NONE)) )
        end

    fun checkpoint (ref cs) = #2 (VectorSlice.base cs)

    fun reset (stream, mark) =
        stream := VectorSlice.slice (#1 (VectorSlice.base (!stream)), mark, NONE)
end


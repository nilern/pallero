structure NipoTokens = struct
    datatype token = Eq of Pos.t
                   | Bar of Pos.t
                   | LBrace of Pos.t
                   | RBrace of Pos.t
                   | Semi of Pos.t

    val toString =
        fn Eq _ => "="
         | Bar _ => "|"
         | LBrace _ => "{"
         | RBrace _ => "}"
         | Semi _ => ";"
end

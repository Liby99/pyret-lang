provide {
    parse-pattern: parse-pattern,
    parse-ast: parse-ast,
    parse-ds-rules: parse-ds-rules,
} end

include either

include file("ds-structs.arr")

# Important! The parser must not backtrack too much, or else
# it will take exponential time, and the ellipsis counter will skip numbers.


################################################################################
#  Errors
#

fun parse-error(message :: String):
  raise({"Failed to parse sugar definitions file"; message})
end


################################################################################
#  Tokenization
#

WHITESPACE = [list: " ", "\t", "\n"]
SPECIAL-TOKENS = [list: ",", "|", ";", ":", "(", ")", "[", "]", "{", "}", "@"]

data Token:
  | t-str(tok :: String)
  | t-num(tok :: Number)
  | t-symbol(tok :: String)
  | t-name(tok :: String)
end

fun tokenize(input :: String) -> List<Token> block:
  var token :: String = ""
  var tokens :: List<Token> = [list:]
  var in-string :: Boolean = false

  fun token-break():
    when token <> "" block:
      the-token =
        if string-char-at(token, 0) == '"':
          t-str(string-substring(token, 1, string-length(token) - 1))
        else if SPECIAL-TOKENS.member(token):
          t-symbol(token)
        else:
          cases (Option) string-to-number(token):
            | none      =>
              if token == "...":
                t-symbol(token)
              else:
                t-name(token)
              end
            | some(num) => t-num(num)
          end
        end
      tokens := link(the-token, tokens)
      token := ""
    end
  end

  for each(char from string-explode(input)) block:
    if in-string block:
      token := token + char
      when char == '"' block:
        token-break()
        in-string := false
      end
    else:
      if WHITESPACE.member(char) block:
        token-break()
      else if SPECIAL-TOKENS.member(char):
        token-break()
        token := char
        token-break()
      else if char == '"':
        token-break()
        token := char
        in-string := true
        nothing
      else:
        token := token + char
        nothing
      end
    end
    nothing
  end

  when in-string:
    parse-error("Unterminated string.")
  end
  token-break()
  tokens.reverse()
where:
  #init = time-now()
  #input = string-repeat("[(define-struct    name:Var\t fields:StructFields) @rest:SurfStmts]", 1000)
  #tokenize(input)
  #print(time-now() - init)
  shadow input = "[(define-struct    name:Var\t fields:StructFields ...) @rest:SurfStmts]"
  tokenize(input)
    is [list: t-symbol("["), t-symbol("("), t-name("define-struct"), t-name("name"),
    t-symbol(":"), t-name("Var"), t-name("fields"), t-symbol(":"), t-name("StructFields"),
    t-symbol("..."), t-symbol(")"), t-symbol("@"), t-name("rest"), t-symbol(":"),
    t-name("SurfStmts"), t-symbol("]")]
  shadow input = '{Lambda l 55/6(CONCAT "for-body \n<" (\nFORMAT l false) ">")}'
  tokenize(input)
    is [list: t-symbol("{"), t-name("Lambda"), t-name("l"), t-num(55/6),
    t-symbol("("), t-name("CONCAT"), t-str("for-body \n<"), t-symbol("("),
    t-name("FORMAT"), t-name("l"), t-name("false"), t-symbol(")"), t-str(">"),
    t-symbol(")"), t-symbol("}")]
end





################################################################################
#  Parsing
#

type Parser<A> = (List<Token> -> Option<{A; List<Token>}>)

fun run-parser<A>(parser :: (List<Token> -> Option<{A; List<Token>}>), input :: String) -> A:
  tokens = tokenize(input)
  cases (Option) parser(tokens):
    | none => parse-error("Failed to parse")
    | some({res; shadow tokens}) =>
      if tokens == empty:
        res
      else:
        parse-error("Expected end of file")
      end
  end
end

fun parser-empty(tokens :: List<Token>) -> Option<{Nothing; List<Token>}>:
  some({nothing; tokens})
end

fun parser-const<A>(expected :: Token, value :: A) -> (List<Token> -> Option<{A; List<Token>}>):
  lam(tokens :: List<Token>) -> Option<{A; List<Token>}>:
    cases (List) tokens:
      | link(token, rest) =>
        if token == expected:
          some({value; rest})
        else:
          none
        end
      | empty => none
    end
  end
end

fun parser-ignore(expected :: Token) -> (List<Token> -> Option<{Nothing; List<Token>}>):
  parser-const(expected, nothing)
end

fun parser-pred<A>(pred :: (Token -> Option<A>)) -> (List<Token> -> Option<{A; List<Token>}>):
  lam(tokens :: List<Token>) -> Option<{A; List<Token>}>:
    cases (List) tokens:
      | link(token, rest) =>
        cases (Option) pred(token):
          | none => none
          | some(a) => some({a; rest})
        end
      | empty => none
    end
  end
end

fun parser-choices<A>(choices :: List<(List<Token> -> Option<{A; List<Token>}>)>) -> (List<Token> -> Option<{A; List<Token>}>):
  lam(tokens :: List<Token>) -> Option<{A; List<Token>}>:
    cases (List) choices:
      | empty => none
      | link(choice, shadow choices) =>
        cases (Option) choice(tokens):
          | some(answer) => some(answer)
          | none => parser-choices(choices)(tokens)
        end
    end
  end
end

fun parser-chain<A, B>(
    f :: (A -> Parser<B>),
    parser :: Parser<A>)
  -> Parser<B>:
  lam(tokens :: List<Token>) -> Option<{B; List<Token>}>:
    cases (Option) parser(tokens):
      | none => none
      | some({a; shadow tokens}) => f(a)(tokens)
    end
  end
end

fun parser-1<A, B>(
    func :: (A -> B),
    parser :: (List<Token> -> Option<{A; List<Token>}>))
  -> (List<Token> -> Option<{B; List<Token>}>):
  lam(tokens :: List<Token>) -> Option<{B; List<Token>}>:
    cases (Option) parser(tokens):
      | none => none
      | some({a; shadow tokens}) =>
        some({func(a); tokens})
    end
  end
end

fun parser-2<A, B, C>(
    join :: (A, B -> C),
    first :: (List<Token> -> Option<{A; List<Token>}>),
    second :: (List<Token> -> Option<{B; List<Token>}>))
  -> (List<Token> -> Option<{C; List<Token>}>):
  for parser-chain(a from first):
    for parser-1(b from second):
      join(a, b)
    end
  end
end

fun parser-3<A, B, C, D>(
    join :: (A, B, C -> D),
    first :: (List<Token> -> Option<{A; List<Token>}>),
    second :: (List<Token> -> Option<{B; List<Token>}>),
    third :: (List<Token> -> Option<{C; List<Token>}>))
  -> (List<Token> -> Option<{D; List<Token>}>):
  for parser-chain(a from first):
    for parser-chain(b from second):
      for parser-1(c from third):
        join(a, b, c)
      end
    end
  end
end

fun parser-4<A, B, C, D, E>(
    join :: (A, B, C, D -> E),
    first :: (List<Token> -> Option<{A; List<Token>}>),
    second :: (List<Token> -> Option<{B; List<Token>}>),
    third :: (List<Token> -> Option<{C; List<Token>}>),
    fourth :: (List<Token> -> Option<{D; List<Token>}>))
  -> (List<Token> -> Option<{E; List<Token>}>):
  for parser-chain(a from first):
    for parser-chain(b from second):
      for parser-chain(c from third):
        for parser-1(d from fourth):
          join(a, b, c, d)
        end
      end
    end
  end
end

fun parser-5<A, B, C, D, E, F>(
    join :: (A, B, C, D, E -> F),
    first :: (List<Token> -> Option<{A; List<Token>}>),
    second :: (List<Token> -> Option<{B; List<Token>}>),
    third :: (List<Token> -> Option<{C; List<Token>}>),
    fourth :: (List<Token> -> Option<{D; List<Token>}>),
    fifth :: (List<Token> -> Option<{E; List<Token>}>))
  -> (List<Token> -> Option<{F; List<Token>}>):
  for parser-chain(a from first):
    for parser-chain(b from second):
      for parser-chain(c from third):
        for parser-chain(d from fourth):
          for parser-1(e from fifth):
            join(a, b, c, d, e)
          end
        end
      end
    end
  end
end

fun parser-seq<A>(parser :: (List<Token> -> Option<{A; List<Token>}>)) -> (List<Token> -> Option<{List<A>; List<Token>}>):
  lam(tokens :: List<Token>) -> Option<{A; List<Token>}>:
    cases (Option) parser(tokens):
      | none => some({empty; tokens})
      | some({res; shadow tokens}) =>
        cases (Option) parser-seq(parser)(tokens):
          | none => panic("parser-seq: recursive call should have succeeded")
          | some({lst; shadow tokens}) => some({link(res, lst); tokens})
        end
    end
  end
end

fun parser-left<A, B>(parser :: (List<Token> -> Option<{A; List<Token>}>)) -> (List<Token> -> Option<{Either<A, B>; List<Token>}>):
  lam(tokens :: List<Token>) -> Option<{Either<A, B>; List<Token>}>:
    cases (Option) parser(tokens):
      | none => none
      | some({res; shadow tokens}) =>  some({left(res); tokens})
    end
  end
end

fun parser-right<A, B>(parser :: (List<Token> -> Option<{B; List<Token>}>)) -> (List<Token> -> Option<{Either<A, B>; List<Token>}>):
  lam(tokens :: List<Token>) -> Option<{Either<A, B>; List<Token>}>:
    cases (Option) parser(tokens):
      | none => none
      | some({res; shadow tokens}) =>  some({right(res); tokens})
    end
  end
end

parser-name = parser-pred(lam(tok):
    cases (Token) tok:
      | t-name(name) => some(name)
      | else => none
    end
  end)

parser-name-list =
  for parser-3(
      _ from parser-ignore(t-symbol("[")),
      names from parser-seq(parser-name),
      _ from parser-ignore(t-symbol("]"))):
    names
  end

fun parser-pattern(pvars :: Option<Set<String>>) 
  -> (List<Token> -> Option<{Pattern; List<Token>}>):

  var label-counter = 0

  fun is-pvar(name :: String) -> Boolean:
    cases (Option) pvars:
      | none => true
      | some(shadow pvars) => pvars.member(name)
    end
  end

  parser-pvar-name = parser-pred(lam(tok):
      cases (Token) tok:
        | t-name(name) =>
          if is-pvar(name):
            some(name)
          else:
            none
          end
        | else => none
      end
    end)

  parser-pvar = parser-choices([list:
      for parser-3(
          pvar from parser-pvar-name,
          _ from parser-ignore(t-symbol(":")),
          typ from parser-name):
        p-pvar(pvar, some(typ))
      end,
      for parser-1(pvar from parser-pvar-name):
        p-pvar(pvar, none)
      end
    ])

  parser-var = for parser-1(name from parser-name):
    p-var(name)
  end

  fun parser-patt():
    rec-pattern = lam(toks): parser-patt()(toks) end
    rec-list = lam(toks): parser-list-body()(toks) end

    parser-choices([list:
        parser-const(t-name("none"), p-option(none)),
        parser-const(t-name("true"), p-value(g-bool(true))),
        parser-const(t-name("false"), p-value(g-bool(false))),
        # Number
        parser-pred(lam(tok):
            cases (Token) tok:
              | t-num(n) => some(p-value(g-num(n)))
              | else => none
            end
          end),
        # String
        parser-pred(lam(tok): # string
            cases (Token) tok:
              | t-str(s) => some(p-value(g-str(s)))
              | else => none
            end
          end),
        # Pattern var
        parser-pvar,
        # Variable
        parser-var,
        # Some
        for parser-4(
            _ from parser-ignore(t-symbol("{")),
            _ from parser-ignore(t-name("some")),
            arg from rec-pattern,
            _ from parser-ignore(t-symbol("}"))):
          p-option(some(arg))
        end,
        # Fresh
        for parser-5(
            _ from parser-ignore(t-symbol("(")),
            _ from parser-ignore(t-name("fresh")),
            names from parser-name-list,
            body from rec-pattern,
            _ from parser-ignore(t-symbol(")"))):
          p-fresh(list-to-set(names), body)
        end,
        # Aux
        for parser-4(
            _ from parser-ignore(t-symbol("{")),
            name from parser-name,
            args from parser-seq(rec-pattern),
            _ from parser-ignore(t-symbol("}"))):
          p-aux(name, args)
        end,
        # Surface
        for parser-4(
            _ from parser-ignore(t-symbol("(")),
            name from parser-name,
            args from parser-seq(rec-pattern),
            _ from parser-ignore(t-symbol(")"))):
          p-surf(name, args)
        end,
        # List
        for parser-3(
            _ from parser-ignore(t-symbol("[")),
            body from rec-list,
            _ from parser-ignore(t-symbol("]"))):
          p-list(body)
        end
      ])
  end

  fun parser-list-body():
    rec-pattern = lam(toks): parser-patt()(toks) end
    rec-list = lam(toks): parser-list-body()(toks) end

    parser-choices([list:
        # Ellipsis
        for parser-2(
            patt from rec-pattern,
            either-ellipsis-or-cons :: Either<Nothing, SeqPattern> from parser-choices([list: 
                parser-left(parser-ignore(t-symbol("..."))),
                parser-right(rec-list)
              ])):
          cases (Either) either-ellipsis-or-cons:
            | left(_) => seq-ellipsis(patt, next-label())
            | right(body) => seq-cons(patt, body)
          end
        end,
        for parser-1(_ from parser-empty):
          seq-empty
        end
      ])
  end

  fun next-label() -> String block:
    label-counter := label-counter + 1
    "l" + tostring(label-counter)
  end
  
  parser-patt()
end

fun parse-pattern(pvars :: Option<Set<String>>, input :: String) -> Pattern:
  run-parser(parser-pattern(pvars), input)
where:
  parse-pattern(none, "3")
    is p-value(g-num(3))
  parse-pattern(none, "(foo 1 2)")
    is p-surf("foo", [list: p-value(g-num(1)), p-value(g-num(2))])
  parse-pattern(none, "[[a b] ...]")
    is p-list(seq-ellipsis(p-list(seq-cons(p-pvar("a", none), seq-cons(p-pvar("b", none), seq-empty))), "l1"))
  parse-pattern(none, "[a b ...]")
    is p-list(seq-cons(p-pvar("a", none), seq-ellipsis(p-pvar("b", none), "l1")))
  parse-pattern(some([set: "a"]), "{c-abc {some a} b}")
    is p-aux("c-abc", [list: p-option(some(p-pvar("a", none))), p-var("b")])

  parse-pattern(none, "[[a ...] [b ...]]") 
    is p-list(seq-cons(p-list(seq-ellipsis(p-pvar("a", none), "l1")), 
      seq-cons(p-list(seq-ellipsis(p-pvar("b", none), "l2")), seq-empty)))
end

parse-lhs = parse-pattern(none, _)

fun parse-rhs(pvars :: Set<String>, input :: String) -> Pattern:
  parse-pattern(some(pvars), input)
end

fun parse-ast(input :: String) -> Term:
  pattern = parse-pattern(some([set:]), input)
  fun pattern-to-ast(shadow pattern :: Pattern) -> Term:
    cases (Pattern) pattern:
      | p-value(v) => g-value(v)
      | p-pvar(_, _) => panic("parse-ast: unexpected pvar")
      | p-var(v) => g-var(naked-var(v))
      | p-core(name, args) => g-core(name, none, args.map(pattern-to-ast))
      | p-aux(name,  args) => g-aux(name,  none, args.map(pattern-to-ast))
      | p-surf(name, args) => g-surf(name, none, args.map(pattern-to-ast))
      | p-list(seq) => g-list(list-to-ast(seq))
      | p-option(opt) => 
        cases (Option) opt:
          | none => none
          | some(p) => some(pattern-to-ast(p))
        end ^ g-option
      | p-tag(lhs, rhs, body) => g-tag(lhs, rhs, pattern-to-ast(body))
      | p-fresh(_, _) => panic("parse-ast: unexpected fresh")
    end
  end
  fun list-to-ast(seq :: SeqPattern) -> List<Term>:
    cases (SeqPattern) seq:
      | seq-ellipsis(_, _) => panic("Unexpected `...` in Term")
      | seq-empty => empty
      | seq-cons(p, shadow seq) => link(pattern-to-ast(p), list-to-ast(seq))
      | seq-ellipsis-list(_, _) =>
        panic("Unexpected ellipsis list in Term")
    end
  end
  pattern-to-ast(pattern)
end

fun gather-pvars(p :: Pattern) -> Set<String>:
  cases (Pattern) p:
    | p-pvar(name, _) => [set: name]
    | p-value(_) => [set: ]
    | p-var(_) => [set: ]
    | p-core(_, args) => gather-pvars-list(args)
    | p-surf(_, args) => gather-pvars-list(args)
    | p-aux(_,  args) => gather-pvars-list(args)
    | p-list(seq) => gather-pvars-seq(seq)
    | p-option(opt) =>
      cases (Option) opt:
        | none => [set: ]
        | some(shadow p) => gather-pvars(p)
      end
    | p-tag(_, _, body) => gather-pvars(body)
    | p-fresh(_, body) => gather-pvars(body)
  end
end

fun gather-pvars-seq(seq :: SeqPattern) -> Set<String>:
  cases (SeqPattern) seq:
    | seq-empty => [set: ] 
    | seq-cons(p, shadow seq) => gather-pvars(p).union(gather-pvars-seq(seq))
    | seq-ellipsis(p, _) => gather-pvars(p)
    | seq-ellipsis-list(lst, _) => gather-pvars-list(lst)
  end
end

fun gather-pvars-list(ps :: List<Pattern>) -> Set<String>:
  for fold(acc from [set: ], p from ps):
    acc.union(gather-pvars(p))
  end
end

parser-ds-rule-case =
  for parser-chain(_ from parser-ignore(t-symbol("|"))):
    for parser-chain(lhs from parser-pattern(none)):
      for parser-chain(_ from parser-ignore(t-name("=>"))):
        pvars = gather-pvars(lhs)
        for parser-1(rhs from parser-pattern(some(pvars))):
          ds-rule-case(lhs, rhs)
        end
      end
    end
  end

parser-ds-rule =
  for parser-5(
      _ from parser-ignore(t-name("sugar")),
      op from parser-name,
      _ from parser-ignore(t-symbol(":")),
      kases from parser-seq(parser-ds-rule-case),
      _ from parser-ignore(t-name("end"))):
    ds-rule(op, kases)
  end

parser-ds-rules = parser-seq(parser-ds-rule)

fun parse-ds-rules(input :: String) -> List<DsRule>:
  run-parser(parser-ds-rules, input)
where:
  parse-ds-rules("sugar and: | (and) => (and) end")
    is [list: ds-rule("and", [list:
        ds-rule-case(parse-lhs("(and)"), parse-lhs("(and)"))])]
  parse-ds-rules(
    ```
    sugar or: 
    | (or a:Expr b) => (let (bind x a) (if x x b))
    end
    ```) is [list:
    ds-rule("or", [list:
        ds-rule-case(
          p-surf("or", [list: p-pvar("a", some("Expr")), p-pvar("b", none)]), 
          p-surf("let", [list: 
              p-surf("bind", [list: p-var("x"), p-pvar("a", none)]),
              p-surf("if", [list: p-var("x"), p-var("x"), p-pvar("b", none)])]))])]
end
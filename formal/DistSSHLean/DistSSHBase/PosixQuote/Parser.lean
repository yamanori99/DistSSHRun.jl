/-!
# POSIX sh word parser (subset for `posix_quote`)

Lean model of single-quote / backslash / IFS word tokenization used to parse
`DistSSHBase.posix_quote` output. Total `step` state machine (`termination_by cs.length`).
-/

namespace DistSSHLean.DistSSHBase.PosixQuote

/-- IFS whitespace terminates an unquoted word (POSIX §2.6.5). -/
def isIfs (c : Char) : Bool :=
  c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\x0b' || c == '\x0c'

/-- Parser state: unquoted vs inside single quotes. -/
inductive St where
  | unq : St
  | sq : St

private theorem list_drop1_lt (c : Char) (rest : List Char) :
    rest.length < (c :: rest).length := by simpa using Nat.lt_succ_self rest.length

private theorem list_drop2_lt (c₁ c₂ : Char) (rest : List Char) :
    rest.length < (c₁ :: c₂ :: rest).length := by
  simpa [List.length, Nat.succ_eq_add_one] using
    Nat.lt_of_lt_of_le (Nat.lt_succ_self rest.length) (Nat.le_add_right _ 1)

/--
Read one POSIX sh word: `acc` holds chars in reverse; result is `acc.reverse` and unconsumed input.
-/
def step (st : St) (cs acc : List Char) : Option (List Char × List Char) :=
  match st, cs with
  | _, [] =>
    match st with
    | St.unq => some (acc.reverse, [])
    | St.sq => none
  | St.unq, '\'' :: rest => step St.sq rest acc
  | St.unq, '\\' :: [] => none
  | St.unq, '\\' :: c' :: rest => step St.unq rest (c' :: acc)
  | St.unq, c :: rest =>
    if isIfs c then some (acc.reverse, c :: rest) else step St.unq rest (c :: acc)
  | St.sq, '\'' :: rest => step St.unq rest acc
  | St.sq, c :: rest => step St.sq rest (c :: acc)
termination_by cs.length
decreasing_by
  simp_wf
  all_goals first
    | exact list_drop2_lt _ _ _
    | exact list_drop1_lt _ _
    | exact list_drop1_lt _ _
    | exact list_drop1_lt _ _

/-- Parse one word starting unquoted (same role as the former `wordCore`). -/
def wordCore (cs acc : List Char) : Option (List Char × List Char) :=
  step St.unq cs acc

/--
Skip leading IFS, parse exactly one word, and require no trailing non-IFS input
(`rest'.isEmpty` after `dropWhile isIfs` on the remainder of `wordCore`).
Single-word roundtrip theorems use this check; `shParseWord` only exposes the word.
-/
def shParseWordChars (cs : List Char) : Option (List Char) :=
  let cs := cs.dropWhile isIfs
  if cs.isEmpty then none
  else
    match wordCore cs [] with
    | none => none
    | some (w, rest) =>
      let rest' := rest.dropWhile isIfs
      if rest'.isEmpty then some w else none

def shParseWord (s : String) : Option String :=
  (shParseWordChars s.toList).map String.ofList

def escapeChar (c : Char) : List Char :=
  if c == '\'' then ['\'', '\\', '\'', '\''] else [c]

def qb : List Char → List Char
  | [] => []
  | c :: cs => escapeChar c ++ qb cs

def posixQuoteOkChars (cs : List Char) : List Char :=
  '\'' :: qb cs ++ ['\'']

def posixQuoteOk (s : String) : String :=
  String.ofList (posixQuoteOkChars s.toList)

def containsNul (s : String) : Bool :=
  s.any (· = '\x00')

/-- Decoder for `qb` (proofs only; not linked to Julia `posix_quote`). -/
def decQb : List Char → Option (List Char)
  | '\'' :: '\\' :: '\'' :: '\'' :: rest => decQb rest >>= fun t => some ('\'' :: t)
  | '\'' :: _ => none
  | [] => some []
  | c :: rest => decQb rest >>= fun t => some (c :: t)

def posixQuote (s : String) : Option String :=
  if containsNul s then none else some (posixQuoteOk s)

def posixQuoteSourceFile : String := "lib/DistSSHBase/src/ssh/ssh.jl"

end DistSSHLean.DistSSHBase.PosixQuote
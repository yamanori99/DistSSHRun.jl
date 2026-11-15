import DistSSHLean.DistSSHBase.PosixQuote.Parser
import DistSSHLean.Registry.Types

namespace DistSSHLean.DistSSHBase.PosixQuote

open DistSSHLean

theorem decQb_qb : ∀ cs, decQb (qb cs) = some cs := by
  intro cs
  induction cs with
  | nil => rfl
  | cons c cs ih =>
    by_cases h : c = '\''
    · subst h; simp [qb, escapeChar, decQb, ih]
    · simp [qb, escapeChar, decQb, h, ih]

def posixQuoteNulProp : Prop :=
  ∀ s : String, containsNul s → posixQuote s = none

theorem posixQuote_nul : posixQuoteNulProp := by
  intro s h
  simp [posixQuote, h]

def posixQuoteNoNulProp : Prop :=
  ∀ s : String, ¬containsNul s → posixQuote s = some (posixQuoteOk s)

theorem posixQuote_no_nul : posixQuoteNoNulProp := by
  intro s h
  simp [posixQuote, h]

/-! ### `step` on `posixQuoteOkChars` -/

private theorem step_sq_close (acc : List Char) :
    step St.sq ('\'' :: []) acc = some (acc.reverse, []) := by
  simp only [step]

private theorem step_sq_cons_ne (c : Char) (rest acc : List Char) (h : c ≠ '\'') :
    step St.sq (c :: rest) acc = step St.sq rest (c :: acc) := by
  by_cases hc : c == '\''
  · have : c = '\'' := by simpa [beq_iff_eq] using hc
    exact absurd this h
  · simp only [step]

private theorem step_sq_quoteEmbed (cs acc : List Char) :
    step St.sq ('\'' :: '\\' :: '\'' :: '\'' :: qb cs ++ '\'' :: []) acc =
      step St.sq (qb cs ++ '\'' :: []) ('\'' :: acc) := by
  simp only [List.cons_append, step]

theorem step_sq_qb (cs acc : List Char) :
    step St.sq (qb cs ++ '\'' :: []) acc = some (acc.reverse ++ cs, []) := by
  induction cs generalizing acc with
  | nil =>
    simp only [qb, List.nil_append, step_sq_close, List.append_nil]
  | cons c cs ih =>
    by_cases h : c = '\''
    · subst h
      simp only [qb, escapeChar, beq_iff_eq, ↓reduceIte, List.cons_append, List.nil_append]
      have harr :
          '\'' :: '\\' :: '\'' :: '\'' :: (qb cs ++ '\'' :: []) =
            '\'' :: '\\' :: '\'' :: '\'' :: qb cs ++ '\'' :: [] := by
        simp [List.cons_append]
      rw [harr, step_sq_quoteEmbed, ih]
      congr 1 <;> simp [List.reverse_cons, List.cons_append]
    · have hb : (c == '\'') = false := beq_eq_false_iff_ne.2 h
      simp only [qb, escapeChar, hb, Bool.false_eq_true, ↓reduceIte, List.cons_append, List.nil_append]
      rw [step_sq_cons_ne c (qb cs ++ '\'' :: []) acc h, ih (c :: acc)]
      congr 1 <;> simp [List.reverse_cons, List.cons_append]

theorem wordCore_posixQuoteOkChars (cs acc : List Char) :
    wordCore (posixQuoteOkChars cs) acc = some (acc.reverse ++ cs, []) := by
  simpa [wordCore, posixQuoteOkChars, step, St.unq] using step_sq_qb cs acc

private theorem not_ifs_quote : ¬isIfs '\'' := by decide

private theorem posixQuoteOkChars_dropWhile (cs : List Char) :
    List.dropWhile isIfs (posixQuoteOkChars cs) = posixQuoteOkChars cs := by
  simpa [posixQuoteOkChars, List.append_assoc, List.cons_append] using
    List.dropWhile_cons_of_neg (p := isIfs) (a := '\'') (l := qb cs ++ ['\'']) not_ifs_quote

def posixQuoteRoundtripCharsProp : Prop :=
  ∀ cs : List Char, shParseWordChars (posixQuoteOkChars cs) = some cs

theorem posixQuote_roundtrip_chars : posixQuoteRoundtripCharsProp := by
  intro cs
  unfold shParseWordChars
  rw [posixQuoteOkChars_dropWhile]
  have hnempty : (posixQuoteOkChars cs).isEmpty = false := by
    simp [posixQuoteOkChars, List.isEmpty_cons]
  simp only [hnempty, Bool.false_eq_true, ↓reduceIte]
  have hcore := wordCore_posixQuoteOkChars cs []
  simp only [hcore, List.reverse_nil, List.nil_append, List.dropWhile_nil, List.isEmpty_nil, ↓reduceIte]

def posixQuoteRoundtripProp : Prop :=
  ∀ s : String, ¬containsNul s → shParseWord (posixQuoteOk s) = some s

theorem posixQuote_roundtrip : posixQuoteRoundtripProp := by
  intro s _
  have h : shParseWordChars (posixQuoteOkChars s.toList) = some s.toList :=
    posixQuote_roundtrip_chars s.toList
  unfold shParseWord posixQuoteOk
  rw [String.toList_ofList, h, Option.map_some, String.ofList_toList]

def entries : List Registry.Entry := [
  { id := "posix-quote-roundtrip-chars"
    juliaFile := posixQuoteSourceFile
    juliaFns := ["posix_quote"]
    statement := "POSIX sh word parse of `posixQuoteOkChars cs` yields `cs` alone (no trailing junk)."
    preconditions := "Lean `shParseWordChars`; single-quote/backslash/IFS subset."
    status := .proven
    prop := ``posixQuoteRoundtripCharsProp
    thm := some ``posixQuote_roundtrip_chars },
  { id := "posix-quote-roundtrip"
    juliaFile := posixQuoteSourceFile
    juliaFns := ["posix_quote"]
    statement := "POSIX sh word parse of `posixQuoteOk s` yields `s` when s has no NUL."
    preconditions := "¬ containsNul s; trailing non-IFS forbidden via `shParseWordChars`."
    status := .proven
    prop := ``posixQuoteRoundtripProp
    thm := some ``posixQuote_roundtrip },
  { id := "posix-quote-nul"
    juliaFile := posixQuoteSourceFile
    juliaFns := ["posix_quote"]
    statement := "Model `posixQuote` returns none when the word contains NUL."
    preconditions := "containsNul s."
    status := .proven
    prop := ``posixQuoteNulProp
    thm := some ``posixQuote_nul },
  { id := "posix-quote-no-nul"
    juliaFile := posixQuoteSourceFile
    juliaFns := ["posix_quote"]
    statement := "Model `posixQuote` returns some quoted string when there is no NUL."
    preconditions := "¬ containsNul s."
    status := .proven
    prop := ``posixQuoteNoNulProp
    thm := some ``posixQuote_no_nul },
]

end DistSSHLean.DistSSHBase.PosixQuote
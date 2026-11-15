/-!
Used only by check-proof-escapes.py --self-test; not part of the Lake build.
-/

theorem bad : True := by
  sorry

theorem also_bad : True := native_decide (1 = 1)
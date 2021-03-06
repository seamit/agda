
data Nat : Set where
  zero : Nat
  suc  : Nat → Nat

{-# BUILTIN NATURAL Nat #-}

data _≡_ {A : Set} (x : A) : A → Set where
  refl : x ≡ x

{-# NO_TERMINATION_CHECK #-}
loop : Nat → Nat
loop n = loop n

thm : ∀ n → loop n ≡ 42
thm n = refl

-- {-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleInstances #-}

module Agda.TypeChecking.Rules.LHS.Problem where

import Data.Monoid ( Monoid(mappend,mempty) )
import Data.Foldable
import Data.Traversable

import Agda.Syntax.Common
import Agda.Syntax.Literal
import Agda.Syntax.Position
import Agda.Syntax.Internal as I
import Agda.Syntax.Internal.Pattern
import qualified Agda.Syntax.Abstract as A

import Agda.TypeChecking.Substitute as S
import Agda.TypeChecking.Pretty

import Agda.Utils.Permutation

type Substitution   = [Maybe Term]
type FlexibleVars   = [FlexibleVar Nat]

-- | When we encounter a flexible variable in the unifier, where did it come from?
--   The alternatives are ordered such that we will assign the higher one first,
--   i.e., first we try to assign a @DotFlex@, then...
data FlexibleVarKind
  = RecordFlex   -- ^ From a record pattern ('ConP').
  | ImplicitFlex -- ^ From a hidden formal argument ('ImplicitP').
  | DotFlex      -- ^ From a dot pattern ('DotP').
  deriving (Eq, Ord, Show)

-- | Flexible variables are equipped with information where they come from,
--   in order to make a choice which one to assign when two flexibles are unified.
data FlexibleVar a = FlexibleVar
  { flexHiding :: Hiding
  , flexKind   :: FlexibleVarKind
  , flexVar    :: a
  } deriving (Eq, Show, Functor, Foldable, Traversable)

instance LensHiding (FlexibleVar a) where
  getHiding     = flexHiding
  mapHiding f x = x { flexHiding = f (flexHiding x) }

defaultFlexibleVar :: a -> FlexibleVar a
defaultFlexibleVar a = FlexibleVar Hidden ImplicitFlex a

flexibleVarFromHiding :: Hiding -> a -> FlexibleVar a
flexibleVarFromHiding h a = FlexibleVar h ImplicitFlex a

instance Ord (FlexibleVar Nat) where
  (FlexibleVar h2 f2 i2) <= (FlexibleVar h1 f1 i1) =
    f1 > f2 || (f1 == f2 && (hgt h1 h2 || (h1 == h2 && i1 <= i2)))
    where
      hgt x y | x == y = False
      hgt Hidden _ = True
      hgt _ Hidden = False
      hgt Instance _ = True
      hgt _ _ = False

-- | State of typechecking a LHS; input to 'split'.
--   [Ulf Norell's PhD, page. 35]
--
--   In @Problem ps p delta@,
--   @ps@ are the user patterns of supposed type @delta@.
--   @p@ is the pattern resulting from the splitting.
data Problem' p = Problem
  { problemInPat  :: [A.NamedArg A.Pattern]  -- ^ User patterns.
  , problemOutPat :: p                       -- ^ Patterns after splitting.
  , problemTel    :: Telescope               -- ^ Type of patterns.
  , problemRest   :: ProblemRest             -- ^ Patterns that cannot be typed yet.
  }
  deriving Show

-- | The permutation should permute @allHoles@ of the patterns to correspond to
--   the abstract patterns in the problem.
type Problem	 = Problem' (Permutation, [I.NamedArg Pattern])
type ProblemPart = Problem' ()

-- | User patterns that could not be given a type yet.
--
--   Example:
--   @
--      f : (b : Bool) -> if b then Nat else Nat -> Nat
--      f true          = zero
--      f false zero    = zero
--      f false (suc n) = n
--   @
--   In this sitation, for clause 2, we construct an initial problem
--   @
--      problemInPat = [false]
--      problemTel   = (b : Bool)
--      problemRest.restPats = [zero]
--      problemRest.restType = if b then Nat else Nat -> Nat
--   @
--   As we instantiate @b@ to @false@, the 'restType' reduces to
--   @Nat -> Nat@ and we can move pattern @zero@ over to @problemInPat@.

data ProblemRest = ProblemRest
  { restPats :: [A.NamedArg A.Pattern]
    -- ^ List of user patterns which could not yet be typed.
  , restType :: I.Arg Type
    -- ^ Type eliminated by 'restPats'.
    --   Can be 'Irrelevant' to indicate that we came by
    --   an irrelevant projection and, hence, the rhs must
    --   be type-checked in irrelevant mode.
  }
  deriving Show

data Focus
  = Focus
    { focusCon      :: QName
    , focusImplicit :: Bool -- ^ Do we come from an implicit record pattern?
    , focusConArgs  :: [A.NamedArg A.Pattern]
    , focusRange    :: Range
    , focusOutPat   :: OneHolePatterns
    , focusHoleIx   :: Int  -- ^ Index of focused variable in the out patterns.
    , focusDatatype :: QName
    , focusParams   :: [I.Arg Term]
    , focusIndices  :: [I.Arg Term]
    , focusType     :: Type -- ^ Type of variable we are splitting, kept for record patterns.
    }
  | LitFocus Literal OneHolePatterns Int Type

data SplitProblem

  = Split ProblemPart [Name] (I.Arg Focus) (Abs ProblemPart)
    -- ^ Split on constructor pattern.
    --   The @[Name]@s give the as-bindings for the focus.

  | SplitRest { splitProjection :: I.Arg QName, splitRestType :: Type }
    -- ^ Split on projection pattern.
    --   The projection could be belonging to an irrelevant record field.

data SplitError
  = NothingToSplit
  | SplitPanic String
    -- ^ __IMPOSSIBLE__, only there to make this instance of 'Error'.

data DotPatternInst = DPI A.Expr Term (I.Dom Type)
data AsBinding      = AsB Name Term Type

-- | State worked on during the main loop of checking a lhs.
data LHSState = LHSState
  { lhsProblem :: Problem
  , lhsSubst   :: S.Substitution
  , lhsDPI     :: [DotPatternInst]
  , lhsAsB     :: [AsBinding]
  }

instance Subst ProblemRest where
  applySubst rho p = p { restType = applySubst rho $ restType p }

instance Subst (Problem' p) where
  applySubst rho p = p { problemTel  = applySubst rho $ problemTel p
                       , problemRest = applySubst rho $ problemRest p }

instance Subst DotPatternInst where
  applySubst rho (DPI e v a) = uncurry (DPI e) $ applySubst rho (v,a)

instance Subst AsBinding where
  applySubst rho (AsB x v a) = uncurry (AsB x) $ applySubst rho (v, a)

instance PrettyTCM DotPatternInst where
  prettyTCM (DPI e v a) = sep
    [ prettyA e <+> text "="
    , nest 2 $ prettyTCM v <+> text ":"
    , nest 2 $ prettyTCM a
    ]

instance PrettyTCM AsBinding where
  prettyTCM (AsB x v a) =
    sep [ prettyTCM x <> text "@" <> parens (prettyTCM v)
        , nest 2 $ text ":" <+> prettyTCM a
        ]

-- | 'ProblemRest' is a right dominant monoid.
--   @pr1 \`mappend\` pr2 = pr2@ unless @pr2 = mempty@, then it is @pr1@.
--   Basically, this means that the left 'ProblemRest' is discarded, so
--   use it wisely!
instance Monoid ProblemRest where
  mempty = ProblemRest [] (defaultArg typeDontCare)
  mappend pr (ProblemRest [] _) = pr
  mappend _  pr                 = pr

instance Monoid p => Monoid (Problem' p) where
  mempty = Problem [] mempty EmptyTel mempty
  Problem ps1 qs1 tel1 pr1 `mappend` Problem ps2 qs2 tel2 pr2 =
    Problem (ps1 ++ ps2) (mappend qs1 qs2) (abstract tel1 tel2) (mappend pr1 pr2)

{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeSynonymInstances #-}

-- | The monad for the termination checker.
--
--   The termination monad @TerM@ is an extension of
--   the type checking monad 'TCM' by an environment
--   with information needed by the termination checker.

module Agda.Termination.Monad where

import Control.Applicative
import Control.Monad.Error.Class
import Control.Monad.Reader
import Control.Monad.Writer
import Control.Monad.State

import Data.Functor ((<$>))
import qualified Data.List as List

import Agda.Interaction.Options (defaultCutOff)

import Agda.Syntax.Abstract (QName,IsProjP(..))
import Agda.Syntax.Common   (Delayed(..), Induction(..), Dom(..))
import Agda.Syntax.Internal
import Agda.Syntax.Literal
import Agda.Syntax.Position (noRange)

import Agda.Termination.CutOff
import Agda.Termination.Order (Order,le,unknown)
import Agda.Termination.RecCheck (anyDefs)

import Agda.TypeChecking.Monad
import Agda.TypeChecking.Monad.Builtin
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Records
import Agda.TypeChecking.Substitute

import Agda.Utils.Maybe
import Agda.Utils.Monad
import Agda.Utils.Pretty (Pretty)
import qualified Agda.Utils.Pretty as P
import Agda.Utils.VarSet (VarSet)
import qualified Agda.Utils.VarSet as VarSet

#include "../undefined.h"
import Agda.Utils.Impossible

-- | The mutual block we are checking.
--
--   The functions are numbered according to their order of appearance
--   in this list.

type MutualNames = [QName]

-- | The target of the function we are checking.

type Target = QName

-- | The current guardedness level.

type Guarded = Order

-- | The termination environment.

data TerEnv = TerEnv

  -- First part: options, configuration.

  { terUseDotPatterns :: Bool
    -- ^ Are we mining dot patterns to find evindence of structal descent?
  , terGuardingTypeConstructors :: Bool
    -- ^ Do we assume that record and data type constructors
    --   preserve guardedness?
  , terSizeSuc :: Maybe QName
    -- ^ The name of size successor, if any.
  , terSharp   :: Maybe QName
    -- ^ The name of the delay constructor (sharp), if any.
  , terCutOff  :: CutOff
    -- ^ Depth at which to cut off the structural order.

  -- Second part: accumulated info during descent into decls./term.

  , terCurrent :: QName
    -- ^ The name of the function we are currently checking.
  , terMutual  :: MutualNames
    -- ^ The names of the functions in the mutual block we are checking.
    --   This includes the internally generated functions
    --   (with, extendedlambda, coinduction).
  , terUserNames :: [QName]
    -- ^ The list of name actually appearing in the file (abstract syntax).
    --   Excludes the internally generated functions.
  , terTarget  :: Maybe Target
    -- ^ Target type of the function we are currently termination checking.
    --   Only the constructors of 'Target' are considered guarding.
  , terDelayed :: Delayed
    -- ^ Are we checking a delayed definition?
  , terPatterns :: [DeBruijnPat]
    -- ^ The patterns of the clause we are checking.
  , terPatternsRaise :: !Int
    -- ^ Number of additional binders we have gone under
    --   (and consequently need to raise the patterns to compare to terms).
    --   Updated during call graph extraction, hence strict.
  , terGuarded :: !Guarded
    -- ^ The current guardedness status.  Changes as we go deeper into the term.
    --   Updated during call graph extraction, hence strict.
  , terUseSizeLt :: Bool
    -- ^ When extracting usable size variables during construction of the call
    --   matrix, can we take the variable for use with SIZELT constraints from the context?
    --   Yes, if we are under an inductive constructor.
    --   No, if we are under a record constructor.
  , terUsableVars :: VarSet
    -- ^ Pattern variables that can be compared to argument variables using SIZELT.
  }

-- | An empty termination environment.
--
--   Values are set to a safe default meaning that with these
--   initial values the termination checker will not miss
--   termination errors it would have seen with better settings
--   of these values.
--
--   Values that do not have a safe default are set to
--   @IMPOSSIBLE@.

--   Note: Do not write @__IMPOSSIBLE__@ in the haddock comment above
--   since it will be expanded by the CPP, leading to a haddock parse error.

defaultTerEnv :: TerEnv
defaultTerEnv = TerEnv
  { terUseDotPatterns           = False -- must be False initially!
  , terGuardingTypeConstructors = False
  , terSizeSuc                  = Nothing
  , terSharp                    = Nothing
  , terCutOff                   = defaultCutOff
  , terUserNames                = __IMPOSSIBLE__ -- needs to be set!
  , terMutual                   = __IMPOSSIBLE__ -- needs to be set!
  , terCurrent                  = __IMPOSSIBLE__ -- needs to be set!
  , terTarget                   = Nothing
  , terDelayed                  = NotDelayed
  , terPatterns                 = __IMPOSSIBLE__ -- needs to be set!
  , terPatternsRaise            = 0
  , terGuarded                  = le -- not initially guarded
  , terUseSizeLt                = False -- initially, not under data constructor
  , terUsableVars               = VarSet.empty
  }

-- | Termination monad service class.

class (Functor m, Monad m) => MonadTer m where
  terAsk   :: m TerEnv
  terLocal :: (TerEnv -> TerEnv) -> m a -> m a

  terAsks :: (TerEnv -> a) -> m a
  terAsks f = f <$> terAsk

-- | Termination monad.

newtype TerM a = TerM { terM :: ReaderT TerEnv TCM a }
  deriving (Functor, Applicative, Monad)

runTerm :: TerEnv -> TerM a -> TCM a
runTerm tenv (TerM m) = runReaderT m tenv

instance MonadTer TerM where
  terAsk     = TerM $ ask
  terLocal f = TerM . local f . terM

-- * Termination monad is a 'MonadTCM'.

instance MonadReader TCEnv TerM where
  ask       = TerM $ lift $ ask
  local f m = TerM $ ReaderT $ local f . runReaderT (terM m)

instance MonadState TCState TerM where
  get     = TerM $ lift $ get
  put     = TerM . lift . put

instance MonadIO TerM where
  liftIO = TerM . liftIO

instance MonadTCM TerM where
  liftTCM = TerM . lift

instance MonadError TCErr TerM where
  throwError = liftTCM . throwError
  catchError m handler = TerM $ ReaderT $ \ tenv -> do
    runTerm tenv m `catchError` (\ err -> runTerm tenv $ handler err)

-- * Modifiers and accessors for the termination environment in the monad.

terGetGuardingTypeConstructors :: TerM Bool
terGetGuardingTypeConstructors = terAsks terGuardingTypeConstructors

terGetUseDotPatterns :: TerM Bool
terGetUseDotPatterns = terAsks terUseDotPatterns

terSetUseDotPatterns :: Bool -> TerM a -> TerM a
terSetUseDotPatterns b = terLocal $ \ e -> e { terUseDotPatterns = b }

terGetSizeSuc :: TerM (Maybe QName)
terGetSizeSuc = terAsks terSizeSuc

terGetCurrent :: TerM QName
terGetCurrent = terAsks terCurrent

terSetCurrent :: QName -> TerM a -> TerM a
terSetCurrent q = terLocal $ \ e -> e { terCurrent = q }

terGetSharp :: TerM (Maybe QName)
terGetSharp = terAsks terSharp

terGetCutOff :: TerM CutOff
terGetCutOff = terAsks terCutOff

terGetMutual :: TerM MutualNames
terGetMutual = terAsks terMutual

terGetUserNames :: TerM [QName]
terGetUserNames = terAsks terUserNames

terGetTarget :: TerM (Maybe Target)
terGetTarget = terAsks terTarget

terSetTarget :: Maybe Target -> TerM a -> TerM a
terSetTarget t = terLocal $ \ e -> e { terTarget = t }

terGetDelayed :: TerM Delayed
terGetDelayed = terAsks terDelayed

terSetDelayed :: Delayed -> TerM a -> TerM a
terSetDelayed b = terLocal $ \ e -> e { terDelayed = b }

terGetPatterns :: TerM DeBruijnPats
terGetPatterns = raiseDBP <$> terAsks terPatternsRaise <*> terAsks terPatterns

terSetPatterns :: DeBruijnPats -> TerM a -> TerM a
terSetPatterns ps = terLocal $ \ e -> e { terPatterns = ps }

terRaise :: TerM a -> TerM a
terRaise = terLocal $ \ e -> e { terPatternsRaise = terPatternsRaise e + 1 }

terGetGuarded :: TerM Guarded
terGetGuarded = terAsks terGuarded

terModifyGuarded :: (Order -> Order) -> TerM a -> TerM a
terModifyGuarded f = terLocal $ \ e -> e { terGuarded = f $ terGuarded e }

terSetGuarded :: Order -> TerM a -> TerM a
terSetGuarded = terModifyGuarded . const

terUnguarded :: TerM a -> TerM a
terUnguarded = terSetGuarded unknown

-- | Should the codomain part of a function type preserve guardedness?
terPiGuarded :: TerM a -> TerM a
terPiGuarded m = ifM terGetGuardingTypeConstructors m $ terUnguarded m

-- | Lens for 'terUsableVars'.

terGetUsableVars :: TerM VarSet
terGetUsableVars = terAsks terUsableVars

terModifyUsableVars :: (VarSet -> VarSet) -> TerM a -> TerM a
terModifyUsableVars f = terLocal $ \ e -> e { terUsableVars = f $ terUsableVars e }

terSetUsableVars :: VarSet -> TerM a -> TerM a
terSetUsableVars = terModifyUsableVars . const

-- | Lens for 'terUseSizeLt'.

terGetUseSizeLt :: TerM Bool
terGetUseSizeLt = terAsks terUseSizeLt

terModifyUseSizeLt :: (Bool -> Bool) -> TerM a -> TerM a
terModifyUseSizeLt f = terLocal $ \ e -> e { terUseSizeLt = f $ terUseSizeLt e }

terSetUseSizeLt :: Bool -> TerM a -> TerM a
terSetUseSizeLt = terModifyUseSizeLt . const

-- | Compute usable vars from patterns and run subcomputation.
withUsableVars :: UsableSizeVars a => a -> TerM b -> TerM b
withUsableVars pats m = do
  vars <- usableSizeVars pats
  terSetUsableVars vars $ m

-- | Set 'terUseSizeLt' when going under constructor @c@.
conUseSizeLt :: QName -> TerM a -> TerM a
conUseSizeLt c m = do
  caseMaybeM (liftTCM $ isRecordConstructor c)
    (terSetUseSizeLt True m)
    (const $ terSetUseSizeLt False m)

-- | Set 'terUseSizeLt' for arguments following projection @q@.
projUseSizeLt :: QName -> TerM a -> TerM a
projUseSizeLt q m = isCoinductiveProjection q >>= (`terSetUseSizeLt` m)
-- projUseSizeLt q m = do
--   ifM (liftTCM $ isProjectionButNotCoinductive q)
--     (terSetUseSizeLt False m)
--     (terSetUseSizeLt True  m)

-- | For termination checking purposes flat should not be considered a
--   projection. That is, it flat doesn't preserve either structural order
--   or guardedness like other projections do.
--   Andreas, 2012-06-09: the same applies to projections of recursive records.
isProjectionButNotCoinductive :: MonadTCM tcm => QName -> tcm Bool
isProjectionButNotCoinductive qn = liftTCM $ do
  b <- isProjectionButNotCoinductive' qn
  reportSDoc "term.proj" 60 $ do
    text "identifier" <+> prettyTCM qn <+> do
      text $
        if b then "is an inductive projection"
          else "is either not a projection or coinductive"
  return b
  where
    isProjectionButNotCoinductive' qn = do
      flat <- fmap nameOfFlat <$> coinductionKit
      if Just qn == flat
        then return False
        else do
          mp <- isProjection qn
          case mp of
            Just Projection{ projProper = Just{}, projFromType = t }
              -> isInductiveRecord t
            _ -> return False

-- | Check whether a projection belongs to a coinductive record
--   and is actually recursive.
--   E.g.
--   @
--      isCoinductiveProjection (Stream.head) = return False
--
--      isCoinductiveProjection (Stream.tail) = return True
--   @
isCoinductiveProjection :: MonadTCM tcm => QName -> tcm Bool
isCoinductiveProjection q = liftTCM $ do
  flat <- fmap nameOfFlat <$> coinductionKit
  -- yes for ♭
  if Just q == flat then return True else do
  pdef <- getConstInfo q
  case isProjection_ (theDef pdef) of
    Just Projection{ projProper = Just{}, projFromType = r, projIndex = n }
      -> caseMaybeM (isRecord r) __IMPOSSIBLE__ $ \ rdef -> do
           -- no for inductive or non-recursive record
           if recInduction rdef /= Just CoInductive then return False else do
           if not (recRecursive rdef) then return False else do
           -- TODO: the following test for recursiveness of a projection should be cached.
           -- E.g., it could be stored in the @Projection@ component.
           -- Now check if type of field mentions mutually recursive symbol.
           -- Get the type of the field by dropping record parameters and record argument.
           let TelV tel core = telView' (defType pdef)
               tel' = drop n $ telToList tel
           -- Check if any recursive symbols appear in the record type.
           -- Q (2014-07-01): Should we normalize the type?
           names <- anyDefs (r : recMutual rdef) (map (snd . unDom) tel', core)
           return $ not $ null names
    _ -> return False


-- * De Bruijn patterns.

type DeBruijnPats = [DeBruijnPat]

-- | Patterns with variables as de Bruijn indices.
type DeBruijnPat = DeBruijnPat' Int

data DeBruijnPat' a
  = VarDBP a
    -- ^ De Bruijn Index.
  | ConDBP QName [DeBruijnPat' a]
    -- ^ The name refers to either an ordinary
    --   constructor or the successor function on sized types.
  | LitDBP Literal
  | ProjDBP QName
  deriving (Functor, Show)

instance IsProjP (DeBruijnPat' a) where
  isProjP (ProjDBP d) = Just d
  isProjP _           = Nothing

instance PrettyTCM DeBruijnPat where
  prettyTCM (VarDBP i)    = text $ show i
  prettyTCM (ConDBP c ps) = parens (prettyTCM c <+> hsep (map prettyTCM ps))
  prettyTCM (LitDBP l)    = prettyTCM l
  prettyTCM (ProjDBP d)   = prettyTCM d

-- | A dummy pattern used to mask a pattern that cannot be used
--   for structural descent.

unusedVar :: DeBruijnPat
unusedVar = LitDBP (LitString noRange "term.unused.pat.var")

-- | @raiseDBP n ps@ increases each de Bruijn index in @ps@ by @n@.
--   Needed when going under a binder during analysis of a term.

raiseDBP :: Int -> DeBruijnPats -> DeBruijnPats
raiseDBP 0 = id
raiseDBP n = map $ fmap (n +)

-- | Extract variables from 'DeBruijnPat's that could witness a decrease
--   via a SIZELT constraint.
--
--   These variables must be under an inductive constructor (with no record
--   constructor in the way), or after a coinductive projection (with no
--   inductive one in the way).

class UsableSizeVars a where
  usableSizeVars :: a -> TerM VarSet

instance UsableSizeVars DeBruijnPat where
  usableSizeVars p =
    case p of
      VarDBP i    -> ifM terGetUseSizeLt (return $ VarSet.singleton i) (return $ mempty)
      ConDBP c ps -> conUseSizeLt c $ usableSizeVars ps
      LitDBP{}    -> return mempty
      ProjDBP{}   -> return mempty

instance UsableSizeVars [DeBruijnPat] where
  usableSizeVars ps =
    case ps of
      []               -> return mempty
      (ProjDBP q : ps) -> projUseSizeLt q $ usableSizeVars ps
      (p         : ps) -> mappend <$> usableSizeVars p <*> usableSizeVars ps

-- * Call pathes

-- | The call information is stored as free monoid
--   over 'CallInfo'.  As long as we never look at it,
--   only accumulate it, it does not matter whether we use
--   'Set', (nub) list, or 'Tree'.
--   Internally, due to lazyness, it is anyway a binary tree of
--   'mappend' nodes and singleton leafs.
--   Since we define no order on 'CallInfo' (expensive),
--   we cannot use a 'Set' or nub list.
--   Performance-wise, I could not see a difference between Set and list.

newtype CallPath = CallPath { callInfos :: [CallInfo] }
  deriving (Show, Monoid)

-- | Only show intermediate nodes.  (Drop last 'CallInfo').
instance Pretty CallPath where
  pretty (CallPath cis0) = if List.null cis then P.empty else
    P.hsep (map (\ ci -> arrow P.<+> P.pretty ci) cis) P.<+> arrow
    where
      cis   = init cis0
      arrow = P.text "-->"

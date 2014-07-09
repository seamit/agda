{-# LANGUAGE CPP #-}

module Agda.TypeChecking.Monad.Builtin where

import Control.Applicative
import Control.Monad.Error.Class
import Control.Monad.State

import Data.Functor
import qualified Data.Map as Map

import Agda.Syntax.Common
import Agda.Syntax.Position
import Agda.Syntax.Literal
import Agda.Syntax.Internal
import Agda.TypeChecking.Monad.Base
import Agda.TypeChecking.Substitute

import Agda.Utils.Monad (when_)
import Agda.Utils.Maybe
import Agda.Utils.Tuple

#include "../../undefined.h"
import Agda.Utils.Impossible

class (Functor m, Applicative m, Monad m) => HasBuiltins m where
  getBuiltinThing :: String -> m (Maybe (Builtin PrimFun))

litType :: Literal -> TCM Type
litType l = case l of
    LitInt _ n	  -> do
      primZero
      when_ (n > 0) $ primSuc
      el <$> primNat
    LitFloat _ _  -> el <$> primFloat
    LitChar _ _   -> el <$> primChar
    LitString _ _ -> el <$> primString
    LitQName _ _  -> el <$> primQName
  where
    el t = El (mkType 0) t

instance MonadIO m => HasBuiltins (TCMT m) where
  getBuiltinThing b = liftM2 mplus (Map.lookup b <$> gets stLocalBuiltins)
                      (Map.lookup b <$> gets stImportedBuiltins)

setBuiltinThings :: BuiltinThings PrimFun -> TCM ()
setBuiltinThings b = modify $ \s -> s { stLocalBuiltins = b }

bindBuiltinName :: String -> Term -> TCM ()
bindBuiltinName b x = do
	builtin <- getBuiltinThing b
	case builtin of
	    Just (Builtin y) -> typeError $ DuplicateBuiltinBinding b y x
	    Just (Prim _)    -> typeError $ NoSuchBuiltinName b
	    Nothing	     -> modify $ \st ->
              st { stLocalBuiltins =
                    Map.insert b (Builtin x) $ stLocalBuiltins st
                 }

bindPrimitive :: String -> PrimFun -> TCM ()
bindPrimitive b pf = do
  builtin <- gets stLocalBuiltins
  setBuiltinThings $ Map.insert b (Prim pf) builtin

getBuiltin :: String -> TCM Term
getBuiltin x =
  fromMaybeM (typeError $ NoBindingForBuiltin x) $ getBuiltin' x

getBuiltin' :: HasBuiltins m => String -> m (Maybe Term)
getBuiltin' x = do
    builtin <- getBuiltinThing x
    case builtin of
	Just (Builtin t) -> return $ Just (killRange t)
	_		 -> return Nothing

getPrimitive' :: HasBuiltins m => String -> m (Maybe PrimFun)
getPrimitive' x = (getPrim =<<) <$> getBuiltinThing x
  where
    getPrim (Prim pf) = return pf
    getPrim _         = Nothing

getPrimitive :: String -> TCM PrimFun
getPrimitive x =
  fromMaybeM (typeError $ NoSuchPrimitiveFunction x) $ getPrimitive' x

-- | Rewrite a literal to constructor form if possible.
constructorForm :: Term -> TCM Term
constructorForm v = constructorForm' primZero primSuc v

constructorForm' :: Applicative m => m Term -> m Term -> Term -> m Term
constructorForm' pZero pSuc v = case ignoreSharing v of
{- 2012-04-02 changed semantics of DontCare
-- Andreas, 2011-10-03, the following line restores IrrelevantLevel
    DontCare v                  -> constructorForm v
-}
    Lit (LitInt r n)            -> cons (Lit . LitInt r) n
--     Level (Max [])              -> primLevelZero
--     Level (Max [ClosedLevel n]) -> cons primLevelZero primLevelSuc (Level . Max . (:[]) . ClosedLevel) n
    _                           -> pure v
  where
    cons lit n
      | n == 0    = pZero
      | n > 0     = (`apply` [defaultArg $ lit $ n - 1]) <$> pSuc
      | otherwise = pure v

---------------------------------------------------------------------------
-- * The names of built-in things
---------------------------------------------------------------------------

primInteger, primFloat, primChar, primString, primBool, primTrue, primFalse,
    primList, primNil, primCons, primIO, primNat, primSuc, primZero,
    primNatPlus, primNatMinus, primNatTimes, primNatDivSucAux, primNatModSucAux,
    primNatEquality, primNatLess,
    primSize, primSizeLt, primSizeSuc, primSizeInf,
    primInf, primSharp, primFlat,
    primEquality, primRefl,
    primRewrite, -- Name of rewrite relation
    primLevel, primLevelZero, primLevelSuc, primLevelMax,
    primIrrAxiom, primSizeMax,
    -- builtins for reflection:
    primQName, primArgInfo, primArgArgInfo, primArg, primArgArg, primAgdaTerm, primAgdaTermVar,
    primAgdaTermLam, primAgdaTermExtLam, primAgdaTermDef, primAgdaTermCon, primAgdaTermPi,
    primAgdaTermSort, primAgdaTermLit, primAgdaTermUnsupported,
    primAgdaType, primAgdaTypeEl,
    primHiding, primHidden, primInstance, primVisible,
    primRelevance, primRelevant, primIrrelevant,
    primAgdaLiteral, primAgdaLitNat, primAgdaLitFloat, primAgdaLitString, primAgdaLitChar, primAgdaLitQName,
    primAgdaSort, primAgdaSortSet, primAgdaSortLit, primAgdaSortUnsupported,
    primAgdaDefinition, primAgdaDefinitionFunDef, primAgdaDefinitionDataDef, primAgdaDefinitionRecordDef,
    primAgdaDefinitionPostulate, primAgdaDefinitionPrimitive, primAgdaDefinitionDataConstructor,
    primAgdaFunDef, primAgdaFunDefCon, primAgdaClause, primAgdaClauseClause, primAgdaClauseAbsurd,
    primAgdaPattern, primAgdaPatCon, primAgdaPatVar, primAgdaPatDot,
    primAgdaDataDef, primAgdaRecordDef
    :: TCM Term
primInteger      = getBuiltin builtinInteger
primFloat        = getBuiltin builtinFloat
primChar         = getBuiltin builtinChar
primString       = getBuiltin builtinString
primBool         = getBuiltin builtinBool
primTrue         = getBuiltin builtinTrue
primFalse        = getBuiltin builtinFalse
primList         = getBuiltin builtinList
primNil          = getBuiltin builtinNil
primCons         = getBuiltin builtinCons
primIO           = getBuiltin builtinIO
primNat          = getBuiltin builtinNat
primSuc          = getBuiltin builtinSuc
primZero         = getBuiltin builtinZero
primNatPlus      = getBuiltin builtinNatPlus
primNatMinus     = getBuiltin builtinNatMinus
primNatTimes     = getBuiltin builtinNatTimes
primNatDivSucAux = getBuiltin builtinNatDivSucAux
primNatModSucAux = getBuiltin builtinNatModSucAux
primNatEquality  = getBuiltin builtinNatEquals
primNatLess      = getBuiltin builtinNatLess
primSize         = getBuiltin builtinSize
primSizeLt       = getBuiltin builtinSizeLt
primSizeSuc      = getBuiltin builtinSizeSuc
primSizeInf      = getBuiltin builtinSizeInf
primSizeMax      = getBuiltin builtinSizeMax
primInf          = getBuiltin builtinInf
primSharp        = getBuiltin builtinSharp
primFlat         = getBuiltin builtinFlat
primEquality     = getBuiltin builtinEquality
primRefl         = getBuiltin builtinRefl
primRewrite      = getBuiltin builtinRewrite
primLevel        = getBuiltin builtinLevel
primLevelZero    = getBuiltin builtinLevelZero
primLevelSuc     = getBuiltin builtinLevelSuc
primLevelMax     = getBuiltin builtinLevelMax
primIrrAxiom     = getBuiltin builtinIrrAxiom
primQName        = getBuiltin builtinQName
primArg          = getBuiltin builtinArg
primArgArg       = getBuiltin builtinArgArg
primAgdaSort     = getBuiltin builtinAgdaSort
primAgdaType     = getBuiltin builtinAgdaType
primAgdaTypeEl   = getBuiltin builtinAgdaTypeEl
primHiding       = getBuiltin builtinHiding
primHidden       = getBuiltin builtinHidden
primInstance     = getBuiltin builtinInstance
primVisible      = getBuiltin builtinVisible
primRelevance    = getBuiltin builtinRelevance
primRelevant     = getBuiltin builtinRelevant
primIrrelevant   = getBuiltin builtinIrrelevant
primArgInfo      = getBuiltin builtinArgInfo
primArgArgInfo   = getBuiltin builtinArgArgInfo
primAgdaSortSet  = getBuiltin builtinAgdaSortSet
primAgdaSortLit  = getBuiltin builtinAgdaSortLit
primAgdaSortUnsupported = getBuiltin builtinAgdaSortUnsupported
primAgdaTerm         = getBuiltin builtinAgdaTerm
primAgdaTermVar      = getBuiltin builtinAgdaTermVar
primAgdaTermLam      = getBuiltin builtinAgdaTermLam
primAgdaTermExtLam   = getBuiltin builtinAgdaTermExtLam
primAgdaTermDef      = getBuiltin builtinAgdaTermDef
primAgdaTermCon      = getBuiltin builtinAgdaTermCon
primAgdaTermPi       = getBuiltin builtinAgdaTermPi
primAgdaTermSort     = getBuiltin builtinAgdaTermSort
primAgdaTermLit      = getBuiltin builtinAgdaTermLit
primAgdaTermUnsupported     = getBuiltin builtinAgdaTermUnsupported
primAgdaLiteral   = getBuiltin builtinAgdaLiteral
primAgdaLitNat    = getBuiltin builtinAgdaLitNat
primAgdaLitFloat  = getBuiltin builtinAgdaLitFloat
primAgdaLitChar   = getBuiltin builtinAgdaLitChar
primAgdaLitString = getBuiltin builtinAgdaLitString
primAgdaLitQName  = getBuiltin builtinAgdaLitQName
primAgdaFunDef    = getBuiltin builtinAgdaFunDef
primAgdaFunDefCon = getBuiltin builtinAgdaFunDefCon
primAgdaDataDef   = getBuiltin builtinAgdaDataDef
primAgdaRecordDef = getBuiltin builtinAgdaRecordDef
primAgdaPattern   = getBuiltin builtinAgdaPattern
primAgdaPatCon    = getBuiltin builtinAgdaPatCon
primAgdaPatVar    = getBuiltin builtinAgdaPatVar
primAgdaPatDot    = getBuiltin builtinAgdaPatDot
primAgdaPatLit    = getBuiltin builtinAgdaPatLit
primAgdaPatProj   = getBuiltin builtinAgdaPatProj
primAgdaPatAbsurd = getBuiltin builtinAgdaPatAbsurd
primAgdaClause    = getBuiltin builtinAgdaClause
primAgdaClauseClause = getBuiltin builtinAgdaClauseClause
primAgdaClauseAbsurd = getBuiltin builtinAgdaClauseAbsurd
primAgdaDefinitionFunDef          = getBuiltin builtinAgdaDefinitionFunDef
primAgdaDefinitionDataDef         = getBuiltin builtinAgdaDefinitionDataDef
primAgdaDefinitionRecordDef       = getBuiltin builtinAgdaDefinitionRecordDef
primAgdaDefinitionDataConstructor = getBuiltin builtinAgdaDefinitionDataConstructor
primAgdaDefinitionPostulate       = getBuiltin builtinAgdaDefinitionPostulate
primAgdaDefinitionPrimitive       = getBuiltin builtinAgdaDefinitionPrimitive
primAgdaDefinition                = getBuiltin builtinAgdaDefinition

builtinNat          = "NATURAL"
builtinSuc          = "SUC"
builtinZero         = "ZERO"
builtinNatPlus      = "NATPLUS"
builtinNatMinus     = "NATMINUS"
builtinNatTimes     = "NATTIMES"
builtinNatDivSucAux = "NATDIVSUCAUX"
builtinNatModSucAux = "NATMODSUCAUX"
builtinNatEquals    = "NATEQUALS"
builtinNatLess      = "NATLESS"
builtinInteger      = "INTEGER"
builtinFloat        = "FLOAT"
builtinChar         = "CHAR"
builtinString       = "STRING"
builtinBool         = "BOOL"
builtinTrue         = "TRUE"
builtinFalse        = "FALSE"
builtinList         = "LIST"
builtinNil          = "NIL"
builtinCons         = "CONS"
builtinIO           = "IO"
builtinSize         = "SIZE"
builtinSizeLt       = "SIZELT"
builtinSizeSuc      = "SIZESUC"
builtinSizeInf      = "SIZEINF"
builtinSizeMax      = "SIZEMAX"
builtinInf          = "INFINITY"
builtinSharp        = "SHARP"
builtinFlat         = "FLAT"
builtinEquality     = "EQUALITY"
builtinRefl         = "REFL"
builtinRewrite      = "REWRITE"
builtinLevelMax     = "LEVELMAX"
builtinLevel        = "LEVEL"
builtinLevelZero    = "LEVELZERO"
builtinLevelSuc     = "LEVELSUC"
builtinIrrAxiom     = "IRRAXIOM"
builtinQName        = "QNAME"
builtinAgdaSort     = "AGDASORT"
builtinAgdaSortSet  = "AGDASORTSET"
builtinAgdaSortLit  = "AGDASORTLIT"
builtinAgdaSortUnsupported = "AGDASORTUNSUPPORTED"
builtinAgdaType     = "AGDATYPE"
builtinAgdaTypeEl   = "AGDATYPEEL"
builtinHiding       = "HIDING"
builtinHidden       = "HIDDEN"
builtinInstance     = "INSTANCE"
builtinVisible      = "VISIBLE"
builtinRelevance    = "RELEVANCE"
builtinRelevant     = "RELEVANT"
builtinIrrelevant   = "IRRELEVANT"
builtinArg          = "ARG"
builtinArgInfo      = "ARGINFO"
builtinArgArgInfo   = "ARGARGINFO"
builtinArgArg       = "ARGARG"
builtinAgdaTerm         = "AGDATERM"
builtinAgdaTermVar      = "AGDATERMVAR"
builtinAgdaTermLam      = "AGDATERMLAM"
builtinAgdaTermExtLam   = "AGDATERMEXTLAM"
builtinAgdaTermDef      = "AGDATERMDEF"
builtinAgdaTermCon      = "AGDATERMCON"
builtinAgdaTermPi       = "AGDATERMPI"
builtinAgdaTermSort     = "AGDATERMSORT"
builtinAgdaTermLit      = "AGDATERMLIT"
builtinAgdaTermUnsupported = "AGDATERMUNSUPPORTED"
builtinAgdaLiteral   = "AGDALITERAL"
builtinAgdaLitNat    = "AGDALITNAT"
builtinAgdaLitFloat  = "AGDALITFLOAT"
builtinAgdaLitChar   = "AGDALITCHAR"
builtinAgdaLitString = "AGDALITSTRING"
builtinAgdaLitQName  = "AGDALITQNAME"
builtinAgdaFunDef                    = "AGDAFUNDEF"
builtinAgdaFunDefCon                 = "AGDAFUNDEFCON"
builtinAgdaClause                    = "AGDACLAUSE"
builtinAgdaClauseClause              = "AGDACLAUSECLAUSE"
builtinAgdaClauseAbsurd              = "AGDACLAUSEABSURD"
builtinAgdaPattern                   = "AGDAPATTERN"
builtinAgdaPatVar                    = "AGDAPATVAR"
builtinAgdaPatCon                    = "AGDAPATCON"
builtinAgdaPatDot                    = "AGDAPATDOT"
builtinAgdaPatLit                    = "AGDAPATLIT"
builtinAgdaPatProj                   = "AGDAPATPROJ"
builtinAgdaPatAbsurd                 = "AGDAPATABSURD"
builtinAgdaDataDef                   = "AGDADATADEF"
builtinAgdaRecordDef                 = "AGDARECORDDEF"
builtinAgdaDefinitionFunDef          = "AGDADEFINITIONFUNDEF"
builtinAgdaDefinitionDataDef         = "AGDADEFINITIONDATADEF"
builtinAgdaDefinitionRecordDef       = "AGDADEFINITIONRECORDDEF"
builtinAgdaDefinitionDataConstructor = "AGDADEFINITIONDATACONSTRUCTOR"
builtinAgdaDefinitionPostulate       = "AGDADEFINITIONPOSTULATE"
builtinAgdaDefinitionPrimitive       = "AGDADEFINITIONPRIMITIVE"
builtinAgdaDefinition                = "AGDADEFINITION"

-- | The coinductive primitives.

data CoinductionKit = CoinductionKit
  { nameOfInf   :: QName
  , nameOfSharp :: QName
  , nameOfFlat  :: QName
  }

-- | Tries to build a 'CoinductionKit'.

coinductionKit :: TCM (Maybe CoinductionKit)
coinductionKit = (do
  Def inf   _ <- ignoreSharing <$> primInf
  Def sharp _ <- ignoreSharing <$> primSharp
  Def flat  _ <- ignoreSharing <$> primFlat
  return $ Just $ CoinductionKit
    { nameOfInf   = inf
    , nameOfSharp = sharp
    , nameOfFlat  = flat
    })
    `catchError` \_ -> return Nothing

------------------------------------------------------------------------
-- * Builtin equality
------------------------------------------------------------------------

-- | Get the name of the equality type.
primEqualityName :: TCM QName
primEqualityName = do
  eq <- primEquality
  -- Andreas, 2014-05-17 moved this here from TC.Rules.Def
  -- Don't know why up to 2 hidden lambdas need to be stripped,
  -- but I left the code in place.
  -- Maybe it was intended that equality could be declared
  -- in three different ways:
  -- 1. universe and type polymorphic
  -- 2. type polymorphic only
  -- 3. monomorphic.
  let lamV (Lam i b)  = mapFst (getHiding i :) $ lamV (unAbs b)
      lamV (Shared p) = lamV (derefPtr p)
      lamV v          = ([], v)
  return $ case lamV eq of
    ([Hidden, Hidden], Def equality _) -> equality
    ([Hidden],         Def equality _) -> equality
    ([],               Def equality _) -> equality
    _                                  -> __IMPOSSIBLE__


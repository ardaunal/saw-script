{-# OPTIONS_GHC -Wall #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Verifier.SAW.Cryptol
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : huffman@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.Cryptol where

import Control.Monad (foldM, join, unless)
import Data.Bifunctor (first)
import qualified Data.Foldable as Fold
import Data.List
import qualified Data.IntTrie as IntTrie
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Vector as Vector
import Prelude ()
import Prelude.Compat

import qualified Cryptol.Eval.Type as TV
import qualified Cryptol.Eval.Monad as V
import qualified Cryptol.Eval.Value as V
import qualified Cryptol.Eval.Concrete.Value as V
import Cryptol.Eval.Type (evalValType)
import qualified Cryptol.TypeCheck.AST as C
import qualified Cryptol.TypeCheck.Subst as C (Subst, apSubst, singleTParamSubst)
import qualified Cryptol.ModuleSystem.Name as C (asPrim, nameIdent)
import qualified Cryptol.Utils.Ident as C (Ident, PrimIdent(..), packIdent, unpackIdent, prelPrim, floatPrim, arrayName)
import qualified Cryptol.Utils.Logger as C (quietLogger)
import Cryptol.TypeCheck.TypeOf (fastTypeOf, fastSchemaOf)
import Cryptol.Utils.PP (pretty)

import Verifier.SAW.Cryptol.Panic
import Verifier.SAW.Conversion
import Verifier.SAW.FiniteValue (FirstOrderType(..), FirstOrderValue(..))
import qualified Verifier.SAW.Simulator.Concrete as SC
import Verifier.SAW.Prim (BitVector(..))
import Verifier.SAW.Rewriter
import Verifier.SAW.SharedTerm
import Verifier.SAW.Simulator.MonadLazy (force)
import Verifier.SAW.TypedAST (mkSort, mkModuleName, FieldName)

import GHC.Stack

--------------------------------------------------------------------------------
-- Type Environments

-- | SharedTerms are paired with a deferred shift amount for loose variables
data Env = Env
  { envT :: Map Int    (Term, Int) -- ^ Type variables are referenced by unique id
  , envE :: Map C.Name (Term, Int) -- ^ Term variables are referenced by name
  , envP :: Map C.Prop (Term, [FieldName], Int)
              -- ^ Bound propositions are referenced implicitly by their types
              --   The actual class dictionary we need is obtained by applying the
              --   given field selectors (in reverse order!) to the term.
  , envC :: Map C.Name C.Schema    -- ^ Cryptol type environment
  , envS :: [Term]                 -- ^ SAW-Core bound variable environment (for type checking)
  }

emptyEnv :: Env
emptyEnv = Env Map.empty Map.empty Map.empty Map.empty []

liftTerm :: (Term, Int) -> (Term, Int)
liftTerm (t, j) = (t, j + 1)

liftProp :: (Term, [FieldName], Int) -> (Term, [FieldName], Int)
liftProp (t, fns, j) = (t, fns, j + 1)

-- | Increment dangling bound variables of all types in environment.
liftEnv :: Env -> Env
liftEnv env =
  Env { envT = fmap liftTerm (envT env)
      , envE = fmap liftTerm (envE env)
      , envP = fmap liftProp (envP env)
      , envC = envC env
      , envS = envS env
      }

bindTParam :: SharedContext -> C.TParam -> Env -> IO Env
bindTParam sc tp env = do
  let env' = liftEnv env
  v <- scLocalVar sc 0
  k <- importKind sc (C.tpKind tp)
  return $ env' { envT = Map.insert (C.tpUnique tp) (v, 0) (envT env')
                , envS = k : envS env }

bindName :: SharedContext -> C.Name -> C.Schema -> Env -> IO Env
bindName sc name schema env = do
  let env' = liftEnv env
  v <- scLocalVar sc 0
  t <- importSchema sc env schema
  return $ env' { envE = Map.insert name (v, 0) (envE env')
                , envC = Map.insert name schema (envC env')
                , envS = t : envS env' }

bindProp :: SharedContext -> C.Prop -> Env -> IO Env
bindProp sc prop env = do
  let env' = liftEnv env
  v <- scLocalVar sc 0
  k <- scSort sc (mkSort 0)
  return $ env' { envP = insertSupers prop [] v (envP env')
                , envS = k : envS env'
                }

-- | When we insert a nonerasable prop into the environment, make
--   sure to also insert all its superclasses.  We arrange it so
--   that every class dictionary contains the implementation of its
--   superclass dictionaries, which can be extracted via field projections.
insertSupers ::
  C.Prop ->
  [FieldName] {- Field names to project the associated class (in reverse order) -} ->
  Term ->
  Map C.Prop (Term, [FieldName], Int) ->
  Map C.Prop (Term, [FieldName], Int)
insertSupers prop fs v m
  -- If the prop is already in the map, stop
  | Just _ <- Map.lookup prop m = m

  -- Insert the prop and check if it has any superclasses that also need to be added
  | otherwise = Map.insert (normalizeProp prop) (v, fs, 0) $ go prop

 where
 super p f t = insertSupers (C.TCon (C.PC p) [t]) (f:fs) v

 go (C.TCon (C.PC p) [t]) =
    case p of
      C.PRing      -> super C.PZero "ringZero" t m
      C.PLogic     -> super C.PZero "logicZero" t m
      C.PField     -> super C.PRing "fieldRing" t m
      C.PIntegral  -> super C.PRing "integralRing" t m
      C.PRound     -> super C.PField "roundField" t . super C.PCmp "roundCmp" t $ m
      C.PCmp       -> super C.PEq "cmpEq" t m
      C.PSignedCmp -> super C.PEq "signedCmpEq" t m
      _ -> m
 go _ = m


-- | We normalize the first argument of 'Literal' class constraints
-- arbitrarily to 'inf', so that we can ignore that parameter when
-- matching dictionaries.
normalizeProp :: C.Prop -> C.Prop
normalizeProp prop =
  case C.pIsLiteral prop of
    Just (_, a) -> C.pLiteral C.tInf a
    Nothing -> prop

--------------------------------------------------------------------------------

importKind :: SharedContext -> C.Kind -> IO Term
importKind sc kind =
  case kind of
    C.KType       -> scSort sc (mkSort 0)
    C.KNum        -> scDataTypeApp sc "Cryptol.Num" []
    C.KProp       -> scSort sc (mkSort 0)
    (C.:->) k1 k2 -> join $ scFun sc <$> importKind sc k1 <*> importKind sc k2

importTFun :: SharedContext -> C.TFun -> IO Term
importTFun sc tf =
  case tf of
    C.TCWidth         -> scGlobalDef sc "Cryptol.tcWidth"
    C.TCAdd           -> scGlobalDef sc "Cryptol.tcAdd"
    C.TCSub           -> scGlobalDef sc "Cryptol.tcSub"
    C.TCMul           -> scGlobalDef sc "Cryptol.tcMul"
    C.TCDiv           -> scGlobalDef sc "Cryptol.tcDiv"
    C.TCMod           -> scGlobalDef sc "Cryptol.tcMod"
    C.TCExp           -> scGlobalDef sc "Cryptol.tcExp"
    C.TCMin           -> scGlobalDef sc "Cryptol.tcMin"
    C.TCMax           -> scGlobalDef sc "Cryptol.tcMax"
    C.TCCeilDiv       -> scGlobalDef sc "Cryptol.tcCeilDiv"
    C.TCCeilMod       -> scGlobalDef sc "Cryptol.tcCeilMod"
    C.TCLenFromThenTo -> scGlobalDef sc "Cryptol.tcLenFromThenTo"

-- | Precondition: @not ('isErasedProp' pc)@.
importPC :: SharedContext -> C.PC -> IO Term
importPC sc pc =
  case pc of
    C.PEqual     -> panic "importPC PEqual" []
    C.PNeq       -> panic "importPC PNeq" []
    C.PGeq       -> panic "importPC PGeq" []
    C.PFin       -> panic "importPC PFin" []
    C.PHas _     -> panic "importPC PHas" []
    C.PZero      -> scGlobalDef sc "Cryptol.PZero"
    C.PLogic     -> scGlobalDef sc "Cryptol.PLogic"
    C.PRing      -> scGlobalDef sc "Cryptol.PRing"
    C.PIntegral  -> scGlobalDef sc "Cryptol.PIntegral"
    C.PField     -> scGlobalDef sc "Cryptol.PField"
    C.PRound     -> scGlobalDef sc "Cryptol.PRound"
    C.PEq        -> scGlobalDef sc "Cryptol.PEq"
    C.PCmp       -> scGlobalDef sc "Cryptol.PCmp"
    C.PSignedCmp -> scGlobalDef sc "Cryptol.PSignedCmp"
    C.PLiteral   -> scGlobalDef sc "Cryptol.PLiteral"
    C.PAnd       -> panic "importPC PAnd" []
    C.PTrue      -> panic "importPC PTrue" []
    C.PFLiteral  -> panic "importPC PFLiteral" []
    C.PValidFloat -> panic "importPC PValidFloat" []

-- | Translate size types to SAW values of type Num, value types to SAW types of sort 0.
importType :: SharedContext -> Env -> C.Type -> IO Term
importType sc env ty =
  case ty of
    C.TVar tvar ->
      case tvar of
        C.TVFree{} {- Int Kind (Set TVar) Doc -} -> unimplemented "TVFree"
        C.TVBound v -> case Map.lookup (C.tpUnique v) (envT env) of
                         Just (t, j) -> incVars sc 0 j t
                         Nothing -> panic "importType TVBound" []
    C.TUser _ _ t  -> go t
    C.TRec (Map.fromList -> fm) ->
      importType sc env (C.tTuple (Map.elems fm))

    C.TCon tcon tyargs ->
      case tcon of
        C.TC tc ->
          case tc of
            C.TCNum n    -> scCtorApp sc "Cryptol.TCNum" =<< sequence [scNat sc (fromInteger n)]
            C.TCInf      -> scCtorApp sc "Cryptol.TCInf" []
            C.TCBit      -> scBoolType sc
            C.TCInteger  -> scIntegerType sc
            C.TCIntMod   -> scGlobalApply sc "Cryptol.IntModNum" =<< traverse go tyargs
            C.TCFloat    -> scGlobalApply sc "Cryptol.TCFloat" =<< traverse go tyargs
            C.TCArray    -> do a <- go (tyargs !! 0)
                               b <- go (tyargs !! 1)
                               scArrayType sc a b
            C.TCRational -> scGlobalApply sc "Cryptol.Rational" []
            C.TCSeq      -> scGlobalApply sc "Cryptol.seq" =<< traverse go tyargs
            C.TCFun      -> do a <- go (tyargs !! 0)
                               b <- go (tyargs !! 1)
                               scFun sc a b
            C.TCTuple _n -> scTupleType sc =<< traverse go tyargs
            C.TCNewtype (C.UserTC _qn _k) -> unimplemented "TCNewtype" -- user-defined, @T@
            C.TCAbstract{} -> panic "importType TODO: abstract type" []
        C.PC pc ->
          case pc of
            C.PLiteral -> -- we omit first argument to class Literal
              do a <- go (tyargs !! 1)
                 scGlobalApply sc "Cryptol.PLiteral" [a]
            _ ->
              do pc' <- importPC sc pc
                 tyargs' <- traverse go tyargs
                 scApplyAll sc pc' tyargs'
        C.TF tf ->
          do tf' <- importTFun sc tf
             tyargs' <- traverse go tyargs
             scApplyAll sc tf' tyargs'
        C.TError _k _msg ->
          panic "importType TError" []
  where
    go = importType sc env

isErasedProp :: C.Prop -> Bool
isErasedProp prop =
  case prop of
    C.TCon (C.PC C.PZero     ) _ -> False
    C.TCon (C.PC C.PLogic    ) _ -> False
    C.TCon (C.PC C.PRing     ) _ -> False
    C.TCon (C.PC C.PIntegral ) _ -> False
    C.TCon (C.PC C.PField    ) _ -> False
    C.TCon (C.PC C.PRound    ) _ -> False
    C.TCon (C.PC C.PEq       ) _ -> False
    C.TCon (C.PC C.PCmp      ) _ -> False
    C.TCon (C.PC C.PSignedCmp) _ -> False
    C.TCon (C.PC C.PLiteral  ) _ -> False
    _ -> True

importPropsType :: SharedContext -> Env -> [C.Prop] -> C.Type -> IO Term
importPropsType sc env [] ty = importType sc env ty
importPropsType sc env (prop : props) ty
  | isErasedProp prop = importPropsType sc env props ty
  | otherwise =
    do p <- importType sc env prop
       t <- importPropsType sc env props ty
       scFun sc p t

nameToString :: C.Name -> String
nameToString = C.unpackIdent . C.nameIdent

tparamToString :: C.TParam -> String
--tparamToString tp = maybe "_" nameToString (C.tpName tp)
tparamToString tp = maybe ("u" ++ show (C.tpUnique tp)) nameToString (C.tpName tp)

importPolyType :: SharedContext -> Env -> [C.TParam] -> [C.Prop] -> C.Type -> IO Term
importPolyType sc env [] props ty = importPropsType sc env props ty
importPolyType sc env (tp : tps) props ty =
  do k <- importKind sc (C.tpKind tp)
     env' <- bindTParam sc tp env
     t <- importPolyType sc env' tps props ty
     scPi sc (tparamToString tp) k t

importSchema :: SharedContext -> Env -> C.Schema -> IO Term
importSchema sc env (C.Forall tparams props ty) = importPolyType sc env tparams props ty

tIsRec' :: C.Type -> Maybe (Map C.Ident C.Type)
tIsRec' t = fmap Map.fromList (C.tIsRec t)

proveProp :: HasCallStack => SharedContext -> Env -> C.Prop -> IO Term
proveProp sc env prop =
  case Map.lookup (normalizeProp prop) (envP env) of

    -- Class dictionary was provided as an argument
    Just (prf, fs, j) ->
       do -- shift deBruijn indicies by j
          v <- incVars sc 0 j prf
          -- apply field projections as necessary to compute superclasses
          -- NB: reverse the order of the fields
          foldM (scRecordSelect sc) v (reverse fs)

    -- Class dictionary not provided, compute it from the structure of types
    Nothing ->
      case prop of
        -- instance Zero Bit
        (C.pIsZero -> Just (C.tIsBit -> True))
          -> do scGlobalApply sc "Cryptol.PZeroBit" []
        -- instance Zero Integer
        (C.pIsZero -> Just (C.tIsInteger -> True))
          -> do scGlobalApply sc "Cryptol.PZeroInteger" []
        -- instance Zero (Z n)
        (C.pIsZero -> Just (C.tIsIntMod -> Just n))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PZeroIntModNum" [n']
        -- instance Zero [n]
        (C.pIsZero -> Just (C.tIsSeq -> Just (n, C.tIsBit -> True)))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PZeroSeqBool" [n']
        -- instance ValidFloat e p => Zero (Float e p)
        (C.pIsZero -> Just (tIsFloat -> Just (e, p)))
          -> do e' <- importType sc env e
                p' <- importType sc env p
                scGlobalApply sc "Cryptol.PZeroFloat" [e', p']
        -- instance (Zero a) => Zero [n]a
        (C.pIsZero -> Just (C.tIsSeq -> Just (n, a)))
          -> do n' <- importType sc env n
                a' <- importType sc env a
                pa <- proveProp sc env (C.pZero a)
                scGlobalApply sc "Cryptol.PZeroSeq" [n', a', pa]
        -- instance (Zero b) => Zero (a -> b)
        (C.pIsZero -> Just (C.tIsFun -> Just (a, b)))
          -> do a' <- importType sc env a
                b' <- importType sc env b
                pb <- proveProp sc env (C.pZero b)
                scGlobalApply sc "Cryptol.PZeroFun" [a', b', pb]
        -- instance (Zero a, Zero b, ...) => Zero (a, b, ...)
        (C.pIsZero -> Just (C.tIsTuple -> Just ts))
          -> do ps <- traverse (proveProp sc env . C.pZero) ts
                scTuple sc ps
        -- instance (Zero a, Zero b, ...) => Zero { x : a, y : b, ... }
        (C.pIsZero -> Just (tIsRec' -> Just fm))
          -> do proveProp sc env (C.pZero (C.tTuple (Map.elems fm)))

        -- instance Logic Bit
        (C.pIsLogic -> Just (C.tIsBit -> True))
          -> do scGlobalApply sc "Cryptol.PLogicBit" []
        -- instance Logic [n]
        (C.pIsLogic -> Just (C.tIsSeq -> Just (n, C.tIsBit -> True)))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PLogicSeqBool" [n']
        -- instance (Logic a) => Logic [n]a
        (C.pIsLogic -> Just (C.tIsSeq -> Just (n, a)))
          -> do n' <- importType sc env n
                a' <- importType sc env a
                pa <- proveProp sc env (C.pLogic a)
                scGlobalApply sc "Cryptol.PLogicSeq" [n', a', pa]
        -- instance (Logic b) => Logic (a -> b)
        (C.pIsLogic -> Just (C.tIsFun -> Just (a, b)))
          -> do a' <- importType sc env a
                b' <- importType sc env b
                pb <- proveProp sc env (C.pLogic b)
                scGlobalApply sc "Cryptol.PLogicFun" [a', b', pb]
        -- instance Logic ()
        (C.pIsLogic -> Just (C.tIsTuple -> Just []))
          -> do scGlobalApply sc "Cryptol.PLogicUnit" []
        -- instance (Logic a, Logic b) => Logic (a, b)
        (C.pIsLogic -> Just (C.tIsTuple -> Just [t]))
          -> do proveProp sc env (C.pLogic t)
        (C.pIsLogic -> Just (C.tIsTuple -> Just (t : ts)))
          -> do a <- importType sc env t
                b <- importType sc env (C.tTuple ts)
                pa <- proveProp sc env (C.pLogic t)
                pb <- proveProp sc env (C.pLogic (C.tTuple ts))
                scGlobalApply sc "Cryptol.PLogicPair" [a, b, pa, pb]
        -- instance (Logic a, Logic b, ...) => instance Logic { x : a, y : b, ... }
        (C.pIsLogic -> Just (tIsRec' -> Just fm))
          -> do proveProp sc env (C.pLogic (C.tTuple (Map.elems fm)))

        -- instance Ring Integer
        (C.pIsRing -> Just (C.tIsInteger -> True))
          -> do scGlobalApply sc "Cryptol.PRingInteger" []
        -- instance Ring (Z n)
        (C.pIsRing -> Just (C.tIsIntMod -> Just n))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PRingIntModNum" [n']
        -- instance (fin n) => Ring [n]
        (C.pIsRing -> Just (C.tIsSeq -> Just (n, C.tIsBit -> True)))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PRingSeqBool" [n']
        -- instance ValidFloat e p => Ring (Float e p)
        (C.pIsRing -> Just (tIsFloat -> Just (e, p)))
          -> do e' <- importType sc env e
                p' <- importType sc env p
                scGlobalApply sc "Cryptol.PRingFloat" [e', p']
        -- instance (Ring a) => Ring [n]a
        (C.pIsRing -> Just (C.tIsSeq -> Just (n, a)))
          -> do n' <- importType sc env n
                a' <- importType sc env a
                pa <- proveProp sc env (C.pRing a)
                scGlobalApply sc "Cryptol.PRingSeq" [n', a', pa]
        -- instance (Ring b) => Ring (a -> b)
        (C.pIsRing -> Just (C.tIsFun -> Just (a, b)))
          -> do a' <- importType sc env a
                b' <- importType sc env b
                pb <- proveProp sc env (C.pRing b)
                scGlobalApply sc "Cryptol.PRingFun" [a', b', pb]
        -- instance Ring ()
        (C.pIsRing -> Just (C.tIsTuple -> Just []))
          -> do scGlobalApply sc "Cryptol.PRingUnit" []
        -- instance (Ring a, Ring b) => Ring (a, b)
        (C.pIsRing -> Just (C.tIsTuple -> Just [t]))
          -> do proveProp sc env (C.pRing t)
        (C.pIsRing -> Just (C.tIsTuple -> Just (t : ts)))
          -> do a <- importType sc env t
                b <- importType sc env (C.tTuple ts)
                pa <- proveProp sc env (C.pRing t)
                pb <- proveProp sc env (C.pRing (C.tTuple ts))
                scGlobalApply sc "Cryptol.PRingPair" [a, b, pa, pb]
        -- instance (Ring a, Ring b, ...) => instance Ring { x : a, y : b, ... }
        (C.pIsRing -> Just (tIsRec' -> Just fm))
          -> do proveProp sc env (C.pRing (C.tTuple (Map.elems fm)))

        -- instance Integral Integer
        (C.pIsIntegral -> Just (C.tIsInteger -> True))
          -> scGlobalApply sc "Cryptol.PIntegralInteger" []
        -- instance Integral [n]
        (C.pIsIntegral -> Just (C.tIsSeq -> (Just (n, C.tIsBit -> True))))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PIntegralSeqBool" [n']

        -- TODO, Field instances
        -- TODO, Round instances

        -- instance Eq Bit
        (C.pIsEq -> Just (C.tIsBit -> True))
          -> do scGlobalApply sc "Cryptol.PEqBit" []
        -- instance Eq Integer
        (C.pIsEq -> Just (C.tIsInteger -> True))
          -> do scGlobalApply sc "Cryptol.PEqInteger" []
        -- instance Eq (Z n)
        (C.pIsEq -> Just (C.tIsIntMod -> Just n))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PEqIntModNum" [n']
        -- instance (fin n) => Eq [n]
        (C.pIsEq -> Just (C.tIsSeq -> Just (n, C.tIsBit -> True)))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PEqSeqBool" [n']
        -- instance (fin n, Eq a) => Eq [n]a
        (C.pIsEq -> Just (C.tIsSeq -> Just (n, a)))
          -> do n' <- importType sc env n
                a' <- importType sc env a
                pa <- proveProp sc env (C.pEq a)
                scGlobalApply sc "Cryptol.PEqSeq" [n', a', pa]
        -- instance Eq ()
        (C.pIsEq -> Just (C.tIsTuple -> Just []))
          -> do scGlobalApply sc "Cryptol.PEqUnit" []
        -- instance (Eq a, Eq b) => Eq (a, b)
        (C.pIsEq -> Just (C.tIsTuple -> Just [t]))
          -> do proveProp sc env (C.pEq t)
        (C.pIsEq -> Just (C.tIsTuple -> Just (t : ts)))
          -> do a <- importType sc env t
                b <- importType sc env (C.tTuple ts)
                pa <- proveProp sc env (C.pEq t)
                pb <- proveProp sc env (C.pEq (C.tTuple ts))
                scGlobalApply sc "Cryptol.PEqPair" [a, b, pa, pb]
        -- instance (Eq a, Eq b, ...) => instance Eq { x : a, y : b, ... }
        (C.pIsEq -> Just (tIsRec' -> Just fm))
          -> do proveProp sc env (C.pEq (C.tTuple (Map.elems fm)))

        -- instance Cmp Bit
        (C.pIsCmp -> Just (C.tIsBit -> True))
          -> do scGlobalApply sc "Cryptol.PCmpBit" []
        -- instance Cmp Integer
        (C.pIsCmp -> Just (C.tIsInteger -> True))
          -> do scGlobalApply sc "Cryptol.PCmpInteger" []
        -- instance (fin n) => Cmp [n]
        (C.pIsCmp -> Just (C.tIsSeq -> Just (n, C.tIsBit -> True)))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PCmpSeqBool" [n']
        -- instance (fin n, Cmp a) => Cmp [n]a
        (C.pIsCmp -> Just (C.tIsSeq -> Just (n, a)))
          -> do n' <- importType sc env n
                a' <- importType sc env a
                pa <- proveProp sc env (C.pCmp a)
                scGlobalApply sc "Cryptol.PCmpSeq" [n', a', pa]
        -- instance Cmp ()
        (C.pIsCmp -> Just (C.tIsTuple -> Just []))
          -> do scGlobalApply sc "Cryptol.PCmpUnit" []
        -- instance (Cmp a, Cmp b) => Cmp (a, b)
        (C.pIsCmp -> Just (C.tIsTuple -> Just [t]))
          -> do proveProp sc env (C.pCmp t)
        (C.pIsCmp -> Just (C.tIsTuple -> Just (t : ts)))
          -> do a <- importType sc env t
                b <- importType sc env (C.tTuple ts)
                pa <- proveProp sc env (C.pCmp t)
                pb <- proveProp sc env (C.pCmp (C.tTuple ts))
                scGlobalApply sc "Cryptol.PCmpPair" [a, b, pa, pb]
        -- instance (Cmp a, Cmp b, ...) => instance Cmp { x : a, y : b, ... }
        (C.pIsCmp -> Just (tIsRec' -> Just fm))
          -> do proveProp sc env (C.pCmp (C.tTuple (Map.elems fm)))

        -- instance (fin n) => SignedCmp [n]
        (C.pIsSignedCmp -> Just (C.tIsSeq -> Just (n, C.tIsBit -> True)))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PSignedCmpWord" [n']
        -- instance (fin n, SignedCmp a) => SignedCmp [n]a
        (C.pIsSignedCmp -> Just (C.tIsSeq -> Just (n, a)))
          -> do n' <- importType sc env n
                a' <- importType sc env a
                pa <- proveProp sc env (C.pSignedCmp a)
                scGlobalApply sc "Cryptol.PSignedCmpSeq" [n', a', pa]
        -- instance SignedCmp ()
        (C.pIsSignedCmp -> Just (C.tIsTuple -> Just []))
          -> do scGlobalApply sc "Cryptol.PSignedCmpUnit" []
        -- instance (SignedCmp a, SignedCmp b) => SignedCmp (a, b)
        (C.pIsSignedCmp -> Just (C.tIsTuple -> Just [t]))
          -> do proveProp sc env (C.pSignedCmp t)
        (C.pIsSignedCmp -> Just (C.tIsTuple -> Just (t : ts)))
          -> do a <- importType sc env t
                b <- importType sc env (C.tTuple ts)
                pa <- proveProp sc env (C.pSignedCmp t)
                pb <- proveProp sc env (C.pSignedCmp (C.tTuple ts))
                scGlobalApply sc "Cryptol.PSignedCmpPair" [a, b, pa, pb]
        -- instance (SignedCmp a, SignedCmp b, ...) => instance SignedCmp { x : a, y : b, ... }
        (C.pIsSignedCmp -> Just (tIsRec' -> Just fm))
          -> do proveProp sc env (C.pSignedCmp (C.tTuple (Map.elems fm)))

        -- instance Literal val Integer
        (C.pIsLiteral -> Just (_, C.tIsInteger -> True))
          -> do scGlobalApply sc "Cryptol.PLiteralInteger" []
        -- instance Literal val (Z n)
        (C.pIsLiteral -> Just (_, C.tIsIntMod -> Just n))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PLiteralIntModNum" [n']
        -- instance (fin n, n >= width val) => Literal val [n]
        (C.pIsLiteral -> Just (_, C.tIsSeq -> Just (n, C.tIsBit -> True)))
          -> do n' <- importType sc env n
                scGlobalApply sc "Cryptol.PLiteralSeqBool" [n']

        _ -> do panic "proveProp" [pretty prop]
  where
    -- TODO: Move to Cryptol/TypeCheck/Type.hs in cryptol package
    tIsFloat :: C.Type -> Maybe (C.Type, C.Type)
    tIsFloat ty =
      case C.tNoUser ty of
        C.TCon (C.TC C.TCFloat) [e, p] -> Just (e, p)
        _ -> Nothing


importPrimitive :: SharedContext -> C.Name -> IO Term
importPrimitive sc n
  | Just nm <- C.asPrim n, Just term <- Map.lookup nm (prelPrims <> arrayPrims <> floatPrims) = term sc
  | Just nm <- C.asPrim n = panic "Unknown Cryptol primitive name" [show nm]
  | otherwise = panic "Improper Cryptol primitive name" [show n]

prelPrims :: Map C.PrimIdent (SharedContext -> IO Term)
prelPrims =
  Map.fromList $
  first C.prelPrim <$>
  [ ("True",         flip scBool True)
  , ("False",        flip scBool False)
  , ("number",       flip scGlobalDef "Cryptol.ecNumber")      -- Converts a numeric type into its corresponding value.
     --                                                        -- {val, a} (Literal val a) => a

  , ("fromZ",        flip scGlobalDef "Cryptol.ecFromZ")       -- {n} (fin n, n >= 1) => Z n -> Integer

    -- -- Zero
  , ("zero",         flip scGlobalDef "Cryptol.ecZero")        -- {a} (Zero a) => a

    -- -- Logic
  , ("&&",           flip scGlobalDef "Cryptol.ecAnd")         -- {a} (Logic a) => a -> a -> a
  , ("||",           flip scGlobalDef "Cryptol.ecOr")          -- {a} (Logic a) => a -> a -> a
  , ("^",            flip scGlobalDef "Cryptol.ecXor")         -- {a} (Logic a) => a -> a -> a
  , ("complement",   flip scGlobalDef "Cryptol.ecCompl")       -- {a} (Logic a) => a -> a

    -- -- Ring
  , ("fromInteger",  flip scGlobalDef "Cryptol.ecFromInteger") -- {a} (Ring a) => Integer -> a
  , ("+",            flip scGlobalDef "Cryptol.ecPlus")        -- {a} (Ring a) => a -> a -> a
  , ("-",            flip scGlobalDef "Cryptol.ecMinus")       -- {a} (Ring a) => a -> a -> a
  , ("*",            flip scGlobalDef "Cryptol.ecMul")         -- {a} (Ring a) => a -> a -> a
  , ("negate",       flip scGlobalDef "Cryptol.ecNeg")         -- {a} (Ring a) => a -> a

    -- -- Integral
  , ("toInteger",    flip scGlobalDef "Cryptol.ecToInteger")   -- {a} (Integral a) => a -> Integer
  , ("/",            flip scGlobalDef "Cryptol.ecDiv")         -- {a} (Integral a) => a -> a -> a
  , ("%",            flip scGlobalDef "Cryptol.ecMod")         -- {a} (Integral a) => a -> a -> a
  , ("^^",           flip scGlobalDef "Cryptol.ecExp")         -- {a} (Ring a, Integral b) => a -> b -> a
  , ("infFrom",      flip scGlobalDef "Cryptol.ecInfFrom")     -- {a} (Integral a) => a -> [inf]a
  , ("infFromThen",  flip scGlobalDef "Cryptol.ecInfFromThen") -- {a} (Integral a) => a -> a -> [inf]a

    -- -- Field
  , ("recip",        flip scGlobalDef "Cryptol.ecRecip")       -- {a} (Field a) => a -> a
  , ("/.",           flip scGlobalDef "Cryptol.ecFieldDiv")    -- {a} (Field a) => a -> a -> a

    -- -- Round
  , ("ceiling",      flip scGlobalDef "Cryptol.ecCeiling")     -- {a} (Round a) => a -> Integer
  , ("floor",        flip scGlobalDef "Cryptol.ecFloor")       -- {a} (Round a) => a -> Integer
  , ("trunc",        flip scGlobalDef "Cryptol.ecTruncate")    -- {a} (Round a) => a -> Integer
  , ("roundAway",    flip scGlobalDef "Cryptol.ecRoundAway")   -- {a} (Round a) => a -> Integer
  , ("roundToEven",  flip scGlobalDef "Cryptol.ecRoundToEven") -- {a} (Round a) => a -> Integer

    -- -- Eq
  , ("==",           flip scGlobalDef "Cryptol.ecEq")          -- {a} (Eq a) => a -> a -> Bit
  , ("!=",           flip scGlobalDef "Cryptol.ecNotEq")       -- {a} (Eq a) => a -> a -> Bit

    -- -- Cmp
  , ("<",            flip scGlobalDef "Cryptol.ecLt")          -- {a} (Cmp a) => a -> a -> Bit
  , (">",            flip scGlobalDef "Cryptol.ecGt")          -- {a} (Cmp a) => a -> a -> Bit
  , ("<=",           flip scGlobalDef "Cryptol.ecLtEq")        -- {a} (Cmp a) => a -> a -> Bit
  , (">=",           flip scGlobalDef "Cryptol.ecGtEq")        -- {a} (Cmp a) => a -> a -> Bit

    -- -- SignedCmp
  , ("<$",           flip scGlobalDef "Cryptol.ecSLt")         -- {a} (SignedCmp a) => a -> a -> Bit

    -- -- Bitvector primitives
  , ("/$",           flip scGlobalDef "Cryptol.ecSDiv")        -- {n} (fin n, n>=1) => [n] -> [n] -> [n]
  , ("%$",           flip scGlobalDef "Cryptol.ecSMod")        -- {n} (fin n, n>=1) => [n] -> [n] -> [n]
  , ("lg2",          flip scGlobalDef "Cryptol.ecLg2")         -- {n} (fin n) => [n] -> [n]
  , (">>$",          flip scGlobalDef "Cryptol.ecSShiftR")     -- {n, ix} (fin n, n >= 1, Integral ix) => [n] -> ix -> [n]

    -- -- Rational primitives
  , ("ratio",        flip scGlobalDef "Cryptol.ecRatio")       -- Integer -> Integer -> Rational

    -- -- FLiteral
  , ("fraction",     flip scGlobalDef "Cryptol.ecFraction")    -- {m, n, r, a} FLiteral m n r a => a

    -- -- Shifts/rotates
  , ("<<",           flip scGlobalDef "Cryptol.ecShiftL")      -- {n, ix, a} (Integral ix, Zero a) => [n]a -> ix -> [n]a
  , (">>",           flip scGlobalDef "Cryptol.ecShiftR")      -- {n, ix, a} (Integral ix, Zero a) => [n]a -> ix -> [n]a
  , ("<<<",          flip scGlobalDef "Cryptol.ecRotL")        -- {n, ix, a} (fin n, Integral ix) => [n]a -> ix -> [n]a
  , (">>>",          flip scGlobalDef "Cryptol.ecRotR")        -- {n, ix, a} (fin n, Integral ix) => [n]a -> ix -> [n]a

    -- -- Sequences primitives
  , ("#",            flip scGlobalDef "Cryptol.ecCat")         -- {a,b,d} (fin a) => [a] d -> [b] d -> [a + b] d
  , ("splitAt",      flip scGlobalDef "Cryptol.ecSplitAt")     -- {a,b,c} (fin a) => [a+b] c -> ([a]c,[b]c)
  , ("join",         flip scGlobalDef "Cryptol.ecJoin")        -- {a,b,c} (fin b) => [a][b]c -> [a * b]c
  , ("split",        flip scGlobalDef "Cryptol.ecSplit")       -- {a,b,c} (fin b) => [a * b] c -> [a][b] c
  , ("reverse",      flip scGlobalDef "Cryptol.ecReverse")     -- {a,b} (fin a) => [a] b -> [a] b
  , ("transpose",    flip scGlobalDef "Cryptol.ecTranspose")   -- {a,b,c} [a][b]c -> [b][a]c
  , ("@",            flip scGlobalDef "Cryptol.ecAt")          -- {n, a, ix} (Integral ix) => [n]a -> ix -> a
  , ("!",            flip scGlobalDef "Cryptol.ecAtBack")      -- {n, a, ix} (fin n, Integral ix) => [n]a -> ix -> a
  , ("update",       flip scGlobalDef "Cryptol.ecUpdate")      -- {n, a, ix} (Integral ix) => [n]a -> ix -> a -> [n]a
  , ("updateEnd",    flip scGlobalDef "Cryptol.ecUpdateEnd")   -- {n, a, ix} (fin n, Integral ix) => [n]a -> ix -> a -> [n]a

    -- -- Enumerations
  , ("fromTo",       flip scGlobalDef "Cryptol.ecFromTo")
    --                            -- fromTo : {first, last, bits, a}
    --                            --           ( fin last, fin bits, last >== first,
    --                            --             Literal first a, Literal last a)
    --                            --        => [1 + (last - first)]a
  , ("fromThenTo",   flip scGlobalDef "Cryptol.ecFromThenTo")
    --                            -- fromThenTo : {first, next, last, a, len}
    --                            --              ( fin first, fin next, fin last
    --                            --              , Literal first a, Literal next a, Literal last a
    --                            --              , first != next
    --                            --              , lengthFromThenTo first next last == len) => [len]a

  , ("error",        flip scGlobalDef "Cryptol.ecError")       -- {at,len} (fin len) => [len][8] -> at -- Run-time error
  , ("random",       flip scGlobalDef "Cryptol.ecRandom")      -- {a} => [32] -> a -- Random values
  , ("trace",        flip scGlobalDef "Cryptol.ecTrace")       -- {n,a,b} [n][8] -> a -> b -> b
  ]

arrayPrims :: Map C.PrimIdent (SharedContext -> IO Term)
arrayPrims =
  Map.fromList $
  first (C.PrimIdent C.arrayName) <$>
  [ ("arrayConstant", flip scGlobalDef "Cryptol.ecArrayConstant") -- {a,b} b -> Array a b
  , ("arrayLookup",   flip scGlobalDef "Cryptol.ecArrayLookup") -- {a,b} Array a b -> a -> b
  , ("arrayUpdate",   flip scGlobalDef "Cryptol.ecArrayUpdate") -- {a,b} Array a b -> a -> b -> Array a b
  ]

floatPrims :: Map C.PrimIdent (SharedContext -> IO Term)
floatPrims =
  Map.fromList $
  first C.floatPrim <$>
  [ ("fpNaN",      flip scGlobalDef "Cryptol.ecFpNaN")
  , ("fpPosInf",   flip scGlobalDef "Cryptol.ecFpPosInf")
  , ("fpFromBits", flip scGlobalDef "Cryptol.ecFpFromBits")
  , ("fpToBits",   flip scGlobalDef "Cryptol.ecFpToBits")
  , ("=.=",        flip scGlobalDef "Cryptol.ecFpEq")
  , ("fpAdd",      flip scGlobalDef "Cryptol.ecFpAdd")
  , ("fpSub",      flip scGlobalDef "Cryptol.ecFpSub")
  , ("fpMul",      flip scGlobalDef "Cryptol.ecFpMul")
  , ("fpDiv",      flip scGlobalDef "Cryptol.ecFpDiv")
  ]


-- | Convert a Cryptol expression to a SAW-Core term. Calling
-- 'scTypeOf' on the result of @'importExpr' sc env expr@ must yield a
-- type that is equivalent (i.e. convertible) with the one returned by
-- @'importSchema' sc env ('fastTypeOf' ('envC' env) expr)@.
importExpr :: SharedContext -> Env -> C.Expr -> IO Term
importExpr sc env expr =
  case expr of
    C.EList es t ->
      do t' <- importType sc env t
         es' <- traverse (importExpr' sc env (C.tMono t)) es
         scVector sc t' es'

    C.ETuple es ->
      do es' <- traverse (importExpr sc env) es
         scTuple sc es'

    C.ERec (Map.fromList -> fm) ->
      do es' <- traverse (importExpr sc env) (Map.elems fm)
         scTuple sc es'

    C.ESel e sel ->
      -- Elimination for tuple/record/list
      case sel of
        C.TupleSel i _maybeLen ->
          do e' <- importExpr sc env e
             let t = fastTypeOf (envC env) e
             case C.tIsTuple t of
               Just ts ->
                 do scTupleSelector sc e' (i+1) (length ts)
               Nothing ->
                 do f <- mapTupleSelector sc env i t
                    scApply sc f e'
        C.RecordSel x _ ->
          do e' <- importExpr sc env e
             let t = fastTypeOf (envC env) e
             case tIsRec' t of
               Just fm ->
                 do i <- the (elemIndex x (Map.keys fm))
                    scTupleSelector sc e' (i+1) (Map.size fm)
               Nothing ->
                 do f <- mapRecordSelector sc env x t
                    scApply sc f e'
        C.ListSel i _maybeLen ->
          do let t = fastTypeOf (envC env) e
             (n, a) <-
               case C.tIsSeq t of
                 Just (n, a) -> return (n, a)
                 Nothing -> panic "importExpr" ["ListSel: not a list type"]
             a' <- importType sc env a
             n' <- importType sc env n
             e' <- importExpr sc env e
             i' <- scNat sc (fromIntegral i)
             scGlobalApply sc "Cryptol.eListSel" [a', n', e', i']

    C.ESet e1 sel e2 ->
      case sel of
        C.TupleSel i _maybeLen ->
          do e1' <- importExpr sc env e1
             e2' <- importExpr sc env e2
             let t1 = fastTypeOf (envC env) e1
             case C.tIsTuple t1 of
               Nothing -> panic "importExpr" ["ESet/TupleSel: not a tuple type"]
               Just ts ->
                 do ts' <- traverse (importType sc env) ts
                    let t2' = ts' !! i
                    f <- scGlobalApply sc "Cryptol.const" [t2', t2', e2']
                    g <- tupleUpdate sc f i ts'
                    scApply sc g e1'
        C.RecordSel x _ ->
          do e1' <- importExpr sc env e1
             e2' <- importExpr sc env e2
             let t1 = fastTypeOf (envC env) e1
             case tIsRec' t1 of
               Nothing -> panic "importExpr" ["ESet/TupleSel: not a tuple type"]
               Just tm ->
                 do i <- the (elemIndex x (Map.keys tm))
                    ts' <- traverse (importType sc env) (Map.elems tm)
                    let t2' = ts' !! i
                    f <- scGlobalApply sc "Cryptol.const" [t2', t2', e2']
                    g <- tupleUpdate sc f i ts'
                    scApply sc g e1'
        C.ListSel _i _maybeLen ->
          panic "importExpr" ["ESet/ListSel: unsupported"]

    C.EIf e1 e2 e3 ->
      do let ty = fastTypeOf (envC env) e2
         ty' <- importType sc env ty
         e1' <- importExpr sc env e1
         e2' <- importExpr sc env e2
         e3' <- importExpr' sc env (C.tMono ty) e3
         scGlobalApply sc "Prelude.ite" [ty', e1', e2', e3']

    C.EComp len eltty e mss ->
      importComp sc env len eltty e mss

    C.EVar qname ->
      case Map.lookup qname (envE env) of
        Just (e', j) -> incVars sc 0 j e'
        Nothing      -> panic "importExpr" ["unknown variable: " ++ show qname]

    C.ETAbs tp e ->
      do env' <- bindTParam sc tp env
         k <- importKind sc (C.tpKind tp)
         e' <- importExpr sc env' e
         scLambda sc (tparamToString tp) k e'

    C.ETApp e t ->
      do e' <- importExpr sc env e
         t' <- importType sc env t
         scApply sc e' t'

    C.EApp e1 e2 ->
      do e1' <- importExpr sc env e1
         let t1 = fastTypeOf (envC env) e1
         t1a <-
           case C.tIsFun t1 of
             Just (a, _) -> return a
             Nothing -> panic "importExpr" ["expected function type"]
         e2' <- importExpr' sc env (C.tMono t1a) e2
         scApply sc e1' e2'

    C.EAbs x t e ->
      do t' <- importType sc env t
         env' <- bindName sc x (C.tMono t) env
         e' <- importExpr sc env' e
         scLambda sc (nameToString x) t' e'

    C.EProofAbs prop e
      | isErasedProp prop -> importExpr sc env e
      | otherwise ->
        do p' <- importType sc env prop
           env' <- bindProp sc prop env
           e' <- importExpr sc env' e
           scLambda sc "_P" p' e'

    C.EProofApp e ->
      case fastSchemaOf (envC env) e of
        C.Forall [] (p : _ps) _ty
          | isErasedProp p -> importExpr sc env e
          | otherwise ->
            do e' <- importExpr sc env e
               prf <- proveProp sc env p
               scApply sc e' prf
        s -> panic "importExpr" ["EProofApp: invalid type: " ++ show (e, s)]

    C.EWhere e dgs ->
      do env' <- importDeclGroups sc env dgs
         importExpr sc env' e

  where
    the :: Maybe a -> IO a
    the = maybe (panic "importExpr" ["internal type error"]) return


-- | Convert a Cryptol expression with the given type schema to a
-- SAW-Core term. Calling 'scTypeOf' on the result of @'importExpr''
-- sc env schema expr@ must yield a type that is equivalent (i.e.
-- convertible) with the one returned by @'importSchema' sc env
-- schema@.
importExpr' :: SharedContext -> Env -> C.Schema -> C.Expr -> IO Term
importExpr' sc env schema expr =
  case expr of
    C.ETuple es ->
      do ty <- the (C.isMono schema)
         ts <- the (C.tIsTuple ty)
         es' <- sequence (zipWith go ts es)
         scTuple sc es'

    C.ERec (Map.fromList -> fm) ->
      do ty <- the (C.isMono schema)
         tm <- the (tIsRec' ty)
         let es = Map.elems fm
         es' <- sequence (zipWith go (Map.elems tm) es)
         scTuple sc es'

    C.EIf e1 e2 e3 ->
      do ty <- the (C.isMono schema)
         ty' <- importType sc env ty
         e1' <- importExpr sc env e1
         e2' <- importExpr' sc env schema e2
         e3' <- importExpr' sc env schema e3
         scGlobalApply sc "Prelude.ite" [ty', e1', e2', e3']

    C.ETAbs tp e ->
      do schema' <-
           case schema of
             C.Forall (tp1 : tparams) props ty ->
               let s = C.singleTParamSubst tp1 (C.TVar (C.TVBound tp))
               in return (C.Forall tparams (map (plainSubst s) props) (plainSubst s ty))
             C.Forall [] _ _ -> panic "importExpr'" ["internal error: unexpected type abstraction"]
         env' <- bindTParam sc tp env
         k <- importKind sc (C.tpKind tp)
         e' <- importExpr' sc env' schema' e
         scLambda sc (tparamToString tp) k e'

    C.EAbs x _ e ->
      do ty <- the (C.isMono schema)
         (a, b) <- the (C.tIsFun ty)
         a' <- importType sc env a
         env' <- bindName sc x (C.tMono a) env
         e' <- importExpr' sc env' (C.tMono b) e
         scLambda sc (nameToString x) a' e'

    C.EProofAbs _ e ->
      do (prop, schema') <-
           case schema of
             C.Forall [] (p : ps) ty -> return (p, C.Forall [] ps ty)
             C.Forall _ _ _ -> panic "importExpr" ["internal type error"]
         if isErasedProp prop
           then importExpr' sc env schema' e
           else do p' <- importType sc env prop
                   env' <- bindProp sc prop env
                   e' <- importExpr' sc env' schema' e
                   scLambda sc "_P" p' e'

    C.EWhere e dgs ->
      do env' <- importDeclGroups sc env dgs
         importExpr' sc env' schema e

    C.EList     {} -> fallback
    C.ESel      {} -> fallback
    C.ESet      {} -> fallback
    C.EComp     {} -> fallback
    C.EVar      {} -> fallback
    C.EApp      {} -> fallback
    C.ETApp     {} -> fallback
    C.EProofApp {} -> fallback

  where
    go :: C.Type -> C.Expr -> IO Term
    go t = importExpr' sc env (C.tMono t)

    the :: Maybe a -> IO a
    the = maybe (panic "importExpr" ["internal type error"]) return

    fallback :: IO Term
    fallback =
      do let t1 = fastTypeOf (envC env) expr
         t2 <- the (C.isMono schema)
         expr' <- importExpr sc env expr
         coerceTerm sc env t1 t2 expr'

mapTupleSelector :: SharedContext -> Env -> Int -> C.Type -> IO Term
mapTupleSelector sc env i = fmap fst . go
  where
    go :: C.Type -> IO (Term, C.Type)
    go t =
      case C.tNoUser t of
        (C.tIsSeq -> Just (n, a)) -> do
          (f, b) <- go a
          a' <- importType sc env a
          b' <- importType sc env b
          n' <- importType sc env n
          g <- scGlobalApply sc "Cryptol.seqMap" [a', b', n', f]
          return (g, C.tSeq n b)
        (C.tIsFun -> Just (n, a)) -> do
          (f, b) <- go a
          a' <- importType sc env a
          b' <- importType sc env b
          n' <- importType sc env n
          g <- scGlobalApply sc "Cryptol.compose" [n', a', b', f]
          return (g, C.tFun n b)
        (C.tIsTuple -> Just ts) -> do
          x <- scLocalVar sc 0
          y <- scTupleSelector sc x (i+1) (length ts)
          t' <- importType sc env t
          f <- scLambda sc "x" t' y
          return (f, ts !! i)
        _ -> panic "importExpr" ["invalid tuple selector", show i, show t]

mapRecordSelector :: SharedContext -> Env -> C.Ident -> C.Type -> IO Term
mapRecordSelector sc env i = fmap fst . go
  where
    go :: C.Type -> IO (Term, C.Type)
    go t =
      case C.tNoUser t of
        (C.tIsSeq -> Just (n, a)) ->
          do (f, b) <- go a
             a' <- importType sc env a
             b' <- importType sc env b
             n' <- importType sc env n
             g <- scGlobalApply sc "Cryptol.seqMap" [a', b', n', f]
             return (g, C.tSeq n b)
        (C.tIsFun -> Just (n, a)) ->
          do (f, b) <- go a
             a' <- importType sc env a
             b' <- importType sc env b
             n' <- importType sc env n
             g <- scGlobalApply sc "Cryptol.compose" [n', a', b', f]
             return (g, C.tFun n b)
        (tIsRec' -> Just tm) | Just k <- elemIndex i (Map.keys tm) ->
          do x <- scLocalVar sc 0
             y <- scTupleSelector sc x (k+1) (Map.size tm)
             t' <- importType sc env t
             f <- scLambda sc "x" t' y
             return (f, Map.elems tm !! k)
        _ -> panic "importExpr" ["invalid record selector", show i, show t]

tupleUpdate :: SharedContext -> Term -> Int -> [Term] -> IO Term
tupleUpdate _ f 0 [_] = return f
tupleUpdate sc f 0 (a : ts) =
  do b <- scTupleType sc ts
     scGlobalApply sc "Cryptol.updFst" [a, b, f]
tupleUpdate sc f n (a : ts) =
  do g <- tupleUpdate sc f (n - 1) ts
     b <- scTupleType sc ts
     scGlobalApply sc "Cryptol.updSnd" [a, b, g]
tupleUpdate _ _ _ [] = panic "tupleUpdate" ["empty tuple"]

-- | Apply a substitution to a type *without* simplifying
-- constraints like @Ring [n]a@ to @Ring a@. (This is in contrast to
-- 'apSubst', which performs simplifications wherever possible.)
plainSubst :: C.Subst -> C.Type -> C.Type
plainSubst s ty =
  case ty of
    C.TCon tc ts   -> C.TCon tc (map (plainSubst s) ts)
    C.TUser f ts t -> C.TUser f (map (plainSubst s) ts) (plainSubst s t)
    C.TRec fs      -> C.TRec [ (x, plainSubst s t) | (x, t) <- fs ]
    C.TVar x       -> C.apSubst s (C.TVar x)

-- | Currently this imports declaration groups by inlining all the
-- definitions. (With subterm sharing, this is not as bad as it might
-- seem.) We might want to think about generating let or where
-- expressions instead.
importDeclGroup :: Bool -> SharedContext -> Env -> C.DeclGroup -> IO Env

importDeclGroup isTopLevel sc env (C.Recursive [decl]) =
  case C.dDefinition decl of
    C.DPrim ->
      panic "importDeclGroup" ["Primitive declarations cannot be recursive:", show (C.dName decl)]
    C.DExpr expr ->
      do env1 <- bindName sc (C.dName decl) (C.dSignature decl) env
         t' <- importSchema sc env (C.dSignature decl)
         e' <- importExpr' sc env1 (C.dSignature decl) expr
         let x = nameToString (C.dName decl)
         f' <- scLambda sc x t' e'
         rhs <- scGlobalApply sc "Prelude.fix" [t', f']
         rhs' <- if not isTopLevel then return rhs else scConstant sc x rhs t'
         let env' = env { envE = Map.insert (C.dName decl) (rhs', 0) (envE env)
                        , envC = Map.insert (C.dName decl) (C.dSignature decl) (envC env) }
         return env'


-- - A group of mutually-recursive declarations -
-- We handle this by "tupling up" all the declarations using a record and
-- taking the fixpoint at this record type.  The desired declarations are then
-- achieved by projecting the field names from this record.
importDeclGroup isTopLevel sc env (C.Recursive decls) =
  do -- build the environment for the declaration bodies
     let dm = Map.fromList [ (C.dName d, d) | d <- decls ]

     -- grab a reference to the outermost variable; this will be the record in the body
     -- of the lambda we build later
     v0 <- scLocalVar sc 0

     -- build a list of projections from a record variable
     vm <- traverse (scRecordSelect sc v0 . nameToString . C.dName) dm

     -- the types of the declarations
     tm <- traverse (importSchema sc env . C.dSignature) dm
     -- the type of the recursive record
     rect <- scRecordType sc (Map.assocs $ Map.mapKeys nameToString tm)

     let env1 = liftEnv env
     let env2 = env1 { envE = Map.union (fmap (\v -> (v, 0)) vm) (envE env1)
                     , envC = Map.union (fmap C.dSignature dm) (envC env1)
                     , envS = rect : envS env1 }

     let extractDeclExpr decl =
           case C.dDefinition decl of
             C.DExpr expr -> importExpr' sc env2 (C.dSignature decl) expr
             C.DPrim ->
                panic "importDeclGroup"
                        [ "Primitive declarations cannot be recursive:"
                        , show (C.dName decl)
                        ]

     -- the raw imported bodies of the declarations
     em <- traverse extractDeclExpr dm

     -- the body of the recursive record
     recv <- scRecord sc (Map.mapKeys nameToString em)

     -- build a lambda from the record body...
     f <- scLambda sc "fixRecord" rect recv

     -- and take its fixpoint
     rhs <- scGlobalApply sc "Prelude.fix" [rect, f]

     -- finally, build projections from the fixed record to shove into the environment
     -- if toplevel, then wrap each binding with a Constant constructor
     let mkRhs d t =
           do let s = nameToString (C.dName d)
              r <- scRecordSelect sc rhs s
              if isTopLevel then scConstant sc s r t else return r
     rhss <- sequence (Map.intersectionWith mkRhs dm tm)

     let env' = env { envE = Map.union (fmap (\v -> (v, 0)) rhss) (envE env)
                    , envC = Map.union (fmap C.dSignature dm) (envC env)
                    }
     return env'

importDeclGroup isTopLevel sc env (C.NonRecursive decl) =
  case C.dDefinition decl of
    C.DPrim
     | isTopLevel -> do
        rhs <- importPrimitive sc (C.dName decl)
        let env' = env { envE = Map.insert (C.dName decl) (rhs, 0) (envE env)
                      , envC = Map.insert (C.dName decl) (C.dSignature decl) (envC env) }
        return env'
     | otherwise -> do
        panic "importDeclGroup" ["Primitive declarations only allowed at top-level:", show (C.dName decl)]

    C.DExpr expr -> do
     rhs <- importExpr' sc env (C.dSignature decl) expr
     rhs' <- if not isTopLevel then return rhs else do
       t <- importSchema sc env (C.dSignature decl)
       scConstant sc (nameToString (C.dName decl)) rhs t
     let env' = env { envE = Map.insert (C.dName decl) (rhs', 0) (envE env)
                    , envC = Map.insert (C.dName decl) (C.dSignature decl) (envC env) }
     return env'

importDeclGroups :: SharedContext -> Env -> [C.DeclGroup] -> IO Env
importDeclGroups sc = foldM (importDeclGroup False sc)

importTopLevelDeclGroups :: SharedContext -> Env -> [C.DeclGroup] -> IO Env
importTopLevelDeclGroups sc = foldM (importDeclGroup True sc)

coerceTerm :: SharedContext -> Env -> C.Type -> C.Type -> Term -> IO Term
coerceTerm sc env t1 t2 e
  | t1 == t2 = do return e
  | otherwise =
    do t1' <- importType sc env t1
       t2' <- importType sc env t2
       q <- proveEq sc env t1 t2
       scGlobalApply sc "Prelude.coerce" [t1', t2', q, e]

proveEq :: SharedContext -> Env -> C.Type -> C.Type -> IO Term
proveEq sc env t1 t2
  | t1 == t2 =
    do s <- scSort sc (mkSort 0)
       t' <- importType sc env t1
       scCtorApp sc "Prelude.Refl" [s, t']
  | otherwise =
    case (C.tNoUser t1, C.tNoUser t2) of
      (C.tIsSeq -> Just (n1, a1), C.tIsSeq -> Just (n2, a2)) ->
        do n1' <- importType sc env n1
           n2' <- importType sc env n2
           a1' <- importType sc env a1
           a2' <- importType sc env a2
           num <- scDataTypeApp sc "Cryptol.Num" []
           nEq <- if n1 == n2
                  then scGlobalApply sc "Prelude.Refl" [num, n1']
                  else scGlobalApply sc "Prelude.unsafeAssert" [num, n1', n2']
           aEq <- proveEq sc env a1 a2
           if a1 == a2
             then scGlobalApply sc "Cryptol.seq_cong1" [n1', n2', a1', nEq]
             else scGlobalApply sc "Cryptol.seq_cong" [n1', n2', a1', a2', nEq, aEq]
      (C.tIsFun -> Just (a1, b1), C.tIsFun -> Just (a2, b2)) ->
        do a1' <- importType sc env a1
           a2' <- importType sc env a2
           b1' <- importType sc env b1
           b2' <- importType sc env b2
           aEq <- proveEq sc env a1 a2
           bEq <- proveEq sc env b1 b2
           scGlobalApply sc "Cryptol.fun_cong" [a1', a2', b1', b2', aEq, bEq]
      (C.tIsTuple -> Just (a1 : ts1), C.tIsTuple -> Just (a2 : ts2))
        | length ts1 == length ts2 ->
          do let b1 = C.tTuple ts1
                 b2 = C.tTuple ts2
             a1' <- importType sc env a1
             a2' <- importType sc env a2
             b1' <- importType sc env b1
             b2' <- importType sc env b2
             aEq <- proveEq sc env a1 a2
             bEq <- proveEq sc env b1 b2
             if b1 == b2
               then scGlobalApply sc "Cryptol.pair_cong1" [a1', a2', b1', aEq]
               else if a1 == a2
                    then scGlobalApply sc "Cryptol.pair_cong2" [a1', b1', b2', bEq]
                    else scGlobalApply sc "Cryptol.pair_cong" [a1', a2', b1', b2', aEq, bEq]
      (tIsRec' -> Just tm1, tIsRec' -> Just tm2)
        | Map.keys tm1 == Map.keys tm2 ->
          proveEq sc env (C.tTuple (Map.elems tm1)) (C.tTuple (Map.elems tm2))
      (_, _) ->
        panic "proveEq" ["Internal type error:", pretty t1, pretty t2]

--------------------------------------------------------------------------------
-- List comprehensions

importComp :: SharedContext -> Env -> C.Type -> C.Type -> C.Expr -> [[C.Match]] -> IO Term
importComp sc env lenT elemT expr mss =
  do let zipAll [] = panic "importComp" ["zero-branch list comprehension"]
         zipAll [branch] =
           do (xs, len, ty, args) <- importMatches sc env branch
              m <- importType sc env len
              a <- importType sc env ty
              return (xs, m, a, [args], len)
         zipAll (branch : branches) =
           do (xs, len, ty, args) <- importMatches sc env branch
              m <- importType sc env len
              a <- importType sc env ty
              (ys, n, b, argss, len') <- zipAll branches
              zs <- scGlobalApply sc "Cryptol.seqZip" [a, b, m, n, xs, ys]
              mn <- scGlobalApply sc "Cryptol.tcMin" [m, n]
              ab <- scTupleType sc [a, b]
              return (zs, mn, ab, args : argss, C.tMin len len')
     (xs, n, a, argss, lenT') <- zipAll mss
     f <- lambdaTuples sc env elemT expr argss
     b <- importType sc env elemT
     ys <- scGlobalApply sc "Cryptol.seqMap" [a, b, n, f, xs]
     -- The resulting type might not match the annotation, so we coerce
     coerceTerm sc env (C.tSeq lenT' elemT) (C.tSeq lenT elemT) ys

lambdaTuples :: SharedContext -> Env -> C.Type -> C.Expr -> [[(C.Name, C.Type)]] -> IO Term
lambdaTuples sc env _ty expr [] = importExpr sc env expr
lambdaTuples sc env ty expr (args : argss) =
  do f <- lambdaTuple sc env ty expr argss args
     if null args || null argss
       then return f
       else do a <- importType sc env (tNestedTuple (map snd args))
               b <- importType sc env (tNestedTuple (map (tNestedTuple . map snd) argss))
               c <- importType sc env ty
               scGlobalApply sc "Prelude.uncurry" [a, b, c, f]

lambdaTuple :: SharedContext -> Env -> C.Type -> C.Expr -> [[(C.Name, C.Type)]] -> [(C.Name, C.Type)] -> IO Term
lambdaTuple sc env ty expr argss [] = lambdaTuples sc env ty expr argss
lambdaTuple sc env ty expr argss ((x, t) : args) =
  do a <- importType sc env t
     env' <- bindName sc x (C.Forall [] [] t) env
     e <- lambdaTuple sc env' ty expr argss args
     f <- scLambda sc (nameToString x) a e
     if null args
        then return f
        else do b <- importType sc env (tNestedTuple (map snd args))
                let tuple = tNestedTuple (map (tNestedTuple . map snd) argss)
                c <- importType sc env (if null argss then ty else C.tFun tuple ty)
                scGlobalApply sc "Prelude.uncurry" [a, b, c, f]

tNestedTuple :: [C.Type] -> C.Type
tNestedTuple [] = C.tTuple []
tNestedTuple [t] = t
tNestedTuple (t : ts) = C.tTuple [t, tNestedTuple ts]


-- | Returns the shared term, length type, element tuple type, bound
-- variables.
importMatches :: SharedContext -> Env -> [C.Match]
              -> IO (Term, C.Type, C.Type, [(C.Name, C.Type)])
importMatches _sc _env [] = panic "importMatches" ["importMatches: empty comprehension branch"]

importMatches sc env [C.From name _len _eltty expr] = do
  (len, ty) <- case C.tIsSeq (fastTypeOf (envC env) expr) of
                 Just x -> return x
                 Nothing -> panic "importMatches" ["type mismatch from: " ++ show (fastTypeOf (envC env) expr)]
  xs <- importExpr sc env expr
  return (xs, len, ty, [(name, ty)])

importMatches sc env (C.From name _len _eltty expr : matches) = do
  (len1, ty1) <- case C.tIsSeq (fastTypeOf (envC env) expr) of
                   Just x -> return x
                   Nothing -> panic "importMatches" ["type mismatch from: " ++ show (fastTypeOf (envC env) expr)]
  m <- importType sc env len1
  a <- importType sc env ty1
  xs <- importExpr sc env expr
  env' <- bindName sc name (C.Forall [] [] ty1) env
  (body, len2, ty2, args) <- importMatches sc env' matches
  n <- importType sc env len2
  b <- importType sc env ty2
  f <- scLambda sc (nameToString name) a body
  result <- scGlobalApply sc "Cryptol.from" [a, b, m, n, xs, f]
  return (result, C.tMul len1 len2, C.tTuple [ty1, ty2], (name, ty1) : args)

importMatches sc env [C.Let decl]
  | C.DPrim <- C.dDefinition decl = do
     panic "importMatches" ["Primitive declarations not allowed in 'let':", show (C.dName decl)]
  | C.DExpr expr <- C.dDefinition decl = do
     e <- importExpr sc env expr
     ty1 <- case C.dSignature decl of
              C.Forall [] [] ty1 -> return ty1
              _ -> unimplemented "polymorphic Let"
     a <- importType sc env ty1
     result <- scGlobalApply sc "Prelude.single" [a, e]
     return (result, C.tOne, ty1, [(C.dName decl, ty1)])

importMatches sc env (C.Let decl : matches) =
  case C.dDefinition decl of
    C.DPrim -> do
     panic "importMatches" ["Primitive declarations not allowed in 'let':", show (C.dName decl)]
    C.DExpr expr -> do
     e <- importExpr sc env expr
     ty1 <- case C.dSignature decl of
              C.Forall [] [] ty1 -> return ty1
              _ -> unimplemented "polymorphic Let"
     a <- importType sc env ty1
     env' <- bindName sc (C.dName decl) (C.dSignature decl) env
     (body, len, ty2, args) <- importMatches sc env' matches
     n <- importType sc env len
     b <- importType sc env ty2
     f <- scLambda sc (nameToString (C.dName decl)) a body
     result <- scGlobalApply sc "Cryptol.mlet" [a, b, n, e, f]
     return (result, len, C.tTuple [ty1, ty2], (C.dName decl, ty1) : args)

pIsNeq :: C.Type -> Maybe (C.Type, C.Type)
pIsNeq ty = case C.tNoUser ty of
              C.TCon (C.PC C.PNeq) [t1, t2] -> Just (t1, t2)
              _                             -> Nothing

--------------------------------------------------------------------------------
-- Utilities

asCryptolTypeValue :: SC.CValue -> Maybe C.Type
asCryptolTypeValue v =
  case v of
    SC.VBoolType -> return C.tBit
    SC.VIntType -> return C.tInteger
    SC.VArrayType v1 v2 -> do
      t1 <- asCryptolTypeValue v1
      t2 <- asCryptolTypeValue v2
      return $ C.tArray t1 t2
    SC.VVecType (SC.VNat n) v2 -> do
      t2 <- asCryptolTypeValue v2
      return (C.tSeq (C.tNum n) t2)
    SC.VDataType "Prelude.Stream" [v1] -> do
      t1 <- asCryptolTypeValue v1
      return (C.tSeq C.tInf t1)
    SC.VUnitType -> return (C.tTuple [])
    SC.VPairType v1 v2 -> do
      t1 <- asCryptolTypeValue v1
      t2 <- asCryptolTypeValue v2
      case C.tIsTuple t2 of
        Just ts -> return (C.tTuple (t1 : ts))
        Nothing -> return (C.tTuple [t1, t2])
    SC.VPiType v1 f -> do
      case v1 of
        -- if we see that the parameter is a Cryptol.Num, it's a
        -- pretty good guess that it originally was a
        -- polymorphic number type.
        SC.VDataType "Cryptol.Num" [] ->
          let msg= unwords ["asCryptolTypeValue: can't infer a polymorphic Cryptol"
                           ,"type. Please, make sure all numeric types are"
                           ,"specialized before constructing a typed term."
                           ]
          in error msg
            -- otherwise we issue a generic error about dependent type inference
        _ -> do
          let msg = unwords ["asCryptolTypeValue: can't infer a Cryptol type"
                            ,"for a dependent SAW-Core type."
                            ]
          let v2 = SC.runIdentity (f (error msg))
          t1 <- asCryptolTypeValue v1
          t2 <- asCryptolTypeValue v2
          return (C.tFun t1 t2)
    _ -> Nothing

scCryptolType :: SharedContext -> Term -> IO C.Type
scCryptolType sc t =
  do modmap <- scGetModuleMap sc
     case asCryptolTypeValue (SC.evalSharedTerm modmap Map.empty t) of
       Just ty -> return ty
       Nothing -> panic "scCryptolType" ["scCryptolType: unsupported type " ++ showTerm t]

scCryptolEq :: SharedContext -> Term -> Term -> IO Term
scCryptolEq sc x y =
  do rules <- concat <$> traverse defRewrites (defs1 ++ defs2)
     let ss = addConvs natConversions (addRules rules emptySimpset)
     tx <- scTypeOf sc x >>= rewriteSharedTerm sc ss >>= scCryptolType sc
     ty <- scTypeOf sc y >>= rewriteSharedTerm sc ss >>= scCryptolType sc
     unless (tx == ty) $
       panic "scCryptolEq"
                 [ "scCryptolEq: type mismatch between"
                 , pretty tx
                 , "and"
                 , pretty ty
                 ]

     -- Actually apply the equality function, along with the Eq class dictionary
     t <- scTypeOf sc x
     c <- scCryptolType sc t
     k <- importType sc emptyEnv c
     eqPrf <- proveProp sc emptyEnv (C.pEq c)
     scGlobalApply sc "Cryptol.ecEq" [k, eqPrf, x, y]

  where
    defs1 = map (mkIdent (mkModuleName ["Prelude"])) ["bitvector"]
    defs2 = map (mkIdent (mkModuleName ["Cryptol"])) ["seq", "ty"]
    defRewrites ident =
      do maybe_def <- scFindDef sc ident
         case maybe_def of
           Nothing -> return []
           Just def -> scDefRewriteRules sc def

-- | Convert from SAWCore's Value type to Cryptol's, guided by the
-- Cryptol type schema.
exportValueWithSchema :: C.Schema -> SC.CValue -> V.Value
exportValueWithSchema (C.Forall [] [] ty) v = exportValue (evalValType Map.empty ty) v
exportValueWithSchema _ _ = V.VPoly (error "exportValueWithSchema")
-- TODO: proper support for polymorphic values

exportValue :: TV.TValue -> SC.CValue -> V.Value
exportValue ty v = case ty of

  TV.TVBit ->
    V.VBit (SC.toBool v)

  TV.TVInteger ->
    V.VInteger (case v of SC.VInt x -> x; _ -> error "exportValue: expected integer")

  TV.TVIntMod _modulus ->
    V.VInteger (case v of SC.VInt x -> x; _ -> error "exportValue: expected integer")

  TV.TVArray{} -> error $ "exportValue: (on array type " ++ show ty ++ ")"

  TV.TVRational -> error "exportValue: Not yet implemented: Rational"

  TV.TVFloat _ _ -> panic "exportValue: Not yet implemented: Float" []

  TV.TVSeq _ e ->
    case v of
      SC.VWord w -> V.word V.Concrete (toInteger (width w)) (unsigned w)
      SC.VVector xs
        | TV.isTBit e -> V.VWord (toInteger (Vector.length xs)) (V.ready (V.LargeBitsVal (fromIntegral (Vector.length xs))
                            (V.finiteSeqMap V.Concrete . map (V.ready . V.VBit . SC.toBool . SC.runIdentity . force) $ Fold.toList xs)))
        | otherwise   -> V.VSeq (toInteger (Vector.length xs)) $ V.finiteSeqMap V.Concrete $
                            map (V.ready . exportValue e . SC.runIdentity . force) $ Vector.toList xs
      _ -> error $ "exportValue (on seq type " ++ show ty ++ ")"

  -- infinite streams
  TV.TVStream e ->
    case v of
      SC.VExtra (SC.CStream trie) -> V.VStream (V.IndexSeqMap $ \i -> V.ready $ exportValue e (IntTrie.apply trie i))
      _ -> error $ "exportValue (on seq type " ++ show ty ++ ")"

  -- tuples
  TV.TVTuple etys -> V.VTuple (exportTupleValue etys v)

  -- records
  TV.TVRec fields ->
      V.VRecord (Map.fromList $ exportRecordValue (Map.assocs (Map.fromList fields)) v)

  -- functions
  TV.TVFun _aty _bty ->
    V.VFun (error "exportValue: TODO functions")

  -- abstract types
  TV.TVAbstract{} ->
    error "exportValue: TODO abstract types"

exportTupleValue :: [TV.TValue] -> SC.CValue -> [V.Eval V.Value]
exportTupleValue tys v =
  case (tys, v) of
    ([]    , SC.VUnit    ) -> []
    ([t]   , _           ) -> [V.ready $ exportValue t v]
    (t : ts, SC.VPair x y) -> (V.ready $ exportValue t (run x)) : exportTupleValue ts (run y)
    _                      -> error $ "exportValue: expected tuple"
  where
    run = SC.runIdentity . force

exportRecordValue :: [(C.Ident, TV.TValue)] -> SC.CValue -> [(C.Ident, V.Eval V.Value)]
exportRecordValue fields v =
  case (fields, v) of
    ([]         , SC.VUnit    ) -> []
    ([(n, t)]   , _           ) -> [(n, V.ready $ exportValue t v)]
    ((n, t) : ts, SC.VPair x y) ->
      (n, V.ready $ exportValue t (run x)) : exportRecordValue ts (run y)
    (_, SC.VRecordValue (alistAllFields
                         (map (C.unpackIdent . fst) fields) -> Just ths)) ->
      zipWith (\(n,t) x -> (n, V.ready $ exportValue t (run x))) fields ths
    _                              -> error $ "exportValue: expected record"
  where
    run = SC.runIdentity . force

fvAsBool :: FirstOrderValue -> Bool
fvAsBool (FOVBit b) = b
fvAsBool _ = error "fvAsBool: expected FOVBit value"

exportFirstOrderValue :: FirstOrderValue -> V.Value
exportFirstOrderValue fv =
  case fv of
    FOVBit b    -> V.VBit b
    FOVInt i    -> V.VInteger i
    FOVWord w x -> V.word V.Concrete (toInteger w) x
    FOVVec t vs
      | t == FOTBit -> V.VWord len (V.ready (V.LargeBitsVal len (V.finiteSeqMap V.Concrete . map (V.ready . V.VBit . fvAsBool) $ vs)))
      | otherwise   -> V.VSeq  len (V.finiteSeqMap V.Concrete (map (V.ready . exportFirstOrderValue) vs))
      where len = toInteger (length vs)
    FOVArray{}  -> error $ "exportFirstOrderValue: unsupported FOT Array"
    FOVTuple vs -> V.VTuple (map (V.ready . exportFirstOrderValue) vs)
    FOVRec vm   -> V.VRecord $ Map.fromList [ (C.packIdent n, V.ready $ exportFirstOrderValue v) | (n, v) <- Map.assocs vm ]

importFirstOrderValue :: FirstOrderType -> V.Value -> IO FirstOrderValue
importFirstOrderValue t0 v0 = V.runEval (V.EvalOpts C.quietLogger V.defaultPPOpts) (go t0 v0)
  where
  go :: FirstOrderType -> V.Value -> V.Eval FirstOrderValue
  go t v = case (t,v) of
    (FOTBit         , V.VBit b)        -> return (FOVBit b)
    (FOTInt         , V.VInteger i)    -> return (FOVInt i)
    (FOTVec _ FOTBit, V.VWord w wv)    -> FOVWord (fromIntegral w) . V.bvVal <$> (V.asWordVal V.Concrete =<< wv)
    (FOTVec _ ty    , V.VSeq len xs)   -> FOVVec ty <$> traverse (go ty =<<) (V.enumerateSeqMap len xs)
    (FOTTuple tys   , V.VTuple xs)     -> FOVTuple <$> traverse (\(ty, x) -> go ty =<< x) (zip tys xs)
    (FOTRec fs      , V.VRecord xs)    ->
        do xs' <- Map.fromList <$> mapM importField (Map.assocs xs)
           let missing = Set.difference (Map.keysSet fs) (Map.keysSet xs')
           unless (Set.null missing)
                  (panic "importFirstOrderValue" $
                         ["Missing fields while importing finite value:"] ++ Set.toList missing)
           return $ FOVRec $ xs'
      where
       importField :: (C.Ident, V.Eval V.Value) -> V.Eval (String, FirstOrderValue)
       importField (C.unpackIdent -> nm,x)
         | Just ty <- Map.lookup nm fs = do
                x' <- go ty =<< x
                return (nm, x')
         | otherwise = panic "importFirstOrderValue" ["Unexpected field name while importing finite value:", show nm]

    _ -> panic "importFirstOrderValue"
                ["Expected finite value of type:", show t, "but got", show v]

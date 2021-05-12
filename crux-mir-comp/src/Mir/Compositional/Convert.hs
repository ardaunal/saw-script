{-# LANGUAGE DataKinds #-}
{-# Language FlexibleContexts #-}
{-# Language GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Conversions between Crucible `RegValue`s and SAW `Term`s.
module Mir.Compositional.Convert
where

import Control.Lens ((^.), (^..), each)
import Control.Monad
import Control.Monad.IO.Class
import Data.Functor.Const
import Data.IORef
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Parameterized.Context (pattern Empty, pattern (:>), Assignment)
import qualified Data.Parameterized.Context as Ctx
import Data.Parameterized.Some
import Data.Parameterized.TraversableFC
import Data.Set (Set)
import qualified Data.Set as Set
import GHC.Stack (HasCallStack)

import Lang.Crucible.Backend
import Lang.Crucible.Simulator.RegValue
import Lang.Crucible.Types

import qualified What4.Expr.Builder as W4
import qualified What4.Interface as W4
import qualified What4.Partial as W4
import qualified What4.SWord as W4

import qualified Verifier.SAW.SharedTerm as SAW
import qualified Verifier.SAW.Simulator.MonadLazy as SAW
import qualified Verifier.SAW.Simulator.Value as SAW
import Verifier.SAW.Simulator.What4 (SValue)
import qualified Verifier.SAW.Simulator.What4 as SAW

import Mir.Intrinsics
import qualified Mir.Mir as M
import Mir.TransTy (tyToRepr, canInitialize, isUnsized)


-- | TypeShape is used to classify MIR `Ty`s and their corresponding
-- CrucibleTypes into a few common cases.  We don't use `Ty` directly because
-- there are some `Ty`s that have identical structure (such as TyRef vs.
-- TyRawPtr) or similar enough structure that we'd rather write only one case
-- (such as `u8` vs `i8` vs `i32`, all primitives/BaseTypes).  And we don't use
-- TypeRepr directly because it's lacking information in some cases (notably
-- `TyAdt`, which is always AnyRepr, concealing the actual field types of the
-- struct).
--
-- In each constructor, the first `M.Ty` is the overall MIR type (e.g., for
-- ArrayShape, this is the TyArray type).  The overall `TypeRepr tp` isn't
-- stored directly, but can be computed with `shapeType`.
data TypeShape (tp :: CrucibleType) where
    UnitShape :: M.Ty -> TypeShape UnitType
    PrimShape :: M.Ty -> BaseTypeRepr btp -> TypeShape (BaseToType btp)
    TupleShape :: M.Ty -> [M.Ty] -> Assignment FieldShape ctx -> TypeShape (StructType ctx)
    ArrayShape :: M.Ty -> M.Ty -> TypeShape tp -> TypeShape (MirVectorType tp)
    StructShape :: M.Ty -> [M.Ty] -> Assignment FieldShape ctx -> TypeShape AnyType
    -- | Note that RefShape contains only a TypeRepr for the pointee type, not
    -- a TypeShape.  None of our operations need to recurse inside pointers,
    -- and also this saves us from some infinite recursion.
    RefShape :: M.Ty -> M.Ty -> TypeRepr tp -> TypeShape (MirReferenceType tp)

-- | The TypeShape of a struct field, which might have a MaybeType wrapper to
-- allow for partial initialization.
data FieldShape (tp :: CrucibleType) where
    OptField :: TypeShape tp -> FieldShape (MaybeType tp)
    ReqField :: TypeShape tp -> FieldShape tp

-- | Return the `TypeShape` of `ty`.
--
-- It is guaranteed that the `tp :: CrucibleType` index of the resulting
-- `TypeShape` matches that returned by `tyToRepr`.
tyToShape :: M.Collection -> M.Ty -> Some TypeShape
tyToShape col ty = go ty
  where
    go :: M.Ty -> Some TypeShape
    go ty = case ty of
        M.TyBool -> goPrim ty
        M.TyChar -> goPrim ty
        M.TyInt _ -> goPrim ty
        M.TyUint _ -> goPrim ty
        M.TyTuple [] -> goUnit ty
        M.TyTuple tys -> goTuple ty tys
        M.TyClosure tys -> goTuple ty tys
        M.TyFnDef _ -> goUnit ty
        M.TyArray ty' _ | Some shp <- go ty' -> Some $ ArrayShape ty ty' shp
        M.TyAdt nm _ _ -> case Map.lookup nm (col ^. M.adts) of
            Just (M.Adt _ M.Struct [v] _ _) -> goStruct ty (v ^.. M.vfields . each . M.fty)
            Just (M.Adt _ ak _ _ _) -> error $ "tyToShape: AdtKind " ++ show ak ++ " NYI"
            Nothing -> error $ "tyToShape: bad adt: " ++ show ty
        M.TyRef ty' mutbl -> goRef ty ty' mutbl
        M.TyRawPtr ty' mutbl -> goRef ty ty' mutbl
        _ -> error $ "tyToShape: " ++ show ty ++ " NYI"

    goPrim :: M.Ty -> Some TypeShape
    goPrim ty | Some tpr <- tyToRepr ty, AsBaseType btpr <- asBaseType tpr =
        Some $ PrimShape ty btpr
    goPrim ty | Some tpr <- tyToRepr ty =
        error $ "tyToShape: type " ++ show ty ++ " produced non-primitive type " ++ show tpr

    goUnit :: M.Ty -> Some TypeShape
    goUnit ty = Some $ UnitShape ty

    goTuple :: M.Ty -> [M.Ty] -> Some TypeShape
    goTuple ty tys | Some flds <- loop tys Empty = Some $ TupleShape ty tys flds
      where
        loop :: forall ctx. [M.Ty] -> Assignment FieldShape ctx -> Some (Assignment FieldShape)
        loop [] flds = Some flds
        loop (ty:tys) flds | Some fld <- go ty = loop tys (flds :> OptField fld)

    goStruct :: M.Ty -> [M.Ty] -> Some TypeShape
    goStruct ty tys | Some flds <- loop tys Empty = Some $ StructShape ty tys flds
      where
        loop :: forall ctx. [M.Ty] -> Assignment FieldShape ctx -> Some (Assignment FieldShape)
        loop [] flds = Some flds
        loop (ty:tys) flds | Some fld <- goField ty = loop tys (flds :> fld)

    goField :: M.Ty -> Some FieldShape
    goField ty | Some shp <- go ty = case canInitialize ty of
        True -> Some $ ReqField shp
        False -> Some $ OptField shp

    goRef :: M.Ty -> M.Ty -> M.Mutability -> Some TypeShape
    goRef ty ty' _ | isUnsized ty' = error $
        "tyToShape: fat pointer " ++ show ty ++ " NYI"
    goRef ty ty' _ | Some tpr <- tyToRepr ty' = Some $ RefShape ty ty' tpr

-- | Given a `Ty` and the result of `tyToRepr ty`, produce a `TypeShape` with
-- the same index `tp`.  Raises an `error` if the `TypeRepr` doesn't match
-- `tyToRepr ty`.
tyToShapeEq :: M.Collection -> M.Ty -> TypeRepr tp -> TypeShape tp
tyToShapeEq col ty tpr | Some shp <- tyToShape col ty =
    case testEquality (shapeType shp) tpr of
        Just Refl -> shp
        Nothing -> error $ "tyToShapeEq: type " ++ show ty ++
            " does not have representation " ++ show tpr ++
            " (got " ++ show (shapeType shp) ++ " instead)"

shapeType :: TypeShape tp -> TypeRepr tp
shapeType shp = go shp
  where
    go :: forall tp. TypeShape tp -> TypeRepr tp
    go (UnitShape _) = UnitRepr
    go (PrimShape _ btpr) = baseToType btpr
    go (TupleShape _ _ flds) = StructRepr $ fmapFC fieldShapeType flds
    go (ArrayShape _ _ shp) = MirVectorRepr $ shapeType shp
    go (StructShape _ _ _flds) = AnyRepr
    go (RefShape _ _ tpr) = MirReferenceRepr tpr

fieldShapeType :: FieldShape tp -> TypeRepr tp
fieldShapeType (ReqField shp) = shapeType shp
fieldShapeType (OptField shp) = MaybeRepr $ shapeType shp

shapeMirTy :: TypeShape tp -> M.Ty
shapeMirTy (UnitShape ty) = ty
shapeMirTy (PrimShape ty _) = ty
shapeMirTy (TupleShape ty _ _) = ty
shapeMirTy (ArrayShape ty _ _) = ty
shapeMirTy (StructShape ty _ _) = ty
shapeMirTy (RefShape ty _ _) = ty

fieldShapeMirTy :: FieldShape tp -> M.Ty
fieldShapeMirTy (ReqField shp) = shapeMirTy shp
fieldShapeMirTy (OptField shp) = shapeMirTy shp


-- | Run `f` on each `SymExpr` in `v`.
visitRegValueExprs ::
    forall sym tp m.
    Monad m =>
    sym ->
    TypeRepr tp ->
    RegValue sym tp ->
    (forall btp. W4.SymExpr sym btp -> m ()) ->
    m ()
visitRegValueExprs _sym tpr_ v_ f = go tpr_ v_
  where
    go :: forall tp'. TypeRepr tp' -> RegValue sym tp' -> m ()
    go tpr v | AsBaseType _btpr <- asBaseType tpr = f v
    go AnyRepr (AnyValue tpr' v') = go tpr' v'
    go UnitRepr () = return ()
    go (MaybeRepr _tpr) W4.Unassigned = return ()
    go (MaybeRepr tpr') (W4.PE p v') = f p >> go tpr' v'
    go (VectorRepr tpr') vec = mapM_ (go tpr') vec
    go (StructRepr ctxr) fields = forMWithRepr_ ctxr fields $ \tpr' (RV v') -> go tpr' v'
    go (VariantRepr ctxr) variants = forMWithRepr_ ctxr variants $ \tpr' (VB pe) -> case pe of
        W4.Unassigned -> return ()
        W4.PE p v' -> f p >> go tpr' v'
    go (MirVectorRepr tpr') vec = case vec of
        MirVector_Vector v -> mapM_ (go tpr') v
        MirVector_PartialVector pv -> mapM_ (go (MaybeRepr tpr')) pv
        MirVector_Array _ -> error $ "visitRegValueExprs: unsupported: MirVector_Array"
    -- For now, we require that all references within a MethodSpec be
    -- nonoverlapping, and ignore the `SymExpr`s inside.  If we ever want to
    -- write a spec for e.g. `f(arr, &arr[i], i)`, where the second reference
    -- is offset from the first by a symbolic integer value, then we'd need to
    -- visit exprs from some suffix of each MirReference.
    go (MirReferenceRepr _) _ = return ()
    go tpr _ = error $ "visitRegValueExprs: unsupported: " ++ show tpr

    forMWithRepr_ :: forall ctx m f. Monad m =>
        CtxRepr ctx -> Assignment f ctx -> (forall tp. TypeRepr tp -> f tp -> m ()) -> m ()
    forMWithRepr_ ctxr assn f = void $
        Ctx.zipWithM (\x y -> f x y >> return (Const ())) ctxr assn

-- | Run `f` on each free symbolic variable in `e`.
visitExprVars ::
    forall t tp m.
    MonadIO m =>
    W4.IdxCache t (Const ()) ->
    W4.Expr t tp ->
    (forall tp'. W4.ExprBoundVar t tp' -> m ()) ->
    m ()
visitExprVars cache e f = go Set.empty e
  where
    go :: Set (Some (W4.ExprBoundVar t)) -> W4.Expr t tp' -> m ()
    go bound e = void $ W4.idxCacheEval cache e (go' bound e >> return (Const ()))

    go' :: Set (Some (W4.ExprBoundVar t)) -> W4.Expr t tp' -> m ()
    go' bound e = case e of
        W4.BoundVarExpr v
          | not $ Set.member (Some v) bound -> f v
          | otherwise -> return ()
        W4.NonceAppExpr nae -> case W4.nonceExprApp nae of
            W4.Forall v e' -> go (Set.insert (Some v) bound) e'
            W4.Exists v e' -> go (Set.insert (Some v) bound) e'
            W4.Annotation _ _ e' -> go bound e'
            W4.ArrayFromFn _ -> error "unexpected ArrayFromFn"
            W4.MapOverArrays _ _ _ -> error "unexpected MapOverArrays"
            W4.ArrayTrueOnEntries _ _ -> error "unexpected ArrayTrueOnEntries"
            W4.FnApp _ _ -> error "unexpected FnApp"
        W4.AppExpr ae ->
            void $ W4.traverseApp (\e' -> go bound e' >> return e') $ W4.appExprApp ae
        W4.StringExpr _ _ -> return ()
        W4.BoolExpr _ _ -> return ()
        W4.SemiRingLiteral _ _ _ -> return ()


readMaybeType :: forall tp sym. IsSymInterface sym =>
    sym -> String -> TypeRepr tp -> RegValue sym (MaybeType tp) ->
    IO (RegValue sym tp)
readMaybeType sym desc tpr rv = readPartExprMaybe sym rv >>= \x -> case x of
    Just x -> return x
    Nothing -> error $ "regToSetup: accessed possibly-uninitialized " ++ desc ++
        " of type " ++ show tpr

readPartExprMaybe :: IsSymInterface sym => sym -> W4.PartExpr (W4.Pred sym) a -> IO (Maybe a)
readPartExprMaybe _sym W4.Unassigned = return Nothing
readPartExprMaybe _sym (W4.PE p v)
  | Just True <- W4.asConstantPred p = return $ Just v
  | otherwise = return Nothing


-- | Convert a `SAW.Term` into a `W4.Expr`.
termToExpr :: forall sym t st fs.
    (IsSymInterface sym, sym ~ W4.ExprBuilder t st fs, HasCallStack) =>
    sym ->
    SAW.SharedContext ->
    Map SAW.VarIndex (Some (W4.Expr t)) ->
    SAW.Term ->
    IO (Some (W4.SymExpr sym))
termToExpr sym sc varMap term = do
    sv <- termToSValue sym sc varMap term
    case SAW.valueToSymExpr sv of
        Just x -> return x
        Nothing -> error $ "termToExpr: failed to convert SValue"

-- | Convert a `SAW.Term` into a Crucible `RegValue`.  Requires a `TypeShape`
-- giving the expected MIR/Crucible type in order to distinguish cases like
-- `(A, (B, C))` vs `(A, B, C)` (these are the same type in saw-core).
termToReg :: forall sym t st fs tp.
    (IsSymInterface sym, sym ~ W4.ExprBuilder t st fs, HasCallStack) =>
    sym ->
    SAW.SharedContext ->
    Map SAW.VarIndex (Some (W4.Expr t)) ->
    SAW.Term ->
    TypeShape tp ->
    IO (RegValue sym tp)
termToReg sym sc varMap term shp = do
    sv <- termToSValue sym sc varMap term
    go shp sv
  where
    go :: forall tp'. TypeShape tp' -> SValue sym -> IO (RegValue sym tp')
    go shp sv = case (shp, sv) of
        (UnitShape _, SAW.VUnit) -> return ()
        (PrimShape _ BaseBoolRepr, SAW.VBool b) -> return b
        (PrimShape _ (BaseBVRepr w), SAW.VWord (W4.DBV e))
          | Just Refl <- testEquality (W4.exprType e) (BaseBVRepr w) -> return e
        (TupleShape _ _ flds, _) -> do
            svs <- tupleToListRev (Ctx.sizeInt $ Ctx.size flds) [] sv
            goTuple flds svs
        _ -> error $ "termToReg: type error: need to produce " ++ show (shapeType shp) ++
            ", but simulator returned " ++ show sv

    -- | Convert an `SValue` tuple (built from nested `VPair`s) into a list of
    -- the inner `SValue`s, in reverse order.
    tupleToListRev :: Int -> [SValue sym] -> SValue sym -> IO [SValue sym]
    tupleToListRev 2 acc (SAW.VPair x y) = do
        x' <- SAW.force x
        y' <- SAW.force y
        return $ y' : x' : acc
    tupleToListRev n acc (SAW.VPair x xs) | n > 2 = do
        x' <- SAW.force x
        xs' <- SAW.force xs
        tupleToListRev (n - 1) (x' : acc) xs'
    tupleToListRev n _ _ = error $ "bad tuple size " ++ show n
    tupleToListRev n _ v = error $ "termToReg: expected tuple of " ++ show n ++
        " elements, but got " ++ show v

    goTuple :: forall ctx.
        Assignment FieldShape ctx ->
        [SValue sym] ->
        IO (RegValue sym (StructType ctx))
    goTuple Empty [] = return Empty
    goTuple (flds :> fld) (sv : svs) = do
        rv <- goField fld sv
        rvs <- goTuple flds svs
        return (rvs :> RV rv)

    goField :: forall tp'. FieldShape tp' -> SValue sym -> IO (RegValue sym tp')
    goField (ReqField shp) sv = go shp sv
    goField (OptField shp) sv = W4.justPartExpr sym <$> go shp sv

-- | Common code for termToExpr and termToReg
termToSValue :: forall sym t st fs.
    (IsSymInterface sym, sym ~ W4.ExprBuilder t st fs, HasCallStack) =>
    sym ->
    SAW.SharedContext ->
    Map SAW.VarIndex (Some (W4.Expr t)) ->
    SAW.Term ->
    IO (SAW.SValue sym)
termToSValue sym sc varMap term = do
    let convert (Some expr) = case SAW.symExprToValue (W4.exprType expr) expr of
            Just x -> return x
            Nothing -> error $ "termToExpr: failed to convert var  of what4 type " ++
                show (W4.exprType expr)
    ecMap <- mapM convert varMap
    ref <- newIORef mempty
    SAW.w4SolveBasic sym sc mempty ecMap ref mempty term

-- | Convert a `SAW.Term` to a `W4.Pred`.  If the term doesn't have boolean
-- type, this will raise an error.
termToPred :: forall sym t st fs.
    (IsSymInterface sym, sym ~ W4.ExprBuilder t st fs, HasCallStack) =>
    sym ->
    SAW.SharedContext ->
    Map SAW.VarIndex (Some (W4.Expr t)) ->
    SAW.Term ->
    IO (W4.Pred sym)
termToPred sym sc varMap term = do
    Some expr <- termToExpr sym sc varMap term
    case W4.exprType expr of
        BaseBoolRepr -> return expr
        btpr -> error $ "termToPred: got result of type " ++ show btpr ++ ", not BaseBoolRepr"

-- | Convert a `SAW.Term` representing a type to a `W4.BaseTypeRepr`.
termToType :: forall sym t st fs.
    (IsSymInterface sym, sym ~ W4.ExprBuilder t st fs, HasCallStack) =>
    sym ->
    SAW.SharedContext ->
    SAW.Term ->
    IO (Some W4.BaseTypeRepr)
termToType sym sc term = do
    ref <- newIORef mempty
    sv <- SAW.w4SolveBasic sym sc mempty mempty ref mempty term
    tv <- case sv of
        SAW.TValue tv -> return tv
        _ -> error $ "termToType: bad SValue"
    case tv of
        SAW.VBoolType -> return $ Some BaseBoolRepr
        SAW.VVecType w SAW.VBoolType -> do
            Some w <- return $ mkNatRepr w
            LeqProof <- case testLeq (knownNat @1) w of
                Just x -> return x
                Nothing -> error "termToPred: zero-width bitvector"
            return $ Some $ BaseBVRepr w
        _ -> error $ "termToType: bad SValue"

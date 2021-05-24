{-# LANGUAGE CPP #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

{- |
Module      : Verifier.SAW.Simulator.Prims
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.Simulator.Prims
( Prim(..)
, BasePrims(..)
, constMap
  -- * primitive function constructors
, primFun
, strictFun
, constFun
, boolFun
, natFun
, intFun
, intModFun
, tvalFun
, wordFun
, vectorFun
, Pack
, Unpack

  -- * primitive computations
, selectV
, expByNatOp
, intToNatOp
, natToIntOp
, vRotateL
, vRotateR
, vShiftL
, vShiftR
, muxValue
, shifter
) where

import Prelude hiding (sequence, mapM)

import GHC.Stack( HasCallStack )

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif
import Control.Monad (liftM, unless, mzero)
import Control.Monad.Fix (MonadFix(mfix))
import Control.Monad.Trans
import Control.Monad.Trans.Maybe
import Data.Bits
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Vector (Vector)
import qualified Data.Vector as V
import Numeric.Natural (Natural)

import Verifier.SAW.Term.Functor (Ident, primType, primName)
import Verifier.SAW.Simulator.Value
import Verifier.SAW.Prim
import qualified Verifier.SAW.Prim as Prim

import qualified Verifier.SAW.Utils as Panic (panic)


-- | A utility type for implementing primitive functions.
--   This type allows primtives to more easily define
--   functions that expect certain kinds of arguments,
--   and allows the simulator to respond gracefully if
--   the actual arguments don't match the expected filters.
data Prim l
  = PrimFun    (Thunk l -> Prim l)
  | PrimStrict (Value l -> Prim l)
  | forall a. PrimFilterFun Text (Value l -> MaybeT (EvalM l) a) (a -> Prim l)
  | Prim (EvalM l (Value l))
  | PrimValue (Value l)

-- | A primitive that takes a nonstrict argument
primFun :: (Thunk l -> Prim l) -> Prim l
primFun = PrimFun

-- | A primitive that takes a strict argument
strictFun :: (Value l -> Prim l) -> Prim l
strictFun = PrimStrict

-- | A primitive that ignores an argument
constFun :: Prim l -> Prim l
constFun p = PrimFun (const p)

-- | A primitive that requires a boolean argument
boolFun :: VMonad l => (VBool l -> Prim l) -> Prim l
boolFun = PrimFilterFun "expected Bool" r
  where r (VBool b) = pure b
        r _ = mzero

-- | A primitive that requires a concrete natural argument
natFun :: VMonad l => (Natural -> Prim l) -> Prim l
natFun = PrimFilterFun "expected Nat" r
  where r (VNat n) = pure n
        r (VCtorApp (primName -> "Prelude.Zero") [] [])  = pure 0
        r (VCtorApp (primName -> "Prelude.Succ") [] [x]) = succ <$> (r =<< lift (force x))
        r _ = mzero

-- | A primitive that requires an integer argument
intFun :: VMonad l => (VInt l -> Prim l) -> Prim l
intFun = PrimFilterFun "expected Integer" r
  where r (VInt i) = pure i
        r _ = mzero

-- | A primitive that requires a (Z n) argument
intModFun :: VMonad l => (VInt l -> Prim l) -> Prim l
intModFun = PrimFilterFun "expeted IntMod" r
  where r (VIntMod _ i) = pure i
        r _ = mzero

-- | A primitive that requires a type argument
tvalFun :: VMonad l => (TValue l -> Prim l) -> Prim l
tvalFun = PrimFilterFun "expected type value" r
  where r (TValue tv) = pure tv
        r _ = mzero

-- | A primitive that requires a packed word argument
wordFun :: VMonad l => Pack l -> (VWord l -> Prim l) -> Prim l
wordFun pack = PrimFilterFun "expected word" r
  where r (VWord w)    = pure w
        r (VVector xs) = lift . pack =<< V.mapM (\x -> r' =<< lift (force x)) xs
        r _ = mzero

        r' (VBool b)   = pure b
        r' _ = mzero

-- | A primitive that requires a vector argument
vectorFun :: (VMonad l, Show (Extra l)) =>
  Unpack l -> (Vector (Thunk l) -> Prim l) -> Prim l
vectorFun unpack = PrimFilterFun "expected vector" r
  where r (VVector xs) = pure xs
        r (VWord w)    = fmap (ready . VBool) <$> lift (unpack w)
        r _ = mzero

------------------------------------------------------------
--

-- | A collection of implementations of primitives on base types.
-- These can be used to derive other primitives on higher types.
data BasePrims l =
  BasePrims
  { bpAsBool :: VBool l -> Maybe Bool
    -- Bitvectors
  , bpUnpack  :: VWord l -> EvalM l (Vector (VBool l))
  , bpPack    :: Vector (VBool l) -> MWord l
  , bpBvAt    :: VWord l -> Int -> MBool l
  , bpBvLit   :: Int -> Integer -> MWord l
  , bpBvSize  :: VWord l -> Int
  , bpBvJoin  :: VWord l -> VWord l -> MWord l
  , bpBvSlice :: Int -> Int -> VWord l -> MWord l
    -- Conditionals
  , bpMuxBool  :: VBool l -> VBool l -> VBool l -> MBool l
  , bpMuxWord  :: VBool l -> VWord l -> VWord l -> MWord l
  , bpMuxInt   :: VBool l -> VInt l -> VInt l -> MInt l
  , bpMuxExtra :: TValue l -> VBool l -> Extra l -> Extra l -> EvalM l (Extra l)
    -- Booleans
  , bpTrue   :: VBool l
  , bpFalse  :: VBool l
  , bpNot    :: VBool l -> MBool l
  , bpAnd    :: VBool l -> VBool l -> MBool l
  , bpOr     :: VBool l -> VBool l -> MBool l
  , bpXor    :: VBool l -> VBool l -> MBool l
  , bpBoolEq :: VBool l -> VBool l -> MBool l
    -- Bitvector logical
  , bpBvNot  :: VWord l -> MWord l
  , bpBvAnd  :: VWord l -> VWord l -> MWord l
  , bpBvOr   :: VWord l -> VWord l -> MWord l
  , bpBvXor  :: VWord l -> VWord l -> MWord l
    -- Bitvector arithmetic
  , bpBvNeg  :: VWord l -> MWord l
  , bpBvAdd  :: VWord l -> VWord l -> MWord l
  , bpBvSub  :: VWord l -> VWord l -> MWord l
  , bpBvMul  :: VWord l -> VWord l -> MWord l
  , bpBvUDiv :: VWord l -> VWord l -> MWord l
  , bpBvURem :: VWord l -> VWord l -> MWord l
  , bpBvSDiv :: VWord l -> VWord l -> MWord l
  , bpBvSRem :: VWord l -> VWord l -> MWord l
  , bpBvLg2  :: VWord l -> MWord l
    -- Bitvector comparisons
  , bpBvEq   :: VWord l -> VWord l -> MBool l
  , bpBvsle  :: VWord l -> VWord l -> MBool l
  , bpBvslt  :: VWord l -> VWord l -> MBool l
  , bpBvule  :: VWord l -> VWord l -> MBool l
  , bpBvult  :: VWord l -> VWord l -> MBool l
  , bpBvsge  :: VWord l -> VWord l -> MBool l
  , bpBvsgt  :: VWord l -> VWord l -> MBool l
  , bpBvuge  :: VWord l -> VWord l -> MBool l
  , bpBvugt  :: VWord l -> VWord l -> MBool l
    -- Bitvector shift/rotate
  , bpBvRolInt :: VWord l -> Integer -> MWord l
  , bpBvRorInt :: VWord l -> Integer -> MWord l
  , bpBvShlInt :: VBool l -> VWord l -> Integer -> MWord l
  , bpBvShrInt :: VBool l -> VWord l -> Integer -> MWord l
  , bpBvRol    :: VWord l -> VWord l -> MWord l
  , bpBvRor    :: VWord l -> VWord l -> MWord l
  , bpBvShl    :: VBool l -> VWord l -> VWord l -> MWord l
  , bpBvShr    :: VBool l -> VWord l -> VWord l -> MWord l
    -- Bitvector misc
  , bpBvPopcount           :: VWord l -> MWord l
  , bpBvCountLeadingZeros  :: VWord l -> MWord l
  , bpBvCountTrailingZeros :: VWord l -> MWord l
  , bpBvForall             :: Natural -> (VWord l -> MBool l) -> MBool l
    -- Integer operations
  , bpIntAdd :: VInt l -> VInt l -> MInt l
  , bpIntSub :: VInt l -> VInt l -> MInt l
  , bpIntMul :: VInt l -> VInt l -> MInt l
  , bpIntDiv :: VInt l -> VInt l -> MInt l
  , bpIntMod :: VInt l -> VInt l -> MInt l
  , bpIntNeg :: VInt l -> MInt l
  , bpIntAbs :: VInt l -> MInt l
  , bpIntEq :: VInt l -> VInt l -> MBool l
  , bpIntLe :: VInt l -> VInt l -> MBool l
  , bpIntLt :: VInt l -> VInt l -> MBool l
  , bpIntMin :: VInt l -> VInt l -> MInt l
  , bpIntMax :: VInt l -> VInt l -> MInt l
    -- Array operations
  , bpArrayConstant :: TValue l -> TValue l -> Value l -> MArray l
  , bpArrayLookup :: VArray l -> Value l -> MValue l
  , bpArrayUpdate :: VArray l -> Value l -> Value l -> MArray l
  , bpArrayEq :: VArray l -> VArray l -> MBool l
  }

bpBool :: VMonad l => BasePrims l -> Bool -> MBool l
bpBool bp True = return (bpTrue bp)
bpBool bp False = return (bpFalse bp)

-- | Given implementations of the base primitives, construct a table
-- containing implementations of all primitives.
constMap ::
  forall l.
  (VMonadLazy l, MonadFix (EvalM l), Show (Extra l)) =>
  BasePrims l ->
  Map Ident (Prim l)
constMap bp = Map.fromList
  -- Boolean
  [ ("Prelude.Bool"  , PrimValue (TValue VBoolType))
  , ("Prelude.True"  , PrimValue (VBool (bpTrue bp)))
  , ("Prelude.False" , PrimValue (VBool (bpFalse bp)))
  , ("Prelude.not"   , boolFun (Prim . liftM VBool . bpNot bp))
  , ("Prelude.and"   , boolBinOp (bpAnd bp))
  , ("Prelude.or"    , boolBinOp (bpOr bp))
  , ("Prelude.xor"   , boolBinOp (bpXor bp))
  , ("Prelude.boolEq", boolBinOp (bpBoolEq bp))
  -- Bitwise
  , ("Prelude.bvAnd" , wordBinOp (bpPack bp) (bpBvAnd bp))
  , ("Prelude.bvOr"  , wordBinOp (bpPack bp) (bpBvOr  bp))
  , ("Prelude.bvXor" , wordBinOp (bpPack bp) (bpBvXor bp))
  , ("Prelude.bvNot" , wordUnOp  (bpPack bp) (bpBvNot bp))
  -- Arithmetic
  , ("Prelude.bvNeg" , wordUnOp  (bpPack bp) (bpBvNeg bp))
  , ("Prelude.bvAdd" , wordBinOp (bpPack bp) (bpBvAdd bp))
  , ("Prelude.bvSub" , wordBinOp (bpPack bp) (bpBvSub bp))
  , ("Prelude.bvMul" , wordBinOp (bpPack bp) (bpBvMul bp))
  , ("Prelude.bvUDiv", wordBinOp (bpPack bp) (bpBvUDiv bp))
  , ("Prelude.bvURem", wordBinOp (bpPack bp) (bpBvURem bp))
  , ("Prelude.bvSDiv", wordBinOp (bpPack bp) (bpBvSDiv bp))
  , ("Prelude.bvSRem", wordBinOp (bpPack bp) (bpBvSRem bp))
  , ("Prelude.bvLg2" , wordUnOp  (bpPack bp) (bpBvLg2  bp))
  -- Comparisons
  , ("Prelude.bvEq"  , wordBinRel (bpPack bp) (bpBvEq  bp))
  , ("Prelude.bvsle" , wordBinRel (bpPack bp) (bpBvsle bp))
  , ("Prelude.bvslt" , wordBinRel (bpPack bp) (bpBvslt bp))
  , ("Prelude.bvule" , wordBinRel (bpPack bp) (bpBvule bp))
  , ("Prelude.bvult" , wordBinRel (bpPack bp) (bpBvult bp))
  , ("Prelude.bvsge" , wordBinRel (bpPack bp) (bpBvsge bp))
  , ("Prelude.bvsgt" , wordBinRel (bpPack bp) (bpBvsgt bp))
  , ("Prelude.bvuge" , wordBinRel (bpPack bp) (bpBvuge bp))
  , ("Prelude.bvugt" , wordBinRel (bpPack bp) (bpBvugt bp))
    -- Bitvector misc
  , ("Prelude.bvPopcount", wordUnOp (bpPack bp) (bpBvPopcount bp))
  , ("Prelude.bvCountLeadingZeros", wordUnOp (bpPack bp) (bpBvCountLeadingZeros bp))
  , ("Prelude.bvCountTrailingZeros", wordUnOp (bpPack bp) (bpBvCountTrailingZeros bp))
  , ("Prelude.bvForall",
        natFun $ \n ->
        strictFun $ \f ->
          Prim (VBool <$>  bpBvForall bp n (toWordPred f))
    )

  -- Nat
  , ("Prelude.Succ", succOp)
  , ("Prelude.addNat", addNatOp)
  , ("Prelude.subNat", subNatOp bp)
  , ("Prelude.mulNat", mulNatOp)
  , ("Prelude.minNat", minNatOp)
  , ("Prelude.maxNat", maxNatOp)
  , ("Prelude.divModNat", divModNatOp)
  , ("Prelude.expNat", expNatOp)
  , ("Prelude.widthNat", widthNatOp)
  , ("Prelude.natCase", natCaseOp)
  , ("Prelude.equalNat", equalNatOp bp)
  , ("Prelude.ltNat", ltNatOp bp)
  -- Integers
  , ("Prelude.Integer", PrimValue (TValue VIntType))
  , ("Prelude.intAdd", intBinOp (bpIntAdd bp))
  , ("Prelude.intSub", intBinOp (bpIntSub bp))
  , ("Prelude.intMul", intBinOp (bpIntMul bp))
  , ("Prelude.intDiv", intBinOp (bpIntDiv bp))
  , ("Prelude.intMod", intBinOp (bpIntMod bp))
  , ("Prelude.intNeg", intUnOp  (bpIntNeg bp))
  , ("Prelude.intAbs", intUnOp  (bpIntAbs bp))
  , ("Prelude.intEq" , intBinCmp (bpIntEq bp))
  , ("Prelude.intLe" , intBinCmp (bpIntLe bp))
  , ("Prelude.intLt" , intBinCmp (bpIntLt bp))
  , ("Prelude.intMin", intBinOp (bpIntMin bp))
  , ("Prelude.intMax", intBinOp (bpIntMax bp))
  -- Modular Integers
  , ("Prelude.IntMod", natFun $ \n -> PrimValue (TValue (VIntModType n)))
  -- Vectors
  , ("Prelude.Vec", vecTypeOp)
  , ("Prelude.gen", genOp)
  , ("Prelude.atWithDefault", atWithDefaultOp bp)
  , ("Prelude.upd", updOp bp)
  , ("Prelude.take", takeOp bp)
  , ("Prelude.drop", dropOp bp)
  , ("Prelude.append", appendOp bp)
  , ("Prelude.join", joinOp bp)
  , ("Prelude.split", splitOp bp)
  , ("Prelude.zip", vZipOp (bpUnpack bp))
  , ("Prelude.foldr", foldrOp (bpUnpack bp))
  , ("Prelude.rotateL", rotateLOp bp)
  , ("Prelude.rotateR", rotateROp bp)
  , ("Prelude.shiftL", shiftLOp bp)
  , ("Prelude.shiftR", shiftROp bp)
  , ("Prelude.EmptyVec", emptyVec)
  -- Miscellaneous
  , ("Prelude.coerce", coerceOp)
  , ("Prelude.bvNat", bvNatOp bp)
  , ("Prelude.bvToNat", bvToNatOp)
  , ("Prelude.error", errorOp)
  , ("Prelude.fix", fixOp)
  -- Overloaded
  , ("Prelude.ite", iteOp bp)
  , ("Prelude.iteDep", iteOp bp)
  -- SMT Arrays
  , ("Prelude.Array", arrayTypeOp)
  , ("Prelude.arrayConstant", arrayConstantOp bp)
  , ("Prelude.arrayLookup", arrayLookupOp bp)
  , ("Prelude.arrayUpdate", arrayUpdateOp bp)
  , ("Prelude.arrayEq", arrayEqOp bp)
  ]

-- | Call this function to indicate that a programming error has
-- occurred, e.g. a datatype invariant has been violated.
panic :: HasCallStack => String -> a
panic msg = Panic.panic "Verifier.SAW.Simulator.Prims" [msg]

------------------------------------------------------------
-- Value accessors and constructors

vNat :: Natural -> Value l
vNat n = VNat n

toBool :: Show (Extra l) => Value l -> VBool l
toBool (VBool b) = b
toBool x = panic $ unwords ["Verifier.SAW.Simulator.toBool", show x]


type Pack l   = Vector (VBool l) -> MWord l
type Unpack l = VWord l -> EvalM l (Vector (VBool l))

toWord :: (VMonad l, Show (Extra l)) => Pack l -> Value l -> MWord l
toWord _ (VWord w) = return w
toWord pack (VVector vv) = pack =<< V.mapM (liftM toBool . force) vv
toWord _ x = panic $ unwords ["Verifier.SAW.Simulator.toWord", show x]

toWordPred :: (VMonad l, Show (Extra l)) => Value l -> VWord l -> MBool l
toWordPred (VFun _ f) = fmap toBool . f . ready . VWord
toWordPred x = panic $ unwords ["Verifier.SAW.Simulator.toWordPred", show x]

toBits :: (VMonad l, Show (Extra l)) => Unpack l -> Value l ->
                                                  EvalM l (Vector (VBool l))
toBits unpack (VWord w) = unpack w
toBits _ (VVector v) = V.mapM (liftM toBool . force) v
toBits _ x = panic $ unwords ["Verifier.SAW.Simulator.toBits", show x]

toVector :: (VMonad l, Show (Extra l)) => Unpack l
         -> Value l -> EvalM l (Vector (Thunk l))
toVector _ (VVector v) = return v
toVector unpack (VWord w) = liftM (fmap (ready . VBool)) (unpack w)
toVector _ x = panic $ unwords ["Verifier.SAW.Simulator.toVector", show x]

vecIdx :: a -> Vector a -> Int -> a
vecIdx err v n =
  case (V.!?) v n of
    Just a -> a
    Nothing -> err

toArray :: (VMonad l, Show (Extra l)) => Value l -> MArray l
toArray (VArray f) = return f
toArray x = panic $ unwords ["Verifier.SAW.Simulator.toArray", show x]

------------------------------------------------------------
-- Standard operator types

-- op :: Bool -> Bool -> Bool;
boolBinOp ::
  (VMonad l, Show (Extra l)) =>
  (VBool l -> VBool l -> MBool l) -> Prim l
boolBinOp op =
  boolFun $ \x ->
  boolFun $ \y ->
    Prim (VBool <$> op x y)

-- op : (n : Nat) -> Vec n Bool -> Vec n Bool;
wordUnOp ::
  (VMonad l, Show (Extra l)) =>
  Pack l -> (VWord l -> MWord l) -> Prim l
wordUnOp pack op =
  constFun $
  wordFun pack $ \x ->
    Prim (VWord <$> op x)

-- op : (n : Nat) -> Vec n Bool -> Vec n Bool -> Vec n Bool;
wordBinOp ::
  (VMonad l, Show (Extra l)) =>
  Pack l -> (VWord l -> VWord l -> MWord l) -> Prim l
wordBinOp pack op =
  constFun $
  wordFun pack $ \x ->
  wordFun pack $ \y ->
    Prim (VWord <$> op x y)

-- op : (n : Nat) -> Vec n Bool -> Vec n Bool -> Bool;
wordBinRel ::
  (VMonad l, Show (Extra l)) =>
  Pack l -> (VWord l -> VWord l -> MBool l) -> Prim l
wordBinRel pack op =
  constFun $
  wordFun pack $ \x ->
  wordFun pack $ \y ->
    Prim (VBool <$> op x y)

------------------------------------------------------------
-- Utility functions

-- @selectV mux maxValue valueFn v@ treats the vector @v@ as an
-- index, represented as a big-endian list of bits. It does a binary
-- lookup, using @mux@ as an if-then-else operator. If the index is
-- greater than @maxValue@, then it returns @valueFn maxValue@.
selectV :: (b -> a -> a -> a) -> Int -> (Int -> a) -> Vector b -> a
selectV mux maxValue valueFn v = impl len 0
  where
    len = V.length v
    err = panic "selectV: impossible"
    impl _ x | x > maxValue || x < 0 = valueFn maxValue
    impl 0 x = valueFn x
    impl i x = mux (vecIdx err v (len - i)) (impl j (x `setBit` j)) (impl j x) where j = i - 1

------------------------------------------------------------
-- Values for common primitives

-- bvNat : (n : Nat) -> Nat -> Vec n Bool;
bvNatOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
bvNatOp bp =
  natFun $ \w ->
  natFun $ \x ->
    Prim (VWord <$> bpBvLit bp (fromIntegral w) (toInteger x)) -- FIXME check for overflow on w

-- bvToNat : (n : Nat) -> Vec n Bool -> Nat;
bvToNatOp :: VMonad l => Prim l
bvToNatOp =
  natFun $ \n ->
  primFun $ \x ->
    Prim (liftM (VBVToNat (fromIntegral n)) (force x)) -- TODO, bad fromIntegral

-- coerce :: (a b :: sort 0) -> Eq (sort 0) a b -> a -> b;
coerceOp :: VMonad l => Prim l
coerceOp =
  constFun $
  constFun $
  constFun $
  primFun (\x -> Prim (force x))

------------------------------------------------------------
-- Nat primitives

-- | Return the number of bits necessary to represent the given value,
-- which should be a value of type Nat.
natSize :: BasePrims l -> Value l -> Natural
natSize _bp val =
  case val of
    VNat n -> widthNat n
    VBVToNat n _ -> fromIntegral n -- TODO, remove this fromIntegral
    VIntToNat _ -> error "natSize: symbolic integer"
    _ -> panic "natSize: expected Nat"

-- | Convert the given value (which should be of type Nat) to a word
-- of the given bit-width. The bit-width must be at least as large as
-- that returned by @natSize@.
natToWord :: (VMonad l, Show (Extra l)) => BasePrims l -> Int -> Value l -> MWord l
natToWord bp w val =
  case val of
    VNat n -> bpBvLit bp w (toInteger n)
    VIntToNat _i -> error "natToWord of VIntToNat TODO!"
    VBVToNat xsize v ->
      do x <- toWord (bpPack bp) v
         case compare xsize w of
           GT -> panic "natToWord: not enough bits"
           EQ -> return x
           LT -> -- zero-extend x to width w
             do pad <- bpBvLit bp (w - xsize) 0
                bpBvJoin bp pad x
    _ -> panic "natToWord: expected Nat"

-- Succ :: Nat -> Nat;
succOp :: VMonad l => Prim l
succOp =
  natFun $ \n -> PrimValue (vNat (succ n))

-- addNat :: Nat -> Nat -> Nat;
addNatOp :: VMonad l => Prim l
addNatOp =
  natFun $ \m ->
  natFun $ \n ->
    PrimValue (vNat (m + n))

-- subNat :: Nat -> Nat -> Nat;
subNatOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
subNatOp bp =
  strictFun $ \x ->
  strictFun $ \y -> Prim (g x y)
  where
    g (VNat i) (VNat j) = return $ VNat (if i < j then 0 else i - j)
    g v1 v2 =
      do let w = toInteger (max (natSize bp v1) (natSize bp v2))
         unless (w <= toInteger (maxBound :: Int))
                (panic "subNatOp" ["width too large", show w])
         x1 <- natToWord bp (fromInteger w) v1
         x2 <- natToWord bp (fromInteger w) v2
         lt <- bpBvult bp x1 x2
         z <- bpBvLit bp (fromInteger w) 0
         d <- bpBvSub bp x1 x2
         VBVToNat (fromInteger w) . VWord <$> bpMuxWord bp lt z d -- TODO, boo fromInteger

-- mulNat :: Nat -> Nat -> Nat;
mulNatOp :: VMonad l => Prim l
mulNatOp =
  natFun $ \m ->
  natFun $ \n ->
    PrimValue (vNat (m * n))

-- minNat :: Nat -> Nat -> Nat;
minNatOp :: VMonad l => Prim l
minNatOp =
  natFun $ \m ->
  natFun $ \n ->
    PrimValue (vNat (min m n))

-- maxNat :: Nat -> Nat -> Nat;
maxNatOp :: VMonad l => Prim l
maxNatOp =
  natFun $ \m ->
  natFun $ \n ->
    PrimValue (vNat (max m n))

-- divModNat :: Nat -> Nat -> #(Nat, Nat);
divModNatOp :: VMonad l => Prim l
divModNatOp =
  natFun $ \m ->
  natFun $ \n -> PrimValue $
    let (q,r) = divMod m n in
    vTuple [ready $ vNat q, ready $ vNat r]

-- expNat :: Nat -> Nat -> Nat;
expNatOp :: VMonad l => Prim l
expNatOp =
  natFun $ \m ->
  natFun $ \n ->
    PrimValue (vNat (m ^ n))

-- widthNat :: Nat -> Nat;
widthNatOp :: VMonad l => Prim l
widthNatOp =
  natFun $ \n ->
    PrimValue (vNat (widthNat n))

-- equalNat :: Nat -> Nat -> Bool;
equalNatOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
equalNatOp bp =
  strictFun $ \x ->
  strictFun $ \y -> Prim (g x y)
  where
    g (VNat i) (VNat j) = VBool <$> bpBool bp (i == j)
    g v1 v2 =
      do let w = toInteger (max (natSize bp v1) (natSize bp v2))
         unless (w <= toInteger (maxBound :: Int))
                (panic "equalNatOp" ["width too large", show w])
         x1 <- natToWord bp (fromInteger w) v1
         x2 <- natToWord bp (fromInteger w) v2
         VBool <$> bpBvEq bp x1 x2

-- ltNat :: Nat -> Nat -> Bool;
ltNatOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
ltNatOp bp =
  strictFun $ \x ->
  strictFun $ \y -> Prim (g x y)
  where
    g (VNat i) (VNat j) = VBool <$> bpBool bp (i < j)
    g v1 v2 =
      do let w = toInteger (max (natSize bp v1) (natSize bp v2))
         unless (w <= toInteger (maxBound :: Int))
                (panic "ltNatOp" ["width too large", show w])
         x1 <- natToWord bp (fromInteger w) v1
         x2 <- natToWord bp (fromInteger w) v2
         VBool <$> bpBvult bp x1 x2

-- natCase :: (p :: Nat -> sort 0) -> p Zero -> ((n :: Nat) -> p (Succ n)) -> (n :: Nat) -> p n;
natCaseOp :: (VMonad l, Show (Extra l)) => Prim l
natCaseOp =
  constFun $
  primFun $ \z ->
  primFun $ \s ->
  natFun $ \n -> Prim $
    if n == 0
    then force z
    else do s' <- force s
            apply s' (ready (VNat (n - 1)))

--------------------------------------------------------------------------------

-- Vec :: (n :: Nat) -> (a :: sort 0) -> sort 0;
vecTypeOp :: VMonad l => Prim l
vecTypeOp =
  natFun $ \n ->
  tvalFun $ \a ->
    PrimValue (TValue (VVecType n a))

-- gen :: (n :: Nat) -> (a :: sort 0) -> (Nat -> a) -> Vec n a;
genOp :: (VMonadLazy l, Show (Extra l)) => Prim l
genOp =
  natFun $ \n ->
  constFun $
  strictFun $ \f -> Prim $
    do let g i = delay $ apply f (ready (VNat (fromIntegral i)))
       if toInteger n > toInteger (maxBound :: Int) then
         panic ("Verifier.SAW.Simulator.gen: vector size too large: " ++ show n)
         else liftM VVector $ V.generateM (fromIntegral n) g


-- atWithDefault :: (n :: Nat) -> (a :: sort 0) -> a -> Vec n a -> Nat -> a;
atWithDefaultOp :: (VMonadLazy l, Show (Extra l)) => BasePrims l -> Prim l
atWithDefaultOp bp =
  natFun $ \n ->
  tvalFun $ \tp ->
  primFun $ \d ->
  strictFun $ \x ->
  strictFun $ \idx -> Prim $
    case idx of
      VNat i ->
        case x of
          VVector xv -> force (vecIdx d xv (fromIntegral i)) -- FIXME dangerous fromIntegral
          VWord xw -> VBool <$> bpBvAt bp xw (fromIntegral i) -- FIXME dangerous fromIntegral
          _ -> panic "atOp: expected vector"
      VBVToNat _sz i -> do
        iv <- toBits (bpUnpack bp) i
        case x of
          VVector xv ->
            selectV (lazyMuxValue bp tp) (fromIntegral n - 1) (force . vecIdx d xv) iv -- FIXME dangerous fromIntegral
          VWord xw ->
            selectV (lazyMuxValue bp tp) (fromIntegral n - 1) (liftM VBool . bpBvAt bp xw) iv -- FIXME dangerous fromIntegral
          _ -> panic "atOp: expected vector"

      VIntToNat _i ->
        error "atWithDefault: symbolic integer TODO"

      _ -> panic $ "atOp: expected Nat, got " ++ show idx

-- upd :: (n :: Nat) -> (a :: sort 0) -> Vec n a -> Nat -> a -> Vec n a;
updOp :: (VMonadLazy l, Show (Extra l)) => BasePrims l -> Prim l
updOp bp =
  natFun $ \n ->
  tvalFun $ \tp ->
  vectorFun (bpUnpack bp) $ \xv ->
  strictFun $ \idx ->
  primFun $ \y -> Prim $
    case idx of
      VNat i
        | toInteger i < toInteger (V.length xv)
           -> return (VVector (xv V.// [(fromIntegral i, y)]))
        | otherwise                   -> return (VVector xv)
      VBVToNat wsize (VWord w) ->
        do let f i = do b <- bpBvEq bp w =<< bpBvLit bp wsize (toInteger i)
                        if wsize < 64 && toInteger i >= 2 ^ wsize
                          then return (xv V.! i)
                          else delay (lazyMuxValue bp tp b (force y) (force (xv V.! i)))
           yv <- V.generateM (V.length xv) f
           return (VVector yv)
      VBVToNat _sz (VVector iv) ->
        do let update i = return (VVector (xv V.// [(i, y)]))
           iv' <- V.mapM (liftM toBool . force) iv
           selectV (lazyMuxValue bp (VVecType n tp)) (fromIntegral n - 1) update iv' -- FIXME dangerous fromIntegral

      VIntToNat _ -> error "updOp: symbolic integer TODO"

      _ -> panic $ "updOp: expected Nat, got " ++ show idx

-- primitive EmptyVec :: (a :: sort 0) -> Vec 0 a;
emptyVec :: VMonad l => Prim l
emptyVec = constFun (PrimValue (VVector V.empty))

-- take :: (a :: sort 0) -> (m n :: Nat) -> Vec (addNat m n) a -> Vec m a;
takeOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
takeOp bp =
  constFun $
  natFun $ \(fromIntegral -> m) ->  -- FIXME dangerous fromIntegral
  constFun $
  strictFun $ \v -> Prim $
    case v of
      VVector vv -> return (VVector (V.take m vv))
      VWord vw -> VWord <$> bpBvSlice bp 0 m vw
      _ -> panic $ "takeOp: " ++ show v

-- drop :: (a :: sort 0) -> (m n :: Nat) -> Vec (addNat m n) a -> Vec n a;
dropOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
dropOp bp =
  constFun $
  natFun $ \(fromIntegral -> m) -> -- FIXME dangerous fromIntegral
  constFun $
  strictFun $ \v -> Prim $
  case v of
    VVector vv -> return (VVector (V.drop m vv))
    VWord vw -> VWord <$> bpBvSlice bp m (bpBvSize bp vw - m) vw
    _ -> panic $ "dropOp: " ++ show v

-- append :: (m n :: Nat) -> (a :: sort 0) -> Vec m a -> Vec n a -> Vec (addNat m n) a;
appendOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
appendOp bp =
  constFun $
  constFun $
  constFun $
  strictFun $ \xs ->
  strictFun $ \ys ->
    Prim (appV bp xs ys)

appV :: (VMonad l, Show (Extra l)) => BasePrims l -> Value l -> Value l -> MValue l
appV bp xs ys =
  case (xs, ys) of
    (VVector xv, _) | V.null xv -> return ys
    (_, VVector yv) | V.null yv -> return xs
    (VWord xw, VWord yw) -> VWord <$> bpBvJoin bp xw yw
    (VVector xv, VVector yv) -> return $ VVector ((V.++) xv yv)
    (VVector xv, VWord yw) -> liftM (\yv -> VVector ((V.++) xv (fmap (ready . VBool) yv))) (bpUnpack bp yw)
    (VWord xw, VVector yv) -> liftM (\xv -> VVector ((V.++) (fmap (ready . VBool) xv) yv)) (bpUnpack bp xw)
    _ -> panic $ "Verifier.SAW.Simulator.Prims.appendOp: " ++ show xs ++ ", " ++ show ys

-- join  :: (m n :: Nat) -> (a :: sort 0) -> Vec m (Vec n a) -> Vec (mulNat m n) a;
joinOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
joinOp bp =
  constFun $
  constFun $
  constFun $
  strictFun $ \x -> Prim $
  case x of
    VVector xv -> do
      vv <- V.mapM force xv
      V.foldM (appV bp) (VVector V.empty) vv
    _ -> panic "Verifier.SAW.Simulator.Prims.joinOp"

-- split :: (m n :: Nat) -> (a :: sort 0) -> Vec (mulNat m n) a -> Vec m (Vec n a);
splitOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
splitOp bp =
  natFun $ \(fromIntegral -> m) ->  -- FIXME dangerous fromIntegral
  natFun $ \(fromIntegral -> n) ->  -- FIXME dangerous fromIntegral
  constFun $
  strictFun $ \x -> Prim $
  case x of
    VVector xv ->
      let f i = ready (VVector (V.slice (i*n) n xv))
      in return (VVector (V.generate m f))
    VWord xw ->
      let f i = (ready . VWord) <$> bpBvSlice bp (i*n) n xw
      in VVector <$> V.generateM m f
    _ -> panic "Verifier.SAW.Simulator.SBV.splitOp"

-- vZip :: (a b :: sort 0) -> (m n :: Nat) -> Vec m a -> Vec n b -> Vec (minNat m n) #(a, b);
vZipOp :: (VMonadLazy l, Show (Extra l)) => Unpack l -> Prim l
vZipOp unpack =
  constFun $
  constFun $
  constFun $
  constFun $
  strictFun $ \x ->
  strictFun $ \y -> Prim $
  do xv <- toVector unpack x
     yv <- toVector unpack y
     let pair a b = ready (vTuple [a, b])
     return (VVector (V.zipWith pair xv yv))


--------------------------------------------------------------------------
-- Generic square-and-multiply

-- primitive expByNat : (a:sort 0) -> a -> (a -> a -> a) -> a -> Nat -> a;
expByNatOp :: (MonadLazy (EvalM l), VMonad l, Show (Extra l)) => BasePrims l -> Prim l
expByNatOp bp =
  tvalFun   $ \tp ->
  strictFun $ \one ->
  strictFun $ \mul ->
  strictFun $ \x   ->
  strictFun $ \e -> Prim $ case e of
    VBVToNat _sz w ->
      do let loop acc [] = return acc
             loop acc (b:bs)
               | Just False <- bpAsBool bp b
               = do sq <- applyAll mul [ ready acc, ready acc ]
                    loop sq bs
               | Just True <- bpAsBool bp b
               = do sq   <- applyAll mul [ ready acc, ready acc ]
                    sq_x <- applyAll mul [ ready sq, ready x ]
                    loop sq_x bs
               | otherwise
               = do sq   <- applyAll mul [ ready acc, ready acc ]
                    sq_x <- applyAll mul [ ready sq, ready x ]
                    acc' <- muxValue bp tp b sq_x sq
                    loop acc' bs

         loop one . V.toList =<< toBits (bpUnpack bp) w

    VIntToNat _ -> error "expByNat: symbolic integer"

    VNat n ->
      do let loop acc [] = return acc
             loop acc (False:bs) =
               do sq <- applyAll mul [ ready acc, ready acc ]
                  loop sq bs
             loop acc (True:bs) =
               do sq   <- applyAll mul [ ready acc, ready acc ]
                  sq_x <- applyAll mul [ ready sq, ready x ]
                  loop sq_x bs

             w = toInteger (widthNat n)

         if w > toInteger (maxBound :: Int) then
           panic "expByNatOp" ["Exponent too large", show n]
         else
           loop one [ testBit n (fromInteger i) | i <- reverse [ 0 .. w-1 ]]

    v -> panic "expByNatOp" [ "Expected Nat value", show v ]



------------------------------------------------------------
-- Shifts and Rotates

-- | Barrel-shifter algorithm. Takes a list of bits in big-endian order.
--   TODO use Natural instead of Integer
shifter :: Monad m => (b -> a -> a -> m a) -> (a -> Integer -> m a) -> a -> [b] -> m a
shifter mux op = go
  where
    go x [] = return x
    go x (b : bs) = do
      x' <- op x (2 ^ length bs)
      y <- mux b x' x
      go y bs

-- shift{L,R} :: (n :: Nat) -> (a :: sort 0) -> a -> Vec n a -> Nat -> Vec n a;
shiftOp :: forall l.
  (HasCallStack, VMonadLazy l, Show (Extra l)) =>
  BasePrims l ->
  -- TODO use Natural instead of Integer
  (Thunk l -> Vector (Thunk l) -> Integer -> Vector (Thunk l)) ->
  (VBool l -> VWord l -> Integer -> MWord l) ->
  (VBool l -> VWord l -> VWord l -> MWord l) ->
  Prim l
shiftOp bp vecOp wordIntOp wordOp =
  natFun $ \n ->
  tvalFun $ \tp ->
  primFun $ \z ->
  strictFun $ \xs ->
  strictFun $ \y -> Prim $
    case y of
      VNat i ->
        case xs of
          VVector xv -> return $ VVector (vecOp z xv (toInteger i))
          VWord xw -> do
            zb <- toBool <$> force z
            VWord <$> wordIntOp zb xw (toInteger (min i n))
          _ -> panic $ "shiftOp: " ++ show xs
      VBVToNat _sz (VVector iv) -> do
        bs <- V.toList <$> traverse (fmap toBool . force) iv
        case xs of
          VVector xv -> VVector <$> shifter (muxVector n tp) (\v i -> return (vecOp z v i)) xv bs
          VWord xw -> do
            zb <- toBool <$> force z
            VWord <$> shifter (bpMuxWord bp) (wordIntOp zb) xw bs
          _ -> panic $ "shiftOp: " ++ show xs
      VBVToNat _sz (VWord iw) ->
        case xs of
          VVector xv -> do
            bs <- V.toList <$> bpUnpack bp iw
            VVector <$> shifter (muxVector n tp) (\v i -> return (vecOp z v i)) xv bs
          VWord xw -> do
            zb <- toBool <$> force z
            VWord <$> wordOp zb xw iw
          _ -> panic $ "shiftOp: " ++ show xs

      VIntToNat _i -> error "shiftOp: symbolic integer TODO"

      _ -> panic $ "shiftOp: " ++ show y
  where
    muxVector :: Natural -> TValue l -> VBool l ->
      Vector (Thunk l) -> Vector (Thunk l) -> EvalM l (Vector (Thunk l))
    muxVector n tp b v1 v2 = toVector (bpUnpack bp) =<< muxVal (VVecType n tp) b (VVector v1) (VVector v2)

    muxVal :: TValue l -> VBool l -> Value l -> Value l -> MValue l
    muxVal = muxValue bp

-- rotate{L,R} :: (n :: Nat) -> (a :: sort 0) -> Vec n a -> Nat -> Vec n a;
rotateOp :: forall l.
  (HasCallStack, VMonadLazy l, Show (Extra l)) =>
  BasePrims l ->
  --   TODO use Natural instead of Integer?
  (Vector (Thunk l) -> Integer -> Vector (Thunk l)) ->
  (VWord l -> Integer -> MWord l) ->
  (VWord l -> VWord l -> MWord l) ->
  Prim l
rotateOp bp vecOp wordIntOp wordOp =
  natFun $ \n ->
  tvalFun $ \tp ->
  strictFun $ \xs ->
  strictFun $ \y -> Prim $
    case y of
      VNat i ->
        case xs of
          VVector xv -> return $ VVector (vecOp xv (toInteger i))
          VWord xw -> VWord <$> wordIntOp xw (toInteger i)
          _ -> panic $ "rotateOp: " ++ show xs
      VBVToNat _sz (VVector iv) -> do
        bs <- V.toList <$> traverse (fmap toBool . force) iv
        case xs of
          VVector xv -> VVector <$> shifter (muxVector n tp) (\v i -> return (vecOp v i)) xv bs
          VWord xw -> VWord <$> shifter (bpMuxWord bp) wordIntOp xw bs
          _ -> panic $ "rotateOp: " ++ show xs
      VBVToNat _sz (VWord iw) ->
        case xs of
          VVector xv -> do
            bs <- V.toList <$> bpUnpack bp iw
            VVector <$> shifter (muxVector n tp) (\v i -> return (vecOp v i)) xv bs
          VWord xw -> do
            VWord <$> wordOp xw iw
          _ -> panic $ "rotateOp: " ++ show xs

      VIntToNat _i -> error "rotateOp: symbolic integer TODO"

      _ -> panic $ "rotateOp: " ++ show y
  where
    muxVector :: HasCallStack => Natural -> TValue l -> VBool l ->
      Vector (Thunk l) -> Vector (Thunk l) -> EvalM l (Vector (Thunk l))
    muxVector n tp b v1 v2 = toVector (bpUnpack bp) =<< muxVal (VVecType n tp) b (VVector v1) (VVector v2)

    muxVal :: HasCallStack => TValue l -> VBool l -> Value l -> Value l -> MValue l
    muxVal = muxValue bp

vRotateL :: Vector a -> Integer -> Vector a
vRotateL xs i
  | V.null xs = xs
  | otherwise = (V.++) (V.drop j xs) (V.take j xs)
  where j = fromInteger (i `mod` toInteger (V.length xs))

vRotateR :: Vector a -> Integer -> Vector a
vRotateR xs i = vRotateL xs (- i)

vShiftL :: a -> Vector a -> Integer -> Vector a
vShiftL x xs i = (V.++) (V.drop j xs) (V.replicate j x)
  where j = fromInteger (i `min` toInteger (V.length xs))

vShiftR :: a -> Vector a -> Integer -> Vector a
vShiftR x xs i = (V.++) (V.replicate j x) (V.take (V.length xs - j) xs)
  where j = fromInteger (i `min` toInteger (V.length xs))

rotateLOp :: (VMonadLazy l, Show (Extra l)) => BasePrims l -> Prim l
rotateLOp bp = rotateOp bp vRotateL (bpBvRolInt bp) (bpBvRol bp)

rotateROp :: (VMonadLazy l, Show (Extra l)) => BasePrims l -> Prim l
rotateROp bp = rotateOp bp vRotateR (bpBvRorInt bp) (bpBvRor bp)

shiftLOp :: (VMonadLazy l, Show (Extra l)) => BasePrims l -> Prim l
shiftLOp bp = shiftOp bp vShiftL (bpBvShlInt bp) (bpBvShl bp)

shiftROp :: (VMonadLazy l, Show (Extra l)) => BasePrims l -> Prim l
shiftROp bp = shiftOp bp vShiftR (bpBvShrInt bp) (bpBvShr bp)


-- foldr :: (a b :: sort 0) -> (n :: Nat) -> (a -> b -> b) -> b -> Vec n a -> b;
foldrOp :: (VMonadLazy l, Show (Extra l)) => Unpack l -> Prim l
foldrOp unpack =
  constFun $
  constFun $
  constFun $
  strictFun $ \f ->
  primFun $ \z ->
  strictFun $ \xs -> Prim $ do
    let g x m = do fx <- apply f x
                   y <- delay m
                   apply fx y
    xv <- toVector unpack xs
    V.foldr g (force z) xv

-- op :: Integer -> Integer;
intUnOp :: VMonad l => (VInt l -> MInt l) -> Prim l
intUnOp f =
  intFun $ \x ->
    Prim (VInt <$> f x)

-- op :: Integer -> Integer -> Integer;
intBinOp :: VMonad l => (VInt l -> VInt l -> MInt l) -> Prim l
intBinOp f =
  intFun $ \x ->
  intFun $ \y ->
    Prim (VInt <$> f x y)

-- op :: Integer -> Integer -> Bool;
intBinCmp :: VMonad l => (VInt l -> VInt l -> MBool l) -> Prim l
intBinCmp f =
  intFun $ \x ->
  intFun $ \y ->
    Prim (VBool <$> f x y)

-- primitive intToNat :: Integer -> Nat;
intToNatOp :: (VMonad l, VInt l ~ Integer) => Prim l
intToNatOp =
  intFun $ \x -> PrimValue $!
    if x >= 0 then VNat (fromInteger x) else VNat 0

-- primitive natToInt :: Nat -> Integer;
natToIntOp :: (VMonad l, VInt l ~ Integer) => Prim l
natToIntOp = natFun $ \x -> PrimValue $ VInt (toInteger x)

-- primitive error :: (a :: sort 0) -> String -> a;
errorOp :: VMonad l => Prim l
errorOp =
  constFun $
  strictFun $ \x -> Prim $
  case x of
    VString s -> Prim.userError (Text.unpack s)
    _ -> Prim.userError "unknown error"

------------------------------------------------------------
-- Conditionals

iteOp :: (HasCallStack, VMonadLazy l, Show (Extra l)) => BasePrims l -> Prim l
iteOp bp =
  tvalFun $ \tp ->
  boolFun $ \b ->
  primFun $ \x ->
  primFun $ \y -> Prim $
    lazyMuxValue bp tp b (force x) (force y)

lazyMuxValue ::
  (HasCallStack, VMonadLazy l, Show (Extra l)) =>
  BasePrims l ->
  TValue l ->
  VBool l -> MValue l -> MValue l -> MValue l
lazyMuxValue bp tp b x y =
  case bpAsBool bp b of
    Just True  -> x
    Just False -> y
    Nothing ->
      do x' <- x
         y' <- y
         muxValue bp tp b x' y'


muxValue :: forall l.
  (HasCallStack, VMonadLazy l, Show (Extra l)) =>
  BasePrims l ->
  TValue l ->
  VBool l -> Value l -> Value l -> MValue l
muxValue bp tp0 b = value tp0
  where
    value :: TValue l -> Value l -> Value l -> MValue l
    value _ (VNat m)  (VNat n)      | m == n = return $ VNat m
    value _ (VString x) (VString y) | x == y = return $ VString x

    value (VPiType _ _tp body) (VFun nm f) (VFun _ g) =
        return $ VFun nm $ \a ->
           do tp' <- applyPiBody body a
              x <- f a
              y <- g a
              value tp' x y

    value VUnitType VUnit VUnit = return VUnit
    value (VPairType t1 t2) (VPair x1 x2) (VPair y1 y2) =
      VPair <$> thunk t1 x1 y1 <*> thunk t2 x2 y2

    value (VRecordType fs) (VRecordValue elems1) (VRecordValue elems2) =
      do let em1 = Map.fromList elems1
         let em2 = Map.fromList elems2
         let build (f,tp) = case (Map.lookup f em1, Map.lookup f em2) of
                              (Just v1, Just v2) ->
                                 do v <- thunk tp v1 v2
                                    pure (f,v)
                              _ -> panic "muxValue" ["Record field missing!", show f]
         VRecordValue <$> traverse build fs

    value (VDataType _nm _ps _ixs) (VCtorApp i ps xv) (VCtorApp j _ yv)
      | i == j = VCtorApp i ps <$> ctorArgs (primType i) ps xv yv
      | otherwise =
      -- TODO, should not be a panic
      panic $ "Verifier.SAW.Simulator.Prims.iteOp: cannot mux different data constructors "
                ++ show i ++ " " ++ show j

    value (VVecType _ tp) (VVector xv) (VVector yv) =
      VVector <$> thunks tp xv yv

    value tp (VExtra x) (VExtra y) =
      VExtra <$> bpMuxExtra bp tp b x y

    value _ (VBool x)         (VBool y)         = VBool <$> bpMuxBool bp b x y
    value _ (VWord x)         (VWord y)         = VWord <$> bpMuxWord bp b x y
    value _ (VInt x)          (VInt y)          = VInt <$> bpMuxInt bp b x y
    value _ (VIntMod n x)     (VIntMod _ y)     = VIntMod n <$> bpMuxInt bp b x y

    value tp x@(VWord _)       y                = toVector (bpUnpack bp) x >>= \xv -> value tp (VVector xv) y
    value tp x                 y@(VWord _)      = toVector (bpUnpack bp) y >>= \yv -> value tp x (VVector yv)

    value _ x@(VNat _)        y                 = nat x y
    value _ x@(VBVToNat _ _)  y                 = nat x y
    value _ x@(VIntToNat _)   y                 = nat x y

    value _ (TValue x)        (TValue y)        = TValue <$> tvalue x y

    value tp x                y                 =
      panic $ "Verifier.SAW.Simulator.Prims.iteOp: malformed arguments: "
      ++ show x ++ " " ++ show y ++ " " ++ show tp


    ctorArgs :: TValue l -> [Thunk l] -> [Thunk l] -> [Thunk l] -> EvalM l [Thunk l]

    -- consume the data type parameters and compute the type of the constructor
    ctorArgs (VPiType _nm _t1 body) (p:ps) xs ys =
      do t' <- applyPiBody body p
         ctorArgs t' ps xs ys

    -- mux the arguments one at a time, as long as the constructor type is not
    -- a dependent function
    ctorArgs (VPiType _nm t1 (VNondependentPi t2)) [] (x:xs) (y:ys)=
      do z  <- thunk t1 x y
         zs <- ctorArgs t2 [] xs ys
         pure (z:zs)
    ctorArgs _ [] [] [] = pure []

    -- TODO, shouldn't be a panic
    ctorArgs (VPiType _nm _t1 (VDependentPi _)) [] _ _ =
      panic $ "Verifier.SAW.Simulator.Prims.iteOp: cannot mux constructors with dependent types"

    ctorArgs _ _ _ _ =
      panic $ "Verifier.SAW.Simulator.Prims.iteOp: constructor arguments mismtch"

    tvalue :: TValue l -> TValue l -> EvalM l (TValue l)
    tvalue (VSort x)         (VSort y)         | x == y = return $ VSort y
    tvalue x                 y                 =
      panic $ "Verifier.SAW.Simulator.Prims.iteOp: malformed arguments: "
      ++ show x ++ " " ++ show y

    thunks :: TValue l -> Vector (Thunk l) -> Vector (Thunk l) -> EvalM l (Vector (Thunk l))
    thunks tp xv yv
      | V.length xv == V.length yv = V.zipWithM (thunk tp) xv yv
      | otherwise                  = panic "Verifier.SAW.Simulator.Prims.iteOp: malformed arguments"

    thunk :: TValue l -> Thunk l -> Thunk l -> EvalM l (Thunk l)
    thunk tp x y = delay $ do x' <- force x; y' <- force y; value tp x' y'

    nat :: Value l -> Value l -> MValue l
    nat v1 v2 =
      do let w = toInteger (max (natSize bp v1) (natSize bp v2))
         unless (w <= toInteger (maxBound :: Int))
                (panic "muxValue" ["width too large", show w])
         x1 <- natToWord bp (fromInteger w) v1
         x2 <- natToWord bp (fromInteger w) v2
         VBVToNat (fromInteger w) . VWord <$> bpMuxWord bp b x1 x2

-- fix :: (a :: sort 0) -> (a -> a) -> a;
fixOp :: (VMonadLazy l, MonadFix (EvalM l), Show (Extra l)) => Prim l
fixOp =
  constFun $
  strictFun $ \f -> Prim
    (force =<< mfix (\x -> delay (apply f x)))

------------------------------------------------------------
-- SMT Array

-- Array :: sort 0 -> sort 0 -> sort 0
arrayTypeOp :: VMonad l => Prim l
arrayTypeOp =
  tvalFun $ \a ->
  tvalFun $ \b ->
    PrimValue (TValue (VArrayType a b))

-- arrayConstant :: (a b :: sort 0) -> b -> (Array a b);
arrayConstantOp :: VMonad l => BasePrims l -> Prim l
arrayConstantOp bp =
  tvalFun $ \a ->
  tvalFun $ \b ->
  strictFun $ \e ->
    Prim (VArray <$> bpArrayConstant bp a b e)

-- arrayLookup :: (a b :: sort 0) -> (Array a b) -> a -> b;
arrayLookupOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
arrayLookupOp bp =
  constFun $
  constFun $
  strictFun $ \f ->
  strictFun $ \i -> Prim $
    do f' <- toArray f
       bpArrayLookup bp f' i

-- arrayUpdate :: (a b :: sort 0) -> (Array a b) -> a -> b -> (Array a b);
arrayUpdateOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
arrayUpdateOp bp =
  constFun $
  constFun $
  strictFun $ \f ->
  strictFun $ \i ->
  strictFun $ \e -> Prim $
    do f' <- toArray f
       VArray <$> bpArrayUpdate bp f' i e

-- arrayEq : (a b : sort 0) -> (Array a b) -> (Array a b) -> Bool;
arrayEqOp :: (VMonad l, Show (Extra l)) => BasePrims l -> Prim l
arrayEqOp bp =
  constFun $
  constFun $
  strictFun $ \x ->
  strictFun $ \y -> Prim $
    do x' <- toArray x
       y' <- toArray y
       VBool <$> bpArrayEq bp x' y'

{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE UndecidableInstances       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Core.Transform
-- Copyright   :  (c) 2011 diagrams-core team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- "Diagrams" defines the core library of primitives
-- forming the basis of an embedded domain-specific language for
-- describing and rendering diagrams.
--
-- The @Transform@ module defines generic transformations
-- parameterized by any vector space.
--
-----------------------------------------------------------------------------

module Diagrams.Core.Transform
       (
         -- * Transformations

         -- ** Invertible linear transformations
         (:-:)(..), (<->), linv, lapp

         -- ** General transformations
       , Transformation(..)
       , inv, transp, transl
       , dropTransl
       , apply
       , papply
       , fromLinear
       , fromOrthogonal
       , fromSymmetric
       , basis
       , dimension
       , onBasis
       , listRep
       , matrixRep
       , matrixHomRep
       , determinant
       , avgScale
       , scaleFromTransform
       , eye

         -- * The Transformable class

       , HasLinearMap
       , Transformable(..)

         -- * Translational invariance

       , TransInv(TransInv)

         -- * Vector space independent transformations
         -- | Most transformations are specific to a particular vector
         --   space, but a few can be defined generically over any
         --   vector space.

       , translation, translate
       , scaling, scale

       ) where

import           Control.Lens            hiding (Action, transform)
import qualified Data.Map                as M
import           Data.Semigroup
import qualified Data.Set                as S

import           Data.Monoid.Action
import           Data.Monoid.Deletable

import           Linear.Affine
import           Linear.Vector

import           Control.Applicative
import           Data.Distributive
import           Data.Foldable           (Foldable, toList)
import           Data.Functor.Rep

import           Diagrams.Core.HasOrigin
import           Diagrams.Core.Points    ()
import           Diagrams.Core.V

------------------------------------------------------------
--  Transformations  ---------------------------------------
------------------------------------------------------------

-------------------------------------------------------
--  Invertible linear transformations  ----------------
-------------------------------------------------------

-- | @(v1 :-: v2)@ is a linear map paired with its inverse.
data (:-:) u v = (u -> v) :-: (v -> u)
infixr 7 :-:

-- | Create an invertible linear map from two functions which are
--   assumed to be linear inverses.
(<->) :: (u -> v) -> (v -> u) -> (u :-: v)
f <-> g = f :-: g

instance Semigroup (a :-: a) where
  (f :-: f') <> (g :-: g') = f . g :-: g' . f'

-- | Invertible linear maps from a vector space to itself form a
--   monoid under composition.
instance Monoid (v :-: v) where
  mempty  = id :-: id
  mappend = (<>)

-- | Invert a linear map.
linv :: (u :-: v) -> (v :-: u)
linv (f :-: g) = g :-: f

-- | Apply a linear map to a vector.
lapp :: (u :-: v) -> u -> v
lapp (f :-: _) = f

--------------------------------------------------
--  Affine transformations  ----------------------
--------------------------------------------------

-- | General (affine) transformations, represented by an invertible
--   linear map, its /transpose/, and a vector representing a
--   translation component.
--
--   By the /transpose/ of a linear map we mean simply the linear map
--   corresponding to the transpose of the map's matrix
--   representation.  For example, any scale is its own transpose,
--   since scales are represented by matrices with zeros everywhere
--   except the diagonal.  The transpose of a rotation is the same as
--   its inverse.
--
--   The reason we need to keep track of transposes is because it
--   turns out that when transforming a shape according to some linear
--   map L, the shape's /normal vectors/ transform according to L's
--   inverse transpose.  This is exactly what we need when
--   transforming bounding functions, which are defined in terms of
--   /perpendicular/ (i.e. normal) hyperplanes.
--
--   For more general, non-invertable transformations, see
--   @Diagrams.Deform@ (in @diagrams-lib@).

data Transformation f a = Transformation (f a :-: f a) (f a :-: f a) (f a)

type instance V (Transformation v a) = v
type instance N (Transformation v a) = a

-- | Identity matrix.
eye :: (Rep t ~ E t, Representable t, Applicative t, Num a) => t (t a)
eye = tabulate $ \(E e) -> unit e

-- | Invert a transformation.
inv :: (Num a, Functor t) => Transformation t a -> Transformation t a
inv (Transformation t t' v) = Transformation (linv t) (linv t')
                                             (negated (lapp (linv t) v))

-- | Get the transpose of a transformation (ignoring the translation
--   component).
transp :: Transformation v a -> (v a :-: v a)
transp (Transformation _ t' _) = t'

-- | Get the translational component of a transformation.
transl :: Transformation v a -> v a
transl (Transformation _ _ v) = v

-- | Drop the translational component of a transformation, leaving only
--   the linear part.
dropTransl :: (Num a, Additive v) => Transformation v a -> Transformation v a
dropTransl (Transformation a a' _) = Transformation a a' zero

-- | Transformations are closed under composition; @t1 <> t2@ is the
--   transformation which performs first @t2@, then @t1@.
instance (Num a, Additive t) => Semigroup (Transformation t a) where
  Transformation t1 t1' v1 <> Transformation t2 t2' v2
    = Transformation (t1 <> t2) (t2' <> t1') (v1 ^+^ lapp t1 v2)

instance (Num a, Additive t) => Monoid (Transformation t a) where
  mempty = Transformation mempty mempty zero
  mappend = (<>)

-- | Transformations can act on transformable things.
instance (Vn a ~ v n, Transformable a) => Action (Transformation v n) a where
  act = transform

-- | Apply a transformation to a vector.  Note that any translational
--   component of the transformation will not affect the vector, since
--   vectors are invariant under translation.
apply :: Transformation v a -> v a -> v a
apply (Transformation (t :-: _) _ _) = t

-- | Apply a transformation to a point.
papply :: (Additive v, Num a) => Transformation v a -> Point v a -> Point v a
papply (Transformation t _ v) (P p) = P $ lapp t p ^+^ v

-- | Create a general affine transformation from an invertible linear
--   transformation and its transpose.  The translational component is
--   assumed to be zero.
fromLinear :: (Additive v, Num a) => (v a :-: v a) -> (v a :-: v a) -> Transformation v a
fromLinear l1 l2 = Transformation l1 l2 zero

-- | An orthogonal linear map is one whose inverse is also its transpose.
fromOrthogonal :: (Additive v, Num n) => (v n :-: v n) -> Transformation v n
fromOrthogonal t = fromLinear t (linv t)

-- | A symmetric linear map is one whose transpose is equal to its self.
fromSymmetric :: (Additive v, Num n) => (v n :-: v n) -> Transformation v n
fromSymmetric t = fromLinear t t


-- | Get the matrix equivalent of the basis of the vector space v as
--   a list of columns.
-- basis :: (Applicative t, Traversable t, Num a) => [t a]
-- basis = choices $ traverse (\a -> SetOne 0 [a]) (pure 1)

-- basis :: (Num a, HasLinearMap f) => [f a]
-- basis = toList eye
  -- where b = map fst (decompose (zero :: v))

-- | Get the dimension of an object whose vector space is an instance of
--   @HasLinearMap@, e.g. transformations, paths, diagrams, etc.
dimension :: forall a v. (v ~ V a, Additive v, Foldable v) => a -> Int
dimension _ = lengthOf folded (zero :: V a Double)

-- | Get the matrix equivalent of the linear transform,
--   (as a list of columns) and the translation vector.  This
--   is mostly useful for implementing backends.
onBasis :: (Num a, HasLinearMap v) => Transformation v a -> ([v a], v a)
onBasis (Transformation (f :-: _) _ t) = (toList vmat, t)
  where vmat = fmap f eye

-- Remove the nth element from a list
remove :: Int -> [a] -> [a]
remove n xs = ys ++ tail zs
  where
    (ys, zs) = splitAt n xs

-- Minor matrix of cofactore C(i,j)
minor :: Int -> Int -> [[a]] -> [[a]]
minor i j xs = remove j $ map (remove i) xs

-- The determinant of a square matrix represented as a list of lists
-- representing column vectors, that is [column].
det :: Num a => [[a]] -> a
det (a:[]) = head a
det m = sum [(-1)^i * (c1 !! i) * det (minor i 0 m) | i <- [0 .. (n-1)]]
  where
    c1 = head m
    n = length m

-- | Convert a vector v to a list of scalars.
listRep :: Foldable f => f a -> [a]
listRep = toList

-- | Convert a `Transformation v` to a matrix representation as a list of
--   column vectors which are also lists.
-- matrixRep :: HasLinearMap v => Transformation v -> [[Scalar v]]
matrixRep :: (Num a, HasLinearMap v)  => Transformation v a -> [[a]]
matrixRep (Transformation (f :-: _) _ _) = eye ^.. traversed . to (toList . f)
-- matrixRep t = map listRep (fst . onBasis $ t)
--

-- | Convert a `Transformation v` to a homogeneous matrix representation.
--   The final list is the translation.
--   The representation leaves off the last row of the matrix as it is
--   always [0,0, ... 1] and this representation is the defacto standard
--   for backends.
matrixHomRep :: (Num a, HasLinearMap v) => Transformation v a -> [[a]]
matrixHomRep t = mr ++ [listRep tl]
  where
    mr = matrixRep t
    tl = transl t

-- | The determinant of a `Transformation`.
determinant :: (Num a, HasLinearMap v) => Transformation v a -> a
determinant t = det . matrixRep $ t

-- | Compute the \"average\" amount of scaling performed by a
--   transformation.  Satisfies the properties
--
--   @
--   avgScale (scaling k) == k
--   avgScale (t1 <> t2)  == avgScale t1 * avgScale t2
--   @
--
avgScale :: (Floating n, HasLinearMap v) => Transformation v n -> n
avgScale t = (abs . determinant $ t) ** (1 / fromIntegral (dimension t))

-- | Scale a functor with the average scale of a transform.
scaleFromTransform :: (HasLinearMap v, Floating n, Functor f)
  => Transformation v n -> f n -> f n
scaleFromTransform t = fmap (* avgScale t)

{-

avgScale is computed as the nth root of the positive determinant.
This works because the determinant is the factor by which a transformation
scales area/volume. See http://en.wikipedia.org/wiki/Determinant.

Proofs for the specified properties:

1. |det (scaling k)|^(1/n) = (k^n)^(1/n) = k
2. |det t1|^(1/n) * |det t2|^(1/n)
   = (|det t1| * |det t2|)^(1/n)
   = |det t1 * det t2|^(1/n)
   = |det (t1 <> t2)|^(1/n)

-}

------------------------------------------------------------
--  The Transformable class  -------------------------------
------------------------------------------------------------

-- | 'HasLinearMap' is a poor man's class constraint synonym, just to
--   help shorten some of the ridiculously long constraint sets.
class (Rep f ~ E f,
       Additive f,
       Applicative f,
       Distributive f,
       Foldable f,
       Representable f,
       Traversable f
       ) => HasLinearMap f
instance (Rep f ~ E f,
          Additive f,
          Applicative f,
          Distributive f,
          Foldable f,
          Representable f,
          Traversable f
          ) => HasLinearMap f

-- | Type class for things @t@ which can be transformed.
class Transformable t where

  -- | Apply a transformation to an object.
  transform :: Transformation (V t) (N t) -> t -> t

instance (Num a, Additive v) => Transformable (Transformation v a) where
  transform t1 t2 = t1 <> t2

instance (Num a, Additive v) => HasOrigin (Transformation v a) where
  moveOriginTo p = translate (origin .-. p)

instance (Transformable t, Transformable s, Vn t ~ Vn s)
      => Transformable (t, s) where
  transform t (x,y) =  ( transform t x
                       , transform t y
                       )

instance (Transformable t, Transformable s, Transformable u, Vn s ~ Vn t, Vn s ~ Vn u)
      => Transformable (t,s,u) where
  transform t (x,y,z) = ( transform t x
                        , transform t y
                        , transform t z
                        )

-- Transform functions by conjugation. That is, reverse-transform argument and
-- forward-transform result. Intuition: If someone shrinks you, you see your
-- environment enlarged. If you rotate right, you see your environment
-- rotating left. Etc. This technique was used extensively in Pan for modular
-- construction of image filters. Works well for curried functions, since all
-- arguments get inversely transformed.

-- instance ( HasBasis (V b), HasTrie (Basis (V b))
--          , Transformable a, Transformable b, V b ~ V a) =>
instance (Vn t ~ v n, Vn t ~ Vn s, Functor v, Num n, Transformable t, Transformable s) => Transformable (s -> t) where
  transform tr f = transform tr . f . transform (inv tr)

instance Transformable t => Transformable [t] where
  transform = map . transform

instance (Transformable t, Ord t) => Transformable (S.Set t) where
  transform = S.map . transform

instance Transformable t => Transformable (M.Map k t) where
  transform = M.map . transform

instance (Num a, Additive t) => Transformable (Point t a) where
  transform = papply

instance Transformable m => Transformable (Deletable m) where
  transform = fmap . transform

------------------------------------------------------------
--  Translational invariance  ------------------------------
------------------------------------------------------------

-- | @TransInv@ is a wrapper which makes a transformable type
--   translationally invariant; the translational component of
--   transformations will no longer affect things wrapped in
--   @TransInv@.
newtype TransInv t = TransInv t
  deriving (Eq, Ord, Show, Semigroup, Monoid)

instance Wrapped (TransInv t) where
  type Unwrapped (TransInv t) = t
  _Wrapped' = iso (\(TransInv t) -> t) TransInv

instance Rewrapped (TransInv t) (TransInv t')

type instance V (TransInv t) = V t
type instance N (TransInv t) = N t

instance HasOrigin (TransInv t) where
  moveOriginTo = const id

instance (Num (N t), Additive (V t), Transformable t) => Transformable (TransInv t) where
  transform (Transformation a a' _) (TransInv t)
    = TransInv (transform (Transformation a a' zero) t)

------------------------------------------------------------
--  Generic transformations  -------------------------------
------------------------------------------------------------

-- | Create a translation.
translation :: v a -> Transformation v a
translation = Transformation mempty mempty

-- | Translate by a vector.
translate :: (Num (N t), Transformable t) => Vn t -> t -> t
translate = transform . translation

-- | Create a uniform scaling transformation.
scaling :: (Additive v, Fractional a)
        => a -> Transformation v a
scaling s = fromSymmetric lin
  where lin = (s *^) <-> (^/ s)

-- | Scale uniformly in every dimension by the given scalar.
scale :: (a ~ N t, Additive (V t), Transformable t, Fractional a, Eq a)
      => N t -> t -> t
scale 0 = error "scale by zero!  Halp!"  -- XXX what should be done here?
scale s = transform $ scaling s


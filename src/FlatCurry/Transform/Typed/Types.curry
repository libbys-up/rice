------------------------------------------------------------------------------
--- Definition of types used to specify transformations on TypedFlatCurry
--- programs.
---
--- This is the typed (`TExpr`) counterpart of `FlatCurry.Transform.Types`
--- from the `flatcurry-transform` package. It lives under the same
--- `FlatCurry/Transform` directory layout (in a `Typed` subdirectory, the
--- way `flatcurry-typed` mirrors `flatcurry`) so it can be migrated into
--- that package directly if it works out well.
---
--- @author Steven Libby
------------------------------------------------------------------------------

module FlatCurry.Transform.Typed.Types (
  -- * Data types for expression transformations
  Path, Step, TExprTransformation, TExprTransformationDet,
  -- * Operations to lift simple transformations to general ones
  makeT, makeTDet,
  -- * Compose deterministic transformations
  (<?>), combine
 ) where

import FlatCurry.Typed.Types

infixr 0 <?>

------------------------------------------------------------------------------

--- A path to some subexpression is represented by a list of integers.
type Path = [Int]

--- A transformation step consists of a string, a path, and an expression.
type Step = (String, Path, TExpr)

--- An expression transformation is a (possibly non-deterministic) operation
--- which takes a pair consisting of a fresh variable index and the position
--- of the expression in the right-hand side, and a TypedFlatCurry
--- expression, and returns a transformed expression, the name of the
--- applied transformation (just for debugging), and the number of new
--- variables used in the transformation.
type TExprTransformation = (VarIndex, Path) -> TExpr -> (TExpr, String, Int)

--- A deterministic expression transformation is a totally defined operation
--- with the same arguments as `TExprTransformation`, returning a `Maybe`
--- value: `Nothing` if the transformation is not applicable, otherwise the
--- transformed expression, the transformation's name, and the number of
--- new variables it used.
type TExprTransformationDet =
  (VarIndex, Path) -> TExpr -> Maybe (TExpr, String, Int)

------------------------------------------------------------------------------

--- Lift a simple transformation on expressions to a general expression
--- transformation, named by the first argument (for debugging).
makeT :: String -> (TExpr -> TExpr) -> TExprTransformation
makeT name f = \_ e -> (f e, name, 0)

--- Lift a simple deterministic transformation on expressions to a general
--- deterministic expression transformation, named by the first argument.
makeTDet :: String -> (TExpr -> Maybe TExpr) -> TExprTransformationDet
makeTDet name f = \_ e -> do e' <- f e
                             Just (e', name, 0)

--- Parallel composition of two deterministic expression transformations,
--- where the second is used only if the first is not applicable.
(<?>) :: TExprTransformationDet -> TExprTransformationDet
     -> TExprTransformationDet
t1 <?> t2 = \env e -> case t1 env e of Nothing -> t2 env e
                                       Just e' -> Just e'

--- Parallel composition of a sequence of deterministic expression
--- transformations, tried left to right.
combine :: [TExprTransformationDet] -> TExprTransformationDet
combine = foldr (<?>) (\_ _ -> Nothing)

------------------------------------------------------------------------------

{-
    Copyright 2012 Gabriel Gonzalez

    This file is part of the Haskell Pipes Library.

    The is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    hPDB is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with the Haskell Pipes Library.  If not, see
    <http://www.gnu.org/licenses/>.
-}

module Control.Pipe.Common (
    -- * Types
    Pipe,
    Zero,
    Producer,
    Consumer,
    Pipeline,
    -- * Creating Pipes
    {-|
        'yield' and 'await' are the only two primitives you need to create
        'Pipe's.  Because 'Pipe' is a monad, you can assemble them using
        ordinary @do@ notation.  Since 'Pipe' is also a monad transformer, you
        can use 'lift' to invoke the base monad.  For example:

> check :: Pipe a a IO r
> check = forever $ do
>     x <- await
>     lift $ putStrLn $ "Can " ++ (show x) ++ " pass?"
>     ok <- lift $ read <$> getLine
>     when ok (yield x)
    -}
    await,
    yield,
    pipe,
    -- * Composing Pipes
    {-|
        There are two possible category implementations for 'Pipe':

        ['Lazy' composition]

            * Evaluate downstream stages before upstream stages

            * Pipe terminations propagate upstream

            * The most downstream 'Pipe' that cleanly terminates produces the
              return value

        ['Strict' composition]

            * Evaluate upstream stages before downstream stages

            * Pipes terminations propagate downstream

            * The most upstream 'Pipe' that cleanly terminates produces the
              return value

        You probably want 'Lazy' composition.

        Both category implementations satisfy the category laws:

        * Composition is associative.  You will get the exact same sequence of
          monadic actions and the same return value upon running the 'Pipe'
          regardless of how you group composition if you only use one type
          of composition (i.e. only 'Lazy' composition or only 'Strict'
          composition).

        * 'id' is the identity 'Pipe'.  Composing a 'Pipe' with 'id' will not
          affect the pipe's sequence of monadic actions or return value when
          you run it.
    -}
    Lazy(..),
    Strict(..),
    -- ** Composition operators
    {-|
        I provide convenience functions for composition that take care of
        newtype wrapping and unwrapping.  For example:

> p1 <+< p2 = unLazy $ Lazy p1 <<< Lazy p2

        '<+<' and '<-<' correspond to '<<<' from "Control.Category"

        '>+>' and '>+>' correspond to '>>>' from "Control.Category"

        '<+<' and '>+>' use 'Lazy' composition (Mnemonic: + for optimistic
        evaluation)

        '<-<' and '>->' use 'Strict' composition (Mnemonic: - for pessimistic
        evaluation) 
    -}
    (<+<),
    (>+>),
    (<-<),
    (>->),
    -- * Running Pipes
    runPipe,
    discard
    ) where

import Control.Applicative
import Control.Category
import Control.Monad
import Control.Monad.Trans
import Prelude hiding ((.), id)

{-|
    The base type for pipes

    [@a@] The type of input received from upstream pipes

    [@b@] The type of output delivered to downstream pipes

    [@m@] The base monad

    [@r@] The type of the monad's final result
-}
data Pipe a b m r =
    Pure r                     -- pure = Pure
  | M     (m   (Pipe a b m r)) -- Monad
  | Await (a -> Pipe a b m r ) -- Functor
  | Yield (b,   Pipe a b m r ) -- Functor

instance (Monad m) => Functor (Pipe a b m) where
    fmap f c = case c of
        Pure r   -> Pure $ f r
        M mc     -> M     $ liftM (fmap f) mc
        Await fc -> Await $ fmap  (fmap f) fc
        Yield fc -> Yield $ fmap  (fmap f) fc

instance (Monad m) => Applicative (Pipe a b m) where
    pure = Pure
    f <*> x = case f of
        Pure r   -> fmap r x
        M mc     -> M     $ liftM (<*> x) mc
        Await fc -> Await $ fmap  (<*> x) fc
        Yield fc -> Yield $ fmap  (<*> x) fc

instance (Monad m) => Monad (Pipe a b m) where
    return = pure
    m >>= f = case m of
        Pure r   -> f r
        M mc     -> M     $ liftM (>>= f) mc
        Await fc -> Await $ fmap  (>>= f) fc
        Yield fc -> Yield $ fmap  (>>= f) fc

instance MonadTrans (Pipe a b) where lift = M . liftM pure

-- | A datatype with no exposed constructors
data Zero = Zero

-- | A pipe that can only produce values
type Producer b m r = Pipe Zero b m r

-- | A pipe that can only consume values
type Consumer a m r = Pipe a Zero m r

-- | A self-contained pipeline that is ready to be run
type Pipeline m r = Pipe Zero Zero m r

{-|
    Wait for input from upstream within the 'Pipe' monad:

    'await' blocks until input is ready.
-}
await :: Pipe a b m a
await = Await Pure 

{-|
    Pass output downstream within the 'Pipe' monad:

    'yield' blocks until the output has been received.
-}
yield :: b -> Pipe a b m ()
yield x = Yield (x, Pure ())

{-|
    Convert a pure function into a pipe

> pipe = forever $ do
>     x <- await
>     yield (f x)
-}
pipe :: (Monad m) => (a -> b) -> Pipe a b m r
pipe f = forever $ await >>= yield . f

newtype Lazy   m r a b = Lazy   { unLazy   :: Pipe a b m r}
newtype Strict m r a b = Strict { unStrict :: Pipe a b m r}

(<+<), (<-<) :: (Monad m) => Pipe b c m r -> Pipe a b m r -> Pipe a c m r
p1 <+< p2 = unLazy   (Lazy   p1 <<< Lazy   p2)
p1 <-< p2 = unStrict (Strict p1 <<< Strict p2)

(>+>), (>->) :: (Monad m) => Pipe a b m r -> Pipe b c m r -> Pipe a c m r
p1 >+> p2 = unLazy   (Lazy   p1 >>> Lazy   p2)
p1 >-> p2 = unStrict (Strict p1 >>> Strict p2)

-- The associativities help pipe chains detect termination quickly
infixr 9 <+<, >->
infixl 9 >+>, <-<

instance (Monad m) => Category (Lazy m r) where
    id = Lazy $ pipe id
    Lazy p1' . Lazy p2' = Lazy $ case (p1', p2') of
        (Yield (x1, p1), p2            ) -> yield x1 >> p1 <+< p2
        (M m1          , p2            ) -> lift m1 >>= \p1 -> p1 <+< p2
        (Pure r1       , _             ) -> Pure r1
        (Await f1      , Yield (x2, p2)) -> f1 x2 <+< p2
        (p1            , Await f2      ) -> await >>= \x -> p1 <+< f2 x
        (p1            , M m2          ) -> lift m2 >>= \p2 -> p1 <+< p2
        (_             , Pure r2       ) -> Pure r2

instance (Monad m) => Category (Strict m r) where
    id = Strict $ pipe id
    Strict p1' . Strict p2' = Strict $ case (p1', p2') of
        (_             , Pure r2       ) -> Pure r2
        (p1            , M m2          ) -> lift m2 >>= \p2 -> p1 <-< p2
        (p1            , Await f2      ) -> await >>= \x -> p1 <-< f2 x
        (Await f1      , Yield (x2, p2)) -> f1 x2 <-< p2
        (Pure r1       , _             ) -> Pure r1
        (M m1          , p2            ) -> lift m1 >>= \p1 -> p1 <-< p2
        (Yield (x1, p1), p2            ) -> yield x1 >> p1 <-< p2

{-|
    Run the 'Pipe' monad transformer, converting it back into the base monad

    'runPipe' will not work on a pipe that has loose input or output ends.  If
    your pipe is still generating unhandled output, use the 'discard' pipe to
    discard the output.  If your pipe still requires input, then how do you
    expect to run it?
-}
runPipe :: (Monad m) => Pipeline m r -> m r
runPipe p' = case p' of
    Pure r          -> return r
    M mp            -> mp >>= runPipe
    Await f         -> runPipe $ f Zero
    Yield (Zero, p) -> runPipe p

-- | The 'discard' pipe silently discards all input fed to it.
discard :: (Monad m) => Consumer a m r
discard = forever await
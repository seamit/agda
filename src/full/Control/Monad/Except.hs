{- 
This is stolen from mtl-2.2.1 with instances added
-}
{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses, UndecidableInstances #-}
module Control.Monad.Except 
  (
    MonadError(..),
    ExceptT(ExceptT),
    Except,
    
    runExceptT,
    mapExceptT,
    withExceptT,
    runExcept,
    mapExcept,
    withExcept,

    module Control.Monad,
    module Control.Monad.Fix,
    module Control.Monad.Trans,
        
  ) where

import Control.Monad.Error.Class
import Control.Monad.Trans
import Control.Monad.Trans.Except 

import Control.Monad
import Control.Monad.Fix

#if defined(__GLASGOW_HASKELL__) && __GLASGOW_HASKELL__ < 707
import Control.Monad.Instances ()
#endif

import Control.Monad.Reader.Class
import Control.Monad.Writer.Class
import Control.Monad.State.Class

instance Monad m => MonadError e (ExceptT e m) where
    throwError = throwE
    catchError = catchE

instance MonadReader r m => MonadReader r (ExceptT e m) where
    ask    = lift ask
    local  = mapExceptT . local
    reader = lift . reader

instance MonadState s m => MonadState s (ExceptT e m) where
    get   = lift get
    put   = lift . put
    state = lift . state

instance MonadWriter w m => MonadWriter w (ExceptT e m) where
    writer = lift . writer
    tell   = lift . tell
    listen = liftListen listen
    pass   = liftPass pass

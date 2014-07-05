module Agda.Utils.Read 
    ( readEither
    , readMaybe
    )
    where

-- These functions can be found in Text.Read since base 4.6.0.0


readEither :: Read a => String -> Either String a
readEither s = case reads s of
          [(x,"")]  -> Right x
          _         -> Left $ "readEither: parse error string " ++ s 

readMaybe :: Read a => String -> Maybe a
readMaybe = either (\_ -> Nothing) Just . readEither
            

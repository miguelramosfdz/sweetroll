{-# LANGUAGE OverloadedStrings, UnicodeSyntax #-}

module DevelMain where

import           Sweetroll.Prelude
import           System.Environment
import           Text.Read (readMaybe)
import           Rapid
import           Network.Wai
import           Network.Wai.Handler.Warp
import           Network.Wai.Middleware.RequestLogger
import           Sweetroll.Api
import           Sweetroll.Conf

app ∷ IO Application
app = liftM logStdoutDev $ initSweetrollApp def { testMode = True } def { secretKey = "TESTKEY" }

update ∷ IO ()
update = do
  port ← lookupEnv "SWEETROLL_DEV_PORT"
  let portNumber = fromMaybe 4000 $ readMaybe =<< port
  rapid 0 $ \r →
    restart r (asString "web") (runSettings (setPort portNumber defaultSettings) =<< app)
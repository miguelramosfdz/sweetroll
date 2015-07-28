{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax #-}
{-# LANGUAGE TypeOperators, TypeFamilies, FlexibleInstances, MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables, UndecidableInstances #-}

-- | The IndieAuth/rel-me-auth implementation, using JSON Web Tokens.
module Sweetroll.Auth (
  JWT
, VerifiedJWT
, module Sweetroll.Auth
) where

import           ClassyPrelude
import           Control.Monad.Except (throwError)
import           Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import           Data.Foldable (asum)
import qualified Data.Stringable as S
import qualified Data.List as L
import           Web.JWT hiding (header)
import           Network.HTTP.Types
import qualified Network.HTTP.Client as HC
import qualified Network.Wai as Wai
import           Servant
import           Servant.Server.Internal (succeedWith)
import           Servant.Server.Internal.Enter
import           Sweetroll.Monads
import           Sweetroll.Conf
import           Sweetroll.Util

data AuthProtect
data AuthProtected α = AuthProtected Text α

instance Enter α φ β ⇒ Enter (AuthProtected α) φ (AuthProtected β) where
  enter f (AuthProtected k a) = AuthProtected k $ enter f a

instance HasServer rest ⇒ HasServer (AuthProtect :> rest) where
  type ServerT (AuthProtect :> rest) α = AuthProtected (JWT VerifiedJWT → ServerT rest α)

  route Proxy (AuthProtected secKey subserver) req respond =
    case asum [ L.lookup hAuthorization (Wai.requestHeaders req) >>= fromHeader
              , join $ L.lookup "access_token" $ Wai.queryString req ] of
      Nothing → respond . succeedWith $ Wai.responseLBS status401 [] "Authorization/access_token not found."
      Just tok → do
        case decodeAndVerifySignature (secret secKey) (S.toText tok) of
          Nothing → respond . succeedWith $ Wai.responseLBS status401 [] "Invalid auth token."
          Just decodedToken → route (Proxy ∷ Proxy rest) (subserver decodedToken) req respond

instance HasLink sub ⇒ HasLink (AuthProtect :> sub) where
  type MkLink (AuthProtect :> sub) = MkLink sub
  toLink _ = toLink (Proxy ∷ Proxy sub)

fromHeader ∷ ByteString → Maybe ByteString
fromHeader "" = Nothing
fromHeader au = return $ drop 7 au -- 7 chars in "Bearer "

getAuth ∷ JWT VerifiedJWT → Sweetroll [(Text, Text)]
getAuth token = return [("me", S.toText meVal)]
  where meVal = case sub $ claims token of
                  Just me → show me
                  _ → ""

signAccessToken ∷ Text → Text → Text → UTCTime → Text
signAccessToken key domain me now = encodeSigned HS256 (secret key) t
  where t = def { iss = stringOrURI domain
                , sub = stringOrURI me
                , iat = intDate $ utcTimeToPOSIXSeconds now }

makeAccessToken ∷ Text → Sweetroll [(Text, Text)]
makeAccessToken me = do
  conf ← getConf
  secs ← getSecs
  now ← liftIO getCurrentTime
  return [ ("access_token", signAccessToken (secretKey secs) (domainName conf) me now)
         , ("scope", "post"), ("me", me) ]

postLogin ∷ Maybe Text → Maybe Text → Maybe Text → Maybe Text → Maybe Text → Sweetroll [(Text, Text)]
postLogin me code redirectUri clientId state = do
  conf ← getConf
  let valid = makeAccessToken $ fromMaybe "unknown" me
      opt = fromMaybe ""
  if testMode conf then valid else do
    let reqBody = writeForm [
                    ("code",         opt code)
                  , ("redirect_uri", opt redirectUri)
                  , ("client_id",    fromMaybe (baseUrl conf) clientId)
                  , (asText "state", opt state) ]
    -- liftIO $ putStrLn $ toText reqBody
    indieAuthReq ← liftIO $ HC.parseUrl $ indieAuthCheckEndpoint conf
    resp ← request (indieAuthReq { HC.method = "POST"
                                 , HC.requestHeaders = [ (hContentType, "application/x-www-form-urlencoded; charset=utf-8") ] -- "indieauth suddenly stopped working" *facepalm*
                                 , HC.requestBody = HC.RequestBodyBS reqBody }) ∷ Sweetroll (HC.Response LByteString)
    if HC.responseStatus resp == ok200 then valid
    else throwError err401

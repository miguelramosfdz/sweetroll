{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax, FlexibleContexts, ConstraintKinds #-}

-- | All the things related to making HTTP requests and parsing them.
module Sweetroll.HTTPClient (
  module Sweetroll.HTTPClient
, module Network.HTTP.Types
, Response
, responseStatus
, responseHeaders
, responseBody
) where

import           Sweetroll.Prelude
import           Sweetroll.Monads ()
import           Data.Conduit
import qualified Data.Conduit.Combinators as C
import qualified Data.Vector as V
import qualified Data.HashMap.Strict as HMS
import           Data.HashMap.Strict (adjust)
import qualified Data.CaseInsensitive as CI
import           Data.Microformats2.Parser
import           Data.IndieWeb.MicroformatsUtil
import           Data.IndieWeb.SiloToMicroformats
import           Data.IndieWeb.Authorship
import           Network.HTTP.Types
import           Network.HTTP.Conduit as HC
import           Network.HTTP.Client.Conduit as HCC
import           Network.HTTP.Client.Internal (setUri) -- The fuck?
import           Network.HTTP.Client (setRequestIgnoreStatus)
import           Sweetroll.Conf (mf2Options)

type MonadHTTP ψ μ = (Has Manager ψ, MonadReader ψ μ, MonadIO μ, MonadBaseControl IO μ)

runHTTP = runEitherT

reqU ∷ (MonadHTTP ψ μ) ⇒ URI → EitherT Text μ Request
reqU uri = hoistEither $ bimap tshow id $ setUri defaultRequest uri

reqS ∷ (MonadHTTP ψ μ, ConvertibleStrings σ String) ⇒ σ → EitherT Text μ Request
reqS uri = hoistEither $ bimap tshow id $ parseUrlThrow $ cs uri

anyStatus ∷ (MonadHTTP ψ μ) ⇒ Request → EitherT Text μ Request
anyStatus req = return $ setRequestIgnoreStatus req

postForm ∷ (MonadHTTP ψ μ) ⇒ [(Text, Text)] → Request → EitherT Text μ Request
postForm form req =
  return req { method = "POST"
             , requestHeaders = [ (hContentType, "application/x-www-form-urlencoded; charset=utf-8") ]
             , requestBody = RequestBodyBS $ writeForm form }

performWithFn ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ (ConduitM ι ByteString μ () → μ ρ) → Request → EitherT Text μ (Response ρ)
performWithFn fn req = do
  res ← lift $ tryAny $ HCC.withResponse req $ \res → do
    putStrLn $ cs $ "Request status for <" ++ show (getUri req) ++ ">: " ++ (show . statusCode . responseStatus $ res)
    body ← fn $ responseBody res
    return res { responseBody = body }
  hoistEither $ bimap tshow id res

performWithVoid ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ Request → EitherT Text μ (Response ())
performWithVoid = performWithFn (const $ return ())

performWithBytes ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ Request → EitherT Text μ (Response LByteString)
performWithBytes = performWithFn ($$ C.sinkLazy)

performWithHtml ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ Request → EitherT Text μ (Response XDocument)
performWithHtml = performWithFn ($$ sinkDoc) . (\req → req { requestHeaders = [ (hAccept, "text/html; charset=utf-8") ] })

fetchEntryWithAuthors ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ URI → Response XDocument → μ (Maybe Value, Value)
fetchEntryWithAuthors uri res = do
  let mf2Options' = mf2Options { baseUri = Just uri }
      mfRoot = parseMf2 mf2Options' $ documentRoot $ responseBody res
  he ← case headMay =<< allMicroformatsOfType "h-entry" mfRoot of
    Just mfEntry@(mfE, _) → do
      let fetch uri' = fmap (\x → responseBody <$> hush x) $ runHTTP $ reqU uri' >>= performWithHtml
      authors ← entryAuthors mf2Options' fetch uri mfRoot mfEntry
      let addAuthors (Object o) = Object $ adjust addAuthors' "properties" o
          addAuthors x = x
          addAuthors' (Object o) = Object $ insertMap "author" (Array $ fromList $ fromMaybe [] authors) o
          addAuthors' x = x
      return $ Just $ addAuthors mfE
    _ → return $ parseTwitter mf2Options' $ documentRoot $ responseBody res
  return $ case he of
             Just mfE → (Just mfE, mfRoot)
             _ → (Nothing, mfRoot)

fetchReferenceContexts ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ Text → Object → μ Object
fetchReferenceContexts k props = do
    newCtxs ← updateCtxs $ lookup k props
    return $ insertMap k newCtxs props
  where updateCtxs (Just (Array v)) = (Array . reverse) `liftM` mapM fetch v
        updateCtxs _ = return $ Array V.empty
        fetch v@(Object _) = maybe (return v) (fetch . String) (v ^? key "properties" . key "url" . nth 0 . _String)
        fetch (String u) = maybeT (return $ String u) return $ do
          uri ← hoistMaybe $ parseURI $ cs u
          resp ← hoistMaybe =<< (liftM hush $ runHTTP $ reqU uri >>= performWithHtml)
          ewa ← fetchEntryWithAuthors uri resp
          case ewa of
            (Just (Object entry), _) → do
              prs ← lift $ fetchAllReferenceContexts $ fromMaybe (HMS.fromList []) $ (Object entry) ^? key "properties" . _Object
              return $ Object $ insertMap "properties" (Object prs) $ insertMap "fetched-url" (toJSON u) entry
            _ → mzero
        fetch x = return x

fetchAllReferenceContexts ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ Object → μ Object
fetchAllReferenceContexts = fetchReferenceContexts "in-reply-to"
                        >=> fetchReferenceContexts "like-of"
                        >=> fetchReferenceContexts "repost-of"
                        >=> fetchReferenceContexts "quotation-of"

jsonFetch ∷ Manager → Value → Value → IO Value
jsonFetch mgr (String uri) rdata = do
  let setData req = return $ req { method = fromMaybe "GET" $ cs . toUpper <$> rdata ^? key "method" . _String
                                 , requestHeaders = fromMaybe [] $ map (bimap (CI.mk . cs) (cs . fromMaybe "" . (^? _String))) . HMS.toList <$> rdata ^? key "headers" . _Object
                                 , requestBody = RequestBodyBS $ fromMaybe "" $ cs <$> rdata ^? key "body" . _String }
  r ← runReaderT (runHTTP $ reqS uri >>= anyStatus >>= setData >>= performWithBytes) mgr
  return $ case r of
                Left errmsg → object [ "error" .= errmsg ]
                Right res → object [ "status" .= statusCode (responseStatus res)
                                   , "headers" .= object (map (\(k, v) → (asText $ cs $ CI.foldedCase k) .= (String $ cs v)) $ responseHeaders res)
                                   , "body" .= String (cs $ responseBody res) ]
jsonFetch _ _ _ = return $ object [ "error" .= String "The URI must be a string" ]

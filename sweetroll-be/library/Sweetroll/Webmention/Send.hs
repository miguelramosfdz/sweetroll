{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax, TupleSections, RankNTypes, FlexibleContexts, RecordWildCards #-}

module Sweetroll.Webmention.Send where

import           Sweetroll.Prelude hiding (from, to)
import           Data.Microformats2.Parser
import           Data.IndieWeb.Endpoints
import qualified Text.HTML.DOM as HTML
import           Text.XML.Lens hiding (from, to)
import           Network.HTTP.Link
import           Sweetroll.Conf
import           Sweetroll.HTTPClient hiding (Header)

type SourceURI = URI

data MentionType = Normal | Syndicate
  deriving (Eq, Show)

data Mention = Mention { mentionTarget   ∷ URI
                       , mentionEndpoint ∷ URI
                       , mentionType     ∷ MentionType }
                       deriving (Eq, Show)

data MentionResult = MentionFailed Mention Text | MentionAccepted Mention | MentionSyndicated Mention Text
  deriving (Eq, Show)

sendWebmention ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ SourceURI → Mention → μ MentionResult
sendWebmention source mention@Mention{..} = do
  resp ← runHTTP $ reqU mentionEndpoint >>= anyStatus
                 >>= postForm [ ("source", tshow source), ("target", tshow mentionTarget) ]
                 >>= performWithBytes
  return $ case resp of
    Left e →
      MentionFailed mention e
    Right r | not (statusIsSuccessful $ responseStatus r) →
      MentionFailed mention $ "Error code: " ++ tshow (responseStatus r)
    Right r | mentionType == Syndicate →
      maybe (MentionFailed mention "No Location header for syndication")
            (MentionSyndicated mention . decodeUtf8)
            (lookup "Location" $ responseHeaders r)
    Right _ →
      MentionAccepted mention

sendWebmentions ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ SourceURI → [Mention] → μ [MentionResult]
sendWebmentions from ms = mapM (sendWebmention from) $ nub ms


linksFromHeader ∷ ∀ body. Response body → [Link]
linksFromHeader r = fromMaybe [] (lookup "Link" (responseHeaders r) >>= parseLinkHeader . decodeUtf8)

discoverWebmentionEndpoints ∷ Value → [Link] → [URI]
discoverWebmentionEndpoints = discoverEndpoints [ "webmention", "http://webmention.org/" ]

getWebmentionEndpoint ∷ Response XDocument → Maybe URI
getWebmentionEndpoint r = listToMaybe $ discoverWebmentionEndpoints mf2Root (linksFromHeader r)
    where mf2Root = parseMf2 mf2Options $ documentRoot $ responseBody r

linkWebmention ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ MentionType → URI → μ (Maybe Mention)
linkWebmention typ uri = do
  resp ← runHTTP $ reqU uri >>= anyStatus >>= performWithHtml
  return $ (\endp → Mention { mentionTarget = uri
                            , mentionEndpoint = endp
                            , mentionType = typ })
           <$> (getWebmentionEndpoint =<< hush resp)

contentWebmentions ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ XElement → μ [Mention]
contentWebmentions e =
  catMaybes <$> (forM (e ^.. entire . el "a") $ \a →
    case parseURI =<< cs <$> a ^? attr "href" of
      Nothing → return Nothing
      Just uri → linkWebmention (if isJust (a ^? attr "data-synd") then Syndicate else Normal) uri)

entryWebmentions ∷ (MonadHTTP ψ μ, MonadCatch μ) ⇒ Value → μ [Mention]
entryWebmentions v = do
  contMs ← contentWebmentions $ documentRoot $ HTML.parseSTChunks $ singleton $
    concat $ v ^.. key "properties" . key "content" . values . key "html" . _String
  ctxMs ← sequence $ do -- List monad
    ctxName ← [ "in-reply-to", "like-of", "repost-of", "quotation-of" ]
    url ← mapMaybe (parseURI . cs) $ nub $
            (v ^.. key "properties" . key ctxName . values . key "properties" . key "url" . values . _String) ++
            (v ^.. key "properties" . key ctxName . values . key "fetched-url" . _String) ++
            (v ^.. key "properties" . key ctxName . values . _String)
    return $ linkWebmention Normal url
  return $ contMs ++ catMaybes ctxMs

{-# LANGUAGE NoImplicitPrelude, OverloadedStrings, UnicodeSyntax #-}
{-# LANGUAGE TypeOperators, TypeFamilies, DataKinds, RecordWildCards #-}
{-# LANGUAGE FlexibleInstances, FlexibleContexts, MultiParamTypeClasses #-}

-- | The HTTP routes
module Sweetroll.Routes where

import           ClassyPrelude
import qualified Network.HTTP.Link as L
import           Servant hiding (toText)
import           Data.String.Conversions
import           Sweetroll.Auth (AuthProtect)
import           Sweetroll.Conf
import           Sweetroll.Micropub.Request
import           Sweetroll.Micropub.Response
import           Sweetroll.Pages
import           Sweetroll.Slice

data HTML
data CSS
data Atom

type WithLink α               = (Headers '[Header "Link" [L.Link]] α)

type IndieConfigRoute         = "indie-config" :> Get '[HTML] IndieConfig
type DefaultCssRoute          = "default-style.css" :> Get '[CSS] LByteString

type PostLoginRoute           = "login" :> ReqBody '[FormUrlEncoded] [(Text, Text)] :> Post '[FormUrlEncoded] [(Text, Text)]
type GetLoginRoute            = "login" :> AuthProtect :> Get '[FormUrlEncoded] [(Text, Text)]
type PostMicropubRoute        = "micropub" :> AuthProtect :> ReqBody '[FormUrlEncoded, JSON] MicropubRequest :> Post '[FormUrlEncoded, JSON] (Headers '[Header "Location" Text] MicropubResponse)
type GetMicropubRoute         = "micropub" :> AuthProtect :> QueryParam "q" Text :> QueryParams "properties" Text :> QueryParam "url" Text :> Get '[FormUrlEncoded, JSON] MicropubResponse

type PostWebmentionRoute      = "webmention" :> ReqBody '[FormUrlEncoded] [(Text, Text)] :> Post '[FormUrlEncoded] ()

type EntryRoute               = Capture "catName" String :> Capture "slug" String :> Get '[HTML] (WithLink (View EntryPage))
type CatRoute                 = Capture "catName" String :> QueryParam "before" Int :> QueryParam "after" Int :> Get '[HTML, Atom] (WithLink (View IndexedPage))
type CatRouteE                = Capture "catName" String :> Get '[HTML, Atom] (WithLink (View IndexedPage))
type CatRouteB                = Capture "catName" String :> QueryParam "before" Int :> Get '[HTML, Atom] (WithLink (View IndexedPage))
type CatRouteA                = Capture "catName" String :> QueryParam "after" Int :> Get '[HTML, Atom] (WithLink (View IndexedPage))
type IndexRoute               = Get '[HTML] (WithLink (View IndexedPage))

type SweetrollAPI             = IndieConfigRoute :<|> DefaultCssRoute
                           :<|> PostLoginRoute :<|> GetLoginRoute
                           :<|> PostMicropubRoute :<|> GetMicropubRoute
                           :<|> PostWebmentionRoute
                           :<|> EntryRoute :<|> CatRoute :<|> IndexRoute

sweetrollAPI ∷ Proxy SweetrollAPI
sweetrollAPI = Proxy

permalink ∷ (IsElem α SweetrollAPI, HasLink α) ⇒ Proxy α → MkLink α -- MkLink is URI
permalink = safeLink sweetrollAPI

showLink ∷ URI → Text
showLink = ("/" ++) . cs . show

catLink ∷ Slice α → URI
catLink Slice{..} = permalink (Proxy ∷ Proxy CatRouteE) sliceCatName

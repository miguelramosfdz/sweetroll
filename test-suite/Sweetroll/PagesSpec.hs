{-# LANGUAGE NoImplicitPrelude, NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings, QuasiQuotes #-}

module Sweetroll.PagesSpec (spec) where

import           ClassyPrelude
import           Test.Hspec
import           Sweetroll.Util (parseISOTime)
import           Sweetroll.Pages
import           Text.RawString.QQ
import           Data.Microformats2
import           Data.Microformats2.Aeson()
import           Web.Simple.Templates.Language

testEntryTpl :: Either String Template
testEntryTpl = compileTemplate [r|<$if(isNote)$note$else$article$endif$>$if(isNote)$
  <p>$content$</p>
$else$
  <h1><a href="$permalink$">$name$</a></h1>
  $content$
$endif$  <time datetime="$publishedAttr$">$published$</time>
</$if(isNote)$note$else$article$endif$>|]

testCategoryTpl :: Either String Template
testCategoryTpl = compileTemplate [r|<category name="$name$">
$for(entry in entries)$<e href="$entry.permalink$">$entry.content$</e>
$endfor$</category>|]

spec :: Spec
spec = do
  describe "renderPage" $ do
    it "renders notes" $ do
      let testNote = defaultEntry {
        entryContent      = Just $ Right "Hello, world!"
      , entryPublished    = parseISOTime "2013-10-17T09:42:49.000Z" }
      case testEntryTpl of
        Left str -> fail str
        Right tpl ->
          renderTemplate tpl mempty (entryView "articles" ("first", testNote)) `shouldBe` [r|<note>
  <p>Hello, world!</p>
  <time datetime="2013-10-17 09:42">17.10.2013 09:42 AM</time>
</note>|]

    it "renders articles" $ do
      let testArticle = defaultEntry {
        entryName         = Just "First post"
      , entryContent      = Just $ Right "<p>This is the content</p>"
      , entryPublished    = parseISOTime "2013-10-17T09:42:49.000Z" }
      case testEntryTpl of
        Left str -> fail str
        Right tpl ->
          renderTemplate tpl mempty (entryView "articles" ("first", testArticle)) `shouldBe` [r|<article>
  <h1><a href="/articles/first">First post</a></h1>
  <p>This is the content</p>
  <time datetime="2013-10-17 09:42">17.10.2013 09:42 AM</time>
</article>|]

    it "renders categories" $ do
      let testEntries = [ ("f", defaultEntry { entryContent = Just $ Right "First note"  }),
                          ("s", defaultEntry { entryContent = Just $ Right "Second note" }) ]
      case testCategoryTpl of
        Left str -> fail str
        Right tpl ->
          renderTemplate tpl mempty (catView "test" testEntries) `shouldBe` [r|<category name="test">
<e href="/test/f">First note</e>
<e href="/test/s">Second note</e>
</category>|]
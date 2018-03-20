{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}

module ES
  ( initServer
  , IndexSettings(..)
  , createIndex
  , checkIndices
  , queryIndex
  , scrollSearch
  ) where

import           Control.Monad ((<=<), forM_, unless)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader (ask, asks)
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.Aeson.Types as J (Parser, parseEither)
import qualified Data.Attoparsec.ByteString as AP
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import           Data.Default (Default(def))
import qualified Data.HashMap.Strict as HM
import           Data.List (intercalate)
import           Data.Monoid ((<>))
import           Data.String (IsString)
import qualified Data.Text as T
import qualified Network.HTTP.Client as HTTP
import           Network.HTTP.Types.Header (hAccept, hContentType)
import           Network.HTTP.Types.Method (StdMethod(GET, PUT), renderStdMethod)
import qualified Network.HTTP.Types.URI as HTTP (Query)
import qualified Network.URI as URI
import qualified Waimwork.Config as C

import Monoid
import JSON
import Schema
import Global

initServer :: C.Config -> IO HTTP.Request
initServer conf = HTTP.parseUrlThrow (conf C.! "server")

elasticSearch :: J.FromJSON r => StdMethod -> [String] -> HTTP.Query -> Maybe J.Encoding -> M r
elasticSearch meth url query body = do
  glob <- ask
  let req = globalES glob
      req' = maybe id setBody body $
        HTTP.setQueryString query req
        { HTTP.method = renderStdMethod meth
        , HTTP.path = HTTP.path req <> BS.intercalate "/" (map (BSC.pack . URI.escapeURIString URI.isUnescapedInURIComponent) url)
        , HTTP.requestHeaders = (hAccept, "application/json") : HTTP.requestHeaders req
        }
  liftIO $ do
    -- print $ HTTP.path req'
    -- print $ JE.encodingToLazyByteString <$> body
    either fail return . (J.parseEither J.parseJSON <=< AP.eitherResult)
      =<< HTTP.withResponse req' (globalHTTP glob) parse
  where
  setBody bod req = req
    { HTTP.requestHeaders = (hContentType, "application/json") : HTTP.requestHeaders req
    , HTTP.requestBody = HTTP.RequestBodyLBS $ JE.encodingToLazyByteString bod
    }
  parse r = AP.parseWith (HTTP.responseBody r) J.json BS.empty

data IndexSettings = IndexSettings
  { indexNumberOfShards
  , indexNumberOfReplicas
  , indexNumberOfRoutingShards :: Word
  }

instance Default IndexSettings where
  def = IndexSettings
    { indexNumberOfShards = 8
    , indexNumberOfReplicas = 1
    , indexNumberOfRoutingShards = 8
    }

instance J.ToJSON IndexSettings where
  toJSON IndexSettings{..} = J.object
    [ "number_of_shards" J..= indexNumberOfShards
    , "number_of_replicas" J..= indexNumberOfReplicas
    , "number_of_routing_shards" J..= indexNumberOfRoutingShards
    ]
  toEncoding IndexSettings{..} = J.pairs
    (  "number_of_shards" J..= indexNumberOfShards
    <> "number_of_replicas" J..= indexNumberOfReplicas
    <> "number_of_routing_shards" J..= indexNumberOfRoutingShards
    )

createIndex :: IndexSettings -> Catalog -> M J.Value
createIndex sets cat@Catalog{ catalogStore = CatalogES idxn mapn } = elasticSearch PUT [T.unpack idxn] [] $ Just $ JE.pairs $
     "settings" .=*
    (  "index" J..= sets)
  <> "mappings" .=*
    (  mapn .=*
      (  "dynamic" J..= J.String "strict"
      <> "properties" J..= HM.map fieldType (catalogFieldMap cat)))
createIndex _ _ = return J.Null

checkIndices :: M ()
checkIndices = do
  cats <- asks $ filter ises . HM.elems . globalCatalogs
  indices <- elasticSearch GET [intercalate "," $ map catalogIndex' cats] [] Nothing
  either
    (fail . ("ES index mismatch: " ++))
    return
    $ J.parseEither (J.withObject "indices" $ forM_ cats . catalog) indices
  where
  ises Catalog{ catalogStore = CatalogES{} } = True
  ises _ = False
  catalogIndex' ~Catalog{ catalogStore = CatalogES idxn _ } = T.unpack idxn
  catalog is ~cat@Catalog{ catalogStore = CatalogES idxn mapn } = parseJSONField idxn (idx cat mapn) is
  idx :: Catalog -> T.Text -> J.Value -> J.Parser ()
  idx cat mapn = J.withObject "index" $ parseJSONField "mappings" $ J.withObject "mappings" $
    parseJSONField mapn (mapping $ expandFields $ catalogFields cat)
  mapping :: Fields -> J.Value -> J.Parser ()
  mapping fields = J.withObject "mapping" $ parseJSONField "properties" $ J.withObject "properties" $ \ps ->
    forM_ fields $ \field -> parseJSONField (fieldName field) (prop field) ps
  prop :: Field -> J.Value -> J.Parser ()
  prop field = J.withObject "property" $ \p -> do
    t <- p J..: "type"
    unless (t == fieldType field) $ fail $ "incorrect field type; should be " ++ show (fieldType field)

scrollTime :: IsString s => s
scrollTime = "10s"

queryIndex :: Catalog -> Query -> M J.Value
queryIndex cat@Catalog{ catalogStore = CatalogES idxn mapn } Query{..} =
  elasticSearch GET
    [T.unpack idxn, T.unpack mapn, "_search"]
    (mwhen queryScroll $ [("scroll", Just scrollTime)])
    $ Just $ JE.pairs $
       (mwhen (queryOffset > 0) $ "from" J..= queryOffset)
    <> (mwhen (queryLimit  > 0) $ "size" J..= queryLimit)
    <> "sort" `JE.pair` JE.list (\(f, a) -> JE.pairs (f J..= if a then "asc" else "desc" :: String)) (querySort ++ [("_doc",True)])
    <> (mwhen (not (null queryFields)) $
       "_source" J..= queryFields)
    <> "query" .=*
      ("bool" .=*
        ("filter" `JE.pair` JE.list (JE.pairs . term) queryFilter))
    <> (mwhen (not (null queryAggs)) $
       "aggs" .=* (foldMap
      (\f -> f .=* (agg (fieldType <$> HM.lookup f (catalogFieldMap cat)) .=* ("field" J..= f)))
      queryAggs))
  where
  term (f, a, Nothing) = "term" .=* (f `JE.pair` bsc a)
  term (f, a, Just b) = "range" .=* (f .=*
    (bound "gte" a <> bound "lte" b))
  bound t a
    | BS.null a = mempty
    | otherwise = t `JE.pair` bsc a
  agg (Just Text) = "terms"
  agg (Just Keyword) = "terms"
  agg _ = "stats"
  bsc = JE.string . BSC.unpack
queryIndex _ _ = return J.Null

scrollSearch :: T.Text -> M J.Value
scrollSearch sid = elasticSearch GET ["_search", "scroll"] [] $ Just $ JE.pairs $
     "scroll" J..= J.String scrollTime
  <> "scroll_id" J..= sid

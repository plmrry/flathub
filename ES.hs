{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module ES
  ( module ES.Types
  , initServer
  , IndexSettings(..)
  , createIndex
  , getIndices
  , queryIndex
  ) where

import           Control.Monad ((<=<))
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader (ask)
import qualified Data.Aeson as J
import qualified Data.Aeson.Encoding as JE
import qualified Data.Aeson.Types as J (parseEither, emptyObject)
import qualified Data.Attoparsec.ByteString as AP
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import           Data.Default (Default(def))
import qualified Data.HashMap.Strict as HM
import           Data.List (intercalate, find)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Network.HTTP.Client as HTTP
import           Network.HTTP.Types.Header (hAccept, hContentType)
import           Network.HTTP.Types.Method (StdMethod(GET, PUT), renderStdMethod)
import qualified Network.URI as URI
import qualified Waimwork.Config as C

import JSON
import ES.Types
import Schema
import Global

initServer :: C.Config -> IO Server
initServer conf = Server
  <$> HTTP.parseUrlThrow (conf C.! "server")

elasticSearch :: J.FromJSON r => StdMethod -> [String] -> Maybe J.Encoding -> M r
elasticSearch meth url body = do
  glob <- ask
  let req = serverRequest $ globalES glob
      req' =
        maybe id setBody body req
        { HTTP.method = renderStdMethod meth
        , HTTP.path = HTTP.path req <> BS.intercalate "/" (map (BSC.pack . URI.escapeURIString URI.isUnescapedInURIComponent) url)
        , HTTP.requestHeaders = (hAccept, "application/json") : HTTP.requestHeaders req
        }
  liftIO $
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
createIndex sets cat = elasticSearch PUT [T.unpack $ catalogIndex cat] $ Just $ JE.pairs $
     "settings" .=*
    (  "index" J..= sets)
  <> "mappings" .=*
    (  catalogMapping cat .=*
      (  "dynamic" J..= J.String "strict"
      <> "properties" .=* (foldMap (\f ->
          fieldName f .=* ("type" J..= fieldType f))
        $ expandFields $ catalogFields cat)))

getIndices :: [String] -> M J.Value
getIndices idx = elasticSearch GET [if null idx then "_all" else intercalate "," idx] Nothing

queryIndex :: Catalog -> Query -> M J.Value
queryIndex cat q =
  clean <$> elasticSearch GET
    [T.unpack $ catalogIndex cat, T.unpack $ catalogMapping cat, "_search"]
    (Just $ JE.pairs $
       "from" J..= queryOffset q
    <> "size" J..= queryLimit q
    <> "sort" `JE.pair` JE.list (\(f, a) -> JE.pairs (f J..= if a then "asc" else "desc" :: String)) (querySort q)
    <> (if null (queryFields q) then mempty else
       "_source" J..= queryFields q)
    <> "query" .=*
      ("bool" .=*
        ("filter" `JE.pair` JE.list (JE.pairs . term) (queryFilter q)))
    <> "aggs" .=* (foldMap
      (\f -> f .=* (agg (fieldType <$> find ((f ==) . fieldName) (expandFields $ catalogFields cat)) .=* ("field" J..= f)))
      (queryAggs q)))
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
  clean = mapObject $ HM.mapMaybeWithKey cleanTop
  cleanTop "aggregations" = Just
  cleanTop "hits" = Just . mapObject (HM.mapMaybeWithKey cleanHits)
  cleanTop _ = const Nothing
  cleanHits "total" = Just
  cleanHits "hits" = Just . mapArray (V.map sourceOnly)
  cleanHits _ = const Nothing
  sourceOnly (J.Object o) = HM.lookupDefault J.emptyObject "_source" o
  sourceOnly v = v
  mapObject :: (J.Object -> J.Object) -> J.Value -> J.Value
  mapObject f (J.Object o) = J.Object (f o)
  mapObject _ v = v
  mapArray :: (V.Vector J.Value -> V.Vector J.Value) -> J.Value -> J.Value
  mapArray f (J.Array v) = J.Array (f v)
  mapArray _ v = v

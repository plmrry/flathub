{-# LANGUAGE OverloadedStrings #-}

-- |https://docs.astropy.org/en/stable/io/ascii/ecsv.html
module Output.ECSV
  ( ecsvHeader
  , ecsvField
  , ecsvOutput
  ) where

import qualified Data.Aeson as J
import qualified Data.Aeson.Types as J
import qualified Data.ByteString.Builder as B
import           Data.Maybe (maybeToList)
import qualified Data.Vector as V
import qualified Network.Wai as Wai

import Catalog
import Type
import Field
import Backend
import Data.ECSV
import Output.Types
import Output.CSV

ecsvType :: Type -> ECSVDataType
ecsvType (Keyword _)   = ECSVString
ecsvType (Long _)      = ECSVInt64
ecsvType (ULong _)     = ECSVUInt64
ecsvType (Integer _)   = ECSVInt32
ecsvType (Short _)     = ECSVInt16
ecsvType (Byte _)      = ECSVInt8
ecsvType (Double _)    = ECSVFloat64
ecsvType (Float _)     = ECSVFloat32
ecsvType (HalfFloat _) = ECSVFloat16
ecsvType (Boolean _)   = ECSVBool
ecsvType (Array _)     = ECSVString
ecsvType (Void _)      = error "ecsvType Void"

ecsvField :: Field -> ECSVColumn
ecsvField f = ECSVColumn
  { ecsvColName = fieldName f
  , ecsvColDataType = ecsvType (fieldType f)
  , ecsvColSubtype = (`ECSVSubTypeArray` [Nothing]) . ecsvType <$> typeIsArray (fieldType f)
  , ecsvColFormat = Nothing
  , ecsvColUnit = fieldUnits f
  , ecsvColDescription = Just $ fieldTitle f <> foldMap (": " <>) (fieldDescr f)
  , ecsvColMeta = Just $ J.object $
    maybeToList (("enum" J..=) <$> fieldEnum f)
  }

ecsvHeader :: Catalog -> V.Vector Field -> [J.Pair] -> B.Builder
ecsvHeader cat fields meta = renderECSVHeader $ ECSVHeader
  { ecsvDelimiter = ','
  , ecsvDatatype = V.map ecsvField fields
  , ecsvMeta = Just $ J.object $
    [ "name" J..= catalogTitle cat
    , "description" J..= catalogDescr cat
    ] ++ meta
  , ecsvSchema = Nothing
  }

ecsvGenerator :: Wai.Request -> Catalog -> DataArgs V.Vector -> OutputBuilder
ecsvGenerator req cat args = csv
  { outputHeader = ecsvHeader cat (dataFields args)
    [ "filters" J..= dataFilters args
    , "sort" J..= map (\(f, a) -> J.object ["field" J..= fieldName f, "order" J..= if a then "asc" :: String else "desc"]) (dataSort args)
    ] <> outputHeader csv
  } where
  csv = outputGenerator csvOutput req cat args

ecsvOutput :: OutputFormat
ecsvOutput = OutputFormat
  { outputMimeType = "text/x-ecsv"
  , outputExtension = "ecsv"
  , outputGenerator = ecsvGenerator
  }

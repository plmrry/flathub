{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE ViewPatterns #-}

import           Control.Exception (throwIO)
import           Control.Monad ((<=<), forM_, when)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader (asks)
import qualified Data.Aeson as J
import           Data.Default (Default(def))
import qualified Data.HashMap.Strict as HM
import           Data.Maybe (fromMaybe, isNothing, isJust)
import           Data.Monoid ((<>))
import qualified Data.Text as T
import qualified Data.Vector as V
import qualified Data.Yaml as YAML
import qualified Network.HTTP.Client as HTTP
import qualified Network.Wai as Wai
import qualified System.Console.GetOpt as Opt
import           System.Environment (getProgName, getArgs)
import           System.Exit (exitFailure)
import qualified Text.Blaze.Html5 as H hiding (text, textValue)
import qualified Text.Blaze.Html5.Attributes as HA
import qualified Waimwork.Blaze as H (text, textValue, preEscapedBuilder)
import qualified Waimwork.Blaze as WH
import qualified Waimwork.Config as C
#ifdef HAVE_pgsql
import qualified Waimwork.Database.PostgreSQL as PG
#endif
import           Waimwork.Response (response, okResponse)
import           Waimwork.Warp (runWaimwork)
import qualified Web.Route.Invertible as R
import           Web.Route.Invertible.URI (routeActionURI)
import           Web.Route.Invertible.Wai (routeWaiError)

import Schema
import Global
import qualified ES
#ifdef HAVE_pgsql
import qualified PG
#endif
import Static
import Query
import Ingest
import Compression

html :: Wai.Request -> H.Markup -> Wai.Response
html req h = okResponse [] $ H.docTypeHtml $ do
  H.head $ do
    forM_ ([["jspm_packages", if isdev then "system.src.js" else "system.js"], ["jspm.config.js"]] ++ if isdev then [["dev.js"]] else [["index.js"]]) $ \src ->
      H.script H.! HA.type_ "text/javascript" H.! HA.src (staticURI src) $ mempty
    -- TODO: use System.resolve:
    forM_ [["jspm_packages", "npm", "datatables.net-dt@1.10.16", "css", "jquery.dataTables.css"], ["main.css"]] $ \src ->
      H.link H.! HA.rel "stylesheet" H.! HA.type_ "text/css" H.! HA.href (staticURI src)
    H.script H.! HA.type_ "text/javascript" H.! HA.src "//cdnjs.cloudflare.com/ajax/libs/mathjax/2.7.3/MathJax.js?config=TeX-AMS_CHTML" $ mempty
  H.body h
  where
  isdev = any ((==) "dev" . fst) $ Wai.queryString req

top :: Route ()
top = getPath R.unit $ \() req -> do
  cats <- asks globalCatalogs
  return $ html req $
    H.dl $
      forM_ (HM.toList cats) $ \(sim, cat) -> do
        H.dt $ H.a H.! HA.href (WH.routeActionValue simulation sim mempty) $
          H.text $ catalogTitle cat
        mapM_ (H.dd . H.preEscapedText) $ catalogDescr cat

simulation :: Route Simulation
simulation = getPath R.parameter $ \sim req -> do
  cat <- askCatalog sim
  let 
    (_, quri) = routeActionURI simulation sim
    fields = catalogFieldGroups cat
    fields' = catalogFields cat
    jcat = J.pairs $
         "uri" J..= show quri
      <> "bulk" J..= map (J.String . R.renderParameter) [BulkCSV Nothing, BulkCSV (Just CompressionGZip)]
      <> "fields" J..= fields'
    fieldBody :: Word -> FieldGroup -> H.Html
    fieldBody d f = H.span WH.!? (HA.title . H.textValue <$> fieldDescr f) $ do
      H.text $ fieldTitle f
      forM_ (fieldUnits f) $ \u -> do
        if d > 1 then H.br else " "
        H.span H.! HA.class_ "units" $ "[" <> H.preEscapedText u <> "]"
    field :: Word -> FieldGroup -> FieldGroup -> H.Html
    field d f' f@Field{ fieldSub = Nothing } = do
      H.th
          H.! HA.rowspan (H.toValue d)
          H.! H.dataAttribute "data" (H.textValue $ fieldName f')
          H.! H.dataAttribute "name" (H.textValue $ fieldName f')
          H.! H.dataAttribute "type" (dtype $ fieldType f)
          H.!? (not (fieldDisp f), H.dataAttribute "visible" "false")
          H.! H.dataAttribute "default-content" mempty $ do
        H.span H.! HA.id ("hide-" <> H.textValue (fieldName f')) H.! HA.class_ "hide" $ H.preEscapedString "&times;"
        fieldBody d f
    field _ _ f@Field{ fieldSub = Just s } = do
      H.th
          H.! HA.colspan (H.toValue $ length $ expandFields s) $
        fieldBody 1 f
    row :: Word -> [(FieldGroup -> FieldGroup, FieldGroup)] -> H.Html
    row d l = do
      H.tr $ mapM_ (\(p, f) -> field d (p f) f) l
      when (d > 1) $ row (pred d) $ foldMap (\(p, f) -> foldMap (fmap (p . subField f, ) . V.toList) $ fieldSub f) l
  return $ html req $ do
    H.script $ do
      "Catalog="
      H.preEscapedBuilder $ J.fromEncoding jcat
    H.h2 $ H.text $ catalogTitle cat
    mapM_ (H.div . H.preEscapedText) $ catalogDescr cat
    H.div $ "Query and explore a subset using the filters, download your selection using the link below, or get the full dataset above."
    H.table H.! HA.id "filt" $ mempty
    H.div H.! HA.id "dhist" $ do
      forM_ ['x','y'] $ \xy -> let xyv = H.stringValue [xy] in
        H.div H.! HA.id ("dhist-" <> xyv) H.! HA.class_ "dhist-xy" $
          H.button H.! HA.id ("dhist-" <> xyv <> "-tog") H.! HA.class_ "dhist-xy-tog" $
            "lin/log"
      H.canvas H.! HA.id "hist" $ mempty
    H.table H.! HA.id "tcat" H.! HA.class_ "compact" $ do
      H.thead $ row (fieldsDepth fields) ((id ,) <$> V.toList fields)
      H.tfoot $ H.tr $ H.td H.! HA.colspan (H.toValue $ length fields') H.! HA.class_ "loading" $ "loading..."
  where
  dtype (Long _) = "num"
  dtype (Integer _) = "num"
  dtype (Short _) = "num"
  dtype (Byte _) = "num"
  dtype (Double _) = "num"
  dtype (Float _) = "num"
  dtype (HalfFloat _) = "num"
  -- dtype (Date _) = "date"
  dtype _ = "string"

routes :: R.RouteMap Action
routes = R.routes
  [ R.routeNormCase top
  , R.routeNormCase static
  , R.routeNormCase simulation
  , R.routeNormCase catalog
  , R.routeNormCase catalogBulk
  ]

data Opts = Opts
  { optConfig :: FilePath
  , optCreate :: [Simulation]
  , optIngest :: Maybe Simulation
  }

instance Default Opts where
  def = Opts "config" [] Nothing

optDescr :: [Opt.OptDescr (Opts -> Opts)]
optDescr =
  [ Opt.Option "f" ["config"] (Opt.ReqArg (\c o -> o{ optConfig = c }) "FILE") "Configuration file [config]"
  , Opt.Option "s" ["create"] (Opt.ReqArg (\i o -> o{ optCreate = T.pack i : optCreate o }) "SIM") "Create storage schema for the simulation"
  , Opt.Option "i" ["ingest"] (Opt.ReqArg (\i o -> o{ optIngest = Just (T.pack i) }) "SIM") "Ingest file(s) into the simulation store"
  ]

createCatalog :: Catalog -> M String
createCatalog cat@Catalog{ catalogStore = CatalogES{} } = show <$> ES.createIndex cat
#ifdef HAVE_pgsql
createCatalog cat@Catalog{ catalogStore = CatalogPG{} } = show <$> PG.createTable cat
#endif

main :: IO ()
main = do
  prog <- getProgName
  oargs <- getArgs
  (opts, args) <- case Opt.getOpt Opt.RequireOrder optDescr oargs of
    (foldr ($) def -> o, a, [])
      | null a || isJust (optIngest o) -> return (o, a)
    (_, _, e) -> do
      mapM_ putStrLn e
      putStrLn $ Opt.usageInfo ("Usage: " ++ prog ++ " [OPTION...]\n       " ++ prog ++ " [OPTION...] -i SIM FILE[@OFFSET] ...") optDescr
      exitFailure
  conf <- C.load $ optConfig opts
  catalogs <- either throwIO return =<< YAML.decodeFileEither (fromMaybe "catalogs.yml" $ conf C.! "catalogs")
  httpmgr <- HTTP.newManager HTTP.defaultManagerSettings
  es <- ES.initServer (conf C.! "elasticsearch")
#ifdef HAVE_pgsql
  pg <- PG.initDB (conf C.! "postgresql")
#endif
  let global = Global
        { globalConfig = conf
        , globalHTTP = httpmgr
        , globalES = es
#ifdef HAVE_pgsql
        , globalPG = pg
#endif
        , globalCatalogs = catalogs
        }

  runGlobal global $ do
    -- create
    mapM_ (liftIO . putStrLn <=< createCatalog . (catalogs HM.!)) $ optCreate opts

    -- check catalogs against dbs
    ES.checkIndices
#ifdef HAVE_pgsql
    PG.checkTables
#endif

    -- ingest
    forM_ (optIngest opts) $ \sim -> do
      let cat = catalogs HM.! sim
      forM_ args $ \f -> do
        liftIO $ putStrLn f
        n <- ingest cat f
        liftIO $ print n
      ES.flushIndex cat

  when (null (optCreate opts) && isNothing (optIngest opts)) $
    runWaimwork conf $ runGlobal global
      . routeWaiError (\s h _ -> return $ response s h ()) routes

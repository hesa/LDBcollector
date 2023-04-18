{-# LANGUAGE CPP               #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell   #-}
module Ldbcollector.Server
    ( serve
    ) where

import           Ldbcollector.Model
import           Ldbcollector.Sink.GraphViz

import qualified Data.Vector                   as V

import qualified Control.Monad.State           as MTL
import qualified Data.ByteString
import qualified Data.ByteString.Lazy          as BL
import qualified Data.Map                      as Map
import qualified Data.Text.Encoding            as Enc
import qualified Data.Text.Lazy                as T
import qualified System.IO.Temp                as Temp
import qualified Text.Blaze.Html.Renderer.Text as BT
import qualified Text.Blaze.Html5              as H
import qualified Text.Blaze.Html5.Attributes   as A

import qualified Data.Graph.Inductive.Graph    as G

import           Data.FileEmbed                (embedFile)
import qualified Network.Wai.Handler.Warp      as Warp
import           Web.Scotty                    as S
import Data.Hashable (Hashable, hash)
import qualified Data.Cache as C
import qualified System.Environment as Env


class ParamMapC a where
    getLicRaw :: a -> T.Text
    getLic :: a -> LicenseName
    getIsExcludeStmts :: a -> Bool
    getEnabledSources :: a -> [SourceRef]
    isSourceEnabled :: a -> SourceRef -> Bool
newtype ParamMap = ParamMap {
        unParamMap :: Map.Map T.Text T.Text
    }
    deriving (Eq,Hashable)
excludeStmts :: T.Text
excludeStmts = "excludeStmts"
instance ParamMapC ParamMap where
    getLicRaw = Map.findWithDefault "BSD-3-Clause" "license" . unParamMap
    getLic = fromText . T.toStrict . getLicRaw
    getIsExcludeStmts = ("on" ==) . Map.findWithDefault "off" excludeStmts . unParamMap
    getEnabledSources = map (Source . T.unpack . fst) . filter (\(_,value) -> value == "on") . Map.assocs . unParamMap
    isSourceEnabled pm s = let
            enabledSources = getEnabledSources pm
        in null enabledSources ||  s `elem` enabledSources

instance Show ParamMap where
    show pm = let
            assocs = (Map.assocs . unParamMap) pm
            licRaw = getLicRaw pm
            lic = getLic pm
            enabledSources = getEnabledSources pm
        in unlines [ "params=" ++ show assocs
                   , "licRaw=" ++ show licRaw
                   , "lic=" ++ show lic
                   , "enabledSources=" ++ show enabledSources
                   ]

evaluateParams :: [S.Param] -> IO ParamMap
evaluateParams params = do
    let pm = (ParamMap . Map.fromList) params
    debugLogIO (show pm)
    return pm

stylesheet :: Data.ByteString.ByteString
stylesheet = $(embedFile "src/assets/styles.css")

scriptJs :: Data.ByteString.ByteString
scriptJs = $(embedFile "src/assets/script.js")

lnToA :: LicenseName -> H.Markup
lnToA ln = H.a H.! A.href ((H.toValue . ("/?license=" ++) . show) ln) $ H.toMarkup ln

listPageAction :: [[LicenseName]] -> ActionM ()
listPageAction clusters = do
    let page = H.html $ do
            H.head $ H.title "ldbcollector-haskell"
            H.body $ do
                H.ul $ mapM_ (\cluster ->
                    H.li (H.ul $ mapM_ (H.li . (\n -> H.a H.! A.href ((H.toValue . ("./svg/"++)) n) $ H.toMarkup n) . show) cluster)) clusters
    html (BT.renderHtml page)

printFacts :: FactId -> LicenseGraph -> IO H.Html
printFacts factId licenseGraph = do
    (facts,_) <-
        runLicenseGraphM' licenseGraph $
            MTL.gets (filter (\(_,f) -> getFactId f == factId) . Map.keys . _facts)
    return . H.html $ do
        mapM_ (\(source,fact) -> do
            H.h1 (H.toMarkup (show source))
            H.h2 $ do
                H.toMarkup (show (getFactId fact))
                " for "
                lnToA (getMainLicenseName fact)
            toMarkup fact
            H.h3 "JSON"
            H.pre (H.toMarkup (let
                                onerror _ _ = Just '_'
                            in Enc.decodeUtf8With onerror (BL.toStrict (encodePretty fact))))) facts

computeSubgraph :: LicenseGraph -> ParamMap -> IO (LicenseGraphType, LicenseNameGraphType, Digraph, [LicenseName], [LicenseName])
computeSubgraph licenseGraph paramMap = do
    let licLN = LGName (getLic paramMap)
    fmap fst . runLicenseGraphM' licenseGraph $ do
            (subgraph,lnsubgraph,digraph,sameNameNodes,otherNameNodes) <- focus (getEnabledSources paramMap) (V.singleton licLN) $
                \(needleNames, sameNames, otherNames, _statements) -> do
                    MTL.gets ((,,,,) . _gr)
                        <*> getLicenseNameGraph
                        <*> (do
                            when (getIsExcludeStmts paramMap) $
                                MTL.modify (\lg@LicenseGraph{_gr=gr} -> lg{_gr=G.labfilter (\case
                                                                                                LGName _ -> True
                                                                                                LGFact _ -> True
                                                                                                _ -> False) gr})
                            getDigraph needleNames sameNames otherNames)
                        <*> pure sameNames
                        <*> pure otherNames
            let graphNodeToLn (Just (LGName ln)) = Just ln
                graphNodeToLn _ = Nothing
            sameNames <- catMaybes <$> mapM (\n -> MTL.gets (graphNodeToLn . (`G.lab` n) . _gr)) sameNameNodes
            otherNames <- catMaybes <$> mapM (\n -> MTL.gets (graphNodeToLn . (`G.lab` n) . _gr)) otherNameNodes
            return (subgraph,lnsubgraph,digraph,sameNames,otherNames)

htmlHeader :: LicenseGraph -> ParamMap -> H.Markup
htmlHeader licenseGraph paramMap = do
    let allLicenseNames = getLicenseGraphLicenseNames licenseGraph
    let allSources = (nub . map fst . Map.keys . _facts) licenseGraph
    let licRaw = getLicRaw paramMap
    H.header $ do
        H.h1 (H.toMarkup licRaw)
        H.div H.! A.class_ "tab" $ do
            H.button H.! A.class_ "tablinks active" H.! A.onclick "openTab(event, 'content-graph')" $ "Graph"
            H.button H.! A.class_ "tablinks" H.! A.onclick "openTab(event, 'content-text')" $ "Summary"
            H.button H.! A.class_ "tablinks" H.! A.onclick "openTab(event, 'content-raw')" $ "Raw"
        H.form H.! A.action "" $ do
            H.input H.! A.name "license" H.! A.id "license" H.! A.value (H.toValue licRaw) H.! A.list "licenses"
            H.datalist H.! A.id "licenses" $
                mapM_ (\license -> H.option H.! A.value (fromString $ show license) $ pure ()) allLicenseNames
            H.h4 "Sources"
            H.ul $
                mapM_ (\(Source source) -> H.li $ do
                        H.input H.! A.type_ "checkbox" H.! A.name (fromString source) H.! A.value "on" H.! (if isSourceEnabled paramMap (Source source)
                                                                                                            then A.checked "checked"
                                                                                                            else mempty)
                        H.label H.! A.for (fromString source) $ fromString source
                    ) allSources
            H.h4 "Graph Options"
            H.ul $ do
                H.li $ do
                    H.input H.! A.type_ "checkbox" H.! A.name (H.toValue excludeStmts) H.! A.value "on" H.! (if getIsExcludeStmts paramMap
                                                                                                             then A.checked "checked"
                                                                                                             else mempty)
                    H.label H.! A.for (H.toValue excludeStmts) $ H.toMarkup excludeStmts
            H.input H.! A.type_ "submit" H.! A.value "reload" H.! A.name "reload"

dotPage :: [S.Param] -> LicenseGraph -> IO H.Html
dotPage params licenseGraph = do
    paramMap <- evaluateParams params
    (_,_,digraph,_,_) <- computeSubgraph licenseGraph paramMap
    let digraphDot = digraphToText digraph

    return . H.html $ do
            let licRaw = getLicRaw paramMap
            H.head $ do
                H.title (H.toMarkup ("ldbcollector-haskell: " <> licRaw))
                H.link H.! A.rel "stylesheet" H.! A.href "https://unpkg.com/normalize.css@8.0.1/normalize.css"
                H.link H.! A.rel "stylesheet" H.! A.href "/styles.css"
                H.script H.! A.src "https://d3js.org/d3.v5.min.js" $ pure ()
                H.script H.! A.src "https://unpkg.com/@hpcc-js/wasm@0.3.11/dist/index.min.js" $ pure ()
                H.script H.! A.src "https://unpkg.com/d3-graphviz@3.0.5/build/d3-graphviz.js" $ pure ()
            H.body $ do
                htmlHeader licenseGraph paramMap
                H.div H.! A.class_ "content" $ pure ()
                dotSvgMarkup digraph

dotSvgMarkup :: Digraph -> H.Markup
dotSvgMarkup digraph = let
        digraphDot = digraphToText digraph
    in do
        H.pre H.! A.id "graph.dot" H.! A.style "display:none;" $ 
            H.toMarkup digraphDot
        H.script $ do
            "d3.select(\".content\")"
            "    .graphviz()"
            "    .engine('fdp')"
            "    .fit(true)"
            "    .renderDot(document.getElementById('graph.dot').textContent);"

mainPage :: ParamMap -> LicenseGraph -> (LicenseGraphType, LicenseNameGraphType, Digraph, [LicenseName], [LicenseName]) -> IO H.Html
mainPage paramMap licenseGraph (subgraph,lnsubgraph,digraph,sameNames,otherNames) = do

    let facts = (mapMaybe (\case
                               LGFact f -> Just f
                               _        -> Nothing
                           . snd) . G.labNodes) subgraph
    let licRaw = getLicRaw paramMap
    return . H.html $ do
            H.head $ do
                H.title (H.toMarkup ("ldbcollector-haskell: " <> licRaw))
                H.link H.! A.rel "stylesheet" H.! A.href "https://unpkg.com/normalize.css@8.0.1/normalize.css"
                H.link H.! A.rel "stylesheet" H.! A.href "/styles.css"
                H.script H.! A.src "https://d3js.org/d3.v5.min.js" $ pure ()
                H.script H.! A.src "https://unpkg.com/@hpcc-js/wasm@0.3.11/dist/index.min.js" $ pure ()
                H.script H.! A.src "https://unpkg.com/d3-graphviz@3.0.5/build/d3-graphviz.js" $ pure ()
            H.body $ do
                htmlHeader licenseGraph paramMap
                H.div H.! A.class_ "content active" H.! A.id "content-graph" H.! A.style "display: block;" $ do
                    dotSvgMarkup digraph
                H.div H.! A.class_ "content" H.! A.id "content-text" $ do
                    H.h2 "LicenseNames"
                    H.ul $ mapM_ (H.li . fromString . show) sameNames
                    H.h3 "LicenseName Hints"
                    H.ul $ mapM_ (H.li . fromString . show) otherNames
                    H.h2 "LicenseTypes"
                    H.ul $ mapM_ (H.li . fromString . show) (nub $ concatMap getImpliedLicenseTypes facts)
                    H.h3 "License Ratings"
                    H.ul $ mapM_ (H.li . H.toMarkup) (nub $ concatMap getImpliedLicenseRatings facts)
                    H.h3 "URLs"
                    H.ul $ mapM_ (H.li . H.toMarkup) (nub $ concatMap getImpliedLicenseUrls facts)
                    -- H.h2 "LicenseNameSubgraph"
                    -- H.pre $
                    --     H.toMarkup (G.prettify lnsubgraph)
                H.div H.! A.class_ "content" H.! A.id "content-raw" $ do
                    H.ul $ mapM_ (\fact -> H.li $ do
                        let factId@(FactId ty hash) = getFactId fact
                        H.h3 $ do
                            H.a H.! A.href (H.toValue $ "./fact" </> ty </> hash) $ H.toMarkup (show factId)
                            " for "
                            lnToA (getMainLicenseName fact)
                        toMarkup fact
                        ) facts
                H.script H.! A.src "/script.js" $
                    pure ()
                H.script "main();"

getMyOptions :: IO S.Options
getMyOptions = do
    port <- maybe 3000 read <$> Env.lookupEnv "PORT"
    putStrLn ("PORT=" ++ show port) 
    return $ S.Options 1 (Warp.setPort port (Warp.setFileInfoCacheDuration 3600 (Warp.setFdCacheDuration 3600 Warp.defaultSettings)))

serve :: LicenseGraphM ()
serve = do
    licenseGraph <- MTL.get
    clusters <- getClusters

    lift $ Temp.withSystemTempDirectory "ldbcollector-haskell" $ \tmpdir -> do
        cache <- C.newCache Nothing
        let init params = do
                paramMap <- evaluateParams params
                C.lookup cache (hash paramMap) >>= \case
                    Just tuple -> return (paramMap, tuple)
                    _ -> do
                        tuple <- computeSubgraph licenseGraph paramMap
                        C.insert cache (hash paramMap) tuple
                        return (paramMap, tuple)
        putStrLn $ "tmpdir=" ++ tmpdir
        myOptions <- getMyOptions
        scottyOpts myOptions $ do
            get "/styles.css" $ raw (BL.fromStrict stylesheet)
            get "/script.js" $ raw (BL.fromStrict scriptJs)
            get "/" $ do
                params <- S.params
                page <- liftAndCatchIO $ do
                    (paramMap, tuple) <- init params
                    mainPage paramMap licenseGraph tuple
                html (BT.renderHtml page)
            get "/dot" $ do
                params <- S.params
                dot <- liftAndCatchIO $ do
                    (paramMap, (subgraph,lnsubgraph,digraph,sameNames,otherNames)) <- init params
                    return (digraphToText digraph)
                text dot
            get "/svg" $ do
                params <- S.params
                svg <- liftAndCatchIO $ do
                    (paramMap, (subgraph,lnsubgraph,digraph,sameNames,otherNames)) <- init params
                    rederDotToText "fdp" digraph
                setHeader "Content-Type" "image/svg+xml"
                text svg
            get "/fact/:facttype/:facthash" $ do
                facttype <- fromString <$> param "facttype"
                facthash <- fromString <$> param "facthash"
                page <- liftAndCatchIO $ printFacts (FactId facttype facthash) licenseGraph
                html (BT.renderHtml page)
            get "/clusters" $ listPageAction clusters

{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Ldbcollector.Source.Warpr
    ( Warpr (..)
    ) where

import qualified Data.Text.Lazy.IO       as T
import qualified Data.Vector             as V
import           Ldbcollector.Model
import qualified Swish.RDF               as TTL
import qualified Swish.RDF.Parser.Turtle as TTL
import qualified Text.Blaze.Html5        as H

data WarprLicense
    = WarprLicense LicenseName TTL.RDFGraph
    deriving (Eq, Ord, Show, Generic)
instance ToJSON WarprLicense where
    toJSON (WarprLicense id graph) = object ["_id" .= id, "_graph" .= show graph]

instance LicenseFactC WarprLicense where
    getType _ = "WarprLicense"
    getApplicableLNs (WarprLicense l _) = LN l
    getImpliedStmts (WarprLicense _ _) = []
    toMarkup (WarprLicense _ g) = H.pre (H.toMarkup (show g))

getWarprLicense :: FilePath -> IO WarprLicense
getWarprLicense ttl = do
    logFileReadIO ttl
    let fromFilename = takeBaseName (takeBaseName ttl)
    ttlText <- T.readFile ttl
    case TTL.parseTurtlefromText ttlText of
        Left err -> fail err
        Right rdf -> return $ WarprLicense (newNLN "warpr" (pack fromFilename)) rdf

newtype Warpr = Warpr FilePath

instance HasOriginalData Warpr where
    getOriginalData (Warpr dir) =
        FromUrl "https://github.com/warpr/licensedb" $
        FromFile dir NoPreservedOriginalData
instance Source Warpr where
    getSource _ = Source "Warpr"
    getFacts (Warpr dir) = do
        ttls <- glob (dir </> "*.ttl")
        V.fromList . map wrapFact <$> mapM getWarprLicense ttls

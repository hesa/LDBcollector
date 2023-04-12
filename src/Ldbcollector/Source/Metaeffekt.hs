{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Ldbcollector.Source.Metaeffekt
    ( Metaeffekt (..)
    ) where

import qualified Data.Map           as Map
import qualified Data.Vector        as V
import qualified Data.Yaml          as Y
import qualified Data.Yaml.Internal as Y
import           Ldbcollector.Model

data MetaeffektLicense
    = MetaeffektLicense
    { _canonicalName    :: LicenseName
    , _category         :: LicenseName
    , _shortName        :: Maybe LicenseName
    , _spdxIdentifier   :: Maybe LicenseName
    , _openCoDEStatus   :: Maybe String
    , _alternativeNames :: [LicenseName]
    , _otherIds         ::  [LicenseName]
    } deriving (Eq, Ord, Show, Generic)
instance FromJSON MetaeffektLicense where
  parseJSON = withObject "MetaeffektLicense" $ \v -> MetaeffektLicense
    <$> v .: "canonicalName"
    <*> v .: "category"
    <*> (fmap (setNS "metaeffekt") <$> v .:? "shortName")
    <*> (fmap (setNS "spdx") <$> v .:? "spdxIdentifier")
    <*> v .:? "openCoDEStatus"
    <*> v .:? "alternativeNames" .!= []
    <*> v .:? "otherIds" .!= []
instance ToJSON MetaeffektLicense

instance LicenseFactC MetaeffektLicense where
    getType _ = "MetaeffektLicense"
    getApplicableLNs l = let
            mainNames = maybeToList (_shortName l) ++ _canonicalName l: maybeToList (_spdxIdentifier l)
        in alternativesFromListOfLNs mainNames `ImpreciseLNs` map LN (_category l : _alternativeNames l <> _otherIds l)
    getImpliedStmts l = case _openCoDEStatus l of
        Just "approved" -> [LicenseRating "CoDEStatus" (PositiveLicenseRating "Approved" Nothing)]
        Just status -> [LicenseRating "CoDEStatus" (NeutralLicenseRating (fromString status) Nothing)]
        _ -> []

getMetaeffektLicense :: FilePath -> IO [MetaeffektLicense]
getMetaeffektLicense yaml = do
    logFileReadIO yaml
    decoded <- Y.decodeFileEither yaml :: IO (Either Y.ParseException MetaeffektLicense)
    case decoded of
        Left err -> do
            stderrLogIO ("ERROR: " ++ show err)
            return []
        Right d  -> return [d]

newtype Metaeffekt = Metaeffekt FilePath

instance Source Metaeffekt where
    getSource _ = Source "Metaeffekt"
    getFacts (Metaeffekt dir) = do
        yamls <- glob (dir </> "**/*.yaml")
        V.fromList . map wrapFact . mconcat <$> mapM getMetaeffektLicense yamls

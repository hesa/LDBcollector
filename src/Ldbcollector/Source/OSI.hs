{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
module Ldbcollector.Source.OSI
    ( OSI (..)
    , isOsiApproved
    ) where

import qualified Data.Vector                         as V
import           Ldbcollector.Model

import           Control.Monad.Except                (runExceptT)
import qualified Network.Protocol.OpenSource.License as OSI
import qualified Data.Text as T

newtype OSILicense
    = OSILicense OSI.OSILicense
    deriving (Eq, Show, Generic)
instance ToJSON OSILicense

isOsiApproved :: Maybe Bool -> LicenseStatement
isOsiApproved (Just True) = LicenseRating $ PositiveLicenseRating "OSI" "Approved" Nothing
isOsiApproved (Just False) = LicenseRating $ NegativeLicenseRating "OSI" "Rejected" Nothing
isOsiApproved Nothing = LicenseRating $ NegativeLicenseRating "OSI" "Not-Approved" Nothing

instance LicenseFactC OSILicense where
    getType _ = "OSILicense"
    getApplicableLNs (OSILicense l) =
        (LN . newNLN "osi" .  OSI.olId) l
        `AlternativeLNs`
        ((LN . newLN  .  OSI.olName) l : map (\i -> LN $ newNLN (OSI.oiScheme i) (OSI.oiIdentifier i)) (OSI.olIdentifiers l))
        `ImpreciseLNs`
        map (LN . newLN . OSI.oonName) (OSI.olOther_names l)
    getImpliedStmts (OSILicense l) = let
            urls = (map (\link -> (LicenseUrl . unpack . OSI.olUrl) link `SubStatements` [LicenseComment (OSI.olNote link)]) . OSI.olLinks) l
            keywords = map (\kw -> case kw of
                    "osi-approved" -> isOsiApproved (Just True)
                    "discouraged" -> LicenseRating $ NegativeLicenseRating "OSI-keyword" kw Nothing
                    "non-reusable" -> LicenseRating $ NegativeLicenseRating "OSI-keyword" kw Nothing
                    "retired" -> LicenseRating $ NegativeLicenseRating "OSI-keyword" kw Nothing
                    "redundant" -> LicenseRating $ NegativeLicenseRating "OSI-keyword" kw Nothing
                    "popular" -> LicenseRating $ PositiveLicenseRating "OSI-keyword" kw Nothing
                    "permissive" -> LicenseType Permissive
                    "copyleft" -> LicenseType Copyleft
                    "special-purpose" -> LicenseRating $ NeutralLicenseRating "OSI-keyword" kw Nothing
                    _ -> (stmt . T.unpack) kw
                ) (OSI.olKeywords l)
        in urls ++ keywords

data OSI = OSI
instance HasOriginalData OSI where
    getOriginalData OSI = 
        FromUrl "https://opensource.org/licenses/" $
        FromUrl "https://api.opensource.org/licenses/" $
        FromUrl "https://github.com/OpenSourceOrg/licenses" 
        NoPreservedOriginalData
instance Source OSI where
    getSource _ = Source "OSI"
    getFacts OSI = do
        response <- runExceptT OSI.allLicenses
        case response of
            Left err -> do
                stderrLogIO $ "Error: " ++ err
                pure mempty
            Right licenses -> (return . V.fromList . map (wrapFact . OSILicense)) licenses

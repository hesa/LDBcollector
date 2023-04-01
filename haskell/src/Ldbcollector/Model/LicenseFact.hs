{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE DefaultSignatures #-}
module Ldbcollector.Model.LicenseFact
  ( Origin (..)
  , FactId
  , FromFact (..)
  , LicenseFact (..)
  , wrapFact, wrapFacts, wrapFactV
  , LicenseFactTask (..)
  , LicenseFactC (..)
  ) where

import           MyPrelude hiding (ByteString)

import           Data.ByteString                  (ByteString)
import qualified Data.ByteString.Lazy.Char8        as C
import           Data.Aeson                        as A
import qualified Data.ByteString.Base16            as B16
import qualified Crypto.Hash.MD5 as MD5
import qualified Data.Map                          as Map
import qualified Data.Vector                       as V

import           Ldbcollector.Model.LicenseName
import           Ldbcollector.Model.LicenseStatement

newtype Origin = Origin String
   deriving (Eq, Show, Ord)

type FactId = String

data FromFact a
    = FromFact
    { originFacts :: [FactId]
    , unFF :: a
    }
deriving instance Show a => Show (FromFact a)
deriving instance Eq a => Eq (FromFact a)
deriving instance Ord a => Ord (FromFact a)

data LicenseFactTask where
    Noop :: LicenseFactTask
    
    AllTs :: [LicenseFactTask] -> LicenseFactTask

    AddLN :: LicenseName -> LicenseFactTask
    SameLNs :: [LicenseName] -> LicenseFactTask -> LicenseFactTask
    BetterLNs :: [LicenseName] -> LicenseFactTask -> LicenseFactTask

    AppliesToLN :: LicenseStatement -> LicenseName -> LicenseFactTask
    MAppliesToLN :: Maybe LicenseStatement -> LicenseName -> LicenseFactTask

    AppliesToStmt :: LicenseStatement -> LicenseStatement -> LicenseFactTask

data ApplicableLNs where
    LN :: LicenseName -> ApplicableLNs
    AlternativeLNs :: [ApplicableLNs] -> ApplicableLNs -> ApplicableLNs
    ImpreciseLNs :: [ApplicableLNs] -> ApplicableLNs -> ApplicableLNs
data ImpliedStmts where
    Stmts :: [LicenseStatement] -> ImpliedStmts

class (Eq a, Ord a) => LicenseFactC a where
    getType :: a -> String
    getFactId :: a -> FactId
    default getFactId :: (ToJSON a) => a -> FactId
    getFactId a = let
        md5 = (C.unpack . C.fromStrict . B16.encode .  MD5.hashlazy . A.encode) a
        in getType a ++ ":" ++ md5
    getApplicableLNs :: a -> ApplicableLNs
    getImpliedStmts :: a -> ImpliedStmts
    getTasks :: a -> [LicenseFactTask]
    getTasks a = [getTask a]
    getTask :: a -> LicenseFactTask
    getTask a = AllTs $ getTasks a

data LicenseFact where
    LicenseFact :: forall a. (Typeable a, ToJSON a, LicenseFactC a) => TypeRep -> a -> LicenseFact
instance Show LicenseFact where
wrapFact :: forall a. (Typeable a, ToJSON a, LicenseFactC a) => a -> LicenseFact
wrapFact a = LicenseFact (typeOf a) a
wrapFacts :: forall a. (Typeable a, ToJSON a, LicenseFactC a) => [a] -> [LicenseFact]
wrapFacts = map wrapFact
wrapFactV :: forall a. (Typeable a, ToJSON a, LicenseFactC a) => V.Vector a -> V.Vector LicenseFact
wrapFactV = V.map wrapFact

instance ToJSON LicenseFact where
    toJSON (LicenseFact _ v) = toJSON v
instance Eq LicenseFact where
    wv1 == wv2 = let
            (LicenseFact t1 _) = wv1
            (LicenseFact t2 _) = wv2
        in ((t1 == t2) && (toJSON wv1 == toJSON wv2))
instance Ord LicenseFact where
    wv1 <= wv2 = let
            (LicenseFact t1 _) = wv1
            (LicenseFact t2 _) = wv2
        in if t1 == t2
           then toJSON wv1 <= toJSON wv2
           else t1 <= t2
instance LicenseFactC LicenseFact where
    getFactId (LicenseFact _ a) = getFactId a
    getTask (LicenseFact _ a) = getTask a

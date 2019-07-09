{-# LANGUAGE OverloadedStrings #-}
module Configuration
  ( configuration
  ) where

import qualified Prelude as P
import           MyPrelude

import qualified Data.Text as T
import           Control.Monad.Trans.Writer.Strict (execWriter, tell)
import qualified Data.Map as M

import Lib

configuration :: Configuration
configuration = Configuration ratingRules overrides "./data"

ratingRules :: RatingRules
ratingRules = let
    addRule desc fun = tell . (:[]) $ RatingRule desc fun

    hasPossitiveJudgements l = let
        fun b j = b || (case j of
                          PositiveJudgement _ -> True
                          _ -> False)
      in M.foldl' fun False . unpackSLSR $ getImpliedJudgement l
    hasNegativeJudgements l = let
        fun b j = b || (case j of
                          NegativeJudgement _ -> True
                          _ -> False)
      in M.foldl' fun False . unpackSLSR $ getImpliedJudgement l

  in execWriter $ do

    addRule "NonComercial is a no-go" $ \l ->
      case unpackRLSR (getImpliedNonCommercial l) of
        Just True -> setRatingOfState RNoGo
        _         -> id

    addRule "should have at least one positive and no negative rating to be Go" $ \l ->
      if hasPossitiveJudgements l && not (hasNegativeJudgements l)
      then id
      else removeRatingFromState RGo

    addRule "only known NonCopyleft Licenses can be go" $ \l ->
      case getCalculatedCopyleft l of
        Just NoCopyleft -> id
        _ -> removeRatingFromState RGo

    addRule "Fedora bad Rating implies at least Stop" $ \l ->
      case M.lookup blueOakLFC (unpackSLSR $ getImpliedJudgement l) of
        Just (NegativeJudgement _) -> removeRatingFromState RGo . removeRatingFromState RAttention
        _                          -> id

    addRule "only SPDX licenses can be better than Stop" $ \l ->
      if l `containsFactOfClass` spdxLFC
      then id
      else removeRatingFromState RGo . removeRatingFromState RAttention

    addRule "possitive Rating by BlueOak helps, and if no other rating is negative it implies Go" $ \l ->
      case M.lookup blueOakLFC (unpackSLSR $ getImpliedJudgement l) of
        Just (PositiveJudgement _) -> if hasNegativeJudgements l
                                      then removeRatingFromState RNoGo . removeRatingFromState RStop
                                      else setRatingOfStateIfPossible RGo
        Just (NegativeJudgement _) -> removeRatingFromState RGo . removeRatingFromState RAttention
        _                          -> id

overrides :: [Override]
overrides =
  [ (emptyOverride "BSD-4-Clause") { oRatingState = Just (RatingState False True True True)
                                   , oJudgement = Just (NegativeJudgement "Advertisement clause (3.) is complicated and prone to conflicts") }
  , (emptyOverride "BSD-4-Clause-UC") { oRatingState = Just (RatingState False True True True)
                                      , oJudgement = Just (NegativeJudgement "Advertisement clause (3.) is complicated and prone to conflicts") }
  ] ++
  [ (emptyOverride "GPL-2.0-only") { oCompatibiliets = Just (isIncompatibleBothWays "Apache-2.0"
                                                              <> isIncompatibleBothWays "GPL-3.0-only"
                                                              <> isCompatibleToWhenDistributedUnderSelf "GPL-2.0-or-later"
                                                            ) }
  ] ++ map (\ sn -> (emptyOverride sn) { oRatingState = Just (FinalRating RNoGo)
                                       , oNonCommecrial = Just True }) [ "CC-BY-NC-1.0", "CC-BY-NC-2.0", "CC-BY-NC-2.5", "CC-BY-NC-3.0", "CC-BY-NC-4.0"
                                                                       , "CC-BY-NC-ND-1.0", "CC-BY-NC-ND-2.0", "CC-BY-NC-ND-2.5", "CC-BY-NC-ND-3.0", "CC-BY-NC-ND-4.0"
                                                                       , "CC-BY-NC-SA-1.0", "CC-BY-NC-SA-2.0", "CC-BY-NC-SA-2.5", "CC-BY-NC-SA-3.0", "CC-BY-NC-SA-4.0" ]
    -- support other IDs
    ++ map (\(sn,oIds) -> (emptyOverride sn) { oOtherLicenseIds = oIds})
           [ ("GPL-1.0-only", [ "GPL-1.0"
                              , "GPL1.0"
                              , "GPL1"
                              ])
           , ("GPL-2.0-only", [ "GPL-2.0"
                              , "GPL2.0"
                              , "GPL2"
                              , "GPL (v2)"
                              ])
           , ("GPL-3.0-only", [ "GPL-3.0"
                              , "GPL3.0"
                              , "GPL3"
                              , "GPL (v3)"
                              ])
           , ("LGPL-2.1-only", [ "LGPL-2.1"
                               , "LGPL2.1"
                               , "LGPL2.1"
                               , "LGPL (v2.1)"
                               ])
           , ("LGPL-3.0-only", [ "LGPL-3.0"
                               , "LGPL-3"
                               , "LGPL3.0"
                               , "LGPL3"
                               , "LGPL (v3.0)"
                               , "LGPL (v3)"
                               ])
           , ("AGPL-1.0-only", [ "AGPL-1.0"
                               , "Affero General Public License (v. 1)"
                               ])
           , ("AGPL-3.0-only", [ "AGPL-3.0"
                               , "AGPL3.0"
                               , "AGPL3"
                               , "AGPL (v3)"
                               , "Affero General Public License 3.0"
                               ])
           , ("GPL-1.0-or-later", [ "GPL-1.0+"
                                  , "GPL1.0+"
                                  , "GPL1+"
                                  ])
           , ("GPL-2.0-or-later", [ "GPL-2.0+"
                                  , "GPL2.0+"
                                  , "GPL2+"
                                  , "GPL (v2 or later)"
                                  ])
           , ("GPL-3.0-or-later", [ "GPL-3.0+"
                                  , "GPL3.0+"
                                  , "GPL3+"
                                  , "GPL (v3 or later)"
                                  ])
           , ("LGPL-2.1-or-later", [ "LGPL-2.1+"
                                   , "LGPL2.1+"
                                   , "LGPL2.1+"
                                   , "LGPL (v2.1 or later)"
                                   ])
           , ("LGPL-3.0-or-later", [ "LGPL-3.0+"
                                   , "LGPL-3+"
                                   , "LGPL3.0+"
                                   , "LGPL3"
                                   , "LGPL (v3.0)"
                                   , "LGPL (v3 or later)"
                                   ])
           , ("AGPL-3.0-or-later", [ "AGPL-3.0+"
                                   , "AGPL3.0+"
                                   , "AGPL3+"
                                   , "AGPL (v3 or later)"
                                   , "Affero General Public License 3.0 or later"
                                   , "GNU Affero General Public License (AGPL-3.0) (v. 3.0)"
                                   ])
           , ("BSL-1.0", [ "BSL (v1.0)"
                         ])
           , ("Zlib", [ "zlib/libpng"
                      ])
           , ("Apache-1.0", [ "Apache (v1.0)"
                            , "Apache Software License 1.0", "ASL 1.0"
                            ])
           , ("Apache-1.1", [ "Apache (v1.1)"
                            , "Apache Software License 1.1", "ASL 1.1"
                            ])
           , ("Apache-2.0", [ "Apache (v2.0)"
                            , "Apache Software License 2.0", "ASL 2.0"
                            ])
           , ("BSL-1.0", [ "BSL (v1)"
                         ])
           , ("BSD-2-Clause", [ "BSD (2 clause)"
                              , "BSD License (two clause)"
                              ])
           , ("BSD-3-Clause", [ "BSD (3 clause)"
                              , "BSD License (no advertising)"
                              ])
           , ("BSD-4-Clause", [ "BSD License (original)"
                              ])
           , ("MIT", [ "MIT license (also X11)"
                     ])
           , ("Sleepycat", [ "Berkeley Database License"
                           , "Sleepycat Software Product License"
                           ])
           , ("Artistic-1.0", [ "Artistic 1.0 (original)"
                              ])
           , ("ClArtistic", [ "Artistic (clarified)"
                            ])
           , ("Artistic-2.0", [ "Artistic 2.0"
                              ,"Artistic License (v. 2.0)"
                              ])
           ]


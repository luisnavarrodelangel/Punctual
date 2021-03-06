{-# LANGUAGE OverloadedStrings, DeriveGeneric, DeriveAnyClass #-}

module Sound.Punctual.Transition where

import GHC.Generics (Generic)
import Control.DeepSeq

import Sound.Punctual.AudioTime
import Sound.Punctual.Duration

data Transition = DefaultCrossFade | CrossFade Duration | HoldPhase deriving (Show, Eq, Generic, NFData)

-- note: returned value represents half of total xfade duration
transitionToXfade :: Double -> Transition -> AudioTime
transitionToXfade _ DefaultCrossFade = 0.25
transitionToXfade _ (CrossFade (Seconds x)) = realToFrac x
transitionToXfade cps (CrossFade (Cycles x)) = (realToFrac $ x/cps)
transitionToXfade _ HoldPhase = 0.005

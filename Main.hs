{-# LANGUAGE RecursiveDo, OverloadedStrings, JavaScriptFFI, FlexibleContexts #-}

module Main where

import System.IO
import Control.Monad.Trans
import Control.Monad.Fix
import Reflex.Dom hiding (getKeyEvent,preventDefault)
import Reflex.Dom.Contrib.KeyEvent
import Data.Time.Clock
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as T
import TextShow
import Control.Concurrent.MVar
import Control.Concurrent
import Data.Map.Strict
import Control.Monad
import GHCJS.DOM.Types (HTMLCanvasElement(..),uncheckedCastTo,JSVal,WebGLRenderingContext)
import JavaScript.Web.AnimationFrame
import GHCJS.Concurrent
import GHCJS.DOM.EventM
import Data.Bool
import Data.Maybe
import Data.Either

import Sound.Punctual.Action hiding ((>>),(<>))
import Sound.Punctual.Program
import Sound.Punctual.Parser
import Sound.Punctual.PunctualW
import Sound.Punctual.WebGL
import Sound.MusicW
import Sound.MusicW.AudioContext hiding (AudioTime)
import Sound.Punctual.MovingAverage
import Sound.Punctual.GL

headElement :: DomBuilder t m => m ()
headElement = do
  el "title" $ text "Punctual"
  let attrs = fromList [("rel", "stylesheet"), ("type", "text/css"), ("href", "style.css")]
  elAttr "link" attrs $ return ()

intro :: Text
intro
  ="-- Punctual, an audiovisual live coding language\n\
   \-- documentation @ https://github.com/dktr0/Punctual.git\n\
   \--\n\
   \-- Chromium/Chrome browser required for full results\n\
   \-- Press Shift-Enter to (re)evaluate/activate code\n\
   \\n\
   \mono (iline [sin (0.11*1...6), sin (0.08/1...6)] [sin (0.06/1...6), sin (0.04*1...6)] 0.002) * [sin 0.11,0.5 ~~ 1 $ sin 0.12, 1] * (1 - rect [0,0.875] [2,0.25]) >> hsv <> 5;\n\
   \0.98 * fb fxy * (fb fxy > 0.1) >> rgb"

   {-
   \sin 60m * -10db => left;\n\
   \sin 60.05m * -10db => right;\n\
   \fx => red;\n\
   \fy * -1 => green;\n\
   \sin (fx * 60m) * sin (fy * 60.05m) * fx * fy * 10db => blue;\n"
   -}

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  getGlobalAudioContextPlayback >>= addWorklets
  mainWidgetWithHead headElement bodyElement

bodyElement :: MonadWidget t m => m ()
bodyElement = do
  liftIO $ putStrLn "Punctual standalone"
  let attrs = fromList [("class","canvas"),("style",T.pack $ "z-index: -1;"), ("width","1920"), ("height","1080")]
  canvas <- liftM (uncheckedCastTo HTMLCanvasElement .  _element_raw . fst) $ elAttr' "canvas" attrs $ return ()
  mv <- liftIO $ forkRenderThreads canvas

  elClass "div" "editorAndStatus" $ do
    statusVisible <- do
      let textAttrs = constDyn $ fromList [("class","editorArea"){- ,("rows","999") -}]
      code <- elClass "div" "editor" $ textArea $ def & textAreaConfig_attributes .~ textAttrs & textAreaConfig_initialValue .~ intro
      let e = _textArea_element code
      e' <- wrapDomEvent (e) (onEventName Keypress) $ do
        y <- getKeyEvent
        let f ke | (keShift ke == True) && (keCtrl ke == False) && (keKeyCode ke == 13) = 1 -- shift-Enter
                 | (keShift ke == True) && (keCtrl ke == True) && (keKeyCode ke == 19) = 2 --ctrl-shift-S
                 | otherwise = 0
        if (f y /= 0) then (preventDefault >> return (f y)) else return 0
      let evaled = tagPromptlyDyn (_textArea_value code) $ ffilter (==1) e'
      shStatus <- toggle True $ ffilter (==2) e'
      performEvaluate mv evaled
      return shStatus

    hideableDiv statusVisible "status" $ do
      (status,fps) <- pollStatus mv
      elClass "div" "errors" $ dynText status
      elClass "div" "fps" $ do
        let fpsText = fmap ((<> " FPS") . showt . (round :: Double -> Int)) fps
        dynText fpsText


performEvaluate :: (PerformEvent t m, MonadIO (Performable m)) => MVar RenderState -> Event t Text -> m ()
performEvaluate mv e = performEvent_ $ fmap (liftIO . f) e
  where
    f x = do
      rs <- takeMVar mv
      putMVar mv $ rs { toParse = Just x }


hideableDiv :: (DomBuilder t m, PostBuild t m) => Dynamic t Bool -> Text -> m a -> m a
hideableDiv isVisible cssClass childWidget = do
  let attrs = fmap (bool (fromList [("hidden","true"),("class",cssClass)]) (Data.Map.Strict.singleton "class" cssClass)) isVisible
  elDynAttr "div" attrs childWidget


data RenderState = RenderState {
  status :: Text,
  toParse :: Maybe Text,
  toUpdate :: Maybe Program,
  glCtx :: GLContext,
  punctualW :: PunctualW,
  punctualWebGL :: PunctualWebGL,
  fps :: MovingAverage,
  t0 :: AudioTime,
  tPrevAnimationFrame :: UTCTime
}


forkRenderThreads :: HTMLCanvasElement -> IO (MVar RenderState)
forkRenderThreads canvas = do
  mic <- liftAudioIO createMicrophone
  gain <- liftAudioIO $ createGain (dbamp (-10))
  comp <- liftAudioIO $ createCompressor (-20) 3 4 0.050 0.1
  dest <- liftAudioIO $ createDestination
  connectNodes gain comp
  connectNodes comp dest
  ac <- getGlobalAudioContext
  t0audio <- liftAudioIO $ audioTime
  let iW = emptyPunctualW ac gain 2 -- hard coded stereo for now
  -- create PunctualWebGL for animation
  glc <- newGLContext canvas
  initialPunctualWebGL <- newPunctualWebGL (Just mic) (Just comp) glc
  -- create an MVar for the render state, fork render threads, return the MVar
  t0system <- getCurrentTime
  mv <- newMVar $ RenderState {
    status = "",
    toParse = Nothing,
    toUpdate = Nothing,
    glCtx = glc,
    punctualW = iW,
    punctualWebGL = initialPunctualWebGL,
    fps = newAverage 60,
    t0 = t0audio,
    tPrevAnimationFrame = t0system
  }
  forkIO $ mainRenderThread mv
  forkIO $ void $ animationThread mv 0
  return mv


mainRenderThread :: MVar RenderState -> IO ()
mainRenderThread mv = do
  rs <- takeMVar mv
  rs' <- parseIfNecessary rs
  rs'' <- updateIfNecessary rs'
  putMVar mv rs''
  threadDelay 200000
  mainRenderThread mv

parseIfNecessary :: RenderState -> IO RenderState
parseIfNecessary rs = if (isNothing $ toParse rs) then return rs else do
  let x = fromJust $ toParse rs
  now <- liftAudioIO $ audioTime
  p <- parse now x
  return $ rs {
    toParse = Nothing,
    toUpdate = either (const Nothing) Just p,
    status = either (T.pack) (const "") p
  }

updateIfNecessary :: RenderState -> IO RenderState
updateIfNecessary rs = if (isNothing $ toUpdate rs) then return rs else do
  let x = fromJust $ toUpdate rs
  let t = (t0 rs, 0.5) -- hard-coded for now...
  nW <- liftAudioIO $ updatePunctualW (punctualW rs) t x
  nGL <- evaluatePunctualWebGL (glCtx rs) t 1 x (punctualWebGL rs)
  return $ rs {
    toUpdate = Nothing,
    punctualW = nW,
    punctualWebGL = nGL
  }

animationThread :: MVar RenderState -> Double -> IO ()
animationThread mv _ = do
  rs <- takeMVar mv
  t1system <- getCurrentTime
  let tDiff = diffUTCTime t1system (tPrevAnimationFrame rs)
  let newFps = updateAverage (fps rs) $ 1 / realToFrac tDiff
  t1audio <- liftAudioIO $ audioTime
  let pwgl = punctualWebGL rs
  nGL <- drawPunctualWebGL (glCtx rs) t1audio 1 pwgl
  nGL' <- displayPunctualWebGL (glCtx rs) nGL
  putMVar mv $ rs {
    tPrevAnimationFrame = t1system,
    fps = newFps,
    punctualWebGL = nGL'
  }
  void $ inAnimationFrame ContinueAsync $ animationThread mv


pollStatus :: (PostBuild t m, PerformEvent t m, TriggerEvent t m, MonadIO (Performable m), MonadFix m, MonadHold t m, MonadIO m) => MVar RenderState -> m (Dynamic t Text, Dynamic t Double)
pollStatus mv = do
  now <- liftIO $ getCurrentTime
  ticks <- tickLossy (0.204::NominalDiffTime) now
  x <- performEvent $ ffor ticks $ \_ -> liftIO $ do
    rs <- readMVar mv
    return (status rs,getAverage $ fps rs)
  dStatus <- holdDyn "" $ fmap fst x
  dFPS <- holdDyn 0 $ fmap snd x
  return (dStatus,dFPS)

module Sound.Punctual.Types where

import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Number

-- Definitions (and transitions):
-- a <> sine 660 -- default crossfade
-- a <2s> sine 660 -- a 2 second crossfade, kind of like xFadein 4 in Tidal
-- a <3c> sine 880 -- a 3-cycle crossfade
-- a @2s <4s> sine 990 -- a 4 second crossfade, starting 2 seconds after eval time
-- a <10s>         -- a 10-second fade out
-- a ~ sine 1 -- when we change the definition of an LFO...
-- a ~ sine 0.5 -- ...we might want to preserve phase instead of crossfade
-- a @(4c,0.5c) ~ sine 0.25 -- 0.5 cycles after next 4-cycle boundary
-- a = sine 4 -- or, more rarely, we might want an instantaneous change
-- <2s> sine 440 -- target is anonymous
-- sine 440 -- target is anonymous and transition is default crossfade

data Duration = Seconds Double | Cycles Double deriving (Show,Eq)

duration :: GenParser Char a Duration
duration = choice $ fmap try [seconds,milliseconds,cycles]

seconds :: GenParser Char a Duration
seconds = do
  x <- fractional3 False
  char 's'
  return $ Seconds x

milliseconds :: GenParser Char a Duration
milliseconds = do
  x <- fractional3 False
  string "ms"
  return $ Seconds (x/1000.0)

cycles :: GenParser Char a Duration
cycles = do
  x <- fractional3 False
  char 'c'
  return $ Cycles x

data DefTime = After Duration | Quant Double Duration deriving (Show,Eq)

defTime :: GenParser Char a DefTime
defTime = choice $ fmap try [after,quant]

after :: GenParser Char a DefTime
after = spaces >> char '@' >> (After <$> duration)

quant :: GenParser Char a DefTime
quant = do
  spaces >> string "@("
  x <- fractional3 False
  spaces
  char ','
  spaces
  y <- duration
  spaces
  char ')'
  return $ Quant x y

data Transition = DefaultCrossFade | CrossFade Duration | HoldPhase deriving (Show, Eq)

transition :: GenParser Char a Transition
transition = choice [
  try (spaces >> string "<>" >> return DefaultCrossFade),
  try crossFade,
  try (spaces >> char '~' >> return HoldPhase),
  try (spaces >> char '=' >> return (CrossFade (Seconds 0.0)))
  ]

crossFade :: GenParser Char a Transition
crossFade = do
  spaces >> char '<' >> spaces
  x <- duration
  char '>'
  return $ CrossFade x

data Target = Explicit String | Anonymous deriving (Show,Eq)

data Definition = Definition Target DefTime Transition Graph deriving (Show, Eq)

definition :: GenParser Char a Definition
definition = choice [
  try targetDefTimeTransitionGraph,
  try targetTransitionGraph,
  try targetDefTimeGraph,
  try defTimeTransitionGraph,
  try defTimeGraph,
  try transitionGraph,
  Definition Anonymous (After (Seconds 0)) DefaultCrossFade <$> graphOrEmptyGraph
  ]

explicitTarget :: GenParser Char a Target
explicitTarget = spaces >> (Explicit <$> many1 letter)

targetDefTimeTransitionGraph :: GenParser Char a Definition
targetDefTimeTransitionGraph = do
  t <- explicitTarget
  d <- defTime
  tr <- transition
  g <- graphOrEmptyGraph
  return $ Definition t d tr g

targetTransitionGraph :: GenParser Char a Definition
targetTransitionGraph = do
  t <- explicitTarget
  tr <- transition
  g <- graphOrEmptyGraph
  return $ Definition t (After (Seconds 0)) tr g

targetDefTimeGraph :: GenParser Char a Definition
targetDefTimeGraph = do
  t <- explicitTarget
  d <- defTime
  g <- graphOrEmptyGraph
  return $ Definition t d DefaultCrossFade g

defTimeTransitionGraph :: GenParser Char a Definition
defTimeTransitionGraph = do
  d <- defTime
  tr <- transition
  g <- graphOrEmptyGraph
  return $ Definition Anonymous d tr g

defTimeGraph :: GenParser Char a Definition
defTimeGraph = do
  x <- defTime
  spaces
  y <- graphOrEmptyGraph
  return $ Definition Anonymous x DefaultCrossFade y

transitionGraph :: GenParser Char a Definition
transitionGraph = do
  x <- transition
  spaces
  y <- graphOrEmptyGraph
  return $ Definition Anonymous (After (Seconds 0)) x y

data Graph = Graph | EmptyGraph deriving (Show,Eq)

graph :: GenParser Char a Graph
graph = spaces >> string "graph" >> return Graph

graphOrEmptyGraph :: GenParser Char a Graph
graphOrEmptyGraph = choice [ try graph, return EmptyGraph ]

parsePunctual :: String -> Either ParseError Definition
parsePunctual = parse punctualParser "(unknown)"

punctualParser :: GenParser Char a Definition
punctualParser = spaces >> definition

{-# LANGUAGE OverloadedStrings #-}
module BuilderTest where

import FrameGraph
import Control.Monad (unless)
import Data.Text (Text)

runTest :: IO ()
runTest = do
  let passes = buildFrameGraph myGraph
  print passes

  unless (length passes == 2) $ error "Expected 2 passes"

  let p1 = passes !! 0
  let p2 = passes !! 1

  unless (pbName p1 == "Pass1") $ error "Pass 1 name mismatch"
  unless (length (pbWrites p1) == 1) $ error "Pass 1 should have 1 write"

  let (wVer, _) = head (pbWrites p1)
  -- wVer should be v1 (ResourceId 0, version 1)
  unless (wVer == ResourceVer (ResourceId 0) 1) $ error ("Pass 1 write version mismatch: " ++ show wVer)

  unless (pbName p2 == "Pass2") $ error "Pass 2 name mismatch"
  unless (length (pbReads p2) == 1) $ error "Pass 2 should have 1 read"

  let (rVer, _) = head (pbReads p2)
  -- rVer should be v1
  unless (rVer == ResourceVer (ResourceId 0) 1) $ error ("Pass 2 read version mismatch: " ++ show rVer)

  putStrLn "Test passed!"

myGraph :: Builder ()
myGraph = do
  res <- createResource (ResourceDesc "test" ResImage FormatR8G8B8A8_UNORM 100 100 1 1 1)
  -- res is v0

  -- Pass 1: Write to res -> v1
  v1 <- addPass "Pass1" QueueGraphics $ do
    writeResource res (ImageUsage False True False)

  -- Pass 2: Read v1
  addPass "Pass2" QueueGraphics $ do
    readResource v1 (ImageUsage True False False)

  return ()

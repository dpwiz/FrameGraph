module Main where

import qualified BuilderTest

main :: IO ()
main = do
  putStrLn "Running tests..."
  BuilderTest.runTest
  putStrLn "All tests passed."

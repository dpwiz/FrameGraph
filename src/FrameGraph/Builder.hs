{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module FrameGraph.Builder
  ( Builder
  , buildFrameGraph
  , createResource
  , importResource
  , addPass
  , readResource
  , writeResource
  , PassBuilderState(..) -- Exporting for testing/inspection
  ) where

import Control.Monad.Trans.State.Strict (State, execState, get, put)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import FrameGraph.Types

-- | Represents a pass being built.
data PassBuilderState = PassBuilderState
  { pbName :: Text
  , pbQueue :: QueueTag
  , pbReads :: [(ResourceVer, ImageUsage)]
  , pbWrites :: [(ResourceVer, ImageUsage)]
  -- We'll add the callback later.
  }
  deriving (Show, Eq)

data ResourceEntry = ResourceEntry
  { reDesc :: ResourceDesc
  , reNextVersion :: Int
  , reImportedHandle :: Maybe VkImage
  }

-- | Global state of the builder.
data BuilderState = BuilderState
  { bsNextResId :: Int
  , bsResources :: Map ResourceId ResourceEntry
  , bsPasses :: [PassBuilderState]
  , bsActivePass :: Maybe PassBuilderState
  }

newtype Builder a = Builder (State BuilderState a)
  deriving (Functor, Applicative, Monad)

initialState :: BuilderState
initialState = BuilderState
  { bsNextResId = 0
  , bsResources = Map.empty
  , bsPasses = []
  , bsActivePass = Nothing
  }

runBuilder :: Builder a -> BuilderState
runBuilder (Builder s) = execState s initialState

-- | Run the builder and return the list of passes (in definition order)
buildFrameGraph :: Builder a -> [PassBuilderState]
buildFrameGraph b = bsPasses (runBuilder b)

createResource :: ResourceDesc -> Builder ResourceVer
createResource desc = Builder $ do
  st <- get
  let rid = ResourceId (bsNextResId st)
      -- Version 0 is the initial state
      entry = ResourceEntry desc 1 Nothing
  put st { bsNextResId = bsNextResId st + 1
         , bsResources = Map.insert rid entry (bsResources st)
         }
  return (ResourceVer rid 0)

importResource :: VkImage -> ResourceDesc -> Builder ResourceVer
importResource handle desc = Builder $ do
  st <- get
  let rid = ResourceId (bsNextResId st)
      entry = ResourceEntry desc 1 (Just handle)
  put st { bsNextResId = bsNextResId st + 1
         , bsResources = Map.insert rid entry (bsResources st)
         }
  return (ResourceVer rid 0)

addPass :: Text -> QueueTag -> Builder a -> Builder a
addPass name queue (Builder inner) = Builder $ do
  -- Start pass
  st <- get
  let newPass = PassBuilderState name queue [] []
  put st { bsActivePass = Just newPass }

  -- Run inner builder
  res <- inner

  -- Finish pass
  st' <- get
  case bsActivePass st' of
    Just finishedPass -> do
      put st' { bsActivePass = Nothing
              , bsPasses = bsPasses st' ++ [finishedPass]
              }
      return res
    Nothing -> error "FrameGraph.Builder: Active pass lost!"

readResource :: ResourceVer -> ImageUsage -> Builder ()
readResource ver usage = Builder $ do
  st <- get
  case bsActivePass st of
    Just p -> do
      let p' = p { pbReads = (ver, usage) : pbReads p }
      put st { bsActivePass = Just p' }
    Nothing -> error "FrameGraph.Builder: readResource called outside of addPass"

writeResource :: ResourceVer -> ImageUsage -> Builder ResourceVer
writeResource (ResourceVer rid oldVer) usage = Builder $ do
  st <- get
  case bsActivePass st of
    Just p -> do
      -- Increment version
      let resources = bsResources st
          entry = resources Map.! rid
          newVer = reNextVersion entry
          newEntry = entry { reNextVersion = newVer + 1 }
          newVerObj = ResourceVer rid newVer

      -- Add implicit read dependency on old version
      let pReads' = (ResourceVer rid oldVer, usage) : pbReads p

      -- Add write dependency on new version
      let pWrites' = (newVerObj, usage) : pbWrites p

      let p' = p { pbReads = pReads', pbWrites = pWrites' }

      put st { bsActivePass = Just p'
             , bsResources = Map.insert rid newEntry resources
             }
      return newVerObj
    Nothing -> error "FrameGraph.Builder: writeResource called outside of addPass"

module FrameGraph.Types
  ( ResourceId (..)
  , ResourceVer (..)
  , SubresourceRange (..)
  , QueueTag (..)
  , ResourceDesc (..)
  , ImageUsage (..)
  , ResourceType (..)
  , Format (..)
  , VkImage
  , VkBuffer
  ) where

import Data.Word (Word32, Word64)
import Data.Text (Text)

-- | A handle to a virtual resource (e.g., "DepthBuffer")
newtype ResourceId = ResourceId Int
  deriving newtype (Eq, Ord, Show, Enum)

-- | An SSA version of a resource (e.g., "DepthBuffer_Ver3")
data ResourceVer = ResourceVer ResourceId Int
  deriving stock (Eq, Ord, Show)

-- | Subresource definition (crucial for Mip/Layer deps)
data SubresourceRange = SubresourceRange
  { baseMip    :: Word32
  , numMips    :: Word32 -- or 'Remaining'
  , baseLayer  :: Word32
  , numLayers  :: Word32
  }
  deriving stock (Eq, Show)

-- | Identifying Queues (Graphics, Compute, Transfer)
data QueueTag = QueueGraphics | QueueCompute | QueueTransfer
  deriving stock (Eq, Show)

-- | Resource Type (Image or Buffer)
data ResourceType = ResImage | ResBuffer
  deriving stock (Eq, Show)

-- | Simplified Format (in a real app, this would be VkFormat)
data Format = FormatR8G8B8A8_UNORM | FormatD32_SFLOAT | FormatUndefined
  deriving stock (Eq, Show)

-- | Descriptor for creating a resource
data ResourceDesc = ResourceDesc
  { name :: Text
  , resType :: ResourceType
  , format :: Format
  , width :: Word32
  , height :: Word32
  , depth :: Word32
  , mips :: Word32
  , layers :: Word32
  }
  deriving stock (Eq, Show)

-- | Usage flags for a resource in a pass
data ImageUsage = ImageUsage
  { readable :: Bool
  , writable :: Bool
  , depthStencil :: Bool
  }
  deriving stock (Eq, Show)

type VkImage = Word64
type VkBuffer = Word64

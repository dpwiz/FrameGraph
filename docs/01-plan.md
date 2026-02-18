# Haskell/Vulkan FrameGraph Implementation Plan

## Architectural Principles
1.  **Strict Separation of Concerns:**
    *   **Define (DSL):** Pure, declarative, SSA-based.
    *   **Compile:** Pure, calculates barriers, batches, and sync.
    *   **Bake:** IO (VMA), allocates memory/views.
    *   **Execute:** IO (Vulkan), records command buffers.
2.  **Modern Vulkan:** Uses `VK_KHR_dynamic_rendering` (no rigid `VkRenderPass` objects), `VK_KHR_synchronization2` (execution graphs), and VMA.
3.  **Haskell Ecosystem:** Uses `fgl` (or `algebraic-graphs`) for topology, `vulkan` package for raw bindings.

---

## Phase 1: The DSL (The "Define" Phase)
**Goal:** Create a user-facing Monad to describe the frame without touching Vulkan handles.

### 1.1 Core Types (`FrameGraph.Types`)
We need strict types to differentiate between a "future resource" and a specific version of it.
```haskell
-- | A handle to a virtual resource (e.g., "DepthBuffer")
newtype ResourceId = ResourceId Int

-- | An SSA version of a resource (e.g., "DepthBuffer_Ver3")
data ResourceVer = ResourceVer ResourceId Int

-- | Subresource definition (crucial for Mip/Layer deps)
data SubresourceRange = SubresourceRange
  { baseMip    :: Word32
  , numMips    :: Word32 -- or 'Remaining'
  , baseLayer  :: Word32
  , numLayers  :: Word32
  }

-- | Identifying Queues (Graphics, Compute, Transfer)
data QueueTag = QueueGraphics | QueueCompute | QueueTransfer
```

### 1.2 The Builder Monad (`FrameGraph.Builder`)
A `State` monad that accumulates nodes and edges.

*   **Logic:**
    *   `createResource :: ResourceDesc -> Builder ResourceVer`
    *   `importResource :: VkImage -> ResourceDesc -> Builder ResourceVer` (For Swapchain/History)
    *   `addPass :: PassName -> QueueTag -> (Builder a) -> Builder a`
*   **The Pass Context:**
    Inside `addPass`, users call `read res` or `write res`.
    *   `read :: ResourceVer -> ImageUsage -> Builder ()`
    *   `write :: ResourceVer -> ImageUsage -> Builder ResourceVer` (Returns new SSA version)
*   **Pass Execution Logic:**
    *   The `PassNode` will store a callback. Since we want draw calls *in* the graph:
    *   `Callback :: (VkCommandBuffer -> ResolvedResources -> IO ())`

---

## Phase 2: The Compiler (The "Compile" Phase)
**Goal:** Pure transformation of the Graph into an Execution Plan. This is the "Brain."

### 2.1 Dependency Analysis (`FrameGraph.Compile.Deps`)
*   **Flattening:** Convert SSA chains into a Directed Acyclic Graph (DAG) of Passes.
*   **Subresource Intersection:**
    *   If Pass A writes `Mip 0` and Pass B reads `Mip 0`, edge A->B exists.
    *   If Pass A writes `Mip 0` and Pass C reads `Mip 1`, no edge (allows parallel execution if supported).

### 2.2 Synchronization & Barriers (`FrameGraph.Compile.Sync`)
*   **Barrier Logic:**
    *   Iterate edges. If `Resource` is written in Pass A and read in Pass B:
        *   Determine `srcStage/srcAccess` (from Pass A usage).
        *   Determine `dstStage/dstAccess` (from Pass B usage).
        *   Determine `oldLayout` / `newLayout`.
    *   Store pending barriers in the *destination* node (Pass B) (Barrier-at-entry).
*   **Cross-Queue Logic (The Async Compute Part):**
    *   Algorithm: Group adjacent passes of the *same* `QueueTag` into **Batches**.
    *   If Batch A (Compute) produces a resource used by Batch B (Graphics):
        *   This cannot be a pipeline barrier.
        *   Compiler injects a **Semaphore Signal** at end of Batch A.
        *   Compiler injects a **Semaphore Wait** at start of Batch B.
        *   Compiler injects a **Queue Ownership Transfer** barrier.

### 2.3 Resource Lifetime Analysis
*   Calculate `first_use` and `last_use` indices for every resource.
*   (Future optimization: Use this for memory aliasing).

---

## Phase 3: The Baker (The "Bake" Phase)
**Goal:** Heavy IO. Allocating memory and views. Run only on startup or resize.

### 3.1 VMA Integration (`FrameGraph.Bake.Memory`)
*   Input: List of `ResourceDesc` from the Compiler.
*   Action:
    *   Iterate resources.
    *   Call `vmaCreateImage` / `vmaCreateBuffer`.
    *   Store handles in a `Map ResourceId VkImage`.

### 3.2 View Creation & Bindless Prep
*   Action:
    *   Create `VkImageView`s for every specific subresource usage required.
    *   **Bindless Integration:**
        *   If the user requests "Bindless", the Baker populates a user-provided `VkDescriptorSet` (or returns a list of writes) mapping `ResourceId` to an index in the global array.

### 3.3 History Buffer Management
*   If a resource is marked `History`:
    *   The Baker allocates *two* physical images (ping-pong).
    *   It maintains a state mapping: `Frame N` uses `Img A`, `Frame N+1` uses `Img B`.

---

## Phase 4: The Executor (The "Execute" Phase)
**Goal:** Per-frame loop. Fast. Minimal allocation.

### 4.1 The Command Loop (`FrameGraph.Exec`)
*   Input: `CompiledGraph`, `BakedResources`, `FrameContext` (Semaphores for swapchain).
*   Logic:
    1.  **Acquire Swapchain Image.**
    2.  **Iterate Batches** (Computed in Phase 2):
        *   Get the `VkQueue` for this batch (Graphics/Compute).
        *   **Begin Command Buffer.**
        *   **Iterate Passes** in Batch:
            *   Issue `vkCmdPipelineBarrier2` (derived from Compiler).
            *   Issue `vkCmdBeginRendering` (Dynamic Rendering).
            *   **Invoke User Callback** (The draw calls/dispatch).
                *   *Note:* The callback receives the *actual* `VkImageViews` corresponding to the virtual resources used in this pass.
            *   Issue `vkCmdEndRendering`.
        *   **End Command Buffer.**
        *   **Submit** to Queue (with computed Semaphore Signals/Waits).

---

## Implementation Roadmap (Step-by-Step)

### Step 1: Types & SSA Graph (Pure)
*   Implement `Builder` monad.
*   Verify SSA logic (writing to a resource generates a new version).
*   *Test:* Write a pure test case generating a graph and ensuring the adjacency list is correct.

### Step 2: The Physical Backend (Vulkan/VMA)
*   Create the `Baker`.
*   Implement `createImage`, `createImageView` wrappers using VMA.
*   Implement a "ResourceManager" that holds `Map ResourceID PhysicalResource`.

### Step 3: Single-Queue Execution
*   Implement `Compiler` logic for standard Pipeline Barriers (no semaphores yet).
*   Implement `Executor` for a single Graphics queue.
*   *Milestone:* Render a Triangle where the vertex buffer is "Uploaded" in Pass 1 and "Drawn" in Pass 2.

### Step 4: Cross-Queue & Subresources
*   Upgrade `Compiler` to group passes into `QueueBatches`.
*   Implement Semaphore injection logic.
*   Add Subresource intersection logic (so Mip 0 write doesn't block Mip 1 read).

### Step 5: History & Bindless
*   Add logic to `Baker` to handle Ping-Pong resources.
*   Expose the `VkImageView` map to the user for global binding.

---

## Detailed Data Structure Preview

To help visualize the "Compiler" output, here is the target data structure:

```haskell
data ExecutionPlan = ExecutionPlan
  { batches :: [Batch]
  , resources :: Map ResourceId ResourceInfo
  }

data Batch = Batch
  { queue      :: QueueTag
  , waitSems   :: [SemaphoreId]
  , signalSems :: [SemaphoreId]
  , passes     :: [CompiledPass]
  }

data CompiledPass = CompiledPass
  { preBarriers  :: [VkImageMemoryBarrier2]
  , executeLogic :: VkCommandBuffer -> ResolvedResources -> IO ()
  , postBarriers :: [VkImageMemoryBarrier2] -- Rare, usually handled by next pass pre-barrier
  }
```

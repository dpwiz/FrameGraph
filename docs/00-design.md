# FrameGraph Design Document

## 1. Introduction

FrameGraph is a rendering architecture that abstracts the complexity of resource management and synchronization in modern graphics APIs (like Vulkan, DX12). It organizes rendering passes into a Directed Acyclic Graph (DAG), where nodes represent passes and edges represent resource dependencies.

By declaring dependencies upfront, the FrameGraph can automatically:
- **Order passes** correctly based on data flow.
- **Insert memory barriers** and transitions at optimal points.
- **Manage transient memory** by aliasing resources that are not used concurrently.
- **Cull unused passes** that do not contribute to the final output.

This document outlines the architecture, data structures, and algorithms required to implement a FrameGraph system, specifically tailored for a Vulkan backend.

## 2. Core Concepts

### 2.1 Pass
A logical unit of work (e.g., "Shadow Pass", "GBuffer Pass", "Lighting Pass"). A pass declares:
- **Inputs**: Resources it reads from.
- **Outputs**: Resources it writes to or creates.
- **Execution**: A callback or command list recording function.

### 2.2 Resource (Virtual)
A handle representing a GPU resource (Texture, Buffer). In FrameGraph, resources are "virtual" until the graph is executed. They come in two flavors:
- **Transient**: Created and managed entirely by the FrameGraph. Their memory can be reused (aliased) after their last usage.
- **Imported**: External resources (like the Swapchain Backbuffer) injected into the graph. Their lifetime is managed outside.

### 2.3 Resource Versioning (SSA)
To maintain a DAG structure, resources are versioned. Writing to an existing resource effectively creates a *new version* of that resource. This acts like Static Single Assignment (SSA) form in compilers.
- **Pass A** writes to `Texture` -> produces `Texture_v1`.
- **Pass B** reads `Texture` (implicitly `Texture_v1`) and writes to it -> produces `Texture_v2`.
- **Pass C** reads `Texture` (implicitly `Texture_v2`).

This ensures clear dependency chains: `Pass A -> Pass B -> Pass C`.

## 3. Architecture & Data Structures

The system revolves around three main structures: `PassNode`, `ResourceNode`, and `ResourceEntry`.

### 3.1 ResourceEntry (The "Real" Resource)
Represents the underlying resource object. It holds the metadata (format, size) and, during execution, the actual API object (e.g., `VkImage`).

| Field | Description |
|---|---|
| `id` | Unique index in the registry. |
| `type` | `Transient` or `Imported`. |
| `descriptor` | Struct containing creation info (extent, format, usage). |
| `version` | The *current* latest version index (used during graph building). |
| `producer` | The `PassNode` that *first created* this resource (allocator). |
| `last` | The *last* `PassNode` that reads/writes *any version* of this resource (for deallocation). |
| `refCount` | Number of active references (for culling). |

### 3.2 ResourceNode (The Graph Node)
Represents a specific *usage* or *version* of a resource in the graph. There can be multiple `ResourceNode`s pointing to a single `ResourceEntry`.

| Field | Description |
|---|---|
| `resourceId` | Index of the `ResourceEntry` it belongs to. |
| `version` | The specific version number (e.g., 1, 2, 3). |
| `producer` | The `PassNode` that wrote/created *this specific version*. |
| `refCount` | Number of passes reading *this specific version*. |

### 3.3 PassNode (The Execution Unit)
Represents a node in the execution graph.

| Field | Description |
|---|---|
| `name` | Debug name. |
| `creates` | List of `ResourceEntry` IDs created by this pass. |
| `reads` | List of `ResourceNode` IDs (specific versions) read by this pass. |
| `writes` | List of `ResourceNode` IDs (specific versions) written by this pass. |
| `refCount` | Number of other passes consuming outputs from this pass (for culling). |
| `sideEffect` | Boolean flag. If true, pass is never culled (e.g., presenting to screen). |
| `execute` | Callback/Function to run the rendering commands. |

## 4. The Build Phase (Setup)

The user defines the graph by adding passes. For each pass, a setup phase runs immediately.

### 4.1 The Builder Interface
The setup phase provides a `Builder` object to the user.

1.  **`create(name, descriptor)`**:
    - Creates a new `ResourceEntry` in the registry.
    - Creates a `ResourceNode` (version 1).
    - Adds the `ResourceEntry` ID to the pass's `creates` list.
    - Adds the `ResourceNode` ID to the pass's `writes` list.
    - Returns a handle to the resource.

2.  **`read(handle)`**:
    - Looks up the *current* version of the resource in the registry.
    - Adds the corresponding `ResourceNode` to the pass's `reads` list.
    - Returns the handle (unchanged).

3.  **`write(handle)`**:
    - **Renaming Logic**:
        - Checks if the pass *creates* this resource. If so, it's a direct write (no rename needed yet).
        - If the pass acts on an existing resource:
            - Adds the *current* version's `ResourceNode` to the `reads` list (implicit read-modify-write dependency).
            - Increments the `ResourceEntry`'s version.
            - Creates a *new* `ResourceNode` with the new version.
            - Adds this new `ResourceNode` to the pass's `writes` list.
            - Returns a *new handle* pointing to the new version.

## 5. The Compile Phase

Once all passes are added, the graph is compiled to determine execution order and resource lifetimes.

### 5.1 Step 1: Reference Counting
Initialize `refCount` for all nodes to 0.

1.  Iterate over all **PassNodes**:
    - `pass.refCount` = number of `creates` + number of `writes`.
    - For each **Read** in the pass:
        - Increment `refCount` of the corresponding `ResourceNode`.
    - For each **Write** in the pass:
        - Set `ResourceNode.producer` = this pass.

### 5.2 Step 2: Culling (Dead Code Elimination)
Identify passes that produce unused resources.

1.  Push all `ResourceNode`s with `refCount == 0` into a stack (`unreferenced`).
2.  While `unreferenced` is not empty:
    - Pop `node`.
    - Get `producer` pass of this `node`.
    - If `producer` has `sideEffect`, continue (do not cull).
    - Decrement `producer.refCount`.
    - If `producer.refCount == 0`:
        - The pass is dead.
        - For each **Read** dependency of this pass:
            - Decrement `refCount` of the input `ResourceNode`.
            - If that input's `refCount` becomes 0, push it to `unreferenced`.

### 5.3 Step 3: Lifetime Calculation
Determine the exact lifespan of each `ResourceEntry` to manage memory/transients.

1.  Iterate over all **PassNodes** (skip culled ones):
    - For each **Created** resource:
        - `ResourceEntry.producer` = this pass.
    - For each **Read** or **Written** resource:
        - `ResourceEntry.last` = this pass.
        - *Note*: We track the *physical* resource entry here, updating its "last used by" field to the current pass index. Since we iterate in order, the last update will be correct.

## 6. The Execute Phase

Iterate through the sorted `PassNode` list.

1.  **Check Culling**: If pass is culled (`refCount == 0` and `!sideEffect`), skip.
2.  **Resource Realization**:
    - For each `ResourceEntry` in `pass.creates`:
        - **Allocate**: Call `create()` on the resource (e.g., `vkCreateImage`, `vmaCreateImage`).
        - *Optimization*: Use an aliasing allocator here based on the `ResourceEntry`'s calculated lifetime.
3.  **Barrier Injection (Pre-Read/Pre-Write)**:
    - For each **Read**:
        - Retrieve the resource.
        - Invoke `preRead(barrier_flags)` on the resource logic.
        - *Vulkan*: This is where `vkCmdPipelineBarrier` or `VkImageMemoryBarrier` is recorded to transition layouts (e.g., `COLOR_ATTACHMENT` -> `SHADER_READ_ONLY`).
    - For each **Write**:
        - Retrieve the resource.
        - Invoke `preWrite(barrier_flags)` on the resource logic.
        - *Vulkan*: Transition layout for writing (e.g., `UNDEFINED` -> `COLOR_ATTACHMENT_OPTIMAL`).
4.  **Execute Pass**:
    - Invoke the user-provided execution callback.
    - *Vulkan*: Inside the callback, the user records `vkCmdDraw`, `vkCmdDispatch`, etc.
    - Provide a `Resources` accessor to the callback so it can get actual `VkImageView` handles.
5.  **Resource Derealization**:
    - Iterate all `ResourceEntry`s.
    - If `entry.last == currentPass` and `entry.isTransient`:
        - **Deallocate**: Call `destroy()` (e.g., `vkDestroyImage`).
        - *Optimization*: Return memory to the aliasing allocator pool.

## 7. Vulkan Integration Details

### 7.1 Barriers & Layout Transitions
The `preRead` and `preWrite` hooks are abstract. In a Vulkan implementation, the `ResourceEntry` needs to track its **current state** (layout, access flags, pipeline stage).

- **preRead(requiredState)**:
    - If `currentState != requiredState`:
        - Issue `vkCmdPipelineBarrier`.
        - Update `currentState = requiredState`.
- **preWrite(requiredState)**:
    - Similar logic.
    - *Note*: For `COLOR_ATTACHMENT` output, the `initialLayout` of the RenderPass attachment description usually handles the transition from `UNDEFINED` (or previous). FrameGraph needs to coordinate with the `VkRenderPass` creation or use `vkCmdPipelineBarrier` with Dynamic Rendering.

### 7.2 Render Pass Abstraction
Modern Vulkan (1.3+) favors **Dynamic Rendering** (`VK_KHR_dynamic_rendering`). FrameGraph maps perfectly to this:
- The `PassNode` setup defines the attachments.
- `execute` begins with `vkCmdBeginRendering`.
- Barriers (`preWrite`) ensure attachments are in `COLOR_ATTACHMENT_OPTIMAL`.
- `vkCmdEndRendering` happens after the callback.

If using legacy `VkRenderPass`:
- The FrameGraph must ideally look ahead or cache `VkRenderPass` objects compatible with the attachment formats and load/store ops derived from the graph usage (creates = Clear, reads = Load).

### 7.3 Memory Aliasing
To save VRAM, transient resources that do not overlap in lifetime can share the same `VkDeviceMemory`.
- **Compile Phase** gives exact `[start_index, end_index]` lifetimes for every resource.
- Use a simple greedy allocator (e.g., Offset Allocator) to assign offsets in a large `VkDeviceMemory` block.
- Bind memory (`vkBindImageMemory`) with these offsets when `create()` is called during execution.

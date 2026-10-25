//! One shared C import for SDL3 + Vulkan.
//!
//! Zig generates a distinct opaque type for each `@cImport`, so SDL window
//! pointers from the window module and the Vulkan module must come from the
//! same import.  Keeping it here also guarantees that `SDL_vulkan.h` sees the
//! Khronos types before it declares its own fallback typedefs.

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("vulkan/vulkan.h");
    @cInclude("SDL3/SDL_vulkan.h");
});

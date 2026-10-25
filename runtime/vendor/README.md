# Vendored Khronos Vulkan headers

These headers are copied from the Khronos Vulkan-Headers registry so the runtime
builds without requiring a distribution `vulkan-headers` package.  They are
licensed under Apache-2.0; see the copyright headers in each file.

- Upstream: <https://github.com/KhronosGroup/Vulkan-Headers>
- Header version: 1.4.282 (`VK_HEADER_VERSION 282`)
- Files: `vulkan/vulkan.h`, `vulkan/vulkan_core.h`, `vulkan/vk_platform.h`, and
  the `vk_video/*.h` includes required by `vulkan_core.h`.

The Vulkan loader itself is linked as the system `vulkan` library and is not
vendored.  API use is limited to Vulkan 1.1 core plus `VK_KHR_surface` and
`VK_KHR_swapchain`.

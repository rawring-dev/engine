//! Vulkan [vulkan] window surfaces, swapchain presentation, and framebuffer capture.
//!
//! A `Surface` owns one SDL window's Vulkan instance, physical/logical device,
//! swapchain, and an offscreen colour target.  `present` renders a clear colour
//! into the offscreen target, blits it to the acquired swapchain image, and
//! presents.  `capture` renders the same target and copies it back to host
//! memory as tightly packed RGBA8, which is how frames from a window surface
//! are returned to JITed code.
//!
//! Vulkan calls are single-threaded per `Surface`; callers must serialize
//! operations on one handle.  The offscreen target uses the swapchain's own
//! format, so the blit is always format-identical; BGRA results are byte-swapped
//! during capture to keep the public ABI RGBA regardless of platform.

const std = @import("std");
const abi = @import("abi.zig");
const handles = @import("handles.zig");
const window_mod = @import("window.zig");

pub const c = @import("sdl.zig").c;

pub const Error = error{
    InstanceCreateFailed,
    NoDevice,
    NoQueueFamily,
    SurfaceCreateFailed,
    SwapchainCreateFailed,
    OutOfMemory,
    VulkanFailed,
    WindowNotVulkan,
    InvalidExtent,
};

pub const DeviceInfo = struct {
    count: u32,
    name: [256]u8 = [_]u8{0} ** 256,
    name_len: usize = 0,
    api_version: u32 = 0,
    discrete: bool = false,
};

/// Create a headless Vulkan instance and enumerate physical devices.  This
/// does not touch a window and is safe in display-less environments.
pub fn probe() Error!DeviceInfo {
    var app_info = std.mem.zeroes(c.VkApplicationInfo);
    app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "engine7";
    app_info.applicationVersion = 1;
    app_info.pEngineName = "engine7-runtime";
    app_info.engineVersion = 1;
    app_info.apiVersion = c.VK_API_VERSION_1_1;

    var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
    create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    create_info.pApplicationInfo = &app_info;

    var instance: c.VkInstance = undefined;
    if (c.vkCreateInstance(&create_info, null, &instance) != c.VK_SUCCESS) {
        abi.setError("vkCreateInstance failed (is a Vulkan ICD installed?)");
        return error.InstanceCreateFailed;
    }
    defer c.vkDestroyInstance(instance, null);

    var count: u32 = 0;
    if (c.vkEnumeratePhysicalDevices(instance, &count, null) != c.VK_SUCCESS or count == 0) {
        return DeviceInfo{ .count = 0 };
    }

    const devices = std.heap.c_allocator.alloc(c.VkPhysicalDevice, count) catch return error.OutOfMemory;
    defer std.heap.c_allocator.free(devices);
    if (c.vkEnumeratePhysicalDevices(instance, &count, devices.ptr) != c.VK_SUCCESS) {
        return error.VulkanFailed;
    }

    var info = DeviceInfo{ .count = count };
    if (count > 0) {
        var props = std.mem.zeroes(c.VkPhysicalDeviceProperties);
        c.vkGetPhysicalDeviceProperties(devices[0], &props);
        const name = std.mem.sliceTo(&props.deviceName, 0);
        const n = @min(name.len, info.name.len);
        @memcpy(info.name[0..n], name[0..n]);
        info.name_len = n;
        info.api_version = props.apiVersion;
        info.discrete = props.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU;
    }
    return info;
}

pub const Surface = struct {
    allocator: std.mem.Allocator,
    window: *window_mod.Window,

    instance: ?c.VkInstance = null,
    physical: ?c.VkPhysicalDevice = null,
    device: ?c.VkDevice = null,
    surface: ?c.VkSurfaceKHR = null,
    swapchain: ?c.VkSwapchainKHR = null,

    queue_family: u32 = 0,
    queue: ?c.VkQueue = null,

    format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    bgra: bool = false,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    swapchain_images: []c.VkImage = &.{},

    offscreen_image: ?c.VkImage = null,
    offscreen_memory: ?c.VkDeviceMemory = null,
    offscreen_view: ?c.VkImageView = null,
    framebuffer: ?c.VkFramebuffer = null,
    render_pass: ?c.VkRenderPass = null,

    // Depth target for 3D scene rendering.  The offscreen render pass always
    // carries a depth attachment so the surface's own clear/blit paths and the
    // scene renderer share one framebuffer and one render pass.
    depth_format: c.VkFormat = c.VK_FORMAT_UNDEFINED,
    depth_image: ?c.VkImage = null,
    depth_memory: ?c.VkDeviceMemory = null,
    depth_view: ?c.VkImageView = null,

    readback_buffer: ?c.VkBuffer = null,
    readback_memory: ?c.VkDeviceMemory = null,
    readback_mapped: ?[*]u8 = null,

    command_pool: ?c.VkCommandPool = null,
    command_buffer: ?c.VkCommandBuffer = null,
    fence: ?c.VkFence = null,
    acquire_semaphore: ?c.VkSemaphore = null,
    render_semaphore: ?c.VkSemaphore = null,

    pub fn init(allocator: std.mem.Allocator, window: *window_mod.Window) Error!Surface {
        if (!window.vulkan) {
            abi.setError("window was created without the Vulkan flag");
            return error.WindowNotVulkan;
        }

        var self = Surface{ .allocator = allocator, .window = window };
        errdefer self.deinit();

        try self.createInstance();
        try self.pickDevice();
        try self.createSurface();
        try self.createDevice();
        try self.createSwapchain();
        try self.createOffscreen();
        try self.createCommands();
        return self;
    }

    pub fn deinit(self: *Surface) void {
        if (self.swapchain_images.len > 0) {
            self.allocator.free(self.swapchain_images);
            self.swapchain_images = &.{};
        }
        if (self.device) |device| {
            _ = c.vkDeviceWaitIdle(device);

            if (self.fence) |v| c.vkDestroyFence(device, v, null);
            if (self.acquire_semaphore) |v| c.vkDestroySemaphore(device, v, null);
            if (self.render_semaphore) |v| c.vkDestroySemaphore(device, v, null);
            if (self.command_pool) |v| c.vkDestroyCommandPool(device, v, null);
            self.destroyOffscreen(device);
            if (self.swapchain) |v| c.vkDestroySwapchainKHR(device, v, null);
            if (self.render_pass) |v| c.vkDestroyRenderPass(device, v, null);
            c.vkDestroyDevice(device, null);
        } else if (self.render_pass) |v| {
            if (self.device) |device| c.vkDestroyRenderPass(device, v, null);
        }

        if (self.surface) |v| {
            if (self.instance) |instance| c.vkDestroySurfaceKHR(instance, v, null);
        }
        if (self.instance) |v| c.vkDestroyInstance(v, null);
        self.* = undefined;
    }

    fn createInstance(self: *Surface) Error!void {
        var app_info = std.mem.zeroes(c.VkApplicationInfo);
        app_info.sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO;
        app_info.pApplicationName = "engine7";
        app_info.applicationVersion = 1;
        app_info.pEngineName = "engine7-runtime";
        app_info.engineVersion = 1;
        app_info.apiVersion = c.VK_API_VERSION_1_1;

        var count: u32 = 0;
        const extensions = c.SDL_Vulkan_GetInstanceExtensions(&count) orelse {
            abi.setErrorFmt("SDL_Vulkan_GetInstanceExtensions: {s}", .{window_mod.sdlError()});
            return error.InstanceCreateFailed;
        };

        var create_info = std.mem.zeroes(c.VkInstanceCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
        create_info.pApplicationInfo = &app_info;
        create_info.enabledExtensionCount = count;
        create_info.ppEnabledExtensionNames = extensions;

        var instance: c.VkInstance = undefined;
        const result = c.vkCreateInstance(&create_info, null, &instance);
        if (result != c.VK_SUCCESS) {
            abi.setErrorFmt("vkCreateInstance: {d}", .{result});
            return error.InstanceCreateFailed;
        }
        self.instance = instance;
    }

    fn pickDevice(self: *Surface) Error!void {
        const instance = self.instance.?;
        var count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(instance, &count, null);
        if (count == 0) {
            abi.setError("no Vulkan physical devices");
            return error.NoDevice;
        }
        const devices = self.allocator.alloc(c.VkPhysicalDevice, count) catch return error.OutOfMemory;
        defer self.allocator.free(devices);
        if (c.vkEnumeratePhysicalDevices(instance, &count, devices.ptr) != c.VK_SUCCESS) {
            return error.VulkanFailed;
        }

        for (devices) |device| {
            var family_count: u32 = 0;
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, null);
            if (family_count == 0) continue;
            const families = self.allocator.alloc(c.VkQueueFamilyProperties, family_count) catch return error.OutOfMemory;
            defer self.allocator.free(families);
            c.vkGetPhysicalDeviceQueueFamilyProperties(device, &family_count, families.ptr);

            for (families, 0..) |family, index| {
                if (family.queueCount == 0) continue;
                if (family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT == 0) continue;
                self.physical = device;
                self.queue_family = @intCast(index);
                return;
            }
        }
        return error.NoQueueFamily;
    }

    fn createSurface(self: *Surface) Error!void {
        var surface: c.VkSurfaceKHR = undefined;
        if (!c.SDL_Vulkan_CreateSurface(self.window.handle, self.instance.?, null, &surface)) {
            abi.setErrorFmt("SDL_Vulkan_CreateSurface: {s}", .{window_mod.sdlError()});
            return error.SurfaceCreateFailed;
        }
        self.surface = surface;

        var supported: c.VkBool32 = c.VK_FALSE;
        if (c.vkGetPhysicalDeviceSurfaceSupportKHR(self.physical.?, self.queue_family, surface, &supported) != c.VK_SUCCESS or supported == c.VK_FALSE) {
            abi.setError("chosen Vulkan queue family cannot present to this surface");
            return error.SurfaceCreateFailed;
        }
    }

    fn createDevice(self: *Surface) Error!void {
        var priority: f32 = 1.0;
        var queue_info = std.mem.zeroes(c.VkDeviceQueueCreateInfo);
        queue_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queue_info.queueFamilyIndex = self.queue_family;
        queue_info.queueCount = 1;
        queue_info.pQueuePriorities = &priority;

        var features = c.VkPhysicalDeviceFeatures{};
        var extension_names = [_][*:0]const u8{"VK_KHR_swapchain"};
        var create_info = std.mem.zeroes(c.VkDeviceCreateInfo);
        create_info.sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
        create_info.queueCreateInfoCount = 1;
        create_info.pQueueCreateInfos = &queue_info;
        create_info.pEnabledFeatures = &features;
        create_info.enabledExtensionCount = extension_names.len;
        create_info.ppEnabledExtensionNames = @ptrCast(&extension_names);

        var device: c.VkDevice = undefined;
        const result = c.vkCreateDevice(self.physical.?, &create_info, null, &device);
        if (result != c.VK_SUCCESS) {
            abi.setErrorFmt("vkCreateDevice: {d}", .{result});
            return error.NoDevice;
        }
        self.device = device;

        var queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, self.queue_family, 0, &queue);
        self.queue = queue;
    }

    fn createSwapchain(self: *Surface) Error!void {
        const physical = self.physical.?;
        const surface = self.surface.?;

        var caps = std.mem.zeroes(c.VkSurfaceCapabilitiesKHR);
        if (c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &caps) != c.VK_SUCCESS) {
            return error.SwapchainCreateFailed;
        }

        var format_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &format_count, null);
        if (format_count == 0) return error.SwapchainCreateFailed;
        const formats = self.allocator.alloc(c.VkSurfaceFormatKHR, format_count) catch return error.OutOfMemory;
        defer self.allocator.free(formats);
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &format_count, formats.ptr);

        var chosen = formats[0];
        // Prefer UNORM formats so clear colours and captures are byte-for-byte
        // predictable; fall back to their sRGB counterparts when necessary.
        const preference = [_]c.VkFormat{
            c.VK_FORMAT_B8G8R8A8_UNORM,
            c.VK_FORMAT_R8G8B8A8_UNORM,
            c.VK_FORMAT_B8G8R8A8_SRGB,
            c.VK_FORMAT_R8G8B8A8_SRGB,
        };
        outer: for (preference) |wanted| {
            for (formats) |format| {
                if (format.format == wanted and format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                    chosen = format;
                    break :outer;
                }
            }
        }
        self.format = chosen.format;
        self.bgra = chosen.format == c.VK_FORMAT_B8G8R8A8_SRGB or
            chosen.format == c.VK_FORMAT_B8G8R8A8_UNORM;

        var extent = caps.currentExtent;
        if (extent.width == std.math.maxInt(u32)) {
            const pixel_size = self.window.pixelSize() catch return error.InvalidExtent;
            extent.width = std.math.clamp(@as(u32, @intCast(pixel_size.width)), caps.minImageExtent.width, caps.maxImageExtent.width);
            extent.height = std.math.clamp(@as(u32, @intCast(pixel_size.height)), caps.minImageExtent.height, caps.maxImageExtent.height);
        }
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        self.extent = extent;

        var image_count = caps.minImageCount + 1;
        if (caps.maxImageCount > 0 and image_count > caps.maxImageCount) image_count = caps.maxImageCount;

        var create_info = std.mem.zeroes(c.VkSwapchainCreateInfoKHR);
        create_info.sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
        create_info.surface = surface;
        create_info.minImageCount = image_count;
        create_info.imageFormat = chosen.format;
        create_info.imageColorSpace = chosen.colorSpace;
        create_info.imageExtent = extent;
        create_info.imageArrayLayers = 1;
        create_info.imageUsage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
        create_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        create_info.preTransform = caps.currentTransform;
        create_info.compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        create_info.presentMode = c.VK_PRESENT_MODE_FIFO_KHR;
        create_info.clipped = c.VK_TRUE;
        create_info.oldSwapchain = null;

        var swapchain: c.VkSwapchainKHR = undefined;
        const result = c.vkCreateSwapchainKHR(self.device.?, &create_info, null, &swapchain);
        if (result != c.VK_SUCCESS) {
            abi.setErrorFmt("vkCreateSwapchainKHR: {d}", .{result});
            return error.SwapchainCreateFailed;
        }
        self.swapchain = swapchain;

        var actual: u32 = 0;
        _ = c.vkGetSwapchainImagesKHR(self.device.?, swapchain, &actual, null);
        const images = self.allocator.alloc(c.VkImage, actual) catch return error.OutOfMemory;
        _ = c.vkGetSwapchainImagesKHR(self.device.?, swapchain, &actual, images.ptr);
        self.swapchain_images = images;
    }

    fn recreateSwapchain(self: *Surface) Error!void {
        const device = self.device.?;
        _ = c.vkDeviceWaitIdle(device);
        self.destroyOffscreen(device);
        if (self.render_pass) |render_pass| {
            c.vkDestroyRenderPass(device, render_pass, null);
            self.render_pass = null;
        }
        if (self.swapchain) |swapchain| {
            c.vkDestroySwapchainKHR(device, swapchain, null);
            self.swapchain = null;
        }
        if (self.swapchain_images.len > 0) {
            self.allocator.free(self.swapchain_images);
            self.swapchain_images = &.{};
        }
        try self.createSwapchain();
        try self.createOffscreen();
    }

    /// Pick a depth format supported as an optimal-tiling attachment.  D32 is
    /// preferred; the packed depth/stencil variants cover drivers without it.
    fn chooseDepthFormat(self: *Surface) c.VkFormat {
        const candidates = [_]c.VkFormat{
            c.VK_FORMAT_D32_SFLOAT,
            c.VK_FORMAT_D32_SFLOAT_S8_UINT,
            c.VK_FORMAT_D24_UNORM_S8_UINT,
            c.VK_FORMAT_D16_UNORM,
        };
        for (candidates) |format| {
            var props = std.mem.zeroes(c.VkFormatProperties);
            c.vkGetPhysicalDeviceFormatProperties(self.physical.?, format, &props);
            if (props.optimalTilingFeatures & c.VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT != 0) {
                return format;
            }
        }
        return c.VK_FORMAT_D32_SFLOAT;
    }

    fn createOffscreen(self: *Surface) Error!void {
        const device = self.device.?;
        const extent = self.extent;
        const depth_format = self.chooseDepthFormat();
        self.depth_format = depth_format;

        // The colour attachment finishes in TRANSFER_SRC_OPTIMAL so `capture`
        // can copy it and `present`/scene blits can read it.  Depth is cleared
        // every frame and does not need to persist.
        var attachments = [_]c.VkAttachmentDescription{
            std.mem.zeroes(c.VkAttachmentDescription),
            std.mem.zeroes(c.VkAttachmentDescription),
        };
        attachments[0].format = self.format;
        attachments[0].samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachments[0].loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[0].storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachments[0].stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[0].stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[0].initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[0].finalLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        attachments[1].format = depth_format;
        attachments[1].samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachments[1].loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
        attachments[1].storeOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[1].stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachments[1].stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachments[1].initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        attachments[1].finalLayout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var color_ref = std.mem.zeroes(c.VkAttachmentReference);
        color_ref.attachment = 0;
        color_ref.layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        var depth_ref = std.mem.zeroes(c.VkAttachmentReference);
        depth_ref.attachment = 1;
        depth_ref.layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;

        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &color_ref;
        subpass.pDepthStencilAttachment = &depth_ref;

        const fragment_stage: c.VkPipelineStageFlags =
            c.VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT | c.VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | fragment_stage;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | fragment_stage;
        dependency.srcAccessMask = 0;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            c.VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        render_pass_info.attachmentCount = attachments.len;
        render_pass_info.pAttachments = &attachments;
        render_pass_info.subpassCount = 1;
        render_pass_info.pSubpasses = &subpass;
        render_pass_info.dependencyCount = 1;
        render_pass_info.pDependencies = &dependency;

        var render_pass: c.VkRenderPass = undefined;
        if (c.vkCreateRenderPass(device, &render_pass_info, null, &render_pass) != c.VK_SUCCESS) {
            return error.VulkanFailed;
        }
        self.render_pass = render_pass;

        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.format = self.format;
        image_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
        image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        var image: c.VkImage = undefined;
        if (c.vkCreateImage(device, &image_info, null, &image) != c.VK_SUCCESS) return error.VulkanFailed;
        self.offscreen_image = image;

        var requirements = std.mem.zeroes(c.VkMemoryRequirements);
        c.vkGetImageMemoryRequirements(device, image, &requirements);
        const memory_type = try self.memoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, null);
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = memory_type;
        var memory: c.VkDeviceMemory = undefined;
        if (c.vkAllocateMemory(device, &alloc_info, null, &memory) != c.VK_SUCCESS) return error.VulkanFailed;
        self.offscreen_memory = memory;
        if (c.vkBindImageMemory(device, image, memory, 0) != c.VK_SUCCESS) return error.VulkanFailed;

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = self.format;
        view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        view_info.subresourceRange.baseMipLevel = 0;
        view_info.subresourceRange.levelCount = 1;
        view_info.subresourceRange.baseArrayLayer = 0;
        view_info.subresourceRange.layerCount = 1;
        var view: c.VkImageView = undefined;
        if (c.vkCreateImageView(device, &view_info, null, &view) != c.VK_SUCCESS) return error.VulkanFailed;
        self.offscreen_view = view;

        // Depth image + view.  Scene renderers may reuse this target; the
        // surface's own clear path simply clears it alongside colour.
        var depth_info = std.mem.zeroes(c.VkImageCreateInfo);
        depth_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        depth_info.imageType = c.VK_IMAGE_TYPE_2D;
        depth_info.format = depth_format;
        depth_info.extent = .{ .width = extent.width, .height = extent.height, .depth = 1 };
        depth_info.mipLevels = 1;
        depth_info.arrayLayers = 1;
        depth_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        depth_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        depth_info.usage = c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
        depth_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        depth_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;

        var depth_image: c.VkImage = undefined;
        if (c.vkCreateImage(device, &depth_info, null, &depth_image) != c.VK_SUCCESS) return error.VulkanFailed;
        self.depth_image = depth_image;

        c.vkGetImageMemoryRequirements(device, depth_image, &requirements);
        const depth_memory_type = try self.memoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT, null);
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = depth_memory_type;
        var depth_memory: c.VkDeviceMemory = undefined;
        if (c.vkAllocateMemory(device, &alloc_info, null, &depth_memory) != c.VK_SUCCESS) return error.VulkanFailed;
        self.depth_memory = depth_memory;
        if (c.vkBindImageMemory(device, depth_image, depth_memory, 0) != c.VK_SUCCESS) return error.VulkanFailed;

        var depth_view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        depth_view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        depth_view_info.image = depth_image;
        depth_view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        depth_view_info.format = depth_format;
        depth_view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_DEPTH_BIT;
        depth_view_info.subresourceRange.baseMipLevel = 0;
        depth_view_info.subresourceRange.levelCount = 1;
        depth_view_info.subresourceRange.baseArrayLayer = 0;
        depth_view_info.subresourceRange.layerCount = 1;
        var depth_view: c.VkImageView = undefined;
        if (c.vkCreateImageView(device, &depth_view_info, null, &depth_view) != c.VK_SUCCESS) return error.VulkanFailed;
        self.depth_view = depth_view;

        var fb_attachments = [_]c.VkImageView{ view, depth_view };
        var framebuffer_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
        framebuffer_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        framebuffer_info.renderPass = render_pass;
        framebuffer_info.attachmentCount = fb_attachments.len;
        framebuffer_info.pAttachments = &fb_attachments;
        framebuffer_info.width = extent.width;
        framebuffer_info.height = extent.height;
        framebuffer_info.layers = 1;
        var framebuffer: c.VkFramebuffer = undefined;
        if (c.vkCreateFramebuffer(device, &framebuffer_info, null, &framebuffer) != c.VK_SUCCESS) return error.VulkanFailed;
        self.framebuffer = framebuffer;

        const bytes = @as(c.VkDeviceSize, extent.width) * extent.height * 4;
        var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
        buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buffer_info.size = bytes;
        buffer_info.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        var buffer: c.VkBuffer = undefined;
        if (c.vkCreateBuffer(device, &buffer_info, null, &buffer) != c.VK_SUCCESS) return error.VulkanFailed;
        self.readback_buffer = buffer;

        c.vkGetBufferMemoryRequirements(device, buffer, &requirements);
        const buffer_type = try self.memoryType(
            requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            null,
        );
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = buffer_type;
        var buffer_memory: c.VkDeviceMemory = undefined;
        if (c.vkAllocateMemory(device, &alloc_info, null, &buffer_memory) != c.VK_SUCCESS) return error.VulkanFailed;
        self.readback_memory = buffer_memory;
        if (c.vkBindBufferMemory(device, buffer, buffer_memory, 0) != c.VK_SUCCESS) return error.VulkanFailed;

        var mapped: ?*anyopaque = null;
        if (c.vkMapMemory(device, buffer_memory, 0, c.VK_WHOLE_SIZE, 0, &mapped) != c.VK_SUCCESS) {
            return error.VulkanFailed;
        }
        self.readback_mapped = @ptrCast(mapped);
    }

    fn destroyOffscreen(self: *Surface, device: c.VkDevice) void {
        if (self.readback_memory) |v| {
            if (self.readback_mapped != null) c.vkUnmapMemory(device, v);
            c.vkFreeMemory(device, v, null);
        }
        if (self.readback_buffer) |v| c.vkDestroyBuffer(device, v, null);
        if (self.framebuffer) |v| c.vkDestroyFramebuffer(device, v, null);
        if (self.depth_view) |v| c.vkDestroyImageView(device, v, null);
        if (self.depth_image) |v| c.vkDestroyImage(device, v, null);
        if (self.depth_memory) |v| c.vkFreeMemory(device, v, null);
        if (self.offscreen_view) |v| c.vkDestroyImageView(device, v, null);
        if (self.offscreen_image) |v| c.vkDestroyImage(device, v, null);
        if (self.offscreen_memory) |v| c.vkFreeMemory(device, v, null);
        self.readback_mapped = null;
        self.readback_memory = null;
        self.readback_buffer = null;
        self.framebuffer = null;
        self.depth_view = null;
        self.depth_image = null;
        self.depth_memory = null;
        self.offscreen_view = null;
        self.offscreen_image = null;
        self.offscreen_memory = null;
    }

    fn createCommands(self: *Surface) Error!void {
        const device = self.device.?;

        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        pool_info.queueFamilyIndex = self.queue_family;
        var pool: c.VkCommandPool = undefined;
        if (c.vkCreateCommandPool(device, &pool_info, null, &pool) != c.VK_SUCCESS) return error.VulkanFailed;
        self.command_pool = pool;

        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = pool;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = undefined;
        if (c.vkAllocateCommandBuffers(device, &alloc_info, &cmd) != c.VK_SUCCESS) return error.VulkanFailed;
        self.command_buffer = cmd;

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        fence_info.flags = c.VK_FENCE_CREATE_SIGNALED_BIT;
        var fence: c.VkFence = undefined;
        if (c.vkCreateFence(device, &fence_info, null, &fence) != c.VK_SUCCESS) return error.VulkanFailed;
        self.fence = fence;

        var sem_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sem_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        var acquire: c.VkSemaphore = undefined;
        var render: c.VkSemaphore = undefined;
        if (c.vkCreateSemaphore(device, &sem_info, null, &acquire) != c.VK_SUCCESS) return error.VulkanFailed;
        if (c.vkCreateSemaphore(device, &sem_info, null, &render) != c.VK_SUCCESS) {
            c.vkDestroySemaphore(device, acquire, null);
            return error.VulkanFailed;
        }
        self.acquire_semaphore = acquire;
        self.render_semaphore = render;
    }

    /// Find a memory type index satisfying `bits` and `properties`.
    pub fn memoryType(self: *Surface, bits: u32, properties: c.VkMemoryPropertyFlags, preferred: ?u32) Error!u32 {
        var props = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
        c.vkGetPhysicalDeviceMemoryProperties(self.physical.?, &props);
        if (preferred) |index| {
            if (index < props.memoryTypeCount and (bits & (@as(u32, 1) << @intCast(index))) != 0 and
                (props.memoryTypes[index].propertyFlags & properties) == properties)
            {
                return index;
            }
        }
        var i: u32 = 0;
        while (i < props.memoryTypeCount) : (i += 1) {
            if ((bits & (@as(u32, 1) << @intCast(i))) != 0 and
                (props.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return i;
            }
        }
        return error.VulkanFailed;
    }

    /// Recreate the swapchain and offscreen targets (including depth) when the
    /// window's pixel size changed.  Renderers recording into the offscreen
    /// target should call this once per frame before recording; `acquireFrame`
    /// and `capture` already do it.
    pub fn ensureSize(self: *Surface) Error!void {
        const pixel_size = self.window.pixelSize() catch return error.InvalidExtent;
        const width: u32 = @intCast(pixel_size.width);
        const height: u32 = @intCast(pixel_size.height);
        if (width != self.extent.width or height != self.extent.height) {
            try self.recreateSwapchain();
        }
    }

    /// Wait for the previous frame, reset the command buffer, and begin
    /// recording.  The caller owns recording until it ends the command buffer.
    fn resetFrame(self: *Surface) Error!c.VkCommandBuffer {
        const device = self.device.?;
        const cmd = self.command_buffer.?;
        const fence = self.fence.?;

        _ = c.vkWaitForFences(device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64));
        _ = c.vkResetFences(device, 1, &fence);
        _ = c.vkResetCommandBuffer(cmd, 0);

        var begin = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (c.vkBeginCommandBuffer(cmd, &begin) != c.VK_SUCCESS) return error.VulkanFailed;
        return cmd;
    }

    /// Record the offscreen render pass begin (colour + depth clears) without
    /// ending the pass.  Drawing commands are recorded after this returns.
    fn recordClearPass(self: *Surface, cmd: c.VkCommandBuffer, clear_color: [4]f32, clear_depth: f32) void {
        var clear_values: [2]c.VkClearValue = undefined;
        clear_values[0] = std.mem.zeroes(c.VkClearValue);
        clear_values[0].color.float32 = clear_color;
        clear_values[1] = std.mem.zeroes(c.VkClearValue);
        clear_values[1].depthStencil.depth = clear_depth;
        clear_values[1].depthStencil.stencil = 0;

        var render_area = std.mem.zeroes(c.VkRect2D);
        render_area.extent = self.extent;
        var pass_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
        pass_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        pass_begin.renderPass = self.render_pass.?;
        pass_begin.framebuffer = self.framebuffer.?;
        pass_begin.renderArea = render_area;
        pass_begin.clearValueCount = clear_values.len;
        pass_begin.pClearValues = &clear_values;
        c.vkCmdBeginRenderPass(cmd, &pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    }

    fn beginFrame(self: *Surface, clear: [4]f32) Error!c.VkCommandBuffer {
        const cmd = try self.resetFrame();
        self.recordClearPass(cmd, clear, 1.0);
        c.vkCmdEndRenderPass(cmd);
        return cmd;
    }

    fn submitAndWait(self: *Surface) Error!void {
        try self.submitWait(self.command_buffer.?);
    }

    fn submitWait(self: *Surface, cmd: c.VkCommandBuffer) Error!void {
        const device = self.device.?;
        var submit = std.mem.zeroes(c.VkSubmitInfo);
        submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        if (c.vkQueueSubmit(self.queue.?, 1, &submit, self.fence.?) != c.VK_SUCCESS) {
            return error.VulkanFailed;
        }
        _ = c.vkWaitForFences(device, 1, &self.fence.?, c.VK_TRUE, std.math.maxInt(u64));
    }

    /// Record a full offscreen-to-readback copy.  The offscreen colour image is
    /// in TRANSFER_SRC_OPTIMAL after the render pass.
    fn recordCopyToReadback(self: *Surface, cmd: c.VkCommandBuffer) void {
        var copy = std.mem.zeroes(c.VkBufferImageCopy);
        copy.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        copy.imageSubresource.layerCount = 1;
        copy.imageExtent = .{ .width = self.extent.width, .height = self.extent.height, .depth = 1 };
        c.vkCmdCopyImageToBuffer(
            cmd,
            self.offscreen_image.?,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            self.readback_buffer.?,
            1,
            &copy,
        );
    }

    /// Copy the mapped readback buffer out as tightly packed RGBA8.
    fn readBack(self: *Surface) Error![]u8 {
        const bytes = @as(usize, self.extent.width) * self.extent.height * 4;
        const source = self.readback_mapped.?;
        const out = self.allocator.alloc(u8, bytes) catch return error.OutOfMemory;
        if (self.bgra) {
            var i: usize = 0;
            while (i + 3 < bytes) : (i += 4) {
                out[i] = source[i + 2];
                out[i + 1] = source[i + 1];
                out[i + 2] = source[i];
                out[i + 3] = source[i + 3];
            }
        } else {
            @memcpy(out, source[0..bytes]);
        }
        return out;
    }

    fn barrierToTransferDst(cmd: c.VkCommandBuffer, image: c.VkImage) void {
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier,
        );
    }

    fn barrierToPresent(cmd: c.VkCommandBuffer, image: c.VkImage) void {
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = 0;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &barrier,
        );
    }

    fn blitToSwapchain(self: *Surface, cmd: c.VkCommandBuffer, image: c.VkImage) void {
        barrierToTransferDst(cmd, image);

        var region = std.mem.zeroes(c.VkImageBlit);
        region.srcSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.srcSubresource.layerCount = 1;
        region.srcOffsets[1] = .{ .x = @intCast(self.extent.width), .y = @intCast(self.extent.height), .z = 1 };
        region.dstSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.dstSubresource.layerCount = 1;
        region.dstOffsets[1] = .{ .x = @intCast(self.extent.width), .y = @intCast(self.extent.height), .z = 1 };
        c.vkCmdBlitImage(
            cmd,
            self.offscreen_image.?,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
            c.VK_FILTER_NEAREST,
        );

        barrierToPresent(cmd, image);
    }

    /// Acquire the next swapchain image, recreating the swapchain once if it is
    /// out of date.  Callers must have configured the surface's offscreen
    /// targets (via `ensureSize`) before recording a frame for this image.
    pub fn acquireFrame(self: *Surface) Error!u32 {
        try self.ensureSize();
        const device = self.device.?;

        var index: u32 = 0;
        var result = c.vkAcquireNextImageKHR(
            device,
            self.swapchain.?,
            std.math.maxInt(u64),
            self.acquire_semaphore.?,
            null,
            &index,
        );
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            try self.recreateSwapchain();
            result = c.vkAcquireNextImageKHR(
                device,
                self.swapchain.?,
                std.math.maxInt(u64),
                self.acquire_semaphore.?,
                null,
                &index,
            );
        }
        if (result != c.VK_SUCCESS and result != c.VK_SUBOPTIMAL_KHR) {
            abi.setErrorFmt("vkAcquireNextImageKHR: {d}", .{result});
            return error.VulkanFailed;
        }
        return index;
    }

    /// Begin recording a scene frame into the offscreen colour/depth target
    /// without acquiring a swapchain image.  Used for headless capture.
    pub fn beginSceneCapture(self: *Surface, clear_color: [4]f32, clear_depth: f32) Error!c.VkCommandBuffer {
        try self.ensureSize();
        const cmd = try self.resetFrame();
        self.recordClearPass(cmd, clear_color, clear_depth);
        return cmd;
    }

    /// Finish a `beginSceneCapture` frame, copy the colour target back as
    /// tightly packed RGBA8, and return the host-owned pixels.
    pub fn endSceneCapture(self: *Surface) Error![]u8 {
        const cmd = self.command_buffer.?;
        c.vkCmdEndRenderPass(cmd);
        self.recordCopyToReadback(cmd);
        if (c.vkEndCommandBuffer(cmd) != c.VK_SUCCESS) return error.VulkanFailed;
        try self.submitAndWait();
        return self.readBack();
    }

    /// Begin recording a scene frame that will be presented.  The caller must
    /// acquire the swapchain image first with `acquireFrame`; after drawing it
    /// calls `endScenePresent`, which blits the offscreen colour target to the
    /// acquired image and presents it.
    pub fn beginScene(self: *Surface, clear_color: [4]f32, clear_depth: f32) Error!c.VkCommandBuffer {
        const cmd = try self.resetFrame();
        self.recordClearPass(cmd, clear_color, clear_depth);
        return cmd;
    }

    /// Close the render pass, blit the offscreen colour target to the acquired
    /// swapchain image, and present.  Handles out-of-date swapchains by
    /// dropping the frame after recreating them.
    pub fn endScenePresent(self: *Surface, index: u32) Error!void {
        const cmd = self.command_buffer.?;
        c.vkCmdEndRenderPass(cmd);
        self.blitToSwapchain(cmd, self.swapchain_images[index]);
        if (c.vkEndCommandBuffer(cmd) != c.VK_SUCCESS) return error.VulkanFailed;
        try self.submitAndPresent(cmd, index);
    }

    /// Render `clear` and present it to the window.  Handles window resizes.
    pub fn present(self: *Surface, clear: [4]f32) Error!void {
        const index = try self.acquireFrame();
        const cmd = try self.beginFrame(clear);
        self.blitToSwapchain(cmd, self.swapchain_images[index]);
        if (c.vkEndCommandBuffer(cmd) != c.VK_SUCCESS) return error.VulkanFailed;
        try self.submitAndPresent(cmd, index);
    }

    fn submitAndPresent(self: *Surface, cmd: c.VkCommandBuffer, index: u32) Error!void {
        const device = self.device.?;
        const queue = self.queue.?;

        // The first commands touching the acquired image are the transfer
        // barrier and blit, so wait at the transfer stage.
        const wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
        var submit = std.mem.zeroes(c.VkSubmitInfo);
        submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.waitSemaphoreCount = 1;
        submit.pWaitSemaphores = &self.acquire_semaphore.?;
        submit.pWaitDstStageMask = &wait_stage;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        submit.signalSemaphoreCount = 1;
        submit.pSignalSemaphores = &self.render_semaphore.?;
        if (c.vkQueueSubmit(queue, 1, &submit, self.fence.?) != c.VK_SUCCESS) {
            return error.VulkanFailed;
        }
        _ = c.vkWaitForFences(device, 1, &self.fence.?, c.VK_TRUE, std.math.maxInt(u64));

        var present_info = std.mem.zeroes(c.VkPresentInfoKHR);
        present_info.sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
        present_info.waitSemaphoreCount = 1;
        present_info.pWaitSemaphores = &self.render_semaphore.?;
        present_info.swapchainCount = 1;
        present_info.pSwapchains = &self.swapchain.?;
        present_info.pImageIndices = &index;
        const result = c.vkQueuePresentKHR(queue, &present_info);
        if (result == c.VK_ERROR_OUT_OF_DATE_KHR or result == c.VK_SUBOPTIMAL_KHR) {
            try self.recreateSwapchain();
        } else if (result != c.VK_SUCCESS) {
            abi.setErrorFmt("vkQueuePresentKHR: {d}", .{result});
            return error.VulkanFailed;
        }
    }

    /// Render the offscreen target and copy it back as RGBA8.  The caller owns
    /// the returned slice and should release it with the same allocator.
    pub fn capture(self: *Surface, clear: [4]f32) Error![]u8 {
        const cmd = try self.beginFrame(clear);
        self.recordCopyToReadback(cmd);
        if (c.vkEndCommandBuffer(cmd) != c.VK_SUCCESS) return error.VulkanFailed;
        try self.submitAndWait();
        return self.readBack();
    }

    pub fn size(self: *const Surface) struct { width: u32, height: u32 } {
        return .{ .width = self.extent.width, .height = self.extent.height };
    }

    pub fn formatName(self: *const Surface) []const u8 {
        return if (self.format == c.VK_FORMAT_B8G8R8A8_SRGB)
            "B8G8R8A8_SRGB"
        else if (self.format == c.VK_FORMAT_R8G8B8A8_SRGB)
            "R8G8B8A8_SRGB"
        else if (self.format == c.VK_FORMAT_B8G8R8A8_UNORM)
            "B8G8R8A8_UNORM"
        else if (self.format == c.VK_FORMAT_R8G8B8A8_UNORM)
            "R8G8B8A8_UNORM"
        else
            "other";
    }
};

pub const Registry = handles.Table(Surface);
pub var registry: Registry = .{};

test "Vulkan probe enumerates devices" {
    if (probe()) |info| {
        if (info.count == 0) {
            std.debug.print("skipping Vulkan probe: no physical device (headless/container)\n", .{});
            return;
        }
        try std.testing.expect(info.name_len > 0);
    } else |err| {
        std.debug.print("skipping Vulkan probe: {s} ({s})\n", .{ @errorName(err), abi.lastError() });
    }
}

test "Vulkan window surface presents and captures" {
    var window = window_mod.Window.create("engine7 vulkan", 64, 48, .{
        .hidden = true,
        .vulkan = true,
    }, null) catch |err| {
        std.debug.print("skipping Vulkan window test: {s}\n", .{@errorName(err)});
        window_mod.shutdownVideo();
        return;
    };
    defer window_mod.shutdownVideo();
    defer window.destroy();

    var surface = Surface.init(std.testing.allocator, &window) catch |err| {
        std.debug.print("skipping Vulkan surface test: {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer surface.deinit();

    try surface.present(.{ 0.25, 0.5, 0.75, 1.0 });
    const pixels = try surface.capture(.{ 0.25, 0.5, 0.75, 1.0 });
    defer std.testing.allocator.free(pixels);

    try std.testing.expectEqual(@as(usize, 64 * 48 * 4), pixels.len);
    // UNORM writes 0.25/0.5/0.75 as 64/128/191; sRGB attachments encode the
    // same linear clear values as roughly 137/188/225.
    const encoded = std.mem.endsWith(u8, surface.formatName(), "SRGB");
    const r = pixels[0];
    const g = pixels[1];
    const b = pixels[2];
    const a = pixels[3];
    if (encoded) {
        try std.testing.expect(r > 125 and r < 150);
        try std.testing.expect(g > 175 and g < 200);
        try std.testing.expect(b > 215 and b < 235);
    } else {
        try std.testing.expect(r > 55 and r < 75);
        try std.testing.expect(g > 118 and g < 138);
        try std.testing.expect(b > 181 and b < 201);
    }
    try std.testing.expectEqual(@as(u8, 255), a);
}

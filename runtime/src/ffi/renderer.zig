//! Basic Vulkan 3D scene renderer built on the `Surface` FFI.
//!
//! `Scene` owns a `Surface` (instance/device/swapchain/offscreen target), a
//! SPIR-V vertex/fragment pipeline with a depth test, a host-visible uniform
//! buffer, and a unit cube with a fixed position/normal/colour vertex format.
//! Each frame it writes the model/view/projection matrices plus point-light
//! parameters into the uniform buffer, records one indexed draw into the
//! surface's offscreen colour+depth target, and either presents the result or
//! copies it back for headless validation.
//!
//! Matrix convention: matrices are column-major (`Mat4[col][row]`), matching
//! the explicit `float4` column uniforms in `engine/shaders/*.e7`.  The
//! projection targets Vulkan's [0, 1] clip depth and flips Y so world +Y is up
//! on screen.
//!
//! Everything here is single-threaded per `Scene`, same as `Surface`.

const std = @import("std");
const abi = @import("abi.zig");
const handles = @import("handles.zig");
const vulkan = @import("vulkan.zig");
const window_mod = @import("window.zig");
const shader_assets = @import("shader_assets");

pub const c = vulkan.c;

pub const Error = vulkan.Error || error{
    InvalidShaderBytecode,
    ShaderModuleFailed,
    PipelineCreateFailed,
    DescriptorCreateFailed,
    BufferCreateFailed,
    WindowOperationFailed,
};

/// A scene frame starts from this background colour unless overridden.
pub const default_clear_color = [4]f32{ 0.02, 0.025, 0.04, 1.0 };
pub const default_clear_depth: f32 = 1.0;

/// Fixed vertex format: position, normal, colour.  Matches the
/// `[[vk::location(n)]]` inputs in `engine/shaders/cube.vert.e7`.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    color: [3]f32,
};

pub const vertex_count = 24;
pub const index_count = 36;

/// Uniform block, std140-compatible and 256 bytes.  Each matrix is four
/// explicit columns to keep HLSL/Slang constant-buffer packing unambiguous.
pub const Uniforms = extern struct {
    model: [4][4]f32,
    view: [4][4]f32,
    proj: [4][4]f32,
    camera_pos: [4]f32,
    light_pos: [4]f32,
    light_color: [4]f32,
    params: [4]f32,
};

pub const Mat4 = [4][4]f32;
pub const Vec3 = [3]f32;

pub const Camera = struct {
    eye: Vec3 = .{ 0.0, 1.8, 5.5 },
    /// Radians around world +Y; 0 looks down -Z.
    yaw: f32 = 0.0,
    /// Radians; positive looks up.
    pitch: f32 = -0.14,
};

pub const default_light_color = [4]f32{ 1.0, 0.94, 0.86, 4.0 };
pub const default_ambient = [4]f32{ 0.24, 0.26, 0.30, 1.0 };
pub const default_fov_y: f32 = std.math.degreesToRadians(60.0);
pub const default_near: f32 = 0.1;
pub const default_far: f32 = 100.0;

const Face = struct {
    normal: Vec3,
    corners: [4]Vec3,
    color: Vec3,
};

const cube_faces = [6]Face{
    // +X
    .{ .normal = .{ 1, 0, 0 }, .corners = .{ .{ 1, -1, -1 }, .{ 1, 1, -1 }, .{ 1, 1, 1 }, .{ 1, -1, 1 } }, .color = .{ 0.85, 0.28, 0.24 } },
    // -X
    .{ .normal = .{ -1, 0, 0 }, .corners = .{ .{ -1, -1, 1 }, .{ -1, 1, 1 }, .{ -1, 1, -1 }, .{ -1, -1, -1 } }, .color = .{ 0.25, 0.55, 0.86 } },
    // +Y
    .{ .normal = .{ 0, 1, 0 }, .corners = .{ .{ -1, 1, -1 }, .{ -1, 1, 1 }, .{ 1, 1, 1 }, .{ 1, 1, -1 } }, .color = .{ 0.36, 0.80, 0.36 } },
    // -Y
    .{ .normal = .{ 0, -1, 0 }, .corners = .{ .{ -1, -1, 1 }, .{ -1, -1, -1 }, .{ 1, -1, -1 }, .{ 1, -1, 1 } }, .color = .{ 0.78, 0.72, 0.32 } },
    // +Z
    .{ .normal = .{ 0, 0, 1 }, .corners = .{ .{ -1, -1, 1 }, .{ 1, -1, 1 }, .{ 1, 1, 1 }, .{ -1, 1, 1 } }, .color = .{ 0.82, 0.42, 0.78 } },
    // -Z
    .{ .normal = .{ 0, 0, -1 }, .corners = .{ .{ 1, -1, -1 }, .{ -1, -1, -1 }, .{ -1, 1, -1 }, .{ 1, 1, -1 } }, .color = .{ 0.30, 0.78, 0.78 } },
};

pub const cube_vertices: [vertex_count]Vertex = blk: {
    @setEvalBranchQuota(20_000);
    var vertices: [vertex_count]Vertex = undefined;
    for (cube_faces, 0..) |face, face_index| {
        for (face.corners, 0..) |corner, corner_index| {
            vertices[face_index * 4 + corner_index] = .{
                .position = corner,
                .normal = face.normal,
                .color = face.color,
            };
        }
    }
    break :blk vertices;
};

pub const cube_indices: [index_count]u16 = blk: {
    var indices: [index_count]u16 = undefined;
    for (0..6) |face_index| {
        const base: u16 = @intCast(face_index * 4);
        const at = face_index * 6;
        indices[at + 0] = base + 0;
        indices[at + 1] = base + 1;
        indices[at + 2] = base + 2;
        indices[at + 3] = base + 0;
        indices[at + 4] = base + 2;
        indices[at + 5] = base + 3;
    }
    break :blk indices;
};

// ------------------------------------------------------------- vector math --

fn vAdd(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn vSub(a: Vec3, b: Vec3) Vec3 {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn vScale(a: Vec3, s: f32) Vec3 {
    return .{ a[0] * s, a[1] * s, a[2] * s };
}

fn vDot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn vCross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn vNormalize(a: Vec3) Vec3 {
    const length = @sqrt(vDot(a, a));
    if (length <= 1e-6) return .{ 0, 0, 0 };
    return vScale(a, 1.0 / length);
}

pub fn matIdentity() Mat4 {
    return Mat4{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
}

/// Column-major 4x4 multiply: `mul(a, b)` is the matrix that applies `b` first.
pub fn matMul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var sum: f32 = 0;
            for (0..4) |k| sum += a[k][row] * b[col][k];
            out[col][row] = sum;
        }
    }
    return out;
}

pub fn matRotationX(angle: f32) Mat4 {
    const cos = @cos(angle);
    const sin = @sin(angle);
    var m = matIdentity();
    m[1][1] = cos;
    m[1][2] = sin;
    m[2][1] = -sin;
    m[2][2] = cos;
    return m;
}

pub fn matRotationY(angle: f32) Mat4 {
    const cos = @cos(angle);
    const sin = @sin(angle);
    var m = matIdentity();
    m[0][0] = cos;
    m[0][2] = -sin;
    m[2][0] = sin;
    m[2][2] = cos;
    return m;
}

pub const CameraBasis = struct {
    forward: Vec3,
    right: Vec3,
    up: Vec3,
};

/// FPS-style basis: yaw 0 looks down -Z, positive yaw turns towards +X, and
/// positive pitch looks up.
pub fn cameraBasis(yaw: f32, pitch: f32) CameraBasis {
    const cos_pitch = @cos(pitch);
    const forward = Vec3{
        @sin(yaw) * cos_pitch,
        @sin(pitch),
        -@cos(yaw) * cos_pitch,
    };
    const right = vNormalize(vCross(forward, .{ 0.0, 1.0, 0.0 }));
    const up = vCross(right, forward);
    return .{ .forward = forward, .right = right, .up = up };
}

/// Right-handed look-at view matrix (column-vector convention).  The camera
/// looks down world -Z at yaw 0, with +X to the right and +Y up; this is the
/// single source of truth for view handedness and is shared by the yaw/pitch
/// path and the orbit path.
pub fn matLookAt(eye: Vec3, target: Vec3, up_hint: Vec3) Mat4 {
    const forward = vNormalize(.{ target[0] - eye[0], target[1] - eye[1], target[2] - eye[2] });
    const right = vNormalize(vCross(forward, up_hint));
    const up = vCross(right, forward);
    const back = vScale(forward, -1.0);
    var m = matIdentity();
    m[0] = .{ right[0], right[1], right[2], 0.0 };
    m[1] = .{ up[0], up[1], up[2], 0.0 };
    m[2] = .{ back[0], back[1], back[2], 0.0 };
    m[3] = .{ -vDot(right, eye), -vDot(up, eye), -vDot(back, eye), 1.0 };
    return m;
}

/// World-to-view matrix for an FPS camera (column-vector convention).
pub fn matView(eye: Vec3, yaw: f32, pitch: f32) Mat4 {
    const basis = cameraBasis(yaw, pitch);
    return matLookAt(eye, .{ eye[0] + basis.forward[0], eye[1] + basis.forward[1], eye[2] + basis.forward[2] }, .{ 0.0, 1.0, 0.0 });
}

/// Vulkan projection: maps view-space -near to clip z=0 and -far to z=1 and
/// flips Y for the top-left screen origin.
pub fn matPerspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fov_y * 0.5);
    var m = Mat4{
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
        .{ 0, 0, 0, 0 },
    };
    m[0][0] = f / aspect;
    m[1][1] = -f;
    m[2][2] = far / (near - far);
    m[2][3] = -1.0;
    m[3][2] = near * far / (near - far);
    return m;
}

// ------------------------------------------------------------------- scene --

const BufferAllocation = struct {
    buffer: ?c.VkBuffer = null,
    memory: ?c.VkDeviceMemory = null,
    mapped: ?[*]u8 = null,
};

pub const Scene = struct {
    allocator: std.mem.Allocator,
    surface: vulkan.Surface,

    vert_module: ?c.VkShaderModule = null,
    frag_module: ?c.VkShaderModule = null,
    descriptor_set_layout: ?c.VkDescriptorSetLayout = null,
    descriptor_pool: ?c.VkDescriptorPool = null,
    descriptor_set: ?c.VkDescriptorSet = null,
    pipeline_layout: ?c.VkPipelineLayout = null,
    pipeline: ?c.VkPipeline = null,
    /// Render pass the current pipeline was built against; `Surface` recreates
    /// its render pass on window resize, which requires rebuilding the pipeline.
    pipeline_render_pass: ?c.VkRenderPass = null,

    vertex: BufferAllocation = .{},
    index: BufferAllocation = .{},
    uniform: BufferAllocation = .{},

    camera: Camera = .{},
    /// Model spin angle supplied by the last draw, retained for capture.
    spin: f32 = 0.0,
    light_position: Vec3 = .{ 2.5, 3.0, 2.0 },
    light_color: [4]f32 = default_light_color,
    ambient: [4]f32 = default_ambient,
    clear_color: [4]f32 = default_clear_color,

    /// Create a scene for a Vulkan-flagged window.  `vert_spv`/`frag_spv` are
    /// complete SPIR-V modules (see `engine/shaders/` and `runtime/shaders/`).
    pub fn init(
        allocator: std.mem.Allocator,
        window: *window_mod.Window,
        vert_spv: []const u8,
        frag_spv: []const u8,
    ) Error!Scene {
        var self = Scene{
            .allocator = allocator,
            .surface = undefined,
        };
        self.surface = try vulkan.Surface.init(allocator, window);
        errdefer self.surface.deinit();
        errdefer self.deinit();

        const device = self.surface.device.?;
        self.vert_module = try self.createShaderModule(device, vert_spv);
        self.frag_module = try self.createShaderModule(device, frag_spv);

        try self.createBuffers(device);
        try self.createDescriptors(device);
        try self.createPipeline(device);
        return self;
    }

    pub fn deinit(self: *Scene) void {
        if (self.surface.device) |device| {
            _ = c.vkDeviceWaitIdle(device);
            if (self.pipeline) |v| c.vkDestroyPipeline(device, v, null);
            if (self.pipeline_layout) |v| c.vkDestroyPipelineLayout(device, v, null);
            if (self.descriptor_pool) |v| c.vkDestroyDescriptorPool(device, v, null);
            if (self.descriptor_set_layout) |v| c.vkDestroyDescriptorSetLayout(device, v, null);
            if (self.vert_module) |v| c.vkDestroyShaderModule(device, v, null);
            if (self.frag_module) |v| c.vkDestroyShaderModule(device, v, null);
            destroyBuffer(device, &self.vertex);
            destroyBuffer(device, &self.index);
            destroyBuffer(device, &self.uniform);
        }
        self.pipeline = null;
        self.pipeline_layout = null;
        self.descriptor_pool = null;
        self.descriptor_set = null;
        self.descriptor_set_layout = null;
        self.vert_module = null;
        self.frag_module = null;
        self.surface.deinit();
    }

    /// True when `bytes` looks like a SPIR-V module (little-endian magic).
    pub fn isSpirv(bytes: []const u8) bool {
        if (bytes.len < 20 or bytes.len % 4 != 0) return false;
        const magic = std.mem.readInt(u32, bytes[0..4], .little);
        return magic == 0x07230203;
    }

    fn createShaderModule(self: *Scene, device: c.VkDevice, bytes: []const u8) Error!c.VkShaderModule {
        if (!isSpirv(bytes)) return error.InvalidShaderBytecode;
        const copy = self.allocator.alignedAlloc(u8, .@"4", bytes.len) catch return error.OutOfMemory;
        defer self.allocator.free(copy);
        @memcpy(copy, bytes);

        var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
        info.codeSize = copy.len;
        info.pCode = @ptrCast(copy.ptr);
        var module: c.VkShaderModule = null;
        if (c.vkCreateShaderModule(device, &info, null, &module) != c.VK_SUCCESS) {
            abi.setError("vkCreateShaderModule failed");
            return error.ShaderModuleFailed;
        }
        return module;
    }

    fn createHostBuffer(self: *Scene, device: c.VkDevice, byte_size: usize, usage: c.VkBufferUsageFlags) Error!BufferAllocation {
        var allocation = BufferAllocation{};
        errdefer destroyBuffer(device, &allocation);

        var buffer_info = std.mem.zeroes(c.VkBufferCreateInfo);
        buffer_info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        buffer_info.size = byte_size;
        buffer_info.usage = usage;
        buffer_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        var buffer: c.VkBuffer = null;
        if (c.vkCreateBuffer(device, &buffer_info, null, &buffer) != c.VK_SUCCESS) {
            return error.BufferCreateFailed;
        }
        allocation.buffer = buffer;

        var requirements = std.mem.zeroes(c.VkMemoryRequirements);
        c.vkGetBufferMemoryRequirements(device, buffer, &requirements);
        const memory_type = self.surface.memoryType(
            requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            null,
        ) catch return error.VulkanFailed;
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = memory_type;
        var memory: c.VkDeviceMemory = null;
        if (c.vkAllocateMemory(device, &alloc_info, null, &memory) != c.VK_SUCCESS) {
            return error.BufferCreateFailed;
        }
        allocation.memory = memory;
        if (c.vkBindBufferMemory(device, buffer, memory, 0) != c.VK_SUCCESS) {
            return error.BufferCreateFailed;
        }

        var mapped: ?*anyopaque = null;
        if (c.vkMapMemory(device, memory, 0, c.VK_WHOLE_SIZE, 0, &mapped) != c.VK_SUCCESS) {
            return error.BufferCreateFailed;
        }
        allocation.mapped = @ptrCast(mapped);
        return allocation;
    }

    fn destroyBuffer(device: c.VkDevice, allocation: *BufferAllocation) void {
        if (allocation.memory) |memory| {
            if (allocation.mapped != null) c.vkUnmapMemory(device, memory);
            c.vkFreeMemory(device, memory, null);
        }
        if (allocation.buffer) |buffer| c.vkDestroyBuffer(device, buffer, null);
        allocation.* = .{};
    }

    fn createBuffers(self: *Scene, device: c.VkDevice) Error!void {
        self.vertex = try self.createHostBuffer(
            device,
            @sizeOf(Vertex) * vertex_count,
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        self.index = try self.createHostBuffer(
            device,
            @sizeOf(u16) * index_count,
            c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        self.uniform = try self.createHostBuffer(
            device,
            @sizeOf(Uniforms),
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );

        const vertex_target: *[vertex_count]Vertex = @ptrCast(@alignCast(self.vertex.mapped.?));
        vertex_target.* = cube_vertices;
        const index_target: *[index_count]u16 = @ptrCast(@alignCast(self.index.mapped.?));
        index_target.* = cube_indices;
    }

    fn uniformPtr(self: *Scene) *Uniforms {
        return @ptrCast(@alignCast(self.uniform.mapped.?));
    }

    fn createDescriptors(self: *Scene, device: c.VkDevice) Error!void {
        var binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
        binding.binding = 0;
        binding.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        binding.descriptorCount = 1;
        binding.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = 1;
        layout_info.pBindings = &binding;
        var set_layout: c.VkDescriptorSetLayout = null;
        if (c.vkCreateDescriptorSetLayout(device, &layout_info, null, &set_layout) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.descriptor_set_layout = set_layout;

        var pool_size = std.mem.zeroes(c.VkDescriptorPoolSize);
        pool_size.type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        pool_size.descriptorCount = 1;
        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = 1;
        pool_info.poolSizeCount = 1;
        pool_info.pPoolSizes = &pool_size;
        var pool: c.VkDescriptorPool = null;
        if (c.vkCreateDescriptorPool(device, &pool_info, null, &pool) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.descriptor_pool = pool;

        var allocate_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocate_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate_info.descriptorPool = pool;
        allocate_info.descriptorSetCount = 1;
        allocate_info.pSetLayouts = &set_layout;
        var set: c.VkDescriptorSet = null;
        if (c.vkAllocateDescriptorSets(device, &allocate_info, &set) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.descriptor_set = set;

        var buffer_info = std.mem.zeroes(c.VkDescriptorBufferInfo);
        buffer_info.buffer = self.uniform.buffer.?;
        buffer_info.offset = 0;
        buffer_info.range = @sizeOf(Uniforms);
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        write.pBufferInfo = &buffer_info;
        c.vkUpdateDescriptorSets(device, 1, &write, 0, null);

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &set_layout;
        var pipeline_layout: c.VkPipelineLayout = null;
        if (c.vkCreatePipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.pipeline_layout = pipeline_layout;
    }

    fn createPipeline(self: *Scene, device: c.VkDevice) Error!void {
        if (self.pipeline) |pipeline| {
            c.vkDestroyPipeline(device, pipeline, null);
            self.pipeline = null;
        }

        var stages = [_]c.VkPipelineShaderStageCreateInfo{
            std.mem.zeroes(c.VkPipelineShaderStageCreateInfo),
            std.mem.zeroes(c.VkPipelineShaderStageCreateInfo),
        };
        stages[0].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[0].stage = c.VK_SHADER_STAGE_VERTEX_BIT;
        stages[0].module = self.vert_module.?;
        stages[0].pName = "main";
        stages[1].sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stages[1].stage = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        stages[1].module = self.frag_module.?;
        stages[1].pName = "main";

        var binding = std.mem.zeroes(c.VkVertexInputBindingDescription);
        binding.binding = 0;
        binding.stride = @intCast(@sizeOf(Vertex));
        binding.inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX;

        var attributes = [_]c.VkVertexInputAttributeDescription{
            std.mem.zeroes(c.VkVertexInputAttributeDescription),
            std.mem.zeroes(c.VkVertexInputAttributeDescription),
            std.mem.zeroes(c.VkVertexInputAttributeDescription),
        };
        attributes[0].location = 0;
        attributes[0].binding = 0;
        attributes[0].format = c.VK_FORMAT_R32G32B32_SFLOAT;
        attributes[0].offset = @intCast(@offsetOf(Vertex, "position"));
        attributes[1].location = 1;
        attributes[1].binding = 0;
        attributes[1].format = c.VK_FORMAT_R32G32B32_SFLOAT;
        attributes[1].offset = @intCast(@offsetOf(Vertex, "normal"));
        attributes[2].location = 2;
        attributes[2].binding = 0;
        attributes[2].format = c.VK_FORMAT_R32G32B32_SFLOAT;
        attributes[2].offset = @intCast(@offsetOf(Vertex, "color"));

        var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input.vertexBindingDescriptionCount = 1;
        vertex_input.pVertexBindingDescriptions = &binding;
        vertex_input.vertexAttributeDescriptionCount = @intCast(attributes.len);
        vertex_input.pVertexAttributeDescriptions = &attributes;

        var input_assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        input_assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        input_assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        input_assembly.primitiveRestartEnable = c.VK_FALSE;

        // Viewport and scissor are dynamic; counts are all the rasterizer needs.
        var viewport_state = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport_state.viewportCount = 1;
        viewport_state.scissorCount = 1;

        var raster = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        raster.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.depthClampEnable = c.VK_FALSE;
        raster.rasterizerDiscardEnable = c.VK_FALSE;
        raster.polygonMode = c.VK_POLYGON_MODE_FILL;
        raster.cullMode = c.VK_CULL_MODE_NONE;
        raster.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.depthBiasEnable = c.VK_FALSE;
        raster.lineWidth = 1.0;

        var multisample = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisample.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        multisample.sampleShadingEnable = c.VK_FALSE;

        var depth_stencil = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        depth_stencil.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        depth_stencil.depthTestEnable = c.VK_TRUE;
        depth_stencil.depthWriteEnable = c.VK_TRUE;
        depth_stencil.depthCompareOp = c.VK_COMPARE_OP_LESS;
        depth_stencil.depthBoundsTestEnable = c.VK_FALSE;
        depth_stencil.stencilTestEnable = c.VK_FALSE;

        var blend_attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        blend_attachment.blendEnable = c.VK_FALSE;
        blend_attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT |
            c.VK_COLOR_COMPONENT_G_BIT |
            c.VK_COLOR_COMPONENT_B_BIT |
            c.VK_COLOR_COMPONENT_A_BIT;
        var color_blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        color_blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        color_blend.logicOpEnable = c.VK_FALSE;
        color_blend.attachmentCount = 1;
        color_blend.pAttachments = &blend_attachment;

        var dynamic_states = [_]c.VkDynamicState{
            c.VK_DYNAMIC_STATE_VIEWPORT,
            c.VK_DYNAMIC_STATE_SCISSOR,
        };
        var dynamic_state = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic_state.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic_state.dynamicStateCount = @intCast(dynamic_states.len);
        dynamic_state.pDynamicStates = &dynamic_states;

        var pipeline_info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        pipeline_info.stageCount = @intCast(stages.len);
        pipeline_info.pStages = &stages;
        pipeline_info.pVertexInputState = &vertex_input;
        pipeline_info.pInputAssemblyState = &input_assembly;
        pipeline_info.pViewportState = &viewport_state;
        pipeline_info.pRasterizationState = &raster;
        pipeline_info.pMultisampleState = &multisample;
        pipeline_info.pDepthStencilState = &depth_stencil;
        pipeline_info.pColorBlendState = &color_blend;
        pipeline_info.pDynamicState = &dynamic_state;
        pipeline_info.layout = self.pipeline_layout.?;
        pipeline_info.renderPass = self.surface.render_pass.?;
        pipeline_info.subpass = 0;

        var pipeline: c.VkPipeline = null;
        if (c.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline) != c.VK_SUCCESS) {
            abi.setError("vkCreateGraphicsPipelines failed");
            return error.PipelineCreateFailed;
        }
        self.pipeline = pipeline;
        self.pipeline_render_pass = self.surface.render_pass.?;
    }

    /// Rebuild the pipeline when `Surface` recreated its render pass (resize).
    fn ensurePipeline(self: *Scene) Error!void {
        if (self.pipeline != null and self.pipeline_render_pass == self.surface.render_pass) return;
        try self.createPipeline(self.surface.device.?);
    }

    /// Resize the SDL window (hint) and synchronise the swapchain/offscreen
    /// targets.  Passing zero/negative sizes only synchronises to the current
    /// window size, which is what the renderer does automatically each frame.
    pub fn resize(self: *Scene, width: i32, height: i32) Error!void {
        if (width > 0 and height > 0) {
            if (!c.SDL_SetWindowSize(self.surface.window.handle, width, height)) {
                abi.setErrorFmt("SDL_SetWindowSize: {s}", .{window_mod.sdlError()});
                return error.WindowOperationFailed;
            }
        }
        try self.surface.ensureSize();
        try self.ensurePipeline();
    }

    pub fn setCamera(self: *Scene, eye: Vec3, yaw: f32, pitch: f32) void {
        const limit = std.math.degreesToRadians(89.0);
        self.camera = .{
            .eye = eye,
            .yaw = yaw,
            .pitch = std.math.clamp(pitch, -limit, limit),
        };
    }

    pub fn setLight(self: *Scene, position: Vec3, color: [4]f32) void {
        self.light_position = position;
        self.light_color = color;
    }

    fn writeUniforms(self: *Scene) void {
        const extent = self.surface.extent;
        const aspect = if (extent.height == 0)
            1.0
        else
            @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height));

        const model = matMul(matRotationY(self.spin), matRotationX(0.35));
        const view = matView(self.camera.eye, self.camera.yaw, self.camera.pitch);
        const proj = matPerspective(default_fov_y, aspect, default_near, default_far);

        const target = self.uniformPtr();
        target.* = .{
            .model = model,
            .view = view,
            .proj = proj,
            .camera_pos = .{ self.camera.eye[0], self.camera.eye[1], self.camera.eye[2], 1.0 },
            .light_pos = .{ self.light_position[0], self.light_position[1], self.light_position[2], 1.0 },
            .light_color = self.light_color,
            .params = self.ambient,
        };
    }

    fn recordDraw(self: *Scene, cmd: c.VkCommandBuffer) void {
        const extent = self.surface.extent;
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline.?);

        var viewport = std.mem.zeroes(c.VkViewport);
        viewport.x = 0;
        viewport.y = 0;
        viewport.width = @floatFromInt(extent.width);
        viewport.height = @floatFromInt(extent.height);
        viewport.minDepth = 0;
        viewport.maxDepth = 1;
        c.vkCmdSetViewport(cmd, 0, 1, &viewport);

        var scissor = std.mem.zeroes(c.VkRect2D);
        scissor.extent = extent;
        c.vkCmdSetScissor(cmd, 0, 1, &scissor);

        var vertex_buffer = self.vertex.buffer.?;
        var vertex_offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffer, &vertex_offset);
        c.vkCmdBindIndexBuffer(cmd, self.index.buffer.?, 0, c.VK_INDEX_TYPE_UINT16);

        var descriptor_set = self.descriptor_set.?;
        c.vkCmdBindDescriptorSets(
            cmd,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout.?,
            0,
            1,
            &descriptor_set,
            0,
            null,
        );
        c.vkCmdDrawIndexed(cmd, index_count, 1, 0, 0, 0);
    }

    /// Render one frame and present it to the window.
    ///
    /// `cube_angle` is the model's Y rotation in radians; `light_position` is
    /// the world-space point light.  `delta_seconds` is accepted for callers
    /// that integrate animation themselves and is currently informational.
    pub fn draw(
        self: *Scene,
        delta_seconds: f32,
        cube_angle: f32,
        light_position: Vec3,
    ) Error!void {
        _ = delta_seconds;
        self.spin = cube_angle;
        self.light_position = light_position;

        const index = try self.surface.acquireFrame();
        try self.ensurePipeline();
        self.writeUniforms();

        const cmd = try self.surface.beginScene(self.clear_color, default_clear_depth);
        self.recordDraw(cmd);
        try self.surface.endScenePresent(index);
    }

    /// Render one frame into the offscreen target and return tightly packed
    /// RGBA8 pixels.  Caller owns the slice (same allocator as the scene).
    pub fn captureFrame(
        self: *Scene,
        cube_angle: f32,
        light_position: Vec3,
    ) Error![]u8 {
        self.spin = cube_angle;
        self.light_position = light_position;

        const cmd = try self.surface.beginSceneCapture(self.clear_color, default_clear_depth);
        try self.ensurePipeline();
        self.writeUniforms();
        self.recordDraw(cmd);
        return self.surface.endSceneCapture();
    }

    pub fn size(self: *const Scene) struct { width: u32, height: u32 } {
        return .{ .width = self.surface.extent.width, .height = self.surface.extent.height };
    }
};

pub const Registry = handles.Table(Scene);
pub var registry: Registry = .{};

// ------------------------------------------------------------------- tests --

test "SPIR-V bytecode validation" {
    try std.testing.expect(!Scene.isSpirv(&.{}));
    try std.testing.expect(!Scene.isSpirv("no"));
    // Minimal 5-word module: magic, version, generator, bound, schema.
    const minimal = [_]u8{ 0x03, 0x02, 0x23, 0x07, 0x00, 0x03, 0x01, 0x00, 0x0b, 0x00, 0x08, 0x00, 0x86, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    try std.testing.expect(Scene.isSpirv(&minimal));
    try std.testing.expect(Scene.isSpirv(shader_assets.cube_vert_spv));
    try std.testing.expect(Scene.isSpirv(shader_assets.cube_frag_spv));
}

test "camera basis and matrices match Vulkan conventions" {
    const basis = cameraBasis(0.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), basis.forward[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), basis.forward[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), basis.right[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), basis.up[1], 1e-6);

    const eye = Vec3{ 0.0, 1.5, 4.0 };
    const view = matView(eye, 0.0, 0.0);
    // The eye maps to the view-space origin.
    const eye_view = Vec3{
        view[0][0] * eye[0] + view[1][0] * eye[1] + view[2][0] * eye[2] + view[3][0],
        view[0][1] * eye[0] + view[1][1] * eye[1] + view[2][1] * eye[2] + view[3][1],
        view[0][2] * eye[0] + view[1][2] * eye[1] + view[2][2] * eye[2] + view[3][2],
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_view[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_view[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_view[2], 1e-5);
    // A point ahead of the camera lands on view-space -Z.
    const ahead = Vec3{ 0.0, 0.0, -1.0 };
    const ahead_view = Vec3{
        view[0][0] * ahead[0] + view[1][0] * ahead[1] + view[2][0] * ahead[2] + view[3][0],
        view[0][1] * ahead[0] + view[1][1] * ahead[1] + view[2][1] * ahead[2] + view[3][1],
        view[0][2] * ahead[0] + view[1][2] * ahead[1] + view[2][2] * ahead[2] + view[3][2],
    };
    try std.testing.expectApproxEqAbs(@as(f32, -5.0), ahead_view[2], 1e-5);

    const proj = matPerspective(std.math.degreesToRadians(60.0), 1.5, 0.1, 100.0);
    // Near plane -> NDC z 0, far plane -> NDC z 1.
    const near_z = proj[2][2] * -0.1 + proj[3][2];
    const near_w = proj[2][3] * -0.1;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), near_z / near_w, 1e-5);
    const far_z = proj[2][2] * -100.0 + proj[3][2];
    const far_w = proj[2][3] * -100.0;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_z / far_w, 1e-4);
}

test "view matrix is right-handed and rotates around the camera eye" {
    const eye = Vec3{ 0.0, 1.5, 5.5 };
    // At yaw 0, +X is screen-right: a point to the right of the eye has
    // positive view X.
    const right_point = Vec3{ 1.0, 1.5, 5.0 };
    const view0 = matView(eye, 0.0, 0.0);
    const right_view_x = view0[0][0] * right_point[0] + view0[1][0] * right_point[1] + view0[2][0] * right_point[2] + view0[3][0];
    try std.testing.expect(right_view_x > 0.0);

    // Yaw +30 must rotate the camera toward +X (clockwise from above in a
    // right-handed system): an object straight ahead initially lands on the
    // left side of the view, not the right.
    const ahead = Vec3{ 0.0, 1.5, 0.5 };
    const view30 = matView(eye, std.math.degreesToRadians(30.0), 0.0);
    const ahead_x = view30[0][0] * ahead[0] + view30[1][0] * ahead[1] + view30[2][0] * ahead[2] + view30[3][0];
    try std.testing.expect(ahead_x < 0.0);

    const look = matLookAt(eye, .{ 0.0, 1.5, 0.0 }, .{ 0.0, 1.0, 0.0 });
    try std.testing.expectApproxEqAbs(view0[0][0], look[0][0], 1e-5);
}

test "cube geometry is consistent" {
    try std.testing.expectEqual(@as(usize, 24), cube_vertices.len);
    try std.testing.expectEqual(@as(usize, 36), cube_indices.len);
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(Uniforms));
    for (cube_indices) |index| try std.testing.expect(index < vertex_count);
    for (cube_vertices) |vertex| {
        // Every corner sits on the [-1, 1] cube.
        for (vertex.position) |component| {
            try std.testing.expectApproxEqAbs(@as(f32, 1.0), @abs(component), 1e-6);
        }
        for (vertex.normal) |component| {
            try std.testing.expect(component == 0.0 or @abs(component) == 1.0);
        }
    }
}

test "scene renders a lit spinning cube headlessly" {
    var window = window_mod.Window.create("engine7 scene test", 192, 144, .{
        .hidden = true,
        .vulkan = true,
    }, null) catch |err| {
        std.debug.print("skipping scene render test (no display): {s}\n", .{@errorName(err)});
        window_mod.shutdownVideo();
        return;
    };
    defer window_mod.shutdownVideo();
    defer window.destroy();

    var scene = Scene.init(
        std.testing.allocator,
        &window,
        shader_assets.cube_vert_spv,
        shader_assets.cube_frag_spv,
    ) catch |err| {
        std.debug.print("skipping scene render test (no Vulkan): {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer scene.deinit();

    const light = Vec3{ 2.5, 3.0, 2.0 };
    const first = try scene.captureFrame(0.0, light);
    defer std.testing.allocator.free(first);
    const size = scene.size();
    try std.testing.expectEqual(@as(usize, @as(usize, size.width) * size.height * 4), first.len);

    const clear = scene.clear_color;
    const clear_r: i32 = @intFromFloat(clear[0] * 255.0);
    var lit_pixels: usize = 0;
    var i: usize = 0;
    while (i + 3 < first.len) : (i += 4) {
        const r = @as(i32, first[i]);
        const g = @as(i32, first[i + 1]);
        const b = @as(i32, first[i + 2]);
        // Anything meaningfully brighter than the dark clear colour is the cube.
        if (r + g + b > clear_r * 3 + 60) lit_pixels += 1;
        try std.testing.expectEqual(@as(u8, 255), first[i + 3]);
    }
    // A unit cube at ~4.5 units covers a few percent of a 60-degree view.
    try std.testing.expect(lit_pixels > 300);

    // A different spin angle must change the rendered image (model matrix used).
    const second = try scene.captureFrame(std.math.degreesToRadians(60.0), light);
    defer std.testing.allocator.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));

    // Moving the light must change the shading (point-light uniform used).
    const third = try scene.captureFrame(std.math.degreesToRadians(60.0), .{ -3.0, 1.0, 0.5 });
    defer std.testing.allocator.free(third);
    try std.testing.expect(!std.mem.eql(u8, second, third));

    // Resizing recreates the swapchain/offscreen targets and the pipeline; a
    // subsequent frame must use the new extent.
    try scene.resize(256, 128);
    const resized = scene.size();
    try std.testing.expectEqual(@as(u32, 256), resized.width);
    try std.testing.expectEqual(@as(u32, 128), resized.height);
    const fourth = try scene.captureFrame(std.math.degreesToRadians(30.0), light);
    defer std.testing.allocator.free(fourth);
    try std.testing.expectEqual(@as(usize, 256 * 128 * 4), fourth.len);

    // The presented path (acquire -> record -> blit -> present) also works on a
    // hidden window; the demo's interactive mode uses exactly this.
    try scene.draw(1.0 / 60.0, std.math.degreesToRadians(15.0), light);
    try scene.draw(1.0 / 60.0, std.math.degreesToRadians(20.0), light);
}

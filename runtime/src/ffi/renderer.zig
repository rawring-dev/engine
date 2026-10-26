//! Basic Vulkan 3D scene renderer built on the `Surface` FFI.
//!
//! `Scene` owns a `Surface` (instance/device/swapchain/offscreen target), a
//! SPIR-V vertex/fragment pipeline with a depth test, a host-visible uniform
//! buffer with one aligned slot per drawable object, and a unit cube with a
//! fixed position/normal/colour vertex format.  Each frame it writes the
//! model/view/projection matrices plus point-light parameters into a per-object
//! uniform slot, records one indexed draw per object into the surface's
//! offscreen colour+depth target, and either presents the result or copies it
//! back for headless validation.  The number of objects per frame is dynamic:
//! per-object uniform slots and the recorded-object list grow on demand (a
//! few hundred objects/frame are routine); all share the frame's camera and
//! light.
//!
//! Matrix convention: matrices are column-major (`Mat4[col][row]`), matching
//! the `column_major float4x4` fields emitted from `engine/shaders/*.e7`.
//! The projection targets Vulkan's [0, 1] clip depth and flips Y so world +Y
//! is up on screen.
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
    FrameAlreadyActive,
    FrameNotActive,
    TextureLimit,
    InvalidTexture,
    InvalidMesh,
};

/// A scene frame starts from this background colour unless overridden.
pub const default_clear_color = [4]f32{ 0.02, 0.025, 0.04, 1.0 };
pub const default_clear_depth: f32 = 1.0;

/// Fixed vertex format: position, normal, colour, UV.  Matches the
/// `[[vk::location(n)]]` inputs in `engine/shaders/cube.vert.e7`.
pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    color: [3]f32,
    uv: [2]f32 = .{ 0.0, 0.0 },
};

pub const vertex_count = 24;
pub const index_count = 36;

/// Initial per-frame object capacity.  The object count is dynamic: the
/// uniform buffer and recorded-object list double from here when a frame needs
/// more slots.  There is no fixed per-frame object cap; only allocator,
/// descriptor-pool, and dynamic-offset range limits apply.
pub const initial_object_capacity = 64;

/// Uniform block, std140-compatible and 272 bytes.  Matrices are stored as
/// four contiguous columns (`Mat4[col][row]`), matching the `column_major`
/// `[f32; 4, 4]` fields in `engine/shaders/cube.{vert,frag}.e7`.
pub const Uniforms = extern struct {
    model: [4][4]f32,
    view: [4][4]f32,
    proj: [4][4]f32,
    camera_pos: [4]f32,
    light_pos: [4]f32,
    light_color: [4]f32,
    params: [4]f32,
    /// Per-object tint (rgb multiplies the mesh's vertex colour; a = unused).
    tint: [4]f32,
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

/// One drawable box: world translation, per-axis scale, and an orientation.
/// The built-in unit cube spans [-1, 1], so scale is half-extent based: a
/// 1x1x1 cube needs scale (1, 1, 1), a plane 100x0.2x100 needs (50, 0.1, 50).
///
/// `rotation` is an intrinsic-XYZ Euler triple in radians (x = roll, y = pitch,
/// z = yaw), composed as R = Rz * Ry * Rx to match `physics::quat_from_euler`
/// and the Euler values physics writes back into `Transform.rotation`.
/// `angle` is the legacy single Y rotation and is added to `rotation[1]`; new
/// full-orientation callers set `rotation` and leave `angle` at zero.
pub const Box = struct {
    position: Vec3 = .{ 0.0, 0.0, 0.0 },
    scale: Vec3 = .{ 1.0, 1.0, 1.0 },
    rotation: Vec3 = .{ 0.0, 0.0, 0.0 },
    angle: f32 = 0.0,
};

/// Shape kinds understood by `drawShape`.  Numeric values match the e7
/// `Renderable.kind` field and the `kind` argument of
/// `e7_engine_scene_draw_shape`.
pub const Shape = enum(u8) {
    box = 0,
    sphere = 1,
    capsule = 2,
    plane = 3,
};

pub const shape_count = std.meta.fields(Shape).len;

pub fn shapeFromInt(value: i64) ?Shape {
    return switch (value) {
        0 => .box,
        1 => .sphere,
        2 => .capsule,
        3 => .plane,
        else => null,
    };
}

pub const default_tint = [4]f32{ 1.0, 1.0, 1.0, 1.0 };

/// Combined image-sampler materials: id 0 is always the built-in white 1x1
/// texture, user textures are appended.  The descriptor pool is sized for
/// this many texture/material descriptor sets.
pub const max_textures = 512;

/// Which mesh a recorded draw uses: one of the built-in procedural shapes or
/// a custom uploaded mesh id.
pub const MeshRef = union(enum) {
    builtin: Shape,
    custom: u64,
};

const RecordedObject = struct {
    model: Mat4,
    tint: [4]f32,
    mesh: MeshRef,
    texture: u32,
};

const Texture = struct {
    image: ?c.VkImage = null,
    memory: ?c.VkDeviceMemory = null,
    view: ?c.VkImageView = null,
    set: ?c.VkDescriptorSet = null,
    destroyed: bool = false,
};

const CustomMesh = struct {
    mesh: Mesh = .{},
    destroyed: bool = false,
};

/// Vertex layouts accepted by `uploadMesh` for e7 OBJ data.
pub const MeshLayout = enum(u32) {
    /// Interleaved position(3) + normal(3) + uv(2) = 8 floats (obj.e7 output).
    pos_normal_uv = 0,
    /// Interleaved position(3) + normal(3) + colour(3) + uv(2) = 11 floats.
    pos_normal_color_uv = 1,

    pub fn floatsPerVertex(self: MeshLayout) usize {
        return switch (self) {
            .pos_normal_uv => 8,
            .pos_normal_color_uv => 11,
        };
    }
};

pub fn meshLayoutFromInt(value: i64) ?MeshLayout {
    return switch (value) {
        0 => .pos_normal_uv,
        1 => .pos_normal_color_uv,
        else => null,
    };
}

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
        const face_uvs = [4][2]f32{ .{ 0.0, 0.0 }, .{ 1.0, 0.0 }, .{ 1.0, 1.0 }, .{ 0.0, 1.0 } };
        for (face.corners, 0..) |corner, corner_index| {
            vertices[face_index * 4 + corner_index] = .{
                .position = corner,
                .normal = face.normal,
                .color = face.color,
                .uv = face_uvs[corner_index],
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

/// UV sphere, radius 1.  Smooth normals; neutral vertex colour multiplied by the
/// per-object tint in the fragment shader.
pub const sphere_stacks = 16;
pub const sphere_slices = 24;
pub const sphere_vertex_count = (sphere_stacks + 1) * (sphere_slices + 1);
pub const sphere_index_count = sphere_stacks * sphere_slices * 6;

pub const sphere_vertices: [sphere_vertex_count]Vertex = blk: {
    @setEvalBranchQuota(200_000);
    var vertices: [sphere_vertex_count]Vertex = undefined;
    const row_stride = sphere_slices + 1;
    for (0..sphere_stacks + 1) |stack| {
        const theta = (@as(f32, @floatFromInt(stack)) / sphere_stacks) * std.math.pi;
        const sin_theta = @sin(theta);
        const cos_theta = @cos(theta);
        for (0..sphere_slices + 1) |slice| {
            const phi = (@as(f32, @floatFromInt(slice)) / sphere_slices) * 2.0 * std.math.pi;
            const position = Vec3{ sin_theta * @cos(phi), cos_theta, sin_theta * @sin(phi) };
            vertices[stack * row_stride + slice] = .{
                .position = position,
                .normal = position,
                .color = .{ 1.0, 1.0, 1.0 },
                .uv = .{
                    @as(f32, @floatFromInt(slice)) / sphere_slices,
                    @as(f32, @floatFromInt(stack)) / sphere_stacks,
                },
            };
        }
    }
    break :blk vertices;
};

pub const sphere_indices: [sphere_index_count]u16 = blk: {
    @setEvalBranchQuota(200_000);
    var indices: [sphere_index_count]u16 = undefined;
    const row_stride = sphere_slices + 1;
    var at: usize = 0;
    for (0..sphere_stacks) |stack| {
        for (0..sphere_slices) |slice| {
            const a: u16 = @intCast(stack * row_stride + slice);
            const b: u16 = a + 1;
            const row_below: u16 = @intCast((stack + 1) * row_stride + slice);
            const d: u16 = row_below + 1;
            indices[at + 0] = a;
            indices[at + 1] = row_below;
            indices[at + 2] = b;
            indices[at + 3] = b;
            indices[at + 4] = row_below;
            indices[at + 5] = d;
            at += 6;
        }
    }
    break :blk indices;
};

/// Capsule along Y: hemispherical caps at y=+/-1 with radius 1, so the full
/// mesh spans y in [-2, 2].  Scale (x, y, z) means radius on x/z and cylinder
/// half-height on y: a capsule with radius 0.4 and cylinder half-height 0.6
/// uses scale (0.4, 0.6, 0.4) and spans y in [-1, 1].
pub const capsule_slices = 24;
pub const capsule_cap_stacks = 8;
pub const capsule_rows = capsule_cap_stacks + 1;
pub const capsule_vertex_count = 2 * capsule_rows * (capsule_slices + 1);
pub const capsule_index_count = (2 * capsule_cap_stacks + 1) * capsule_slices * 6;

pub const capsule_vertices: [capsule_vertex_count]Vertex = blk: {
    @setEvalBranchQuota(300_000);
    var vertices: [capsule_vertex_count]Vertex = undefined;
    const row_stride = capsule_slices + 1;
    var row_base: usize = 0;
    // Top hemisphere: theta 0 (pole, y=2) .. pi/2 (ring, y=1).
    for (0..capsule_rows) |stack| {
        const theta = (@as(f32, @floatFromInt(stack)) / capsule_cap_stacks) * (std.math.pi * 0.5);
        const sin_theta = @sin(theta);
        const cos_theta = @cos(theta);
        for (0..capsule_slices + 1) |slice| {
            const phi = (@as(f32, @floatFromInt(slice)) / capsule_slices) * 2.0 * std.math.pi;
            const x = sin_theta * @cos(phi);
            const z = sin_theta * @sin(phi);
            const y = 1.0 + cos_theta;
            vertices[row_base + slice] = .{
                .position = .{ x, y, z },
                .normal = .{ x, y - 1.0, z },
                .color = .{ 1.0, 1.0, 1.0 },
                .uv = .{
                    @as(f32, @floatFromInt(slice)) / capsule_slices,
                    (y + 2.0) / 4.0,
                },
            };
        }
        row_base += row_stride;
    }
    // Bottom hemisphere: pole y=-2 .. ring y=-1.
    for (0..capsule_rows) |stack| {
        const theta = (@as(f32, @floatFromInt(stack)) / capsule_cap_stacks) * (std.math.pi * 0.5);
        const sin_theta = @sin(theta);
        const cos_theta = @cos(theta);
        for (0..capsule_slices + 1) |slice| {
            const phi = (@as(f32, @floatFromInt(slice)) / capsule_slices) * 2.0 * std.math.pi;
            const x = sin_theta * @cos(phi);
            const z = sin_theta * @sin(phi);
            const y = -1.0 - cos_theta;
            vertices[row_base + slice] = .{
                .position = .{ x, y, z },
                .normal = .{ x, y + 1.0, z },
                .color = .{ 1.0, 1.0, 1.0 },
                .uv = .{
                    @as(f32, @floatFromInt(slice)) / capsule_slices,
                    (y + 2.0) / 4.0,
                },
            };
        }
        row_base += row_stride;
    }
    break :blk vertices;
};

pub const capsule_indices: [capsule_index_count]u16 = blk: {
    @setEvalBranchQuota(400_000);
    var indices: [capsule_index_count]u16 = undefined;
    const row_stride = capsule_slices + 1;
    var at: usize = 0;
    var cap_base: u16 = 0;
    for (0..2) |_| {
        for (0..capsule_cap_stacks) |stack| {
            for (0..capsule_slices) |slice| {
                const a: u16 = cap_base + @as(u16, @intCast(stack * row_stride + slice));
                const b: u16 = a + 1;
                const row_below: u16 = a + @as(u16, @intCast(row_stride));
                const d: u16 = row_below + 1;
                indices[at + 0] = a;
                indices[at + 1] = row_below;
                indices[at + 2] = b;
                indices[at + 3] = b;
                indices[at + 4] = row_below;
                indices[at + 5] = d;
                at += 6;
            }
        }
        cap_base += @intCast(capsule_rows * row_stride);
    }
    // Cylinder band between the y=1 ring of the top cap and the y=-1 ring of
    // the bottom cap (the last row of each hemisphere).
    const top_ring: u16 = @intCast((capsule_rows - 1) * row_stride);
    const bottom_ring: u16 = @intCast(capsule_rows * row_stride);
    for (0..capsule_slices) |slice| {
        const a: u16 = top_ring + @as(u16, @intCast(slice));
        const b: u16 = a + 1;
        const below: u16 = bottom_ring + @as(u16, @intCast(slice));
        const d: u16 = below + 1;
        indices[at + 0] = a;
        indices[at + 1] = below;
        indices[at + 2] = b;
        indices[at + 3] = b;
        indices[at + 4] = below;
        indices[at + 5] = d;
        at += 6;
    }
    break :blk indices;
};

/// Flat XZ plane spanning [-1, 1] with a +Y normal; the Y scale is ignored.
pub const plane_vertices = [4]Vertex{
    .{ .position = .{ -1.0, 0.0, -1.0 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1 }, .uv = .{ 0.0, 0.0 } },
    .{ .position = .{ 1.0, 0.0, -1.0 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1 }, .uv = .{ 1.0, 0.0 } },
    .{ .position = .{ 1.0, 0.0, 1.0 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1 }, .uv = .{ 1.0, 1.0 } },
    .{ .position = .{ -1.0, 0.0, 1.0 }, .normal = .{ 0, 1, 0 }, .color = .{ 1, 1, 1 }, .uv = .{ 0.0, 1.0 } },
};
pub const plane_indices = [6]u16{ 0, 1, 2, 0, 2, 3 };

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

pub fn matRotationZ(angle: f32) Mat4 {
    const cos = @cos(angle);
    const sin = @sin(angle);
    var m = matIdentity();
    m[0][0] = cos;
    m[0][1] = sin;
    m[1][0] = -sin;
    m[1][1] = cos;
    return m;
}

pub fn matTranslation(translation: Vec3) Mat4 {
    var m = matIdentity();
    m[3] = .{ translation[0], translation[1], translation[2], 1.0 };
    return m;
}

pub fn matScale(scale: Vec3) Mat4 {
    var m = matIdentity();
    m[0][0] = scale[0];
    m[1][1] = scale[1];
    m[2][2] = scale[2];
    return m;
}

/// Model matrix for a box: translate * Rz(z) * Ry(y) * Rx(x) * scale
/// (column-vector convention, so the box is scaled first, then rotated X, Y,
/// Z, then moved).  This matches the physics Euler convention; the legacy
/// `angle` field adds to the Y component for old callers.
pub fn boxModel(box: Box) Mat4 {
    const rotation = matMul(
        matRotationZ(box.rotation[2]),
        matMul(matRotationY(box.rotation[1] + box.angle), matRotationX(box.rotation[0])),
    );
    return matMul(matTranslation(box.position), matMul(rotation, matScale(box.scale)));
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
    // Column-major storage: the view transform's rows are right/up/back, so
    // its columns are the transposed basis.  (Previously the basis was stored
    // as columns, which coincidentally worked only for axis-aligned yaw=0 but
    // translated the eye whenever pitch changed.)
    var m = matIdentity();
    m[0] = .{ right[0], up[0], back[0], 0.0 };
    m[1] = .{ right[1], up[1], back[1], 0.0 };
    m[2] = .{ right[2], up[2], back[2], 0.0 };
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

const Mesh = struct {
    vertex: BufferAllocation = .{},
    index: BufferAllocation = .{},
    index_count: u32 = 0,
    index_type: c.VkIndexType = c.VK_INDEX_TYPE_UINT16,
};

/// Destroy a texture's GPU image/view/memory.  The descriptor set is returned
/// to the texture pool (the set is not needed once the image is gone).
fn destroyTextureResources(device: c.VkDevice, texture: *Texture) void {
    if (texture.view) |view| c.vkDestroyImageView(device, view, null);
    if (texture.image) |image| c.vkDestroyImage(device, image, null);
    if (texture.memory) |memory| c.vkFreeMemory(device, memory, null);
    texture.view = null;
    texture.image = null;
    texture.memory = null;
}

pub const Scene = struct {
    allocator: std.mem.Allocator,
    surface: vulkan.Surface,

    vert_module: ?c.VkShaderModule = null,
    frag_module: ?c.VkShaderModule = null,
    /// Set 0: per-object uniform buffer (dynamic offset).
    descriptor_set_layout: ?c.VkDescriptorSetLayout = null,
    descriptor_pool: ?c.VkDescriptorPool = null,
    descriptor_set: ?c.VkDescriptorSet = null,
    /// Set 1: per-material combined image sampler + sampler.
    texture_set_layout: ?c.VkDescriptorSetLayout = null,
    texture_pool: ?c.VkDescriptorPool = null,
    textures: std.ArrayListUnmanaged(Texture) = .empty,
    custom_meshes: std.ArrayListUnmanaged(CustomMesh) = .empty,
    /// One-shot upload command buffer/fence for texture and mesh staging.
    upload_pool: ?c.VkCommandPool = null,
    upload_cmd: ?c.VkCommandBuffer = null,
    upload_fence: ?c.VkFence = null,
    pipeline_layout: ?c.VkPipelineLayout = null,
    pipeline: ?c.VkPipeline = null,
    /// Render pass the current pipeline was built against; `Surface` recreates
    /// its render pass on window resize, which requires rebuilding the pipeline.
    pipeline_render_pass: ?c.VkRenderPass = null,

    /// One vertex/index mesh per `Shape` (box, sphere, capsule, plane).
    meshes: [shape_count]Mesh = [_]Mesh{.{}} ** shape_count,
    uniform: BufferAllocation = .{},
    /// Buffers/descriptor sets retired by mid-frame growth.  They stay alive
    /// until the next frame boundary (the GPU may still reference them from a
    /// command buffer that is being recorded).
    retired_uniforms: std.ArrayListUnmanaged(BufferAllocation) = .empty,
    retired_uniform_sets: std.ArrayListUnmanaged(c.VkDescriptorSet) = .empty,
    /// Number of per-object uniform slots currently allocated.
    uniform_capacity: usize = 0,
    /// Bytes between per-object uniform slots (a multiple of the device's
    /// minUniformBufferOffsetAlignment and of @sizeOf(Uniforms)).
    uniform_stride: u32 = @sizeOf(Uniforms),
    /// Draws recorded by the current/last frame, replayed by
    /// `captureRecordedFrame` so headless captures include every object.
    recorded_objects: std.ArrayListUnmanaged(RecordedObject) = .empty,

    camera: Camera = .{},
    default_sampler: ?c.VkSampler = null,
    /// Pending frame state for the split begin/draw/end ABI used by e7.
    frame_index: ?u32 = null,
    frame_cmd: ?c.VkCommandBuffer = null,
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
        self.uniform_stride = self.computeUniformStride();
        self.uniform_capacity = initial_object_capacity;
        self.vert_module = try self.createShaderModule(device, vert_spv);
        self.frag_module = try self.createShaderModule(device, frag_spv);

        try self.createBuffers(device);
        try self.createUploadCommands(device);
        try self.createDescriptors(device);
        try self.createDefaultSampler(device);
        _ = try self.createTextureFromRgba(1, 1, &[_]u8{ 255, 255, 255, 255 });
        try self.createPipeline(device);
        return self;
    }

    pub fn deinit(self: *Scene) void {
        if (self.surface.device) |device| {
            _ = c.vkDeviceWaitIdle(device);
            if (self.pipeline) |v| c.vkDestroyPipeline(device, v, null);
            if (self.pipeline_layout) |v| c.vkDestroyPipelineLayout(device, v, null);
            if (self.descriptor_pool) |v| c.vkDestroyDescriptorPool(device, v, null);
            if (self.texture_pool) |v| c.vkDestroyDescriptorPool(device, v, null);
            if (self.descriptor_set_layout) |v| c.vkDestroyDescriptorSetLayout(device, v, null);
            if (self.texture_set_layout) |v| c.vkDestroyDescriptorSetLayout(device, v, null);
            for (self.textures.items) |*texture| destroyTextureResources(device, texture);
            for (self.custom_meshes.items) |*custom| {
                destroyBuffer(device, &custom.mesh.vertex);
                destroyBuffer(device, &custom.mesh.index);
            }
            if (self.default_sampler) |v| c.vkDestroySampler(device, v, null);
            if (self.upload_fence) |v| c.vkDestroyFence(device, v, null);
            if (self.upload_pool) |v| c.vkDestroyCommandPool(device, v, null);
            if (self.vert_module) |v| c.vkDestroyShaderModule(device, v, null);
            if (self.frag_module) |v| c.vkDestroyShaderModule(device, v, null);
            for (&self.meshes) |*mesh| {
                destroyBuffer(device, &mesh.vertex);
                destroyBuffer(device, &mesh.index);
            }
            self.flushRetiredUniforms();
            destroyBuffer(device, &self.uniform);
        }
        self.recorded_objects.deinit(self.allocator);
        self.retired_uniforms.deinit(self.allocator);
        self.retired_uniform_sets.deinit(self.allocator);
        self.textures.deinit(self.allocator);
        self.custom_meshes.deinit(self.allocator);
        self.pipeline = null;
        self.pipeline_layout = null;
        self.descriptor_pool = null;
        self.descriptor_set = null;
        self.descriptor_set_layout = null;
        self.texture_pool = null;
        self.texture_set_layout = null;
        self.default_sampler = null;
        self.upload_fence = null;
        self.upload_pool = null;
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

    fn createMesh(
        self: *Scene,
        device: c.VkDevice,
        vertices: []const Vertex,
        index_bytes: []const u8,
        index_total: u32,
        index_type: c.VkIndexType,
    ) Error!Mesh {
        var mesh = Mesh{};
        errdefer {
            destroyBuffer(device, &mesh.vertex);
            destroyBuffer(device, &mesh.index);
        }
        mesh.vertex = try self.createHostBuffer(
            device,
            @sizeOf(Vertex) * vertices.len,
            c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        );
        mesh.index = try self.createHostBuffer(
            device,
            index_bytes.len,
            c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        );
        const vertex_target: [*]Vertex = @ptrCast(@alignCast(mesh.vertex.mapped.?));
        @memcpy(vertex_target[0..vertices.len], vertices);
        @memcpy(mesh.index.mapped.?[0..index_bytes.len], index_bytes);
        mesh.index_count = index_total;
        mesh.index_type = index_type;
        return mesh;
    }

    fn createMeshU16(self: *Scene, device: c.VkDevice, vertices: []const Vertex, indices: []const u16) Error!Mesh {
        return self.createMesh(
            device,
            vertices,
            std.mem.sliceAsBytes(indices),
            @intCast(indices.len),
            c.VK_INDEX_TYPE_UINT16,
        );
    }

    fn createBuffers(self: *Scene, device: c.VkDevice) Error!void {
        self.meshes[@intFromEnum(Shape.box)] = try self.createMeshU16(device, &cube_vertices, &cube_indices);
        self.meshes[@intFromEnum(Shape.sphere)] = try self.createMeshU16(device, &sphere_vertices, &sphere_indices);
        self.meshes[@intFromEnum(Shape.capsule)] = try self.createMeshU16(device, &capsule_vertices, &capsule_indices);
        self.meshes[@intFromEnum(Shape.plane)] = try self.createMeshU16(device, &plane_vertices, &plane_indices);
        self.uniform = try self.createHostBuffer(
            device,
            @as(usize, self.uniform_stride) * self.uniform_capacity,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );
    }

    fn computeUniformStride(self: *Scene) u32 {
        var props = std.mem.zeroes(c.VkPhysicalDeviceProperties);
        c.vkGetPhysicalDeviceProperties(self.surface.physical.?, &props);
        const alignment: u32 = @intCast(@max(props.limits.minUniformBufferOffsetAlignment, 1));
        const block_size: u32 = @sizeOf(Uniforms);
        const stride = ((block_size + alignment - 1) / alignment) * alignment;
        return @max(stride, block_size);
    }

    fn uniformSlot(self: *Scene, slot: usize) *Uniforms {
        const offset = @as(usize, slot) * self.uniform_stride;
        return @ptrCast(@alignCast(self.uniform.mapped.? + offset));
    }

    /// Grow the per-object uniform buffer so at least `required` slots fit.
    /// The old buffer and its descriptor set are retired (not destroyed) until
    /// the next frame boundary, because a command buffer that is currently
    /// recording may still reference them.  At a frame boundary the GPU is
    /// idle (the surface waits on its frame fence), so retired generations can
    /// be released safely.
    fn ensureUniformCapacity(self: *Scene, required: usize) Error!void {
        if (required <= self.uniform_capacity) return;
        const device = self.surface.device.?;
        var new_capacity = @max(self.uniform_capacity, initial_object_capacity);
        while (new_capacity < required) new_capacity *= 2;

        const used = @as(usize, self.recorded_objects.items.len) * self.uniform_stride;
        var replacement = try self.createHostBuffer(
            device,
            @as(usize, self.uniform_stride) * new_capacity,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        );
        errdefer destroyBuffer(device, &replacement);
        if (used > 0 and self.uniform.mapped != null) {
            @memcpy(replacement.mapped.?[0..used], self.uniform.mapped.?[0..used]);
        }

        var set: c.VkDescriptorSet = null;
        var allocate_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocate_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate_info.descriptorPool = self.descriptor_pool.?;
        allocate_info.descriptorSetCount = 1;
        allocate_info.pSetLayouts = &self.descriptor_set_layout.?;
        if (c.vkAllocateDescriptorSets(device, &allocate_info, &set) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        const old_allocation = self.uniform;
        const old_set = self.descriptor_set;
        self.uniform = replacement;
        self.descriptor_set = set;
        self.uniform_capacity = new_capacity;
        self.writeUniformDescriptor(set);

        // Keep the previous generation alive until the frame boundary.
        if (old_allocation.buffer != null) {
            self.retired_uniforms.append(self.allocator, old_allocation) catch return error.OutOfMemory;
        }
        if (old_set != null) {
            self.retired_uniform_sets.append(self.allocator, old_set.?) catch return error.OutOfMemory;
        }
    }

    /// Release uniform generations retired during the previous recording.
    /// Must only be called when the GPU is idle for this surface (start of a
    /// frame recording, after the surface's frame fence wait).
    fn flushRetiredUniforms(self: *Scene) void {
        const device = self.surface.device.?;
        for (self.retired_uniforms.items) |*allocation| destroyBuffer(device, allocation);
        self.retired_uniforms.clearRetainingCapacity();
        if (self.retired_uniform_sets.items.len > 0) {
            _ = c.vkFreeDescriptorSets(
                device,
                self.descriptor_pool.?,
                @intCast(self.retired_uniform_sets.items.len),
                self.retired_uniform_sets.items.ptr,
            );
            self.retired_uniform_sets.clearRetainingCapacity();
        }
    }

    fn writeUniformDescriptor(self: *Scene, set: c.VkDescriptorSet) void {
        var buffer_info = std.mem.zeroes(c.VkDescriptorBufferInfo);
        buffer_info.buffer = self.uniform.buffer.?;
        buffer_info.offset = 0;
        buffer_info.range = @sizeOf(Uniforms);
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = set;
        write.dstBinding = 0;
        write.descriptorCount = 1;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
        write.pBufferInfo = &buffer_info;
        c.vkUpdateDescriptorSets(self.surface.device.?, 1, &write, 0, null);
    }

    fn createUploadCommands(self: *Scene, device: c.VkDevice) Error!void {
        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        pool_info.queueFamilyIndex = self.surface.queue_family;
        var pool: c.VkCommandPool = null;
        if (c.vkCreateCommandPool(device, &pool_info, null, &pool) != c.VK_SUCCESS) return error.VulkanFailed;
        self.upload_pool = pool;

        var allocate_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        allocate_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        allocate_info.commandPool = pool;
        allocate_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        allocate_info.commandBufferCount = 1;
        var cmd: c.VkCommandBuffer = null;
        if (c.vkAllocateCommandBuffers(device, &allocate_info, &cmd) != c.VK_SUCCESS) return error.VulkanFailed;
        self.upload_cmd = cmd;

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        var fence: c.VkFence = null;
        if (c.vkCreateFence(device, &fence_info, null, &fence) != c.VK_SUCCESS) return error.VulkanFailed;
        self.upload_fence = fence;
    }

    fn beginUploadCommands(self: *Scene) Error!c.VkCommandBuffer {
        const cmd = self.upload_cmd.?;
        _ = c.vkResetCommandBuffer(cmd, 0);
        var begin = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        if (c.vkBeginCommandBuffer(cmd, &begin) != c.VK_SUCCESS) return error.VulkanFailed;
        return cmd;
    }

    fn submitUpload(self: *Scene) Error!void {
        const device = self.surface.device.?;
        const cmd = self.upload_cmd.?;
        const fence = self.upload_fence.?;
        if (c.vkEndCommandBuffer(cmd) != c.VK_SUCCESS) return error.VulkanFailed;
        var submit = std.mem.zeroes(c.VkSubmitInfo);
        submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1;
        submit.pCommandBuffers = &cmd;
        if (c.vkQueueSubmit(self.surface.queue.?, 1, &submit, fence) != c.VK_SUCCESS) {
            return error.VulkanFailed;
        }
        _ = c.vkWaitForFences(device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64));
        _ = c.vkResetFences(device, 1, &fence);
    }

    fn createDefaultSampler(self: *Scene, device: c.VkDevice) Error!void {
        var info = std.mem.zeroes(c.VkSamplerCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
        info.magFilter = c.VK_FILTER_LINEAR;
        info.minFilter = c.VK_FILTER_LINEAR;
        info.mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_LINEAR;
        info.addressModeU = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        info.addressModeV = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        info.addressModeW = c.VK_SAMPLER_ADDRESS_MODE_REPEAT;
        info.maxLod = 0.0;
        var sampler: c.VkSampler = null;
        if (c.vkCreateSampler(device, &info, null, &sampler) != c.VK_SUCCESS) return error.VulkanFailed;
        self.default_sampler = sampler;
    }

    fn writeTextureDescriptor(self: *Scene, set: c.VkDescriptorSet, view: c.VkImageView) void {
        var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info.imageView = view;
        image_info.imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        var sampler_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        sampler_info.sampler = self.default_sampler.?;
        var writes = [_]c.VkWriteDescriptorSet{
            std.mem.zeroes(c.VkWriteDescriptorSet),
            std.mem.zeroes(c.VkWriteDescriptorSet),
        };
        writes[0].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = set;
        writes[0].dstBinding = 1;
        writes[0].descriptorCount = 1;
        writes[0].descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        writes[0].pImageInfo = &image_info;
        writes[1].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = set;
        writes[1].dstBinding = 2;
        writes[1].descriptorCount = 1;
        writes[1].descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER;
        writes[1].pImageInfo = &sampler_info;
        c.vkUpdateDescriptorSets(self.surface.device.?, writes.len, &writes, 0, null);
    }

    /// Create a GPU texture from tightly packed top-down RGBA8 pixels.
    /// Returns the texture id; id 0 is the built-in white 1x1 texture.
    pub fn createTextureFromRgba(self: *Scene, width: u32, height: u32, pixels: []const u8) Error!u32 {
        if (width == 0 or height == 0) return error.InvalidTexture;
        if (pixels.len != @as(usize, width) * height * 4) return error.InvalidTexture;
        if (self.textures.items.len >= max_textures) return error.TextureLimit;
        const device = self.surface.device.?;

        var texture = Texture{};
        errdefer destroyTextureResources(device, &texture);

        var image_info = std.mem.zeroes(c.VkImageCreateInfo);
        image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
        image_info.imageType = c.VK_IMAGE_TYPE_2D;
        image_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        image_info.extent = .{ .width = width, .height = height, .depth = 1 };
        image_info.mipLevels = 1;
        image_info.arrayLayers = 1;
        image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
        image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
        image_info.usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;
        image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        var image: c.VkImage = null;
        if (c.vkCreateImage(device, &image_info, null, &image) != c.VK_SUCCESS) return error.VulkanFailed;
        texture.image = image;

        var requirements = std.mem.zeroes(c.VkMemoryRequirements);
        c.vkGetImageMemoryRequirements(device, image, &requirements);
        const memory_type = self.surface.memoryType(
            requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            null,
        ) catch return error.VulkanFailed;
        var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc_info.allocationSize = requirements.size;
        alloc_info.memoryTypeIndex = memory_type;
        var memory: c.VkDeviceMemory = null;
        if (c.vkAllocateMemory(device, &alloc_info, null, &memory) != c.VK_SUCCESS) return error.VulkanFailed;
        texture.memory = memory;
        if (c.vkBindImageMemory(device, image, memory, 0) != c.VK_SUCCESS) return error.VulkanFailed;

        var staging = try self.createHostBuffer(device, pixels.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        defer destroyBuffer(device, &staging);
        @memcpy(staging.mapped.?[0..pixels.len], pixels);

        const cmd = try self.beginUploadCommands();
        const subresource = c.VkImageSubresourceRange{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        };
        var to_dst = std.mem.zeroes(c.VkImageMemoryBarrier);
        to_dst.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        to_dst.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        to_dst.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_dst.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_dst.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_dst.image = image;
        to_dst.subresourceRange = subresource;
        to_dst.srcAccessMask = 0;
        to_dst.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
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
            &to_dst,
        );

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = width, .height = height, .depth = 1 };
        c.vkCmdCopyBufferToImage(
            cmd,
            staging.buffer.?,
            image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &region,
        );

        var to_sample = std.mem.zeroes(c.VkImageMemoryBarrier);
        to_sample.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        to_sample.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        to_sample.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        to_sample.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_sample.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_sample.image = image;
        to_sample.subresourceRange = subresource;
        to_sample.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        to_sample.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &to_sample,
        );
        try self.submitUpload();

        var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
        view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        view_info.image = image;
        view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
        view_info.format = c.VK_FORMAT_R8G8B8A8_UNORM;
        view_info.subresourceRange = subresource;
        var view: c.VkImageView = null;
        if (c.vkCreateImageView(device, &view_info, null, &view) != c.VK_SUCCESS) return error.VulkanFailed;
        texture.view = view;

        var allocate_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocate_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate_info.descriptorPool = self.texture_pool.?;
        allocate_info.descriptorSetCount = 1;
        allocate_info.pSetLayouts = &self.texture_set_layout.?;
        var set: c.VkDescriptorSet = null;
        if (c.vkAllocateDescriptorSets(device, &allocate_info, &set) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        texture.set = set;
        self.writeTextureDescriptor(set, view);

        const id: u32 = @intCast(self.textures.items.len);
        self.textures.append(self.allocator, texture) catch return error.OutOfMemory;
        return id;
    }

    /// Destroy a user texture.  Id 0 (the built-in white texture) cannot be
    /// destroyed; ids stay stable for the scene lifetime.
    pub fn destroyTexture(self: *Scene, id: u32) Error!void {
        if (id == 0 or id >= self.textures.items.len) return error.InvalidTexture;
        var texture = &self.textures.items[id];
        if (texture.destroyed) return error.InvalidTexture;
        const device = self.surface.device.?;
        if (texture.set) |set| _ = c.vkFreeDescriptorSets(device, self.texture_pool.?, 1, &set);
        destroyTextureResources(device, texture);
        texture.set = null;
        texture.destroyed = true;
    }

    fn textureSetFor(self: *Scene, id: u32) ?c.VkDescriptorSet {
        if (id >= self.textures.items.len) return null;
        const texture = &self.textures.items[id];
        if (texture.destroyed) return null;
        return texture.set;
    }

    /// Upload an interleaved OBJ-style mesh (vertex layout from
    /// `MeshLayout`) and return its mesh id (>= 1), or `error.InvalidMesh`.
    pub fn uploadMesh(self: *Scene, vertices: []const f32, indices: []const u32, layout: MeshLayout) Error!u64 {
        const stride = layout.floatsPerVertex();
        if (vertices.len == 0 or vertices.len % stride != 0) return error.InvalidMesh;
        if (indices.len == 0 or indices.len % 3 != 0) return error.InvalidMesh;
        const vertex_total = vertices.len / stride;
        if (vertex_total > std.math.maxInt(u32)) return error.InvalidMesh;

        var mesh_vertices = self.allocator.alloc(Vertex, vertex_total) catch return error.OutOfMemory;
        defer self.allocator.free(mesh_vertices);
        for (0..vertex_total) |index| {
            const base = index * stride;
            var vertex = Vertex{
                .position = .{ vertices[base], vertices[base + 1], vertices[base + 2] },
                .normal = .{ vertices[base + 3], vertices[base + 4], vertices[base + 5] },
                .color = .{ 1.0, 1.0, 1.0 },
            };
            if (layout == .pos_normal_color_uv) {
                vertex.color = .{ vertices[base + 6], vertices[base + 7], vertices[base + 8] };
                vertex.uv = .{ vertices[base + 9], vertices[base + 10] };
            } else {
                vertex.uv = .{ vertices[base + 6], vertices[base + 7] };
            }
            mesh_vertices[index] = vertex;
        }
        for (indices) |index| {
            if (index >= vertex_total) return error.InvalidMesh;
        }

        const device = self.surface.device.?;
        var mesh = Mesh{};
        errdefer {
            destroyBuffer(device, &mesh.vertex);
            destroyBuffer(device, &mesh.index);
        }
        if (vertex_total <= std.math.maxInt(u16)) {
            var converted = self.allocator.alloc(u16, indices.len) catch return error.OutOfMemory;
            defer self.allocator.free(converted);
            for (indices, 0..) |index, at| converted[at] = @intCast(index);
            mesh = try self.createMesh(
                device,
                mesh_vertices,
                std.mem.sliceAsBytes(converted),
                @intCast(indices.len),
                c.VK_INDEX_TYPE_UINT16,
            );
        } else {
            mesh = try self.createMesh(
                device,
                mesh_vertices,
                std.mem.sliceAsBytes(indices),
                @intCast(indices.len),
                c.VK_INDEX_TYPE_UINT32,
            );
        }

        self.custom_meshes.append(self.allocator, .{ .mesh = mesh }) catch return error.OutOfMemory;
        return @intCast(self.custom_meshes.items.len);
    }

    fn meshFor(self: *Scene, ref: MeshRef) ?*Mesh {
        return switch (ref) {
            .builtin => |shape| &self.meshes[@intFromEnum(shape)],
            .custom => |id| blk: {
                if (id == 0 or id > self.custom_meshes.items.len) break :blk null;
                const custom = &self.custom_meshes.items[id - 1];
                if (custom.destroyed) break :blk null;
                break :blk &custom.mesh;
            },
        };
    }

    fn createDescriptors(self: *Scene, device: c.VkDevice) Error!void {
        // Set 0: per-object dynamic uniform buffer.
        var uniform_binding = std.mem.zeroes(c.VkDescriptorSetLayoutBinding);
        uniform_binding.binding = 0;
        uniform_binding.descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
        uniform_binding.descriptorCount = 1;
        uniform_binding.stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;
        var uniform_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        uniform_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        uniform_layout_info.bindingCount = 1;
        uniform_layout_info.pBindings = &uniform_binding;
        var uniform_layout: c.VkDescriptorSetLayout = null;
        if (c.vkCreateDescriptorSetLayout(device, &uniform_layout_info, null, &uniform_layout) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.descriptor_set_layout = uniform_layout;

        // Set 1: per-material sampled image + sampler.
        var texture_bindings = [_]c.VkDescriptorSetLayoutBinding{
            std.mem.zeroes(c.VkDescriptorSetLayoutBinding),
            std.mem.zeroes(c.VkDescriptorSetLayoutBinding),
        };
        texture_bindings[0].binding = 1;
        texture_bindings[0].descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        texture_bindings[0].descriptorCount = 1;
        texture_bindings[0].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        texture_bindings[1].binding = 2;
        texture_bindings[1].descriptorType = c.VK_DESCRIPTOR_TYPE_SAMPLER;
        texture_bindings[1].descriptorCount = 1;
        texture_bindings[1].stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT;
        var texture_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        texture_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        texture_layout_info.bindingCount = texture_bindings.len;
        texture_layout_info.pBindings = &texture_bindings;
        var texture_layout: c.VkDescriptorSetLayout = null;
        if (c.vkCreateDescriptorSetLayout(device, &texture_layout_info, null, &texture_layout) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.texture_set_layout = texture_layout;

        // Uniform pool: one set per uniform-buffer generation.  Freed sets are
        // returned to the pool at frame boundaries.
        var uniform_pool_size = std.mem.zeroes(c.VkDescriptorPoolSize);
        uniform_pool_size.type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC;
        uniform_pool_size.descriptorCount = 1024;
        var uniform_pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        uniform_pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        uniform_pool_info.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        uniform_pool_info.maxSets = 1024;
        uniform_pool_info.poolSizeCount = 1;
        uniform_pool_info.pPoolSizes = &uniform_pool_size;
        var uniform_pool: c.VkDescriptorPool = null;
        if (c.vkCreateDescriptorPool(device, &uniform_pool_info, null, &uniform_pool) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.descriptor_pool = uniform_pool;

        // Texture pool: one set per combined image sampler.
        var texture_pool_sizes = [_]c.VkDescriptorPoolSize{
            std.mem.zeroes(c.VkDescriptorPoolSize),
            std.mem.zeroes(c.VkDescriptorPoolSize),
        };
        texture_pool_sizes[0].type = c.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        texture_pool_sizes[0].descriptorCount = max_textures;
        texture_pool_sizes[1].type = c.VK_DESCRIPTOR_TYPE_SAMPLER;
        texture_pool_sizes[1].descriptorCount = max_textures;
        var texture_pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        texture_pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        texture_pool_info.flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT;
        texture_pool_info.maxSets = max_textures;
        texture_pool_info.poolSizeCount = texture_pool_sizes.len;
        texture_pool_info.pPoolSizes = &texture_pool_sizes;
        var texture_pool: c.VkDescriptorPool = null;
        if (c.vkCreateDescriptorPool(device, &texture_pool_info, null, &texture_pool) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.texture_pool = texture_pool;

        var allocate_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        allocate_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        allocate_info.descriptorPool = uniform_pool;
        allocate_info.descriptorSetCount = 1;
        allocate_info.pSetLayouts = &uniform_layout;
        var set: c.VkDescriptorSet = null;
        if (c.vkAllocateDescriptorSets(device, &allocate_info, &set) != c.VK_SUCCESS) {
            return error.DescriptorCreateFailed;
        }
        self.descriptor_set = set;
        self.writeUniformDescriptor(set);

        var set_layouts = [_]c.VkDescriptorSetLayout{ uniform_layout, texture_layout };
        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = set_layouts.len;
        pipeline_layout_info.pSetLayouts = &set_layouts;
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
        attributes[3].location = 3;
        attributes[3].binding = 0;
        attributes[3].format = c.VK_FORMAT_R32G32_SFLOAT;
        attributes[3].offset = @intCast(@offsetOf(Vertex, "uv"));

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

    fn writeUniformSlot(self: *Scene, slot: usize, model: Mat4, tint: [4]f32) void {
        const extent = self.surface.extent;
        const aspect = if (extent.height == 0)
            1.0
        else
            @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height));

        const view = matView(self.camera.eye, self.camera.yaw, self.camera.pitch);
        const proj = matPerspective(default_fov_y, aspect, default_near, default_far);

        self.uniformSlot(slot).* = .{
            .model = model,
            .view = view,
            .proj = proj,
            .camera_pos = .{ self.camera.eye[0], self.camera.eye[1], self.camera.eye[2], 1.0 },
            .light_pos = .{ self.light_position[0], self.light_position[1], self.light_position[2], 1.0 },
            .light_color = self.light_color,
            .params = self.ambient,
            .tint = tint,
        };
    }

    /// Bind the pipeline, dynamic viewport/scissor, and the shared cube
    /// vertex/index buffers.  Per-object draws then only bind their dynamic
    /// uniform slot and record an indexed draw.
    fn recordFrameSetup(self: *Scene, cmd: c.VkCommandBuffer) void {
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
    }

    /// Reset the recorded-object list and bind the shared pipeline state for
    /// the render pass that is currently open.
    fn beginRecordedFrame(self: *Scene, cmd: c.VkCommandBuffer) Error!void {
        // The surface waited on its frame fence before this point, so any
        // generations retired by the previous frame are no longer referenced.
        self.flushRetiredUniforms();
        self.recorded_objects.clearRetainingCapacity();
        // Keep the uniform buffer at least as large as the previous frame's
        // demand so steady-state frames do not grow mid-recording.
        try self.ensureUniformCapacity(self.recorded_objects.capacity);
        self.flushRetiredUniforms();
        self.recordFrameSetup(cmd);
    }

    /// Write `model`/`tint` into the next per-object uniform slot and record
    /// one indexed draw of `mesh` bound to the `texture` material.  Grows the
    /// uniform buffer/list on demand, so there is no fixed per-frame object
    /// cap; only allocator/descriptor limits return an error.
    fn recordObject(
        self: *Scene,
        cmd: c.VkCommandBuffer,
        model: Mat4,
        tint: [4]f32,
        mesh_ref: MeshRef,
        texture_id: u32,
    ) Error!void {
        const mesh = self.meshFor(mesh_ref) orelse return error.InvalidMesh;
        const texture_set = self.textureSetFor(texture_id) orelse return error.InvalidTexture;

        const slot = self.recorded_objects.items.len;
        try self.ensureUniformCapacity(slot + 1);
        self.recorded_objects.append(self.allocator, .{
            .model = model,
            .tint = tint,
            .mesh = mesh_ref,
            .texture = texture_id,
        }) catch return error.OutOfMemory;
        self.writeUniformSlot(slot, model, tint);

        var vertex_buffer = mesh.vertex.buffer.?;
        var vertex_offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(cmd, 0, 1, &vertex_buffer, &vertex_offset);
        c.vkCmdBindIndexBuffer(cmd, mesh.index.buffer.?, 0, mesh.index_type);

        var descriptor_sets = [2]c.VkDescriptorSet{ self.descriptor_set.?, texture_set };
        var dynamic_offset: u32 = @intCast(slot * self.uniform_stride);
        c.vkCmdBindDescriptorSets(
            cmd,
            c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout.?,
            0,
            2,
            &descriptor_sets,
            1,
            &dynamic_offset,
        );
        c.vkCmdDrawIndexed(cmd, mesh.index_count, 1, 0, 0, 0);
    }

    /// Model matrix used by the legacy single-cube entry points (`drawMesh`,
    /// `draw`, `captureFrame`): a Y spin plus the original fixed X tilt.
    fn legacyCubeModel(self: *Scene) Mat4 {
        return matMul(matRotationY(self.spin), matRotationX(0.35));
    }

    /// Begin a presentable frame: acquire the swapchain image, rebuild the
    /// pipeline if needed, and open the render pass.  e7 calls this, then one
    /// or more `drawBox`/`drawMesh` calls, then `endFrame`.
    pub fn beginFrame(self: *Scene) Error!void {
        if (self.frame_index != null) return error.FrameAlreadyActive;
        self.frame_index = try self.surface.acquireFrame();
        try self.ensurePipeline();
        const cmd = self.surface.beginScene(self.clear_color, default_clear_depth) catch |err| {
            self.frame_index = null;
            return err;
        };
        self.frame_cmd = cmd;
        self.beginRecordedFrame(cmd) catch |err| {
            self.frame_cmd = null;
            self.frame_index = null;
            return err;
        };
    }

    /// Draw one box (position, scale, Y angle) in the frame opened by
    /// `beginFrame`.  Every object shares the frame's camera and light.
    pub fn drawBox(self: *Scene, box: Box) Error!void {
        return self.drawShape(.box, box, .{ 1.0, 1.0, 1.0 });
    }

    /// Draw one procedural shape (box/sphere/capsule/plane) with a per-object
    /// RGB tint in the frame opened by `beginFrame` (white material texture).
    pub fn drawShape(self: *Scene, shape: Shape, box: Box, tint: Vec3) Error!void {
        return self.drawShapeTextured(shape, box, tint, 0);
    }

    /// Draw one procedural shape with an explicit material texture id.
    pub fn drawShapeTextured(self: *Scene, shape: Shape, box: Box, tint: Vec3, texture_id: u32) Error!void {
        const cmd = self.frame_cmd orelse return error.FrameNotActive;
        const tint4 = [4]f32{ tint[0], tint[1], tint[2], 1.0 };
        try self.recordObject(cmd, boxModel(box), tint4, .{ .builtin = shape }, texture_id);
    }

    /// Draw a mesh uploaded with `uploadMesh`, with an explicit material
    /// texture id, in the frame opened by `beginFrame`.
    pub fn drawCustom(self: *Scene, mesh_id: u64, box: Box, tint: Vec3, texture_id: u32) Error!void {
        const cmd = self.frame_cmd orelse return error.FrameNotActive;
        const tint4 = [4]f32{ tint[0], tint[1], tint[2], 1.0 };
        try self.recordObject(cmd, boxModel(box), tint4, .{ .custom = mesh_id }, texture_id);
    }

    /// Record the built-in single cube for the frame opened by `beginFrame`.
    /// Kept for the pre-multi-object path and back-compat tests.
    pub fn drawMesh(self: *Scene) void {
        const cmd = self.frame_cmd orelse return;
        self.recordObject(cmd, self.legacyCubeModel(), default_tint, .{ .builtin = .box }, 0) catch {};
    }

    /// Close the render pass and present the acquired image.
    pub fn endFrame(self: *Scene) Error!void {
        const index = self.frame_index orelse return error.FrameNotActive;
        self.frame_cmd = null;
        self.frame_index = null;
        try self.surface.endScenePresent(index);
    }

    /// Render one single-cube frame and present it to the window.
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
        const cmd = try self.surface.beginScene(self.clear_color, default_clear_depth);
        try self.beginRecordedFrame(cmd);
        try self.recordObject(cmd, self.legacyCubeModel(), default_tint, .{ .builtin = .box }, 0);
        try self.surface.endScenePresent(index);
    }

    /// Render one single-cube frame into the offscreen target and return
    /// tightly packed RGBA8 pixels.  Caller owns the slice (same allocator as
    /// the scene).
    pub fn captureFrame(
        self: *Scene,
        cube_angle: f32,
        light_position: Vec3,
    ) Error![]u8 {
        self.spin = cube_angle;
        self.light_position = light_position;

        const cmd = try self.surface.beginSceneCapture(self.clear_color, default_clear_depth);
        try self.ensurePipeline();
        try self.beginRecordedFrame(cmd);
        try self.recordObject(cmd, self.legacyCubeModel(), default_tint, .{ .builtin = .box }, 0);
        return self.surface.endSceneCapture();
    }

    /// Render the objects recorded by the current/last frame (camera state is
    /// the scene's current camera/light) and return RGBA8 pixels.  The engine
    /// frame limiter uses this so a headless capture contains every object that
    /// was drawn, not just the legacy single cube.
    pub fn captureRecordedFrame(self: *Scene) Error![]u8 {
        const saved_count = self.recorded_objects.items.len;
        const saved = self.allocator.alloc(RecordedObject, saved_count) catch return error.OutOfMemory;
        defer self.allocator.free(saved);
        @memcpy(saved, self.recorded_objects.items[0..saved_count]);

        const cmd = try self.surface.beginSceneCapture(self.clear_color, default_clear_depth);
        try self.ensurePipeline();
        try self.beginRecordedFrame(cmd);
        if (saved_count == 0) {
            try self.recordObject(cmd, self.legacyCubeModel(), default_tint, .{ .builtin = .box }, 0);
        } else {
            for (saved) |object| {
                try self.recordObject(cmd, object.model, object.tint, object.mesh, object.texture);
            }
        }
        return self.surface.endSceneCapture();
    }

    /// Number of objects recorded for the current/last frame (test and
    /// diagnostics hook).
    pub fn recordedObjectCount(self: *const Scene) usize {
        return self.recorded_objects.items.len;
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

    // Pitch must rotate the camera around the eye, not translate it: the eye
    // stays at the view-space origin for every pitch.
    const pitched = matView(eye, 0.0, std.math.degreesToRadians(35.0));
    const eye_pitched = Vec3{
        pitched[0][0] * eye[0] + pitched[1][0] * eye[1] + pitched[2][0] * eye[2] + pitched[3][0],
        pitched[0][1] * eye[0] + pitched[1][1] * eye[1] + pitched[2][1] * eye[2] + pitched[3][1],
        pitched[0][2] * eye[0] + pitched[1][2] * eye[1] + pitched[2][2] * eye[2] + pitched[3][2],
    };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_pitched[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_pitched[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), eye_pitched[2], 1e-5);
}

test "cube geometry is consistent" {
    try std.testing.expectEqual(@as(usize, 24), cube_vertices.len);
    try std.testing.expectEqual(@as(usize, 36), cube_indices.len);
    try std.testing.expectEqual(@as(usize, 272), @sizeOf(Uniforms));
    try std.testing.expectEqual(@as(usize, 4), shape_count);
    // Procedural meshes are non-empty and every index is in range.
    try std.testing.expect(sphere_indices.len > 0 and capsule_indices.len > 0);
    for (sphere_indices) |index| try std.testing.expect(index < sphere_vertex_count);
    for (capsule_indices) |index| try std.testing.expect(index < capsule_vertex_count);
    for (plane_indices) |index| try std.testing.expect(index < plane_vertices.len);
    // Unit sphere vertices sit on the unit sphere with outward normals.
    for (sphere_vertices) |vertex| {
        const length_squared = vertex.position[0] * vertex.position[0] +
            vertex.position[1] * vertex.position[1] +
            vertex.position[2] * vertex.position[2];
        try std.testing.expectApproxEqAbs(@as(f32, 1.0), length_squared, 1e-5);
    }
    // Capsule spans y in [-2, 2] and radius 1 on the cylinder.
    var min_y: f32 = 1e9;
    var max_y: f32 = -1e9;
    for (capsule_vertices) |vertex| {
        min_y = @min(min_y, vertex.position[1]);
        max_y = @max(max_y, vertex.position[1]);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -2.0), min_y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), max_y, 1e-5);
    for (plane_vertices) |vertex| try std.testing.expectEqual(@as(f32, 0.0), vertex.position[1]);
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

test "scene draws multiple boxes at distinct positions" {
    var window = window_mod.Window.create("engine7 multi-box test", 320, 240, .{
        .hidden = true,
        .vulkan = true,
    }, null) catch |err| {
        std.debug.print("skipping multi-box render test (no display): {s}\n", .{@errorName(err)});
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
        std.debug.print("skipping multi-box render test (no Vulkan): {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer scene.deinit();

    const light = Vec3{ 2.5, 3.0, 2.0 };
    const boxes = [_]Box{
        .{ .position = .{ 0.0, 0.0, 0.0 }, .scale = .{ 0.6, 0.6, 0.6 }, .angle = 0.0 },
        .{ .position = .{ 2.0, 0.0, 0.0 }, .scale = .{ 0.5, 0.5, 0.5 }, .angle = 0.6 },
        .{ .position = .{ -2.0, 0.5, 0.5 }, .scale = .{ 0.8, 0.4, 0.8 }, .angle = -0.4 },
    };

    // Drawing requires an active frame.
    try std.testing.expectError(error.FrameNotActive, scene.drawBox(boxes[0]));

    // Reference single-cube capture with the same camera/light.
    const single = try scene.captureFrame(0.0, light);
    defer std.testing.allocator.free(single);

    try scene.beginFrame();
    for (boxes) |box| try scene.drawBox(box);
    try std.testing.expectEqual(boxes.len, scene.recordedObjectCount());
    try scene.endFrame();

    const multi = try scene.captureRecordedFrame();
    defer std.testing.allocator.free(multi);
    try std.testing.expect(multi.len == single.len);
    try std.testing.expect(!std.mem.eql(u8, single, multi));

    const size = scene.size();
    const background: u32 = @as(u32, multi[0]) + multi[1] + multi[2];
    var lit_pixels: usize = 0;
    var index: usize = 0;
    while (index + 3 < multi.len) : (index += 4) {
        const sum: u32 = @as(u32, multi[index]) + multi[index + 1] + multi[index + 2];
        if (sum > background + 60) lit_pixels += 1;
        try std.testing.expectEqual(@as(u8, 255), multi[index + 3]);
    }
    try std.testing.expect(lit_pixels > 300);

    // Every box centre must project to a non-background pixel, proving the
    // per-object model matrices moved each draw off the origin.
    const Project = struct {
        fn transform(m: Mat4, v: [4]f32) [4]f32 {
            var out = [4]f32{ 0, 0, 0, 0 };
            for (0..4) |col| {
                for (0..4) |row| out[row] += m[col][row] * v[col];
            }
            return out;
        }

        fn pixel(view_scene: *const Scene, point: Vec3) struct { x: usize, y: usize } {
            const extent = view_scene.surface.extent;
            const aspect = @as(f32, @floatFromInt(extent.width)) / @as(f32, @floatFromInt(extent.height));
            const view = matView(view_scene.camera.eye, view_scene.camera.yaw, view_scene.camera.pitch);
            const proj = matPerspective(default_fov_y, aspect, default_near, default_far);
            const clip = transform(proj, transform(view, .{ point[0], point[1], point[2], 1.0 }));
            const inv_w = 1.0 / clip[3];
            const ndc_x = clip[0] * inv_w;
            const ndc_y = clip[1] * inv_w;
            const x: usize = @intFromFloat(@max(0.0, @min(1.0, ndc_x * 0.5 + 0.5)) * @as(f32, @floatFromInt(extent.width - 1)));
            const y: usize = @intFromFloat(@max(0.0, @min(1.0, ndc_y * 0.5 + 0.5)) * @as(f32, @floatFromInt(extent.height - 1)));
            return .{ .x = x, .y = y };
        }
    };

    for (boxes) |box| {
        const at = Project.pixel(&scene, box.position);
        const offset = (at.y * size.width + at.x) * 4;
        const sum: u32 = @as(u32, multi[offset]) + multi[offset + 1] + multi[offset + 2];
        try std.testing.expect(sum > background + 40);
    }

    // The object count is dynamic: a few hundred boxes fit in one frame and
    // the uniform buffer grows past its initial capacity.
    try scene.beginFrame();
    const many = 300;
    for (0..many) |box_index| {
        const f = @as(f32, @floatFromInt(box_index));
        const x = (f - @as(f32, @floatFromInt(many)) * 0.5) * 0.02;
        const y = 0.3 * @sin(f * 0.3);
        try scene.drawBox(.{
            .position = .{ x, y, 0.5 },
            .scale = .{ 0.05, 0.05, 0.05 },
            .angle = f * 0.1,
        });
    }
    try std.testing.expectEqual(@as(usize, many), scene.recordedObjectCount());
    try scene.endFrame();
    const many_frame = try scene.captureRecordedFrame();
    defer std.testing.allocator.free(many_frame);
    var many_lit: usize = 0;
    var many_index: usize = 0;
    while (many_index + 3 < many_frame.len) : (many_index += 4) {
        const sum: u32 = @as(u32, many_frame[many_index]) + many_frame[many_index + 1] + many_frame[many_index + 2];
        if (sum > background + 60) many_lit += 1;
    }
    try std.testing.expect(many_lit > 300);
}

test "scene renders sphere, capsule, and plane geometry with per-object tint" {
    var window = window_mod.Window.create("engine7 shape test", 256, 192, .{
        .hidden = true,
        .vulkan = true,
    }, null) catch |err| {
        std.debug.print("skipping shape render test (no display): {s}\n", .{@errorName(err)});
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
        std.debug.print("skipping shape render test (no Vulkan): {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer scene.deinit();
    scene.setCamera(.{ 0.0, 1.8, 5.5 }, 0.0, -0.35);
    scene.setLight(.{ 2.0, 4.0, 3.0 }, .{ 1.0, 0.95, 0.9, 2.5 });

    const Capture = struct {
        fn single(
            target: *Scene,
            shape: Shape,
            box: Box,
            tint: Vec3,
        ) Error![]u8 {
            try target.beginFrame();
            try target.drawShape(shape, box, tint);
            try target.endFrame();
            return target.captureRecordedFrame();
        }
    };

    const unit_box = Box{ .position = .{ 0.0, 0.0, 0.0 }, .scale = .{ 0.8, 0.8, 0.8 } };
    const white = Vec3{ 1.0, 1.0, 1.0 };
    const box_frame = try Capture.single(&scene, .box, unit_box, white);
    defer std.testing.allocator.free(box_frame);
    const sphere_frame = try Capture.single(&scene, .sphere, unit_box, white);
    defer std.testing.allocator.free(sphere_frame);
    const capsule_frame = try Capture.single(&scene, .capsule, unit_box, white);
    defer std.testing.allocator.free(capsule_frame);
    const plane_frame = try Capture.single(&scene, .plane, .{
        .position = .{ 0.0, 0.0, 0.0 },
        .scale = .{ 4.0, 0.1, 4.0 },
    }, white);
    defer std.testing.allocator.free(plane_frame);

    // Real geometry differs from the box proxy (not a silhouette swap).
    try std.testing.expect(!std.mem.eql(u8, box_frame, sphere_frame));
    try std.testing.expect(!std.mem.eql(u8, box_frame, capsule_frame));
    try std.testing.expect(!std.mem.eql(u8, box_frame, plane_frame));
    try std.testing.expect(!std.mem.eql(u8, sphere_frame, capsule_frame));

    const background: u32 = @as(u32, sphere_frame[0]) + sphere_frame[1] + sphere_frame[2];
    for ([_][]const u8{ box_frame, sphere_frame, capsule_frame, plane_frame }) |frame| {
        var lit: usize = 0;
        var at: usize = 0;
        while (at + 3 < frame.len) : (at += 4) {
            const sum: u32 = @as(u32, frame[at]) + frame[at + 1] + frame[at + 2];
            if (sum > background + 60) lit += 1;
        }
        try std.testing.expect(lit > 200);
    }

    // Per-object tint changes the rendered pixels: red vs blue sphere.
    const red_frame = try Capture.single(&scene, .sphere, unit_box, .{ 1.0, 0.1, 0.1 });
    defer std.testing.allocator.free(red_frame);
    const blue_frame = try Capture.single(&scene, .sphere, unit_box, .{ 0.1, 0.1, 1.0 });
    defer std.testing.allocator.free(blue_frame);
    try std.testing.expect(!std.mem.eql(u8, red_frame, blue_frame));

    const ChannelSums = struct {
        fn sums(frame: []const u8) struct { r: usize, b: usize } {
            var r: usize = 0;
            var b: usize = 0;
            var at: usize = 0;
            while (at + 3 < frame.len) : (at += 4) {
                r += frame[at];
                b += frame[at + 2];
            }
            return .{ .r = r, .b = b };
        }
    };
    const red = ChannelSums.sums(red_frame);
    const blue = ChannelSums.sums(blue_frame);
    try std.testing.expect(red.r > red.b);
    try std.testing.expect(blue.b > blue.r);
}

test "scene samples GPU textures and draws uploaded custom meshes" {
    var window = window_mod.Window.create("engine7 texture/mesh test", 256, 192, .{
        .hidden = true,
        .vulkan = true,
    }, null) catch |err| {
        std.debug.print("skipping texture/mesh test (no display): {s}\n", .{@errorName(err)});
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
        std.debug.print("skipping texture/mesh test (no Vulkan): {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer scene.deinit();
    scene.setCamera(.{ 0.0, 1.8, 5.5 }, 0.0, -0.25);
    scene.setLight(.{ 2.0, 4.0, 3.0 }, .{ 1.0, 0.95, 0.9, 2.5 });

    const Capture = struct {
        fn single(
            target: *Scene,
            shape: Shape,
            box: Box,
            tint: Vec3,
            texture: u32,
        ) Error![]u8 {
            try target.beginFrame();
            try target.drawShapeTextured(shape, box, tint, texture);
            try target.endFrame();
            return target.captureRecordedFrame();
        }
    };

    const box = Box{ .position = .{ 0.0, 0.0, 0.0 }, .scale = .{ 0.9, 0.9, 0.9 } };
    const white = Vec3{ 1.0, 1.0, 1.0 };

    // 4x4 checker texture: red and blue cells.
    var checker: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const at = (y * 4 + x) * 4;
            const red = (x + y) % 2 == 0;
            checker[at + 0] = if (red) 255 else 20;
            checker[at + 1] = 20;
            checker[at + 2] = if (red) 20 else 255;
            checker[at + 3] = 255;
        }
    }
    const texture_id = try scene.createTextureFromRgba(4, 4, &checker);
    try std.testing.expect(texture_id == 1);

    const tinted = try Capture.single(&scene, .box, box, white, 0);
    defer std.testing.allocator.free(tinted);
    const textured = try Capture.single(&scene, .box, box, white, texture_id);
    defer std.testing.allocator.free(textured);
    try std.testing.expect(!std.mem.eql(u8, tinted, textured));

    // Upload a custom mesh built from the built-in cube geometry, in the
    // 8-float pos/normal/uv layout produced by engine/obj.e7.
    var interleaved = std.testing.allocator.alloc(f32, cube_vertices.len * 8) catch return error.OutOfMemory;
    defer std.testing.allocator.free(interleaved);
    for (cube_vertices, 0..) |vertex, at| {
        const base = at * 8;
        interleaved[base + 0] = vertex.position[0];
        interleaved[base + 1] = vertex.position[1];
        interleaved[base + 2] = vertex.position[2];
        interleaved[base + 3] = vertex.normal[0];
        interleaved[base + 4] = vertex.normal[1];
        interleaved[base + 5] = vertex.normal[2];
        interleaved[base + 6] = vertex.uv[0];
        interleaved[base + 7] = vertex.uv[1];
    }
    var indices = std.testing.allocator.alloc(u32, cube_indices.len) catch return error.OutOfMemory;
    defer std.testing.allocator.free(indices);
    for (cube_indices, 0..) |index, at| indices[at] = index;

    const mesh_id = try scene.uploadMesh(interleaved, indices, .pos_normal_uv);
    try std.testing.expect(mesh_id >= 1);

    // Custom mesh with the checker texture must render content distinct from
    // the built-in box (different UV mapping / geometry path).
    try scene.beginFrame();
    try scene.drawCustom(mesh_id, Box{ .position = .{ 1.6, 0.0, 0.0 }, .scale = .{ 0.7, 0.7, 0.7 } }, white, texture_id);
    try scene.endFrame();
    const custom = try scene.captureRecordedFrame();
    defer std.testing.allocator.free(custom);
    try std.testing.expect(!std.mem.eql(u8, custom, textured));
    var lit: usize = 0;
    var at: usize = 0;
    while (at + 3 < custom.len) : (at += 4) {
        const sum: u32 = @as(u32, custom[at]) + custom[at + 1] + custom[at + 2];
        if (sum > 60) lit += 1;
    }
    try std.testing.expect(lit > 200);

    // Invalid material / mesh ids are rejected.
    try scene.beginFrame();
    try std.testing.expectError(error.InvalidTexture, scene.drawShapeTextured(.box, box, white, 999));
    try std.testing.expectError(error.InvalidMesh, scene.drawCustom(999, box, white, 0));
    try scene.endFrame();

    try scene.destroyTexture(texture_id);
    try std.testing.expectError(error.InvalidTexture, scene.destroyTexture(texture_id));
}

test "scene renders full X/Y/Z Euler orientation, not just Y" {
    var window = window_mod.Window.create("engine7 orientation test", 256, 192, .{
        .hidden = true,
        .vulkan = true,
    }, null) catch |err| {
        std.debug.print("skipping orientation test (no display): {s}\n", .{@errorName(err)});
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
        std.debug.print("skipping orientation test (no Vulkan): {s} ({s})\n", .{ @errorName(err), abi.lastError() });
        return;
    };
    defer scene.deinit();
    scene.setCamera(.{ 0.8, 1.8, 4.8 }, 0.0, -0.25);
    scene.setLight(.{ 2.0, 4.0, 3.0 }, .{ 1.0, 0.95, 0.9, 2.5 });

    const Capture = struct {
        fn single(target: *Scene, box: Box, tint: Vec3, texture: u32) Error![]u8 {
            try target.beginFrame();
            try target.drawShapeTextured(.box, box, tint, texture);
            try target.endFrame();
            return target.captureRecordedFrame();
        }
    };

    // Asymmetric scale makes X/Y/Z rotations produce distinct silhouettes.
    const base = Box{
        .position = .{ 0.0, 0.0, 0.0 },
        .scale = .{ 0.9, 0.45, 0.65 },
        .angle = 0.0,
    };
    const white = Vec3{ 1.0, 1.0, 1.0 };
    const quarter_turn = std.math.pi * 0.5;

    var identity_box = base;
    identity_box.rotation = .{ 0.0, 0.0, 0.0 };
    const identity = try Capture.single(&scene, identity_box, white, 0);
    defer std.testing.allocator.free(identity);

    var rotate_x = base;
    rotate_x.rotation = .{ quarter_turn, 0.0, 0.0 };
    const x90 = try Capture.single(&scene, rotate_x, white, 0);
    defer std.testing.allocator.free(x90);

    var rotate_y = base;
    rotate_y.rotation = .{ 0.0, quarter_turn, 0.0 };
    const y90 = try Capture.single(&scene, rotate_y, white, 0);
    defer std.testing.allocator.free(y90);

    var rotate_z = base;
    rotate_z.rotation = .{ 0.0, 0.0, quarter_turn };
    const z90 = try Capture.single(&scene, rotate_z, white, 0);
    defer std.testing.allocator.free(z90);

    // X=90 and Y=90 must not be the same image (previously only Y was applied).
    try std.testing.expect(!std.mem.eql(u8, x90, y90));
    try std.testing.expect(!std.mem.eql(u8, identity, x90));
    try std.testing.expect(!std.mem.eql(u8, identity, y90));
    try std.testing.expect(!std.mem.eql(u8, identity, z90));

    // Combined X/Z tilt (tumbling) must differ from any single-axis rotation.
    var tumble_box = base;
    tumble_box.rotation = .{ std.math.pi * 0.25, 0.0, std.math.pi * 0.25 };
    const tumble = try Capture.single(&scene, tumble_box, white, 0);
    defer std.testing.allocator.free(tumble);
    try std.testing.expect(!std.mem.eql(u8, identity, tumble));
    try std.testing.expect(!std.mem.eql(u8, x90, tumble));

    const background: u32 = @as(u32, identity[0]) + identity[1] + identity[2];
    for ([_][]const u8{ identity, x90, y90, z90, tumble }) |frame| {
        var lit: usize = 0;
        var at: usize = 0;
        while (at + 3 < frame.len) : (at += 4) {
            const sum: u32 = @as(u32, frame[at]) + frame[at + 1] + frame[at + 2];
            if (sum > background + 60) lit += 1;
        }
        try std.testing.expect(lit > 150);
    }

    // A custom mesh also takes the full Euler orientation.
    var interleaved = std.testing.allocator.alloc(f32, cube_vertices.len * 8) catch return error.OutOfMemory;
    defer std.testing.allocator.free(interleaved);
    for (cube_vertices, 0..) |vertex, at| {
        const offset = at * 8;
        interleaved[offset + 0] = vertex.position[0];
        interleaved[offset + 1] = vertex.position[1];
        interleaved[offset + 2] = vertex.position[2];
        interleaved[offset + 3] = vertex.normal[0];
        interleaved[offset + 4] = vertex.normal[1];
        interleaved[offset + 5] = vertex.normal[2];
        interleaved[offset + 6] = vertex.uv[0];
        interleaved[offset + 7] = vertex.uv[1];
    }
    var indices = std.testing.allocator.alloc(u32, cube_indices.len) catch return error.OutOfMemory;
    defer std.testing.allocator.free(indices);
    for (cube_indices, 0..) |index, at| indices[at] = index;
    const mesh_id = try scene.uploadMesh(interleaved, indices, .pos_normal_uv);
    var custom_x = base;
    custom_x.rotation = .{ quarter_turn, 0.0, 0.0 };
    try scene.beginFrame();
    try scene.drawCustom(mesh_id, custom_x, white, 0);
    try scene.endFrame();
    const custom_frame = try scene.captureRecordedFrame();
    defer std.testing.allocator.free(custom_frame);
    try std.testing.expect(!std.mem.eql(u8, custom_frame, identity));
}

# Higher-order asset server

`engine/assets/server.e7` scans an asset directory tree with a caller-supplied
function value and aggregates the processed files.  `engine/assets/main.e7`
builds the concrete image/mesh/audio collections, the `AssetServer` resource,
and the plugin that owns their lifetime.

## Directory layout

`AssetServerPlugin` scans three cwd-relative roots:

```
engine/assets/images/<folder>/<name>.png|jpg   -> Image
engine/assets/meshes/<folder>/<name>.obj       -> ObjMesh
engine/assets/audio/<folder>/<name>.wav        -> AudioClip
```

The current checked-in samples are:

```
engine/assets/images/cube/cube.png
engine/assets/meshes/cube/cube.obj
engine/assets/audio/sfx/tone.wav
```

Relative keys are rooted at the category directory, e.g.
`server.image("cube/cube.png")`, `server.mesh("cube/cube.obj")`,
`server.audio("sfx/tone.wav")`.  The older flat paths
(`engine/assets/testdata/cube.png`, `engine/assets/cube.obj`,
`engine/assets/testdata/tone.wav`) stay in place because tests and the
`AssetsPlugin` fallback use them.

## Directory listing ABI

The runtime adds one SDL/Vulkan-free host helper:

```
host::list_dir(path) -> str        # e7_engine_list_dir
```

It lists one cwd-relative directory level in the same format as the runtime
filesystem sandbox: one entry name per line, directories suffixed with `/`,
sorted by name for deterministic scans.  A missing/unreadable directory returns
0, which the scan treats as an empty listing.  `host::read_asset(path)` is an
alias of `host::read_shader(path)` (the generic cwd-relative asset text
reader).

## API

```e7
pub AssetCollection<T> <- struct
    files: map[str, T]
    folders: map[str, map[str, T]]

pub scan_assets<T>(root: str, process: (str) -> T) -> AssetCollection<T>
```

* `process` is a named top-level function value (`(str) -> T`); closures and
  captures do not exist in e7.  It is called once per file, in sorted directory
  order, with the full cwd-relative path (`<root>/<relative path>`) so it can
  call `image::load`, an OBJ loader, or `audio_load_wav` directly.
* Directories are walked recursively and are never passed to `process`.
* A missing root yields an empty collection; trailing slashes on the root are
  ignored; an empty directory contributes an empty `folders` entry.
* Loaders return an empty value for unsupported/missing/corrupt files rather
  than aborting the scan (`Image`/`AudioClip` with a 0 handle, `ObjMesh` with no
  indices).  Callbacks should follow the same convention.

### Key semantics

`files` is keyed by the path relative to the scan root, with `/` separators
and subfolders included:

```
files["alpha.txt"]
files["nested/beta.txt"]
files["nested/deep/gamma.txt"]
```

`folders` has one entry per visited directory, keyed by its path relative to
the scan root.  Each value maps that folder's subtree, keyed relative to the
folder itself:

```
folders["nested"]               -> { "beta.txt": ..., "deep/gamma.txt": ... }
folders["nested/deep"]          -> { "gamma.txt": ... }
```

This is deliberately a flat two-level map (not a recursive nested type).
`folder_files(folder)` returns the inner map, or an empty map when the folder
is missing, so iteration/`len()` are always safe.

Generic helpers on `AssetCollection<T>`:

```e7
file_count()                 folder_count()
has_file(path)               file(path)        # guard with has_file
has_folder(folder)           folder_files(folder)
folder_file_count(folder)
```

`file(path)` must only be called after `has_file(path)`; the map
representation has no nil, so a missing entry reads as a zero slot.  The
concrete category wrappers wrap this with safe fallbacks.

### Concrete collections and AssetServer

```e7
pub ImageAssets  { images: AssetCollection<Image> }       image(path), folder_images(folder), count, has_image
pub MeshAssets   { meshes: AssetCollection<ObjMesh> }     mesh(path), folder_meshes(folder), count, has_mesh
pub AudioAssets  { clips:  AssetCollection<AudioClip> }   audio(path), folder_audio(folder), count, has_audio

@resource
pub AssetServer <- struct
    images: ImageAssets
    meshes: MeshAssets
    audio: AudioAssets
    image_root: str
    mesh_root: str
    audio_root: str

impl AssetServer:
    image(path)            # empty Image when absent
    mesh(path)             # empty ObjMesh when absent
    audio(path)            # empty AudioClip when absent
    folder_images(folder)  # map[str, Image]
    folder_meshes(folder)  # map[str, ObjMesh]
    folder_audio(folder)   # map[str, AudioClip]
```

### Plugin and fallback

```e7
pub AssetServerPlugin <- plugin
```

* Inserts `AudioSystem` and initializes SDL audio (`dummy` driver when
  `host::headless()`, default device otherwise; degrades to `ready=false`).
* Scans the three roots and inserts `AssetServer`.
* On `DeInit` frees every registered image handle, frees every WAV clip's
  PCM buffer, and shuts the audio subsystem down.

`AssetsPlugin` keeps loading the flat fallback cube image/OBJ at Init.
`upload_assets` (FrameInit) prefers `AssetServer` entries
(`cube/cube.png`, `cube/cube.obj`) when present, frees the unused fallback
image, and otherwise keeps the fixed paths, so rendering is identical whether
or not the asset server is part of the project.  `AssetServerPlugin` replaces
the demo's former standalone `AudioPlugin`.

## Ownership and lifetime

* Scans are synchronous at plugin init and CPU-only; GPU uploads still happen
  on the first FrameInit once the scene exists.
* `Image` values hold runtime image-registry handles; `AudioClip` values own
  `SDL_malloc`'d PCM bytes.  Both are released by `shutdown_asset_server`.
* e7 aggregates (the collections, OBJ buffers, `AssetServer` itself) are
  process-lifetime allocations; the e7 aggregate ABI has no free path.
* Processing the same path twice yields independent handles; the plugin scans
  each root once.

## Limitations

* No extension filtering: the processor is called for every file, so loaders
  must tolerate non-asset files (they return empty values).
* Only immediate synchronous scanning; no hot reload, watcher, cooked manifest,
  or async streaming.
* Folder aggregation is a flat two-level map rather than a recursive tree.
* Generic `AssetCollection<T>` cannot return a nil `T`; use `has_file` or the
  concrete wrappers for presence checks.
* The callback signature is fixed to one `str` argument returning `T`; there is
  no context/capture parameter or second "result" argument.

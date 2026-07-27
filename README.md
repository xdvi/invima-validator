# invima-validator

## What it is

A shared library, written in Zig and exposed through a C ABI, that queries
Colombia's [datos.gov.co](https://www.datos.gov.co) (Socrata) open-data portal
for INVIMA medicine sanitary registrations and SUIT procedures ("trámites").

It is a lookup and verification client: it asks the public datasets what is on
record and hands back JSON. It is **not** a schema validator and does not check
document formats offline.

Build artifacts:

- Linux: `libinvima_ffi.so`
- macOS: `libinvima_ffi.dylib`
- Windows: `invima_ffi.dll`

Any language with a C FFI (Python, Go, Rust, C#, Node, ...) can consume it.

## Datasets

| Dataset id | Contents |
| --- | --- |
| `i7cb-raxc` | Medicine registrations with status `vigente` |
| `vgr4-gemg` | Medicine registrations in `renovacion` (renewal) |
| `vwwf-4ftk` | Medicine registrations with status `vencido` (expired) |
| `spzp-dfuc` | Medicine registrations with any other status (`otro`) |
| `48fq-mxnm` | SUIT procedures ("trámites"), filtered to the INVIMA entity |

The medicine dataset is selected by the `status` argument you pass to each call.

## Build

Requires Zig 0.16.0.

```sh
zig build            # builds into zig-out/lib
zig build test       # unit tests
zig fmt --check .    # formatting, as CI runs it
```

CI also lints the workflows. It rejects any `${{ }}` expression inside a `run:`
body, because Actions substitutes those as raw shell text before the shell parses
the script; values belong in `env:` instead. Run it locally with:

Both commands need PyYAML (`apt install python3-yaml`, or `pip install pyyaml`):

```sh
python3 scripts/lint_workflows.py             # lints the workflows
python3 scripts/lint_workflows.py --self-test # checks the detector itself
```

Size-optimized artifact (ReleaseSmall, stripped ELF sections, optional UPX
compression):

```sh
./scripts/build.sh --release --upx
```

`--upx` requires the `upx` binary and implies `--release`.

Cross-compilation works through the standard Zig flag:

```sh
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-gnu
```

### CPU baseline on x86_64

On x86_64 the default build pins the `x86_64_v2` CPU baseline instead of
resolving to the native CPU. A native build can emit instructions the build
machine happens to support (for example VAES) that SIGILL on older deployment
CPUs. `x86_64_v2` is present on every x86_64 chip shipped since roughly 2009 and
is enough for this library's JSON/HTTP workload. Only the CPU model is pinned;
OS, arch and ABI stay native, and non-x86_64 hosts are untouched.

Pass `-Dcpu=native` to opt back into host-tuned codegen for a self-built deploy.

## C API

The C header lives at [`include/invima.h`](include/invima.h).

### Conventions

Return codes for every `int32_t` function:

| Code | Meaning |
| --- | --- |
| `0` | Success. `*out_json` holds a NUL-terminated JSON string. |
| `-1` | A required pointer argument was null. `*out_json` is untouched. |
| `-2` | The operation failed. `*out_json` holds a JSON error object `{"error":"..."}`. |

Memory contract:

- Every string written to `out_json` is heap-allocated by the library and
  **must** be released with `invima_free_string`.
- The handle returned by `invima_client_new` **must** be released with
  `invima_client_free`.
- Passing null to `invima_free_string` or `invima_client_free` is a no-op.
- All successful results are NUL-terminated JSON.

Accepted `status` values (case-insensitive):

`vigente`, `renovacion`, `renovación`, `vencido`, `otro`, `otros`

Accepted `field` values (case-insensitive):

`expediente`, `registrosanitario`, `registro_sanitario`

An unrecognized `status` or `field` is not a null-argument error: the call
returns `-2` with an error object in `out_json`.

### Functions

```c
InvimaClientHandle *invima_client_new(const char *app_token);
```

Creates a client. `app_token` is an optional Socrata app token and may be null;
when present it is sent as the `X-App-Token` header. Supplying one is
recommended to avoid throttling on datos.gov.co. Returns null on allocation
failure.

Each request runs against a 30-second deadline and retries a timed-out or
transient connection up to three times, so a stalled upstream returns an error
instead of blocking the caller forever. The deadline needs the multi-threaded
build (the default); `zig build -Dsingle-threaded=true` produces a smaller
library with no request timeout.

```c
void invima_client_free(InvimaClientHandle *handle);
```

Releases the handle. Null is a no-op.

```c
int32_t invima_search_medicines(const InvimaClientHandle *handle,
                                const char *query,
                                const char *status,
                                size_t limit,
                                char **out_json);
```

Full-text search over the dataset selected by `status`. All pointer arguments
are required. On success `*out_json` is a JSON array of medicine suggestions.

```c
int32_t invima_find_by_field(const InvimaClientHandle *handle,
                             const char *field,
                             const char *value,
                             const char *status,
                             size_t limit,
                             char **out_json);
```

Exact lookup by column. `field` selects the column, `value` is matched exactly
(a registration number placed in `expediente` returns `[]`, not a false
positive). All pointer arguments are required. On success `*out_json` is a JSON
array.

```c
int32_t invima_get_medicine_by_cum(const InvimaClientHandle *handle,
                                   const char *expediente,
                                   const char *consecutivo_cum,
                                   const char *cantidad_cum,
                                   const char *status,
                                   char **out_json);
```

Fetches a single medicine record by its CUM triple. All pointer arguments are
required. On success `*out_json` is a JSON object.

```c
int32_t invima_search_tramites(const InvimaClientHandle *handle,
                               const char *texto,
                               size_t limit,
                               size_t offset,
                               char **out_json);
```

Searches INVIMA procedures in the SUIT dataset. `texto` may be null to page
through results without a text filter; `handle` and `out_json` are required. On
success `*out_json` is a JSON object shaped
`{"total":…,"limit":…,"offset":…,"tramites":[…]}`.

```c
void invima_free_string(char *ptr);
```

Frees any string produced through an `out_json` argument. Null is a no-op.

```c
const char *invima_version(void);
```

Returns the library version string. Static storage; do not free.

## Python quickstart

```python
import ctypes, json

lib = ctypes.CDLL("./libinvima_ffi.so")

lib.invima_client_new.argtypes = [ctypes.c_char_p]
lib.invima_client_new.restype = ctypes.c_void_p
lib.invima_client_free.argtypes = [ctypes.c_void_p]
lib.invima_search_medicines.argtypes = [
    ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p,
    ctypes.c_size_t, ctypes.POINTER(ctypes.c_char_p),
]
lib.invima_search_medicines.restype = ctypes.c_int
lib.invima_free_string.argtypes = [ctypes.c_char_p]

handle = lib.invima_client_new(None)  # or b"YOUR_APP_TOKEN"
out = ctypes.c_char_p()
code = lib.invima_search_medicines(handle, b"ibuprofeno", b"vigente", 3, ctypes.byref(out))
if code == 0:
    print(json.loads(out.value.decode()))
lib.invima_free_string(out)
lib.invima_client_free(handle)
```

The full example, including every function and the download of a released
artifact, is in [`examples/demo.py`](examples/demo.py). Run it with `--offline`
to exercise the ABI and the null-argument contract without reaching
datos.gov.co:

```sh
zig build && cp zig-out/lib/libinvima_ffi.so examples/
python examples/demo.py --offline
```

## License

MIT. See [LICENSE](LICENSE).

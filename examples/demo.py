import os
import platform
import sys
import urllib.request
import ctypes
import json

# --offline exercises the ABI without touching datos.gov.co.
OFFLINE = "--offline" in sys.argv

# 1. Detect OS and architecture
system = platform.system()

if system == "Linux":
    lib_filename = "libinvima_ffi.so"
elif system == "Darwin":
    lib_filename = "libinvima_ffi.dylib"
elif system == "Windows":
    lib_filename = "invima_ffi.dll"
else:
    raise RuntimeError(f"Unsupported operating system: {system}")

# 2. Download from GitHub Releases if not present locally
lib_path = os.path.join(os.path.dirname(__file__), lib_filename)
if OFFLINE and not os.path.exists(lib_path):
    raise RuntimeError(f"--offline requires a local {lib_filename} next to this script")
if not os.path.exists(lib_path):
    url = f"https://github.com/xdvi/invima-validator/releases/latest/download/{lib_filename}"
    print(f"Downloading {lib_filename} from {url}...")
    try:
        urllib.request.urlretrieve(url, lib_path)
        print("Download completed.")
    except Exception as e:
        print(f"Failed to download library: {e}")
        if not os.path.exists(lib_path):
            raise

# 3. Load library using ctypes
try:
    lib = ctypes.CDLL(lib_path)
except Exception as e:
    raise RuntimeError(f"Failed to load dynamic library at {lib_path}: {e}")

# Configure function signatures
lib.invima_version.restype = ctypes.c_char_p
lib.invima_version.argtypes = []

lib.invima_client_new.restype = ctypes.c_void_p
lib.invima_client_new.argtypes = [ctypes.c_char_p]

lib.invima_client_free.restype = None
lib.invima_client_free.argtypes = [ctypes.c_void_p]

lib.invima_search_medicines.restype = ctypes.c_int
lib.invima_search_medicines.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_char_p)
]

lib.invima_get_medicine_by_cum.restype = ctypes.c_int
lib.invima_get_medicine_by_cum.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.POINTER(ctypes.c_char_p)
]

lib.invima_find_by_field.restype = ctypes.c_int
lib.invima_find_by_field.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_char_p)
]

lib.invima_search_tramites.restype = ctypes.c_int
lib.invima_search_tramites.argtypes = [
    ctypes.c_void_p,
    ctypes.c_char_p,
    ctypes.c_size_t,
    ctypes.c_size_t,
    ctypes.POINTER(ctypes.c_char_p)
]

lib.invima_free_string.restype = None
lib.invima_free_string.argtypes = [ctypes.c_char_p]

# Test API version
version = lib.invima_version().decode('utf-8')
print(f"=== INVIMA FFI Version: {version} ===")

# Create client handle
handle = lib.invima_client_new(None)
if not handle:
    raise RuntimeError("Failed to create INVIMA client handle")

if OFFLINE:
    print("\n=== Offline ABI check (no network) ===")
    try:
        out = ctypes.c_char_p()
        null_handle_calls = [
            ("invima_search_medicines",
             lib.invima_search_medicines(None, b"x", b"vigente", 1, ctypes.byref(out))),
            ("invima_find_by_field",
             lib.invima_find_by_field(None, b"expediente", b"x", b"vigente", 1, ctypes.byref(out))),
            ("invima_get_medicine_by_cum",
             lib.invima_get_medicine_by_cum(None, b"x", b"1", b"1", b"vigente", ctypes.byref(out))),
            ("invima_search_tramites",
             lib.invima_search_tramites(None, b"x", 1, 0, ctypes.byref(out))),
        ]
        for name, code in null_handle_calls:
            if code != -1:
                raise RuntimeError(f"{name}(NULL handle) returned {code}, expected -1")
            print(f"{name}(NULL handle) = {code}")

        err_ptr = ctypes.c_char_p()
        code = lib.invima_search_medicines(
            handle, b"x", b"estado-invalido", 1, ctypes.byref(err_ptr)
        )
        if code != -2 or not err_ptr.value:
            raise RuntimeError(f"invalid status returned {code}, expected -2 with error JSON")
        payload = json.loads(err_ptr.value.decode("utf-8"))
        lib.invima_free_string(err_ptr)
        if "error" not in payload:
            raise RuntimeError(f"error payload missing 'error' key: {payload}")
        print(f"invalid status = {code}, error JSON = {payload['error']}")
    finally:
        lib.invima_client_free(handle)
    print("\nOffline ABI check passed.")
    sys.exit(0)

failures = []
tolerated = []

try:
    # 1. Search medicines
    print("\n=== Búsqueda CUM: ibuprofeno (vigente) ===")
    out_ptr = ctypes.c_char_p()
    res = lib.invima_search_medicines(
        handle,
        "ibuprofeno".encode('utf-8'),
        "vigente".encode('utf-8'),
        3,
        ctypes.byref(out_ptr)
    )
    
    if res == 0 and out_ptr.value:
        json_str = out_ptr.value.decode('utf-8')
        suggestions = json.loads(json_str)
        for i, item in enumerate(suggestions):
            print(f"{i+1}. {item.get('producto', '?')} | {item.get('registrosanitario', '?')} | CUM {item.get('expediente', '?')}/{item.get('consecutivocum', '?')}/{item.get('cantidadcum', '?')}")
        
        # Get medicine details by CUM of first item
        if suggestions:
            first = suggestions[0]
            print("\n=== Detalle por CUM del primer resultado ===")
            detail_ptr = ctypes.c_char_p()
            res_det = lib.invima_get_medicine_by_cum(
                handle,
                first.get('expediente', '').encode('utf-8'),
                first.get('consecutivocum', '').encode('utf-8'),
                first.get('cantidadcum', '').encode('utf-8'),
                "vigente".encode('utf-8'),
                ctypes.byref(detail_ptr)
            )
            if res_det == 0 and detail_ptr.value:
                detail_str = detail_ptr.value.decode('utf-8')
                detail = json.loads(detail_str)
                print(f"Producto:      {detail.get('producto', '?')}")
                print(f"Titular:       {detail.get('titular', '?')}")
                print(f"Principio:     {detail.get('principioactivo', '?')}")
                print(f"Forma:         {detail.get('formafarmaceutica', '?')}")
                print(f"Estado CUM:    {detail.get('estadocum', '?')}")
                lib.invima_free_string(detail_ptr)
        lib.invima_free_string(out_ptr)
    else:
        failures.append(f"invima_search_medicines returned {res}")
        print(f"Search failed with code {res}")

    # 2. Exact field lookup
    print("\n=== Búsqueda exacta por campo ===")

    def find_by_field(field, value, status="vigente", limit=3):
        out = ctypes.c_char_p()
        code = lib.invima_find_by_field(
            handle,
            field.encode('utf-8'),
            value.encode('utf-8'),
            status.encode('utf-8'),
            limit,
            ctypes.byref(out)
        )
        payload = out.value.decode('utf-8') if out.value else None
        if out.value:
            lib.invima_free_string(out)
        return code, json.loads(payload) if payload else None

    code, rows = find_by_field("expediente", "20048021")
    if code != 0:
        failures.append(f"invima_find_by_field(expediente) returned {code}")
    print(f"expediente=20048021 -> code {code}, {len(rows) if isinstance(rows, list) else rows} fila(s)")
    if isinstance(rows, list) and rows:
        print(f"  {rows[0].get('producto', '?')} | {rows[0].get('registrosanitario', '?')}")

    code, rows = find_by_field("registrosanitario", "invima 2023m-0013598-r2")
    if code != 0:
        failures.append(f"invima_find_by_field(registrosanitario) returned {code}")
    print(f"registrosanitario (minúsculas) -> code {code}, {len(rows) if isinstance(rows, list) else rows} fila(s)")

    # Un registro sanitario en el campo expediente no coincide: [] en vez de un falso positivo.
    code, rows = find_by_field("expediente", "INVIMA 2023M-0013598-R2")
    if code != 0:
        failures.append(f"invima_find_by_field(expediente, registro sanitario) returned {code}")
    elif rows != []:
        failures.append(f"registro sanitario en expediente debía dar [], dio {rows}")
    print(f"registro sanitario puesto en expediente -> code {code}, resultado {rows}")

    # 3. Search SUIT tramites
    print("\n=== Búsqueda de Trámites SUIT ===")
    suit_ptr = ctypes.c_char_p()
    res_suit = lib.invima_search_tramites(
        handle,
        "registro sanitario".encode('utf-8'),
        2,
        0,
        ctypes.byref(suit_ptr)
    )
    if res_suit == 0 and suit_ptr.value:
        suit_str = suit_ptr.value.decode('utf-8')
        suit_results = json.loads(suit_str)
        print(f"Total trámites encontrados: {suit_results.get('total', 0)}")
        for i, tramite in enumerate(suit_results.get('tramites', [])):
            print(f"{i+1}. Código: {tramite.get('numero_unico', '?')} | {tramite.get('nombre_tramite', '?')}")
            print(f"   Propósito: {tramite.get('proposito', '?')}")
            print(f"   Categorías: {', '.join(tramite.get('categorias', []))}")
            pasos = tramite.get('pasos', [])
            if pasos:
                print("   Pasos (primeros 2):")
                for paso in pasos[:2]:
                    print(f"     - Paso {paso.get('orden_paso', '?')}: {paso.get('descripcion_paso', '?')}")
        lib.invima_free_string(suit_ptr)
    else:
        # -2 no distingue "requiere credenciales" de un fallo real del servidor,
        # así que se tolera pero se reporta con el mensaje exacto.
        if res_suit == -2 and suit_ptr.value:
            err_obj = json.loads(suit_ptr.value.decode('utf-8'))
            lib.invima_free_string(suit_ptr)
            if "error" not in err_obj:
                failures.append(f"invima_search_tramites -2 payload missing 'error': {err_obj}")
            else:
                tolerated.append(f"invima_search_tramites -> -2: {err_obj['error']}")
            print(f"Nota: La búsqueda de trámites falló con: {err_obj.get('error', '?')}")
            print("(El dataset público de trámites SUIT 48fq-mxnm requiere credenciales/App Token autorizado en datos.gov.co)")
        else:
            failures.append(f"invima_search_tramites returned {res_suit}")
            print(f"SUIT Search failed with code {res_suit}")

    # texto is documented as optional: NULL lists without a text filter and
    # must never be reported as a missing-argument error.
    print("\n=== Trámites SUIT sin filtro de texto (texto = NULL) ===")
    null_texto_ptr = ctypes.c_char_p()
    res_null_texto = lib.invima_search_tramites(
        handle, None, 1, 0, ctypes.byref(null_texto_ptr)
    )
    if res_null_texto == -1:
        failures.append("invima_search_tramites(texto=NULL) returned -1; NULL texto is valid")
    print(f"texto=NULL -> code {res_null_texto}")
    if null_texto_ptr.value:
        if res_null_texto == -2:
            err = json.loads(null_texto_ptr.value.decode('utf-8'))
            if "error" not in err:
                failures.append(f"invima_search_tramites -2 payload missing 'error': {err}")
        lib.invima_free_string(null_texto_ptr)

finally:
    lib.invima_client_free(handle)

if tolerated:
    print("\nTOLERADO (no bloquea):")
    for item in tolerated:
        print(f"  - {item}")

if failures:
    print("\nFAILURES:")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)

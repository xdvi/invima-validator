import os
import platform
import urllib.request
import ctypes
import json

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
        print(f"Search failed with code {res}")

    # 2. Search SUIT tramites
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
        # Si devuelve error de red o no autorizado
        if res_suit == -2 and suit_ptr.value:
            err_str = suit_ptr.value.decode('utf-8')
            err_obj = json.loads(err_str)
            print(f"Nota: La búsqueda de trámites falló con: {err_obj.get('error', '?')}")
            print("(El dataset público de trámites SUIT 48fq-mxnm requiere credenciales/App Token autorizado en datos.gov.co)")
            lib.invima_free_string(suit_ptr)
        else:
            print(f"SUIT Search failed with code {res_suit}")

finally:
    lib.invima_client_free(handle)

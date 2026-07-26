#ifndef INVIMA_H
#define INVIMA_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * C ABI for libinvima_ffi.
 *
 * Return codes (all int32_t-returning functions):
 *    0  success; *out_json holds a NUL-terminated JSON string.
 *   -1  a required pointer argument was NULL; *out_json is untouched.
 *   -2  the operation failed; *out_json holds {"error":"..."} when it could be
 *       allocated.
 *
 * Ownership: every string written to *out_json is heap-allocated by the library
 * and must be released with invima_free_string.
 */

typedef struct InvimaClientHandle InvimaClientHandle;

/*
 * Creates a client handle.
 * app_token: optional Socrata app token, may be NULL. Sent as X-App-Token.
 * Returns NULL on allocation failure. Caller owns the handle and must release
 * it with invima_client_free.
 */
InvimaClientHandle *invima_client_new(const char *app_token);

/* Releases a handle returned by invima_client_new. NULL is a no-op. */
void invima_client_free(InvimaClientHandle *handle);

/*
 * Full-text search over the medicine registration dataset selected by status.
 * All arguments are required except as noted; NULL yields -1.
 * status: "vigente", "renovacion" ("renovación"), "vencido", "otro" ("otros"),
 *         case-insensitive. An unrecognized value yields -2.
 * On success *out_json is a JSON array; free it with invima_free_string.
 */
int32_t invima_search_medicines(const InvimaClientHandle *handle,
                                const char *query,
                                const char *status,
                                size_t limit,
                                char **out_json);

/*
 * Exact lookup by column.
 * field: "expediente", "registrosanitario" ("registro_sanitario"),
 *        case-insensitive. An unrecognized value yields -2.
 * status: same accepted values as invima_search_medicines.
 * All arguments are required; NULL yields -1.
 * On success *out_json is a JSON array; free it with invima_free_string.
 */
int32_t invima_find_by_field(const InvimaClientHandle *handle,
                             const char *field,
                             const char *value,
                             const char *status,
                             size_t limit,
                             char **out_json);

/*
 * Fetches one medicine record by its CUM triple.
 * status: same accepted values as invima_search_medicines.
 * All arguments are required; NULL yields -1.
 * On success *out_json is a JSON object; free it with invima_free_string.
 */
int32_t invima_get_medicine_by_cum(const InvimaClientHandle *handle,
                                   const char *expediente,
                                   const char *consecutivo_cum,
                                   const char *cantidad_cum,
                                   const char *status,
                                   char **out_json);

/*
 * Searches INVIMA procedures ("trámites") in the SUIT dataset.
 * texto may be NULL to list without a text filter; handle and out_json are
 * required and NULL yields -1.
 * On success *out_json is a JSON object {total, limit, offset, tramites};
 * free it with invima_free_string.
 */
int32_t invima_search_tramites(const InvimaClientHandle *handle,
                               const char *texto,
                               size_t limit,
                               size_t offset,
                               char **out_json);

/* Frees a string produced by any out_json output. NULL is a no-op. */
void invima_free_string(char *ptr);

/* Returns the library version. Static storage; do not free. */
const char *invima_version(void);

#ifdef __cplusplus
}
#endif

#endif /* INVIMA_H */

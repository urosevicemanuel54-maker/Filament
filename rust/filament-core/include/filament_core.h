#ifndef FILAMENT_CORE_H
#define FILAMENT_CORE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Each mapping function takes a raw Instagram JSON body and returns a newly
 * allocated, NUL-terminated flat JSON document holding Filament's models, or
 * NULL when the body could not be mapped. Free the result with
 * filament_free_string().
 */
char *filament_map_timeline(const uint8_t *json, size_t len);
char *filament_map_tray(const uint8_t *json, size_t len);
char *filament_map_comments(const uint8_t *json, size_t len);
char *filament_map_story(const uint8_t *json, size_t len);
char *filament_map_current_user(const uint8_t *json, size_t len);

void filament_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif /* FILAMENT_CORE_H */

#ifndef LIGHTBAR_H
#define LIGHTBAR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct LightbarController LightbarController;

LightbarController *lightbar_create(void);
int32_t lightbar_send(LightbarController *controller, const char *request_json);
char *lightbar_next_event(LightbarController *controller);
void lightbar_free_string(char *event);
void lightbar_destroy(LightbarController *controller);

#ifdef __cplusplus
}
#endif
#endif

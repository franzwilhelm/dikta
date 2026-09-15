#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct DiktatWhisper DiktatWhisper;
DiktatWhisper * diktat_whisper_create(void);
int diktat_whisper_load(DiktatWhisper *, const char * model);
int diktat_whisper_run(DiktatWhisper *, const float *, int, const char * language, const char * vad);
int diktat_whisper_progress(DiktatWhisper *);
void diktat_whisper_reset_progress(DiktatWhisper *);
int diktat_whisper_word_count(DiktatWhisper *);
const char * diktat_whisper_word_text(DiktatWhisper *, int);
double diktat_whisper_word_start(DiktatWhisper *, int);
double diktat_whisper_word_end(DiktatWhisper *, int);
void diktat_whisper_cancel(DiktatWhisper *);
void diktat_whisper_reset_cancel(DiktatWhisper *);
void diktat_whisper_unload(DiktatWhisper *);
void diktat_whisper_free(DiktatWhisper *);
#ifdef __cplusplus
}
#endif

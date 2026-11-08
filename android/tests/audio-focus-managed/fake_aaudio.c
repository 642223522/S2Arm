/* Fake only Android's AAudio API; the sink and managed session are production code. */
#include <aaudio/AAudio.h>
#include <android/log.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include "../../native/capacity_affinity.h"
static AAudioStream stream;
static AAudioStreamBuilder builder;
static aaudio_data_callback_result_t (*callback)(AAudioStream *, void *, void *, int32_t);
static void *callback_user;
int eventfd(unsigned int n, int flags) { (void)n; (void)flags; return open("/dev/null",O_RDWR); }
int __android_log_print(int level,const char *tag,const char *fmt,...) { (void)level;(void)tag;(void)fmt;return 0; }
int s2a_capacity_call_wide(int (*fn)(void *),void *arg,int *result) { (void)fn;(void)arg;(void)result;return 0; }
int AAudio_createStreamBuilder(AAudioStreamBuilder **b) { *b=&builder;return 0; }
#define SETTER(name) void AAudioStreamBuilder_set##name(AAudioStreamBuilder *b,int n) { (void)b;(void)n; }
SETTER(Direction) SETTER(Format) SETTER(SampleRate) SETTER(ChannelCount) SETTER(PerformanceMode) SETTER(SharingMode) SETTER(Usage) SETTER(ContentType)
void AAudioStreamBuilder_setDataCallback(AAudioStreamBuilder *b,aaudio_data_callback_result_t (*fn)(AAudioStream *,void *,void *,int32_t),void *u) { (void)b;callback=fn;callback_user=u; }
void AAudioStreamBuilder_setErrorCallback(AAudioStreamBuilder *b,void (*fn)(AAudioStream *,void *,aaudio_result_t),void *u) { (void)b;(void)fn;(void)u; }
int AAudioStreamBuilder_openStream(AAudioStreamBuilder *b,AAudioStream **s) { (void)b;*s=&stream;return 0; }
void AAudioStreamBuilder_delete(AAudioStreamBuilder *b) { (void)b; }
#define GETTER(name,value) int AAudioStream_get##name(AAudioStream *s) { (void)s;return value; }
GETTER(Format,AAUDIO_FORMAT_PCM_I16) GETTER(SampleRate,48000) GETTER(ChannelCount,2) GETTER(FramesPerBurst,128) GETTER(XRunCount,0) GETTER(BufferSizeInFrames,256) GETTER(SharingMode,0)
int AAudioStream_close(AAudioStream *s) { (void)s;return 0; }
int AAudioStream_setBufferSizeInFrames(AAudioStream *s,int n) { (void)s;return n; }
int AAudioStream_requestStart(AAudioStream *s) { (void)s;return 0; }
int AAudioStream_requestPause(AAudioStream *s) { (void)s;return 0; }
int AAudioStream_requestStop(AAudioStream *s) { (void)s;return 0; }
int test_emit_frame(void) { int16_t audio[2]={123,123}; if (!callback) return -1; callback(&stream,callback_user,audio,1); return audio[0]==0 && audio[1]==0; }

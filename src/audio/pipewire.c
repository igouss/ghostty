// Minimal PipeWire capture of the default sink's monitor, for
// audio-reactive custom shaders. PipeWire's API is mostly macros and
// inline varargs helpers that Zig can't translate, so this file keeps
// all of it behind a three-function API (see src/audio/Capture.zig).
//
// We ask for mono f32 at a fixed rate and let PipeWire's adapter do
// the downmixing and resampling.

#include <stdlib.h>

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>

typedef void (*ghostty_audio_cb)(void* userdata, const float* samples, uint32_t len);

struct ghostty_audio_capture {
  struct pw_thread_loop* loop;
  struct pw_stream* stream;
  struct spa_hook listener;
  ghostty_audio_cb cb;
  void* userdata;
};

static void on_process(void* data) {
  struct ghostty_audio_capture* cap = data;
  struct pw_buffer* b = pw_stream_dequeue_buffer(cap->stream);
  if (b == NULL) return;

  struct spa_data* d = &b->buffer->datas[0];
  if (d->data != NULL && d->chunk != NULL) {
    uint32_t offset = SPA_MIN(d->chunk->offset, d->maxsize);
    uint32_t size = SPA_MIN(d->chunk->size, d->maxsize - offset);
    cap->cb(cap->userdata,
            (const float*)SPA_PTROFF(d->data, offset, void),
            size / sizeof(float));
  }

  pw_stream_queue_buffer(cap->stream, b);
}

static const struct pw_stream_events stream_events = {
    PW_VERSION_STREAM_EVENTS,
    .process = on_process,
};

void ghostty_audio_capture_free(struct ghostty_audio_capture* cap) {
  if (cap == NULL) return;
  if (cap->loop != NULL) {
    // Stopping joins the loop thread, so no callback runs after this.
    pw_thread_loop_stop(cap->loop);
    if (cap->stream != NULL) pw_stream_destroy(cap->stream);
    pw_thread_loop_destroy(cap->loop);
  }
  free(cap);
  pw_deinit();
}

struct ghostty_audio_capture* ghostty_audio_capture_new(uint32_t rate,
                                                        ghostty_audio_cb cb,
                                                        void* userdata) {
  pw_init(NULL, NULL);

  struct ghostty_audio_capture* cap = calloc(1, sizeof(*cap));
  if (cap == NULL) {
    pw_deinit();
    return NULL;
  }
  cap->cb = cb;
  cap->userdata = userdata;

  cap->loop = pw_thread_loop_new("ghostty-audio", NULL);
  if (cap->loop == NULL) goto fail;

  struct pw_properties* props = pw_properties_new(
      PW_KEY_MEDIA_TYPE, "Audio",
      PW_KEY_MEDIA_CATEGORY, "Capture",
      PW_KEY_MEDIA_ROLE, "Music",
      PW_KEY_APP_NAME, "Ghostty",
      PW_KEY_NODE_NAME, "ghostty-audio",
      // Record what the default output plays, and never keep the
      // sink awake just for us.
      PW_KEY_STREAM_CAPTURE_SINK, "true",
      PW_KEY_NODE_PASSIVE, "true",
      NULL);

  // pw_stream_new_simple takes ownership of props, even on failure.
  cap->stream = pw_stream_new_simple(pw_thread_loop_get_loop(cap->loop),
                                     "ghostty-audio", props, &stream_events,
                                     cap);
  if (cap->stream == NULL) goto fail;

  uint8_t buffer[1024];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
  const struct spa_pod* params[1];
  params[0] = spa_format_audio_raw_build(
      &builder, SPA_PARAM_EnumFormat,
      &SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32,
                               .rate = rate,
                               .channels = 1,
                               .position = {SPA_AUDIO_CHANNEL_MONO}));

  if (pw_stream_connect(cap->stream, PW_DIRECTION_INPUT, PW_ID_ANY,
                        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS,
                        params, 1) < 0)
    goto fail;

  if (pw_thread_loop_start(cap->loop) < 0) goto fail;
  return cap;

fail:
  ghostty_audio_capture_free(cap);
  return NULL;
}

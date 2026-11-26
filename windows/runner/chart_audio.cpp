#include "chart_audio.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <memory>
#include <vector>

#include "third_party/miniaudio.h"

namespace {
using Value = flutter::EncodableValue;
using Result = flutter::MethodResult<Value>;
constexpr std::uintmax_t kMaxAudioBytes = 128 * 1024 * 1024;

// Keep UI position queries independent of the mixer-owned decoder cursor.
struct PlaybackSource : ma_data_source_base {
  ma_decoder decoder{};
  ma_uint64 length = 0;
  std::atomic<ma_uint64> cursor{0};

  ma_result Init() {
    static const ma_data_source_vtable callbacks = {
        Read, Seek, Format, Cursor, Length, nullptr, 0};
    auto config = ma_data_source_config_init();
    config.vtable = &callbacks;
    cursor.store(0, std::memory_order_relaxed);
    return ma_data_source_init(&config, this);
  }

  static PlaybackSource& From(ma_data_source* source) {
    return *static_cast<PlaybackSource*>(
        static_cast<ma_data_source_base*>(source));
  }

  static ma_result Read(ma_data_source* source, void* output, ma_uint64 count,
                        ma_uint64* read) {
    auto& self = From(source);
    const auto status = ma_decoder_read_pcm_frames(&self.decoder, output, count, read);
    self.cursor.fetch_add(*read, std::memory_order_relaxed);
    return status;
  }

  static ma_result Seek(ma_data_source* source, ma_uint64 frame) {
    auto& self = From(source);
    const auto status = ma_decoder_seek_to_pcm_frame(&self.decoder, frame);
    if (status == MA_SUCCESS) self.cursor.store(frame, std::memory_order_relaxed);
    return status;
  }

  static ma_result Format(ma_data_source* source, ma_format* format,
                          ma_uint32* channels, ma_uint32* rate,
                          ma_channel* map, size_t capacity) {
    return ma_decoder_get_data_format(&From(source).decoder, format, channels,
                                      rate, map, capacity);
  }

  static ma_result Cursor(ma_data_source* source, ma_uint64* frame) {
    *frame = From(source).cursor.load(std::memory_order_relaxed);
    return MA_SUCCESS;
  }

  static ma_result Length(ma_data_source* source, ma_uint64* frames) {
    *frames = From(source).length;
    return MA_SUCCESS;
  }
};

const Value* Argument(const flutter::MethodCall<Value>& call, const char* key) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!arguments) return nullptr;
  const auto entry = arguments->find(Value(key));
  return entry == arguments->end() ? nullptr : &entry->second;
}

void Report(Result& result, ma_result status) {
  if (status == MA_SUCCESS) {
    result.Success();
  } else {
    result.Error("chart_audio", ma_result_description(status));
  }
}
}  // namespace

struct ChartAudio::Impl {
  explicit Impl(flutter::BinaryMessenger* messenger, const char* name)
      : channel(messenger, name,
                &flutter::StandardMethodCodec::GetInstance()) {
    channel.SetMethodCallHandler(
        [this](const auto& call, auto result) { Handle(call, *result); });
  }

  ~Impl() {
    channel.SetMethodCallHandler(nullptr);
    Close();
  }

  ma_result Open(const std::string& file) {
    Close();
    // Open through a native filesystem path so Windows filenames may be Unicode.
    const auto path = std::filesystem::u8path(file);
    std::error_code error;
    const auto size = std::filesystem::file_size(path, error);
    if (error || size == 0 || size > kMaxAudioBytes) return MA_INVALID_FILE;
    std::ifstream input(path, std::ios::binary);
    bytes.resize(static_cast<size_t>(size));
    if (!input.read(reinterpret_cast<char*>(bytes.data()),
                    static_cast<std::streamsize>(size))) {
      Close();
      return MA_IO_ERROR;
    }
    auto status = ma_decoder_init_memory(bytes.data(), bytes.size(), nullptr,
                                         &source.decoder);
    if (status != MA_SUCCESS) return status;
    decoder_ready = true;
    status = ma_decoder_get_length_in_pcm_frames(&source.decoder, &source.length);
    if (status != MA_SUCCESS || source.length == 0) return MA_INVALID_FILE;
    rate = source.decoder.outputSampleRate;
    if (rate == 0) return MA_INVALID_FILE;
    status = source.Init();
    if (status != MA_SUCCESS) return status;
    source_ready = true;
    status = ma_engine_init(nullptr, &engine);
    if (status != MA_SUCCESS) return status;
    engine_ready = true;
    status = ma_sound_init_from_data_source(
        &engine, &source, MA_SOUND_FLAG_NO_SPATIALIZATION, nullptr, &sound);
    sound_ready = status == MA_SUCCESS;
    if (sound_ready) ma_sound_set_volume(&sound, gain);
    return status;
  }

  void Close() {
    if (sound_ready) ma_sound_uninit(&sound);
    if (engine_ready) ma_engine_uninit(&engine);
    if (source_ready) ma_data_source_uninit(&source);
    if (decoder_ready) ma_decoder_uninit(&source.decoder);
    sound_ready = engine_ready = source_ready = decoder_ready = false;
    std::vector<unsigned char>().swap(bytes);
  }

  int64_t Milliseconds(ma_uint64 frame) const {
    return static_cast<int64_t>(frame / rate * 1000 + frame % rate * 1000 / rate);
  }

  void Handle(const flutter::MethodCall<Value>& call, Result& result) {
    const auto& method = call.method_name();
    if (method == "open") {
      const auto* value = Argument(call, "file");
      const auto* file = value ? std::get_if<std::string>(value) : nullptr;
      const auto status = file ? Open(*file) : MA_INVALID_ARGS;
      if (status == MA_SUCCESS) {
        const auto* loop = Argument(call, "loop");
        const auto* enabled = loop ? std::get_if<bool>(loop) : nullptr;
        if (enabled && *enabled) ma_sound_set_looping(&sound, MA_TRUE);
        result.Success(Value(Milliseconds(source.length)));
      } else {
        Close();
        Report(result, status);
      }
    } else if (method == "close") {
      Close();
      result.Success();
    } else if (method == "volume") {
      const auto* value = Argument(call, "gain");
      const auto* number = value ? std::get_if<double>(value) : nullptr;
      if (!number || !std::isfinite(*number)) {
        Report(result, MA_INVALID_ARGS);
        return;
      }
      gain = static_cast<float>(std::clamp(*number, 0.0, 1.0));
      if (sound_ready) ma_sound_set_volume(&sound, gain);
      result.Success();
    } else if (!sound_ready) {
      result.Error("chart_audio", "Audio is unavailable");
    } else if (method == "play") {
      Report(result, ma_sound_start(&sound));
    } else if (method == "pause") {
      Report(result, ma_sound_stop(&sound));
    } else if (method == "seek") {
      const auto* value = Argument(call, "position");
      if (!value || (!std::holds_alternative<int32_t>(*value) &&
                     !std::holds_alternative<int64_t>(*value))) {
        Report(result, MA_INVALID_ARGS);
        return;
      }
      const auto duration = Milliseconds(source.length);
      const auto ms = std::clamp(value->LongValue(), int64_t{0}, duration);
      const auto frame = ms == duration ? source.length
                                       : static_cast<ma_uint64>(ms) * rate / 1000;
      const auto status = ma_sound_seek_to_pcm_frame(&sound, frame);
      if (status == MA_SUCCESS) {
        result.Success(Value(ms));
      } else {
        Report(result, status);
      }
    } else if (method == "position") {
      ma_uint64 frame = 0;
      const auto status = ma_sound_get_cursor_in_pcm_frames(&sound, &frame);
      if (status == MA_SUCCESS) {
        result.Success(Value(flutter::EncodableList{
            Value(Milliseconds(std::min(frame, source.length))),
            Value(ma_sound_is_playing(&sound) && !ma_sound_at_end(&sound)),
        }));
      } else {
        Report(result, status);
      }
    } else {
      result.NotImplemented();
    }
  }

  flutter::MethodChannel<Value> channel;
  ma_engine engine{};
  PlaybackSource source{};
  ma_sound sound{};
  std::vector<unsigned char> bytes;
  ma_uint32 rate = 0;
  float gain = 1.0f;
  bool engine_ready = false;
  bool decoder_ready = false;
  bool source_ready = false;
  bool sound_ready = false;
};

ChartAudio::ChartAudio(flutter::BinaryMessenger* messenger, const char* channel)
    : impl_(std::make_unique<Impl>(messenger, channel)) {}

ChartAudio::~ChartAudio() = default;

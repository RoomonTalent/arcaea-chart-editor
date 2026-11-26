#ifndef RUNNER_CHART_AUDIO_H_
#define RUNNER_CHART_AUDIO_H_

#include <flutter/binary_messenger.h>

#include <memory>

class ChartAudio {
 public:
  explicit ChartAudio(flutter::BinaryMessenger* messenger,
                      const char* channel = "arcaea_manager/chart_audio");
  ~ChartAudio();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

#endif

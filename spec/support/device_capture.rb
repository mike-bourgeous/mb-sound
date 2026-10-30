# Waiting for what a FastAudio::Playback's capture recorded (the specs of
# fast_audio and its concealment, on miniaudio's null backend).
#
# The capture records the first frames the device plays, from the moment
# Playback.new starts the device, so it holds the silence played before the
# first write reaches the device.  Under Valgrind with parallel processes
# (rake memcheck, 2026-10-30) the writer lagged the device thread by over a
# second, and captures sized for the audio alone held only that silence, or
# the first few thousand frames of the audio.  So captures leave LEAD frames
# for that silence (DeviceCapture.size), and examples wait until the frames
# they read were recorded after the first nonzero sample (#wait_for_played),
# never for a fixed time.
module DeviceCapture
  # Frames of leading silence a capture leaves room for (10 s at 48 kHz)
  LEAD = 480_000

  # How long #wait_for_played waits before failing
  TIMEOUT = SPEC_MEMCHECK ? 180 : 20

  # A capture length holding +frames+ frames of audio after the silence
  # played before it.
  def self.size(frames) = frames + LEAD

  # The capture as one SFloat of interleaved frames, and the frame index of
  # its first nonzero sample (nil if every sample so far is zero).
  def capture_and_start(pb)
    x = Numo::SFloat.from_binary(pb.captured)
    nz = x.ne(0).where
    [x, nz.empty? ? nil : nz[0] / pb.device_channels]
  end

  # The number of frames the capture recorded from its first nonzero sample.
  def played_frames(pb)
    x, start = capture_and_start(pb)
    start ? x.length / pb.device_channels - start : 0
  end

  # Waits until the capture of +pb+ holds +frames+ frames from its first
  # nonzero sample on, raising (with what it did record) after TIMEOUT.
  def wait_for_played(pb, frames, timeout: TIMEOUT)
    deadline = MB::U.clock_now + timeout
    loop do
      got = played_frames(pb)
      return got if got >= frames

      if MB::U.clock_now > deadline || pb.captured.bytesize >= pb.device_channels * 4 * capture_frames_of(pb)
        x, start = capture_and_start(pb)
        raise "the capture recorded #{got} of #{frames} frames after its first nonzero sample " \
              "(#{x.length / pb.device_channels} frames, starting at #{start.inspect}; stats #{pb.stats})"
      end

      sleep 0.01
    end
  end

  # Waits until the capture of +pb+ holds every frame the device had played
  # when called (or is full): the device thread counts frames played before
  # it copies them into the capture.
  def wait_for_capture(pb, timeout: TIMEOUT)
    want = MB::M.min(pb.stats[:frames_played], capture_frames_of(pb))
    deadline = MB::U.clock_now + timeout
    sleep 0.01 until pb.captured.bytesize >= want * pb.device_channels * 4 || MB::U.clock_now > deadline
    raise "the capture recorded #{pb.captured.bytesize / (pb.device_channels * 4)} of #{want} frames played" if pb.captured.bytesize < want * pb.device_channels * 4
  end

  private

  # The capture length +pb+ was opened with (remembered by the examples'
  # playback helpers through #remember_capture)
  def capture_frames_of(pb) = (@capture_frames ||= {}).fetch(pb.object_id, Float::INFINITY)

  def remember_capture(pb, frames)
    (@capture_frames ||= {})[pb.object_id] = frames if frames > 0
    pb
  end
end

module MB
  module Sound
    class Session
      # Records the master bus (what the Session writes to its output,
      # after master effects and master gain) to an audio file, from an
      # exact frame to an exact frame (see #record_audio and
      # design/notes/arrangement.md, Recording).  The render thread only
      # copies each buffer onto a queue; a writer thread sends it to ffmpeg.
      module AudioRecording
        # One recording of the master bus.  +start_frame+ and +stop_frame+
        # are session frames (+stop_frame+ nil while recording); +frames+
        # is how many have been written so far and +peak+ the highest
        # absolute sample.
        class Recorder
          attr_reader :path, :start_frame, :stop_frame, :frames, :peak, :channels, :sample_rate

          # Opens +output+ (an object with #write and #close; by default an
          # ffmpeg file output for +path+).
          def initialize(path, channels:, sample_rate:, output: nil, overwrite: false)
            @path = path
            @channels = channels
            @sample_rate = sample_rate
            @output = output || MB::Sound.file_output(path, channels: channels, sample_rate: sample_rate, overwrite: overwrite)
            @queue = Thread::Queue.new
            @frames = 0
            @peak = 0.0
            @start_frame = nil
            @stop_frame = nil
            @finished = false
            @thread = Thread.new do
              while (bufs = @queue.pop)
                @output.write(bufs)
              end
            rescue => e
              warn "Recording to #{@path} stopped with an error: #{e.class}: #{e.message}"
            ensure
              @output.close rescue nil
            end
            @thread.name = 'MB::Sound recorder'
          end

          # Starts recording on session frame +frame+ (render thread).
          def start(frame)
            @start_frame = frame
          end

          # Stops recording before session frame +frame+ (render thread).
          def stop(frame)
            @stop_frame = frame if @stop_frame.nil? || frame < @stop_frame
          end

          # True once the last frame was queued (see #wait).
          def finished?
            @finished
          end

          # The recording's length in seconds so far.
          def seconds
            @frames.to_f / @sample_rate
          end

          # Queues the part of +mix+ (Arrays of samples per channel starting
          # at session frame +frame+) between the start and stop frames.
          # Returns true once the recording is finished.
          def write(mix, frame)
            return true if @finished
            return false if @start_frame.nil?

            n = mix[0].length
            from = MB::M.max(@start_frame - frame, 0)
            to = @stop_frame ? MB::M.min(@stop_frame - frame, n) : n
            if to > from
              bufs = Array.new(@channels) { |c| mix[c % mix.length][from...to].dup }
              @peak = MB::M.max(@peak, bufs.map { |b| b.abs.max }.max.to_f)
              @frames += to - from
              @queue << bufs
            end

            finish if @stop_frame && frame + n >= @stop_frame
            @finished
          end

          # Stops writing; the file is closed once the writer catches up.
          def finish
            return if @finished
            @finished = true
            @queue << nil
          end

          # Waits for the file to be written and closed.
          def wait
            finish
            @thread.join
            self
          end

          def to_s
            "#{@path} (#{MB::M.sigfigs(seconds, 4)} s#{@finished ? '' : ', recording'}, peak #{MB::M.sigfigs(20 * Math.log10(MB::M.max(@peak, 1e-12)), 3)} dBFS)"
          end
        end

        # Records the master bus to +path+ from the launch point (+at+;
        # right away by default) until #stop_recording.  +output+ replaces
        # the file output (an object with #write and #close, e.g. for
        # specs).  While a take replays, nothing is written (render the
        # replay with -o instead), but the change is still made, so later
        # changes keep their recorded landing times.  Returns the Change;
        # #recordings lists the Recorders.
        def record_audio(path, at: nil, start_time: nil, overwrite: false, output: nil)
          point = at || LaunchPoint::NONE
          time = start_time && !point.given? ? start_time.to_r : launch_time(point, [], default: nil)

          if Session.perform&.[](:source) == :replay
            return change(:record, :audio, time, data: { path: path.to_s, replay: true }) { |_t| }
          end

          rec = Recorder.new(path.to_s, channels: @channels, sample_rate: output_open? ? sample_rate : 48000, output: output, overwrite: overwrite)
          change(:record, :audio, time, data: { path: path.to_s }) { |_t|
            rec.start(@landing_frame || @frame)
            @recording_lock.synchronize { @recordings << rec }
          }
        end

        # Stops every recording of the master bus at the launch point
        # (right away by default).  Returns the Change.
        def stop_recording(at: nil, start_time: nil)
          point = at || LaunchPoint::NONE
          time = start_time && !point.given? ? start_time.to_r : launch_time(point, [], default: nil)
          change(:stop_record, :audio, time, data: {}) { |_t|
            frame = @landing_frame || @frame
            @recording_lock.synchronize { @recordings.each { |r| r.stop(frame) } }
          }
        end

        # The recordings of the master bus (Recorders), oldest first.
        def recordings
          @recording_lock.synchronize { (@all_recordings + @recordings).uniq }
        end

        private

        def init_audio_recording
          @recording_lock = Mutex.new
          @recordings = []
          @all_recordings = []
        end

        # Gives the recorders the buffer of the mix that starts at session
        # frame +frame+ (called by #process_buffer after the output write).
        def record_mix(mix, frame)
          list = @recording_lock.synchronize { @recordings.dup }
          return if list.empty?

          done = list.select { |r| r.write(mix, frame) }
          return if done.empty?

          @recording_lock.synchronize {
            @recordings -= done
            @all_recordings.concat(done)
            @all_recordings.shift while @all_recordings.length > 16
          }
          done.each do |r|
            @journal.note_entry(kind: :recorded, subject: :audio, lands: stamp(nil, frame: r.stop_frame), data: { path: r.path, seconds: r.seconds, peak: r.peak })
          end
        end

        # Finishes every recording (when the Session closes).
        def close_recordings
          list = @recording_lock.synchronize { @recordings.dup.tap { @recordings.clear } }
          list.each(&:wait)
          @recording_lock.synchronize { @all_recordings.concat(list) }
        end
      end
    end
  end
end

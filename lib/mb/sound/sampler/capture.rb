module MB
  module Sound
    module Sampler
      # An output that keeps what is written to it in memory (for #bounce):
      # a NullOutput that doesn't sleep, collecting each channel's buffers.
      class CaptureOutput < NullOutput
        def initialize(channels:, sample_rate: 48000, buffer_size: 800)
          super(channels: channels, sample_rate: sample_rate, buffer_size: buffer_size, sleep: false)
          @bufs = Array.new(channels) { [] }
        end

        def write(data)
          super
          data.each_with_index { |d, c| @bufs[c] << Numo::SFloat.cast(d).dup }
        end

        # The first +frames+ frames written (zeros past the end), one SFloat
        # per channel.
        def channels(frames = nil)
          @bufs.map { |list|
            d = list.empty? ? Numo::SFloat[] : Numo::SFloat.hstack(list)
            next d if frames.nil?
            next d[0...frames].dup if d.length >= frames
            Numo::SFloat.zeros(frames).tap { |z| z[0...d.length] = d unless d.empty? }
          }
        end
      end

      # Live audio being captured into a Sample (MB::Sound#capture_audio):
      # the output a Session's recorder (or a GraphNode::CaptureTap) writes
      # the captured frames to.  #sample is the Sample once #done?.
      class AudioCapture
        # The capture's length in frames.
        attr_reader :frames

        def initialize(frames, root: 60, bpm: nil, channels: 1)
          @frames = Integer(frames)
          @root = root
          @bpm = bpm
          @channel_count = channels
          @bufs = Array.new(channels) { [] }
          @got = 0
          @done = false
          @mutex = Mutex.new
          @cond = ConditionVariable.new
          @sample = nil
        end

        # Adds captured buffers (an Array of channels; any frames past the
        # length are dropped).
        def write(data)
          @mutex.synchronize {
            return if @done
            n = MB::M.min(data[0].length, @frames - @got)
            data.each_with_index { |d, c| @bufs[c] << Numo::SFloat.cast(d[0...n]).dup if c < @channel_count } if n > 0
            @got += n
          }
          close if @got >= @frames
        end

        # Finishes the capture (the recorder calls this when it stops).
        def close
          @mutex.synchronize {
            return if @done
            @done = true
            chans = @bufs.map { |l| l.empty? ? Numo::SFloat.zeros(1) : Numo::SFloat.hstack(l) }
            @sample = Sample.new(chans, root: @root, bpm: @bpm, name: 'capture')
            @cond.broadcast
          }
        end

        # True once every frame was captured.
        def done?
          @done
        end

        # The captured Sample, or nil until #done?.
        def sample
          @sample
        end

        # Waits until #done? (up to +timeout+ seconds), returning self.
        def wait(timeout = nil)
          @mutex.synchronize { @cond.wait(@mutex, timeout) unless @done }
          self
        end

        # Frames captured so far.
        def captured
          @got
        end

        def to_s
          "AudioCapture (#{@got}/#{@frames} frames#{@done ? ', done' : ''})"
        end

        def inspect
          "#<#{self.class.name} #{self}>"
        end
      end
    end

    module GraphNode
      # A silent node that captures another node's output into a
      # Sampler::AudioCapture (MB::Sound#capture_audio with +from:+ a
      # node), ending once the capture is full.
      class CaptureTap
        include GraphNode
        include SampleRateHelper

        def initialize(source, capture, sample_rate: nil)
          @source = source.get_sampler
          @capture = capture
          @sample_rate = (sample_rate || source.sample_rate).to_f
          @node_type_name = 'CaptureTap'
        end

        def sample(count)
          return nil if @capture.done?
          b = @source.sample(count)
          if b.nil? || b.empty?
            @capture.close
            return nil
          end
          @capture.write([b.is_a?(Numo::SComplex) || b.is_a?(Numo::DComplex) ? b.real : b])
          Numo::SFloat.zeros(b.length)
        end

        def sources
          { input: @source }
        end
      end
    end
  end
end

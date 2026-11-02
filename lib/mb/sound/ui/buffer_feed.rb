module MB
  module Sound
    module UI
      # Snapshots of audio that isn't a Session's mix, for a band's meters
      # and scope (play-ui-1: the old cursor-up text meters, MB::Sound::Meter,
      # gave way to the UI's meters everywhere): bin/record.rb's input and
      # what a PlotOutput writes.  The audio thread #push-es each buffer
      # (MasterMeter and ScopeRing, as a Session's UI::Feed keeps them); the
      # painter takes #snapshot (a Band's +source:+).  Peaks between frames
      # are never missed.
      #
      #     feed = UI::BufferFeed.new(channels: 2, sample_rate: 48000)
      #     band = UI::Band.new(layout: UI.layouts[:vis], source: feed.method(:snapshot)).start
      #     loop { feed.push(input.read(800)) }
      class BufferFeed
        attr_reader :channels, :sample_rate

        # Frames pushed so far.
        attr_reader :frames

        def initialize(channels:, sample_rate: 48000, scope_length: Feed::SCOPE_LENGTH)
          @channels = channels
          @sample_rate = sample_rate.to_f
          @meter = MasterMeter.new(channels, @sample_rate)
          @scope = ScopeRing.new(channels, scope_length)
          @lock = Mutex.new
          @frames = 0
          @seq = 0
          @buffer = 0
          @last = nil
        end

        # Adds one buffer (an Array of channels; complex values count as
        # their real part).  Returns self.
        def push(bufs)
          n = bufs[0]&.length.to_i
          return self if n == 0
          bufs = bufs.map { |c| c.is_a?(Numo::SFloat) ? c : Numo::SFloat.cast(c.respond_to?(:real) ? c.real : c) }
          @lock.synchronize {
            @meter.process(bufs)
            @scope.write(bufs)
            @frames += n
            @buffer = n
          }
          self
        end

        # A Snapshot of the buffers since the last one (the master meters
        # and scope; nil before the first buffer).
        def snapshot
          @lock.synchronize {
            return @last if @frames == 0
            @seq += 1
            @last = Snapshot.fake(
              seq: @seq, time: MB::U.clock_now, frame: @frames, playing: true, sample_rate: @sample_rate, buffer_size: @buffer,
              master: @meter.take, scope: @scope.to_a
            )
          }
        end
      end
    end
  end
end

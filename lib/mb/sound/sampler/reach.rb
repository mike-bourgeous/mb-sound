module MB
  module Sound
    module Sampler
      # The keys a drum kit's sampler voices can be asked to play, so they
      # build playback tables only for the regions on those keys
      # (bg-latency-1, 2026-11-22).
      #
      # A sample's playback table (its band-limited levels, see
      # Sample::Audio#table) is built the first time a voice needs it: for a
      # SoundFont drum kit that was every sample of the preset, 3-6 s and
      # 300-500 MB for the acoustic kits, where a generated beat plays 5-8
      # of the kit's keys (11-30% of its sample frames).  A kit built for a
      # clip (Instrument#sampler with a Sequence::Clip) now builds the
      # tables of the regions on the clip's keys (Clip#values, as Drums::Kit
      # builds voices for them), and its voices read a silent stand-in table
      # (PLACEHOLDER) for the others: the regions, their order, and every
      # table slot are as a full build makes them, so a note on a covered
      # key plays the same samples, and a note on another key plays
      # silence.  Swaps cover the new clip's keys before they are queued
      # (MIDI::ClipSource#prepare_clip, called by Session#swap on the
      # calling thread): the missing tables are built there and put into
      # the slots the voices read, so nothing is built on the render
      # thread.  Keys are only added, never dropped.
      #
      # Only drum kits (an Instrument with a #drum_map) without a split
      # key reach part of their keys; anything else, and kits played from
      # live MIDI, streams, or files, builds every table (.for gives nil).
      class Reach
        # The table read for regions out of reach: one level of silence.
        def self.placeholder
          @placeholder ||= Sample.new(Numo::SFloat.zeros(64), name: 'out of reach').audio.table(0, false)
        end

        # A Reach of the keys of +source+ for +instrument+ (see the class
        # description), or nil when the instrument builds every table.
        def self.for(instrument, source)
          return nil unless instrument.drum_map && instrument.split.nil?
          return nil unless source.is_a?(Sequence::Clip)
          keys = keys_of(source) or return nil
          extra = Thread.current[:mb_sound_reach_clips]
          extra&.each do |c|
            k = keys_of(c) or return nil
            keys |= k
          end
          new(keys)
        end

        # The note numbers clip +clip+ plays (Integers 0..127), or nil if
        # any value isn't one.
        def self.keys_of(clip)
          return nil unless clip.respond_to?(:values)
          out = []
          clip.values.each do |v|
            n = v.is_a?(Integer) ? v : (v.respond_to?(:number) ? v.number : nil)
            n = n.to_i if n.is_a?(Float) && n == n.round
            return nil unless n.is_a?(Integer) && n.between?(0, 127)
            out << n
          end
          out.uniq
        end

        # Builds inside the block reach the keys of +clips+ too (a carrying
        # rebuild takes over clip sources that may play swapped clips).
        def self.covering(clips, &block)
          return yield if clips.empty?
          Internal.with_local(:mb_sound_reach_clips, (Thread.current[:mb_sound_reach_clips] || []) + clips, &block)
        end

        # The keys covered (sorted, frozen).
        attr_reader :keys

        def initialize(keys)
          @keys = keys.uniq.sort.freeze
          @mutex = Mutex.new
          @tables = {} # [instrument, channel, rate, mips, interpolation] => [specs, rows, slots]
        end

        # True if region +r+ (an Instrument::Region) plays on a covered key.
        def covers?(r)
          lo, hi = r.keys
          @keys.any? { |k| k >= lo && k <= hi }
        end

        # [specs, rows] for +instrument+'s channel +c+ (see
        # Instrument#kernel_tables), shared by the voices of this Reach: its
        # specs Array gets the real tables of keys covered later (#cover).
        def tables(instrument, c, sample_rate, mips:, interpolation:)
          key = [instrument, c, sample_rate, mips, interpolation]
          entry = @mutex.synchronize { @tables[key] } || begin
            specs, rows, slots = instrument.kernel_tables(c, sample_rate, mips: mips, interpolation: interpolation, reach: self, slots: true)
            @mutex.synchronize { @tables[key] ||= [specs, rows, slots] }
          end
          entry[0, 2]
        end

        # Adds the keys of +clip+ (a Clip, or an Array of note numbers),
        # building the tables of the regions on them on the calling thread
        # (yielding between tables) and putting them into every specs Array
        # handed out.  Returns true if keys were added; false if all were
        # covered; nil if +clip+'s keys aren't note numbers (nothing changes;
        # its other notes stay silent).
        def cover(clip)
          keys = clip.is_a?(Array) ? clip : Reach.keys_of(clip)
          return nil if keys.nil?
          new_keys = keys - @keys
          return false if new_keys.empty?

          entries = @mutex.synchronize { @tables.to_a }
          entries.map { |(inst, *), _| inst }.uniq.each { |inst| Reach.notice(inst, nil, new_keys) }
          @mutex.synchronize { @keys = (@keys | new_keys).sort.freeze }
          Reach.yielding {
            entries.each do |(_instrument, c, rate, _mips, _interp), (specs, _rows, slots)|
              slots.each do |index, regions, m, interp|
                next unless specs[index].equal?(Reach.placeholder_spec(rate, interp)) && regions.any? { |r| covers?(r) }
                specs[index] = Instrument.table_spec(regions[0].sample, c, m, rate, interp)
              end
            end
          }
          true
        end

        # Says at the console (live mode only) that +instrument+ is about
        # to build playback tables, and for how many samples (those on
        # +reach+'s keys, or +keys+, or all for no reach), when any is new:
        # a kit's first load takes a second or more.  Returns the message,
        # or nil.
        def self.notice(instrument, reach, keys = nil)
          return nil unless MB::Sound.live?
          regions = instrument.layers ? instrument.layers.flat_map(&:regions) : instrument.regions
          regions = regions.select { |r| keys ? keys.any? { |k| k.between?(r.keys[0], r.keys[1]) } : reach.covers?(r) } if reach || keys
          todo = regions.map(&:sample).uniq.reject { |s| s.audio.table?(0, s.mips.nil? ? instrument.mips : s.mips) }
          return nil if todo.empty?
          name = instrument.name || 'sampler'
          msg = "#{name}: building playback tables for #{todo.length} sample#{'s' if todo.length != 1} (first use)"
          $stdout.puts "\e[2m#{msg}\e[0m"
          $stdout.flush
          msg
        end

        # Runs the block (a build of playback tables: seconds of Ruby and
        # FFTs holding the GVL) with the calling thread handing the GVL to
        # a live Session's render thread whenever that waits for it
        # (UI::Yielding, as the warm-up and painter threads do), unless it
        # yields already.  Elsewhere (renders, specs, no fast_ui) it just
        # runs the block.
        def self.yielding
          render = Session.existing&.render_thread
          y = render&.alive? && render != Thread.current && defined?(MB::Sound::UI::Yielding) && MB::Sound::UI::Yielding.available? &&
              !FastUI::GVLYield.yielders.include?(Thread.current)
          y &&= MB::Sound::UI::Yielding.join(Thread.current, render: render)
          yield
        ensure
          MB::Sound::UI::Yielding.leave(Thread.current) if y
        end

        # The placeholder's kernel spec at +rate+ for +interpolation+.
        def self.placeholder_spec(rate, interpolation)
          placeholder.kernel_spec(rate, interpolation)
        end
      end
    end
  end
end

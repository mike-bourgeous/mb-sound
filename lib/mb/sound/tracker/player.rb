require 'set'

module MB
  module Sound
    module Tracker
      # Steps a Song the way a tracker's replay routine does, row by row and
      # tick by tick, and records what every channel plays on every tick:
      # which sample starts (and from where), its playback rate in Hz, its
      # volume (0..1, envelopes and global volume included), and its pan
      # (-1..1).  Tracker::Import turns the recording into clips.
      #
      # Each format's effects are a subclass (Player::MOD, Player::S3M,
      # ...): #row_effect runs a cell's effect on the row's first tick,
      # #tick_effect on the others.  The base class walks the order list
      # (skipping S3M/IT marker entries), handles pattern breaks, jumps,
      # loops, and delays, stops when the song comes back to a row it
      # already played (the song's loop: Result#restart), and keeps the
      # visits (one per order entry played: its pattern and rows) that
      # become sections.
      #
      # +mode+ :musical works with exact equal-tempered periods (Floats);
      # :hardware with the format's integer period tables and rounding,
      # so pitches and slides land where the original replay put them.
      class Player
        # One played order entry: +order+ (index in the order list),
        # +pattern+, the +rows+ played ([row, first tick, ticks] each), and
        # its +start+ and +stop+ ticks.
        Visit = Struct.new(:order, :pattern, :rows, :start, :stop, keyword_init: true) do
          def ticks = stop - start
          def first_row = rows.first&.first
        end

        # A sample starting on a channel: at +tick+, +sample+ (0-based index
        # into Song#samples), from +offset+ frames, as neutral +note+.
        Trigger = Data.define(:tick, :sample, :offset, :note)

        # What one channel (a pattern channel, or a background voice of IT's
        # new note actions) played: +triggers+ and, per tick, +freq+ (Hz,
        # nil while silent), +volume+ (0..1), +pan+ (-1..1).
        class Log
          attr_reader :triggers, :freq, :volume, :pan, :name

          def initialize(name)
            @name = name
            @triggers = []
            @freq = []
            @volume = []
            @pan = []
          end

          # True if anything sounded.
          def used?
            !@triggers.empty?
          end
        end

        # The recording: +logs+ (one per channel, then background voices),
        # +visits+, +tempos+ ([[tick, bpm], ...] from tick 0), +ticks+ (the
        # song's length), +restart+ ([visit index, tick] where the song
        # loops back to, or nil when it ends), and +unsupported+ (effect
        # names that were skipped, with counts).
        Result = Data.define(:song, :logs, :visits, :tempos, :ticks, :restart, :unsupported, :channels)

        # The most ticks a song may play (about 2 hours at tempo 125).
        MAX_TICKS = 360_000

        # The 64-step vibrato and tremolo sine (half a cycle, as in
        # ProTracker).
        SINE = [0, 24, 49, 74, 97, 120, 141, 161, 180, 197, 212, 224, 235, 244, 250, 253,
                255, 253, 250, 244, 235, 224, 212, 197, 180, 161, 141, 120, 97, 74, 49, 24].freeze

        # Seconds per tick at +tempo+ BPM.
        def self.tick_seconds(tempo)
          2.5 / tempo
        end

        # The Player subclass for +song+'s format.
        def self.for(song, **options)
          klass = case song.format
                  when :mod then MOD
                  when :"669" then SixSixNine
                  when :s3m then S3M
                  when :xm then XM
                  when :it then IT
                  else raise ArgumentError, "No player for #{song.format.inspect}"
                  end
          klass.new(song, **options)
        end

        # Channel state (see Player#channel_state).
        class Channel
          attr_accessor :index, :sample, :instrument, :note, :period, :target, :volume, :pan, :finetune, :memory, :vib_pos, :vib_wave,
                        :trem_pos, :trem_wave, :loop_row, :loop_count, :delay_note, :cut_tick, :retrig, :out_period, :out_volume, :offset,
                        :voice, :glissando, :tremor, :channel_volume, :key_on, :arp, :last_note, :pan_slide, :env_tick, :fade, :pending,
                        :note_volume, :vol_column

          def initialize(index, pan)
            @index = index
            @sample = nil
            @instrument = nil
            @note = nil
            @period = nil
            @target = nil
            @volume = 0
            @pan = pan
            @finetune = 0
            @memory = Hash.new(0)
            @vib_pos = 0
            @vib_wave = 0
            @trem_pos = 0
            @trem_wave = 0
            @loop_row = 0
            @loop_count = 0
            @delay_note = nil
            @cut_tick = nil
            @retrig = nil
            @out_period = nil
            @out_volume = nil
            @offset = 0
            @voice = nil
            @glissando = false
            @tremor = nil
            @channel_volume = 64
            @key_on = false
            @arp = nil
            @last_note = nil
            @pan_slide = nil
            @env_tick = nil
            @fade = nil
            @pending = nil
            @note_volume = nil
            @vol_column = nil
          end
        end

        attr_reader :song, :mode

        def initialize(song, mode: :musical, max_ticks: MAX_TICKS)
          raise ArgumentError, "mode: is :musical or :hardware (got #{mode.inspect})" unless %i[musical hardware].include?(mode)
          @song = song
          @mode = mode
          @max_ticks = max_ticks
          @unsupported = Hash.new(0)
        end

        def hardware?
          @mode == :hardware
        end

        # Plays the song through once and returns a Result.
        def run
          setup
          visits = []
          visited = {}
          restart = nil
          order = next_order(0)
          row = 0
          while order && @tick < @max_ticks
            pattern_index = @song.orders[order]
            pattern = pattern_at(pattern_index)
            row = 0 if row >= pattern.length
            visit = Visit.new(order: order, pattern: pattern_index, rows: [], start: @tick, stop: @tick)
            visits << visit
            @loop_rows_reset = nil
            jumped = nil
            while row < pattern.length
              key = [order, row]
              if visited.key?(key)
                restart = visited[key]
                break
              end
              visited[key] = [visits.length - 1, @tick]
              @break_to = nil
              @jump_to = nil
              @loop_to = nil
              @delay_rows = 0
              @row_tick_start = @tick
              cells = pattern.rows[row] || []
              start_row(order, row, cells)
              ticks = @speed * (1 + @delay_rows)
              ticks.times { |t| play_tick(t, cells) }
              visit.rows << [row, @row_tick_start, @tick - @row_tick_start]
              visit.stop = @tick

              if @loop_to
                # (rows of the loop body play again: forget them)
                (@loop_to..row).each { |r| visited.delete([order, r]) }
                row = @loop_to
                next
              end
              if @jump_to || @break_to
                jumped = [@jump_to, @break_to]
                break
              end
              row += 1
              break if @tick >= @max_ticks || @stopped
            end
            visits.pop if visit.rows.empty?
            break if restart || @stopped

            if jumped
              target, break_row = jumped
              order = target.nil? ? next_order(order + 1) : next_order(target, wrap: true)
              row = break_row || 0
            else
              order = next_order(order + 1)
              row = 0
            end
            if order.nil? && @song.restart
              order = next_order(@song.restart)
              row = 0
            end
            if order && (v = visited[[order, row.clamp(0, pattern_at(@song.orders[order]).length - 1)]])
              restart = v
              break
            end
          end
          finish
          restart = split_restart(visits, restart) if restart
          Result.new(song: @song, logs: @logs, visits: visits, tempos: @tempos, ticks: @tick, restart: restart,
                     unsupported: @unsupported.dup.freeze, channels: @song.channels)
        end

        private

        def setup
          @tick = 0
          @speed = @song.speed
          @tempo = @song.tempo
          @tempos = [[0, @tempo]]
          @global_volume = @song.global_volume.to_f
          @stopped = false
          @channels = Array.new(@song.channels) { |c| Channel.new(c, @song.pans[c] || 0.0) }
          @channels.each_with_index { |ch, c| ch.channel_volume = @song.channel_volumes[c] || 64 }
          @logs = Array.new(@song.channels) { |c| Log.new(:"ch#{c + 1}") }
        end

        def finish
          @logs.each { |l| pad(l) }
        end

        # A pattern by number (a missing one plays as 64 empty rows).
        def pattern_at(index)
          return EMPTY_PATTERN if index.nil?
          @song.patterns[index] || EMPTY_PATTERN
        end

        EMPTY_PATTERN = Pattern.new(rows: Array.new(64) { [] })

        # The next order index at or after +i+ that plays a pattern
        # (skipping S3M/IT 254 markers; nil at the end or a 255 marker).
        def next_order(i, wrap: false)
          i = 0 if wrap && i >= @song.orders.length
          while i < @song.orders.length
            p = @song.orders[i]
            return nil if p == 255
            return i unless p == 254
            i += 1
          end
          nil
        end

        # A restart in the middle of a visit splits it there, so the
        # loop's target starts a section: returns [visit index, tick].
        def split_restart(visits, restart)
          index, tick = restart
          v = visits[index]
          return restart if v.nil? || v.start == tick
          k = v.rows.index { |r| r[1] == tick }
          return restart if k.nil? || k == 0
          head = Visit.new(order: v.order, pattern: v.pattern, rows: v.rows[0...k], start: v.start, stop: tick)
          tail = Visit.new(order: v.order, pattern: v.pattern, rows: v.rows[k..], start: tick, stop: v.stop)
          visits[index, 1] = [head, tail]
          [index + 1, tick]
        end

        # Row start: the format reads each channel's cell (notes,
        # instruments, volumes, effects' first tick).
        def start_row(order, row, cells)
          @channels.each_with_index { |ch, c| row_cell(ch, cells[c]) }
        end

        def play_tick(t, cells)
          @channels.each_with_index { |ch, c| tick_effect(ch, cells[c], t) if t > 0 }
          @channels.each { |ch| before_record(ch, t) }
          record_tick
          @channels.each { |ch| end_tick(ch, t) }
          @tick += 1
        end

        # Per-channel work after the tick's effects, before it is recorded
        # (auto-vibrato).
        def before_record(ch, t)
        end

        # Per-channel work after the tick is recorded (envelopes and fades
        # move on to the next tick).
        def end_tick(ch, t)
        end

        # Records every channel's output for the current tick.
        def record_tick
          @channels.each_with_index { |ch, c| record(@logs[c], ch) }
        end

        def record(log, ch)
          pad(log)
          s = ch.sample && ch.voice
          freq = s && ch.out_period ? frequency(ch, ch.out_period) : nil
          vol = s ? output_volume(ch) : 0.0
          log.freq[@tick] = freq
          log.volume[@tick] = vol
          log.pan[@tick] = output_pan(ch)
        end

        def pad(log)
          n = log.freq.length
          return if n >= @tick
          log.freq.fill(nil, n...@tick)
          log.volume.fill(0.0, n...@tick)
          log.pan.fill(log.pan.last || 0.0, n...@tick)
        end

        # Starts +sample+ (0-based) on channel +ch+ now, from +offset+.
        def trigger(ch, sample, offset = 0, note = ch.note)
          ch.voice = true
          ch.sample = sample
          s = @song.samples[sample]
          offset = 0 if s && offset >= s.length && !s.loop
          @logs[ch.index].triggers << Trigger.new(tick: @tick, sample: sample, offset: offset, note: note)
        end

        # Stops the channel's sound (note cut).
        def cut(ch)
          ch.voice = nil
        end

        # Notes an effect this player skips (warned once with a count).
        def unsupported(name)
          @unsupported[name] += 1
        end

        # The channel's volume to record (0..1).
        def output_volume(ch)
          v = (ch.out_volume || ch.volume).to_f.clamp(0, 64) / 64.0
          v * @global_volume / 64.0 * ch.channel_volume / 64.0
        end

        def output_pan(ch)
          ch.pan.to_f.clamp(-1.0, 1.0)
        end

        # Tempo (BPM) change from now on.
        def set_tempo(bpm)
          return if bpm == @tempo
          @tempo = bpm
          if @tempos.last[0] == @tick
            @tempos[-1] = [@tick, bpm]
          else
            @tempos << [@tick, bpm]
          end
        end

        # Vibrato/tremolo waveform value at +pos+ (0..63) for +wave+ (0 sine,
        # 1 ramp down, 2 square, 3 random: as sine): -255..255.
        def wave_value(wave, pos)
          pos &= 63
          case wave & 3
          when 1
            v = (pos & 31) * 8
            pos < 32 ? 255 - v : -v
          when 2
            pos < 32 ? 255 : -255
          else
            v = SINE[pos & 31]
            pos < 32 ? v : -v
          end
        end

        # Volume slide: +x+ up or +y+ down (the usual Axy rule: up wins).
        def volume_slide(ch, param)
          x = param >> 4
          y = param & 15
          ch.volume = x > 0 ? [ch.volume + x, 64].min : [ch.volume - y, 0].max
        end
      end
    end
  end
end

require_relative 'player/amiga'
require_relative 'player/mod'
require_relative 'player/six_six_nine'
require_relative 'player/s3m'
require_relative 'player/envelopes'
require_relative 'player/xm'

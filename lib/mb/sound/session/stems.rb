require 'fileutils'

module MB
  module Sound
    class Session
      # Stems: one file per player (track) while a Session renders, each
      # holding that player's contribution to the mix as it enters the
      # master chain (fades, mutes, solos, and ring-outs included), scaled
      # by the master gain.  Every stem starts at the Session's first frame
      # and is padded with silence to the same length as the render, so the
      # files line up sample for sample in any editor.
      #
      # Without a master chain the stems sum to the rendered mix (within
      # float rounding of the order of the sums: players are rendered
      # separately and then added, in the same order as without stems, so
      # the mix itself is unchanged).  With one, they sum to the mix before
      # the chain (times the master gain): compressors, limiters, and master
      # filters act on the sum, so a stem through the master alone wouldn't
      # sound like its part of the mix.
      #
      # With buses (see Buses), a player's stem is the player as heard: its
      # main out if it goes to the master, plus its share of every bus it
      # feeds, from its own copy of each bus, so stems still sum to the mix
      # before the master chain (Writer +buses+ adds each bus's output).
      #
      # Players with the same name (a track's replacements, ringing tails,
      # rebuilt graphs) share one stem; unnamed players (numbered by #bg)
      # get "player_<number>".  Turned on by PlaybackMethods#render's +stems:+
      # (a directory) or Session#stems=.
      module Stems
        # Writes stems to a directory, one file per player name, opened on
        # the player's first frame.
        class Writer
          # The stem files written so far: name => path.
          attr_reader :paths

          # The highest sample magnitude written to each stem: name => peak.
          attr_reader :peaks

          # Writes stems into +dir+ (created if needed) as
          # "<name>.<format>" files at +sample_rate+ with +channels+, scaled
          # by +gain+ (headroom for stems whose part peaks above full scale
          # before a master limiter, which integer formats would clip).
          # +overwrite+ as for MB::Sound.file_output.
          # True to write a stem per bus too (its return; see Buses).
          attr_reader :buses

          # +buses+ also writes each bus's output as its own stem (the
          # tracks' stems already hold their share of every bus).
          def initialize(dir, format: 'flac', channels: 2, sample_rate: 48000, overwrite: false, gain: 1.0, buses: false)
            @buses = buses
            @dir = dir
            @format = format.to_s.delete_prefix('.')
            @channels = channels
            @sample_rate = sample_rate
            @overwrite = overwrite
            @gain = gain.to_f
            @peaks = {}
            @outputs = {}
            @cursors = {}
            @pending = {} # name => [data, frame]: the last part, held back (see #close)
            @paths = {}
            @origin = 0
            FileUtils.mkdir_p(dir)
          end

          # The session frame where stems start (0 by default; a render
          # window's first frame, see RenderWindow): earlier parts are
          # dropped.  Set before the first #add after it.
          attr_accessor :origin

          # Adds +data+ (one Numo array per channel) for the stem +name+,
          # starting at session frame +frame+.  Each stem's last part waits
          # until the next one or #close, which may end the stems inside it
          # (a render ending on the frame its sounds ended, session-2).
          def add(name, data, frame)
            if frame < @origin
              skip = @origin - frame
              return if skip >= data[0].length
              data = data.map { |d| d[skip..] }
              frame = @origin
            end
            output_for(name)
            flush_pending(name)
            data = @gain != 1 ? data.map { |d| d * @gain } : data.map(&:dup)
            peak = data.map { |d| d.abs.max }.max.to_f
            @peaks[name] = peak if peak > @peaks.fetch(name, 0.0)
            @pending[name] = [data, frame]
          end

          # Writes every stem up to +frames+ (the last parts cut there,
          # silence padded up to it) and closes the files.  Warns about
          # stems that went over full scale (clipped in integer formats such
          # as FLAC and WAV).
          def close(frames)
            @outputs.each_key { |name| flush_pending(name, frames); pad(name, frames) }
            @outputs.each_value(&:close)
            @outputs.clear

            over = @peaks.select { |_, p| p > 1.0 }
            unless over.empty?
              worst = over.values.max
              list = over.map { |n, p| "#{n} #{format('%+.1f', 20 * Math.log10(p))} dB" }.join(', ')
              warn "Stems over full scale (clipped in integer formats): #{list}; " \
                "render with stem_gain: #{-(20 * Math.log10(worst)).ceil}.db (--stem-gain #{-(20 * Math.log10(worst)).ceil}) for headroom"
            end
          end

          private

          def output_for(name)
            @outputs[name] ||= begin
              path = File.join(@dir, "#{name}.#{@format}")
              @paths[name] = path
              @cursors[name] = @origin
              MB::Sound.file_output(path, channels: @channels, sample_rate: @sample_rate, overwrite: @overwrite)
            end
          end

          # Writes stem +name+'s held-back part (see #add), cut at session
          # frame +upto+ if given.
          def flush_pending(name, upto = nil)
            data, frame = @pending.delete(name)
            return unless data

            n = data[0].length
            n = MB::M.min(n, upto - frame) if upto
            return if n <= 0

            pad(name, frame)
            data = data.map { |d| d[0...n] } if n < data[0].length
            @outputs[name].write(data)
            @cursors[name] += n
          end

          # Writes silence to stem +name+ up to session frame +frame+.
          def pad(name, frame)
            while @cursors[name] < frame
              n = MB::M.min(frame - @cursors[name], 48000)
              @outputs[name].write(Array.new(@channels) { Numo::SFloat.zeros(n) })
              @cursors[name] += n
            end
          end
        end

        # The stem writer (nil when stems are off).
        attr_reader :stems

        # Sets a Stems::Writer (or nil) to receive each player's part of
        # every rendered span.
        def stems=(writer)
          @stems = writer
        end

        private

        # The stem name of player +p+.
        def stem_name(p)
          name = p.name.is_a?(Symbol) || p.name.is_a?(String) ? p.name.to_s : "player_#{p.name || p.serial}"
          name.gsub(%r{[/\\\0]}, '_')
        end

        # Renders the players of a span one at a time into their own
        # buffers, adds each to +mix+ (in player order, as #render_player
        # would), and sends every player's part (times the master gain) to
        # the stem writer at session frame +frame+.
        def render_players_with_stems(players, mix, from, to, per_sample, count, frame)
          parts = {}
          players.each do |p|
            own = Array.new(@channels) { Numo::SFloat.zeros(count) }
            render_player(p, own, from, to, per_sample, count)
            own.each_with_index { |o, c| mix[c] = mix[c] + o }
            name = stem_name(p)
            if parts[name]
              parts[name] = parts[name].each_with_index.map { |a, c| a + own[c] }
            else
              parts[name] = own
            end
          end
          parts.each { |name, data| @stems.add(name, @master_gain == 1 ? data : data.map { |d| d * @master_gain }, frame) }
        end
      end
    end
  end
end

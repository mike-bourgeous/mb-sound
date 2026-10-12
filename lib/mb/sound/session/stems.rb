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

          # Writes stems into +dir+ (created if needed) as
          # "<name>.<format>" files at +sample_rate+ with +channels+.
          # +overwrite+ as for MB::Sound.file_output.
          def initialize(dir, format: 'flac', channels: 2, sample_rate: 48000, overwrite: false)
            @dir = dir
            @format = format.to_s.delete_prefix('.')
            @channels = channels
            @sample_rate = sample_rate
            @overwrite = overwrite
            @outputs = {}
            @cursors = {}
            @paths = {}
            FileUtils.mkdir_p(dir)
          end

          # Adds +data+ (one Numo array per channel) for the stem +name+,
          # starting at session frame +frame+.
          def add(name, data, frame)
            out = output_for(name)
            pad(name, frame)
            out.write(data)
            @cursors[name] += data[0].length
          end

          # Pads every stem with silence to +frames+ and closes the files.
          def close(frames)
            @outputs.each_key { |name| pad(name, frames) }
            @outputs.each_value(&:close)
            @outputs.clear
          end

          private

          def output_for(name)
            @outputs[name] ||= begin
              path = File.join(@dir, "#{name}.#{@format}")
              @paths[name] = path
              @cursors[name] = 0
              MB::Sound.file_output(path, channels: @channels, sample_rate: @sample_rate, overwrite: @overwrite)
            end
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

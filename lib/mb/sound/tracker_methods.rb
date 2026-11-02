module MB
  module Sound
    # Tracker modules as sets (see MB::Sound::Tracker and
    # design/notes/trackers.md): MOD, 669, S3M, XM, and IT files.
    module TrackerMethods
      # Reads the tracker module at +path+ (.mod, .669, .s3m, .xm, .it) and
      # returns it as a Tracker::Set: a track per channel playing the
      # module's samples, a clip per pattern per channel, a scene per
      # pattern (as played), and a flow through the order list.  `play`,
      # `render`, and `save` take it; `song.setup` puts it on the Session
      # without playing, so `go :p03` launches a pattern as a scene.
      #
      # +mode+ :musical (default: band-limited sample reads, exact
      # equal-tempered pitches, lanes declicked over 1.5 ms, Amiga pans
      # narrowed) or :hardware (drop-sample reads, the format's integer
      # period tables, steps on the tick, pans as written); +separation+
      # sets the stereo width (0..1).  Effects the player skips are listed
      # in one warning.
      #
      #     song = mod_import('tune.mod')
      #     play song
      #     render 'tune.flac', song
      #     song.setup; go :p03; fx :ch2, L.fx.reverb.hall
      def mod_import(path, mode: :musical, separation: nil)
        song = Tracker.read(path)
        song.problems.each { |p| warn "#{File.basename(path.to_s)}: #{p}" }
        set = Tracker::Import.new(song, mode: mode, separation: separation, name: File.basename(path.to_s, '.*')).set
        unless set.unsupported.empty?
          warn "#{File.basename(path.to_s)}: effects not played: #{set.unsupported.map { |n, c| "#{n} (#{c}x)" }.join(', ')}"
        end
        set
      end
      alias tracker_import mod_import

      # The samples of the tracker module at +path+, as Samples (named
      # with their numbers; empty slots left out).
      #
      #     s = mod_samples('tune.mod'); play s[2]
      def mod_samples(path)
        song = Tracker.read(path)
        song.samples.each_with_index.filter_map { |s, i| Tracker::Import.sample_of(s, i) }
      end
    end
  end
end

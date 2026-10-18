module MB
  module Sound
    module GraphNode
      # Mastering presets and the loudness rider as graph methods
      # (mastering-1; see Mastering).  Included in GraphNode and Channels;
      # bundles go through whole (one chain for every channel).
      module MasteringMethods
        # Runs this signal (usually the whole mix, a stereo bundle) through
        # mastering preset +preset+ (:club, :streaming, :quiet, :vinyl, or a
        # Mastering::Preset) with +options+ (see Mastering.preset: +lufs:+,
        # +platform:+, +ceiling:+, +drive:+, +ride:+, +mono:+, +glue:+,
        # +clip:+, +de_ess:+).  Also available as #mastering.
        #
        # The chain's trim (its gain stage) is the preset's +drive+, or the
        # gain a render measured to reach the target (see
        # PlaybackMethods#render), or a rider (+ride: true+).
        #
        #     master { |mix| mix.reverb(:hall, wet: -12.db).master(:club) }
        #     play file_input('mix.flac').master(:streaming, platform: :apple)
        def master(preset = :club, **options)
          Mastering.build(Mastering.preset(preset, **options), self)
        end
        alias mastering master

        # Rides this signal's level toward +target+ (LUFS, or a
        # Loudness::TARGETS name) with a slow gain from its short-term
        # loudness (see Rider: +start+, +range+, +down+, +up+, +gate+).
        # Put a limiter after it.
        #
        #     master { |mix| mix.ride(-14).limit(ceiling: -1.db) }
        def ride(target, start: 0.db, range: 9.db, down: 3.0, up: 10.0, gate: 10.0)
          target = Mastering.target_of(target).lufs unless target.is_a?(Numeric)
          Rider.new(outputs, target: target, start: start, range: range, down: down, up: up, gate: gate)
        end
      end
    end
  end
end

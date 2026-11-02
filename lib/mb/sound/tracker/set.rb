module MB
  module Sound
    module Tracker
      # A module as a set (see Tracker and Tracker::Import): a track per
      # channel, a scene per pattern visit, and the flow that plays the
      # order list.  #setup puts it on the current Session (tempo, tracks,
      # scenes, the flow, built but not playing), #play plays it, and
      # `play set`, `render(file, set)`, and `save :name, set` take it.
      #
      #     song = mod_import('tune.mod')
      #     play song                       # once through (loop: true repeats)
      #     song.setup; go :p03             # a pattern as a scene, looping
      #     song.scenes                     # [:p00, :p01, ...]
      #     song[:p03][:ch2]                # a channel's clip there
      class Set
        # The Tracker::Import this came from.
        attr_reader :import

        # Track names (:ch1, ...), in channel order.
        attr_reader :tracks

        # The sampler instrument every track plays.
        attr_reader :instrument

        # The song's base tempo (BPM).
        attr_reader :bpm

        # The sampler options of every track (Sampler::Instrument#play).
        attr_reader :voice

        # Effects the player skipped ({ 'E3x glissando' => 4 }).
        attr_reader :unsupported

        # [[scene name, whole notes], ...]: the flow's sections in order.
        attr_reader :plays

        # The index in #plays where a looping song comes back to (nil if
        # the song ends).
        attr_reader :restart

        # What each track's sampler goes through: { mix_rate:, bass_mono:,
        # rolloff: } (see Import#initialize).
        attr_reader :post

        def initialize(import:, tracks:, scenes:, plays:, restart:, bpm:, voice:, instrument:, unsupported:, post: {})
          @import = import
          @tracks = tracks.freeze
          @scenes = scenes.freeze
          @plays = plays.freeze
          @restart = restart
          @bpm = bpm
          @voice = voice.freeze
          @instrument = instrument
          @unsupported = unsupported
          @post = post.freeze
          freeze
        end

        # The Song.
        def song
          @import.song
        end

        # :musical or :hardware.
        def mode
          @import.mode
        end

        def name
          @import.name
        end

        # Scene names, in the order they first play.
        def scenes
          @scenes.keys
        end

        # The clips of scene +name+ by track ({ ch1: clip, ... }).
        def [](name)
          s = @scenes.fetch(name) { raise ArgumentError, "No scene #{name.inspect} in #{self.name.inspect}#{Form.suggest(name, scenes)}" }
          s[:clips]
        end

        # The tempo scene +name+ starts at (BPM).
        def tempo_of(name)
          @scenes.fetch(name)[:tempo]
        end

        # Seconds the song plays once through.
        def seconds
          @plays.sum { |name, len|
            s = @scenes[name]
            changes = [[0r, s[:tempo]], *s[:changes], [len, nil]]
            changes.each_cons(2).sum { |(a, bpm), (b, _)| Sequence::TempoMap.seconds_at(b - a, bpm) }
          }.to_f
        end

        # Ticks per row is the Song's speed; a tick is
        # 1/TICKS_PER_WHOLE of a whole note.
        def whole_notes
          @plays.sum(0r) { |_, len| len }
        end

        # The patch every track plays a clip with.
        def patch
          inst = @instrument
          options = @voice
          rate = @post[:mix_rate]
          mono = @post[:bass_mono]
          top = @post[:rolloff]
          return proc { |clip| clip.sampler(inst, **options) } unless rate || mono || top
          proc { |clip|
            out = clip.sampler(inst, **options)
            out = out.decimate(rate, interpolation: :linear) if rate
            out = out.filter(:lowpass, cutoff: top, quality: Math.sqrt(0.5)) if top
            out = out.mono_below(mono) if mono
            out
          }
        end

        # Sets the set up on the current Session (or +session+): the base
        # tempo, a track per channel, the scenes, and the flow (built, not
        # playing; +loop+ true adds a goto back to where the song loops).
        # Returns the Form.
        def setup(session: nil, loop: false)
          return Session.with_context(session: session) { setup(loop: loop) } if session && !session.equal?(Session.current)
          MB::Sound.bpm(@bpm)
          p = patch
          @tracks.each { |t| MB::Sound.track(t, &p) }
          changing = @scenes.values.map { |s| s[:tempo] }.uniq.length > 1 || @scenes.values.any? { |s| !s[:changes].empty? }
          @scenes.each { |n, s|
            values = s[:clips].dup
            values[:tempo] = s[:tempo] if changing
            if s[:changes].empty?
              MB::Sound.scene(n, **values)
            else
              changes = s[:changes]
              MB::Sound.scene(n, **values) { changes.each { |pos, bpm| MB::Sound.tempo(bpm, in: Sequence::Duration.new(pos)) } }
            end
          }
          # (a song that ends stops there, as a tracker does: its looping
          # samples would ring out forever)
          MB::Sound.scene(END_SCENE, others: :cut)
          form(loop: loop)
        end

        # The scene that ends the song: every track stops (a 5 ms declick).
        END_SCENE = :fin

        # The flow (a Form): a section per visit, named after its scene,
        # for its length, then a tick of END_SCENE (every track stops);
        # with +loop+, a label :loop where the song loops back to and a goto
        # there before the end.  Built on the current Session's arrangement
        # (its last form).
        def form(loop: false)
          plays = @plays
          restart = loop ? @restart : nil
          fin = END_SCENE
          Session.current.arrangement.build_form {
            plays.each_with_index { |(n, len), i|
              label :loop if i == restart
              __send__(n, Sequence::Duration.new(len))
            }
            goto :loop if restart
            __send__(fin, Sequence::Duration.new(1/96r))
          }
        end

        # #setup, then plays the flow (options to FormMethods#play_form).
        # Returns the Form::Playback.
        def play(loop: false, **options)
          f = setup(loop: loop)
          MB::Sound.play_form(f, **options)
        end

        # The set set up on a Session of its own (not the current one;
        # nothing plays), as an Arrangement: what `save :song, set` saves
        # (GraphIO.dump takes anything with #to_arrangement).  With +loop+,
        # the flow loops as #setup's does.
        def to_arrangement(loop: false)
          s = Session.new(output: NullOutput.new(channels: 2, sleep: false), transport: Sequence::Transport.new(bpm: @bpm), channels: 2,
                          realtime: false, raise_errors: true)
          setup(session: s, loop: loop)
          s.arrangement
        end

        def to_s
          secs = seconds
          "#{song.format} #{name.inspect} as a set (#{mode}): #{@tracks.length} tracks, #{@scenes.length} scenes, #{@plays.length} sections, " \
            "#{(secs / 60).floor}:#{format('%02d', secs.round % 60)}#{', loops' if @restart}"
        end

        def inspect
          "#<MB::Sound::Tracker::Set #{self}>"
        end
      end
    end
  end
end

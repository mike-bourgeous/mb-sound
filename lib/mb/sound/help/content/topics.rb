# Help topics for the bin/sound.rb console (`help :knobs`, `help.topics`).
#
# Written in `module MB::Sound` (not Help) so notes like A1 in examples
# resolve through MB::Sound.const_missing, as they do in the console.  Only
# the names, a blurb, and the examples are hand-written: each name's line
# comes from its doc comment.  The guard spec (spec/lib/mb/sound/help_spec.rb)
# checks every name, plays every example, and checks its level: peaks at
# most Help::Level::EXAMPLE_PEAK_OVER_TONE_DB over the tone, loudness within
# Help::Level::EXAMPLE_LOUDNESS_WINDOW of the level check tone (a triangle
# peaking at -30 dBFS, about -35 LUFS).  Tones at about -20 dB before the
# master bus land there; the monitor trim (help.level) brings them to the
# listening level.
# Player names start with `try` so an example never replaces your players.
module MB
  module Sound
    Help.topic :play, 'Playing things', group: :start do
      about <<~TEXT
        Everything plays through one background Session that mixes every
        player on a shared timeline; `play` is the foreground version
        (Ctrl-C to stop).  Commands return journal entries that say where
        they land.  Sounds end through envelopes, clips, `until`, or `stop`.
      TEXT
      commands :bg, :stop, :outro, :panic, :players, :stopped, :resume, :forget, :play, :wait, :master_gain, :monitor_gain, :warm_up
      dsl :at, :until, :and_then
      note :method_modules
      see :sets, :now, :files
      example 'a quiet triangle that stops itself' do
        bg :try, 220.hz.triangle.at(-20.db).until(2.bars)
      end
      example 'a pattern on the next bar' do
        bass = seq(A1, A1, rest, A2, A1, rest, G1, E1).n8.loop
        bg :try, bass.tone.ramp.at(-12.db).lp4(600, resonance: 0.4) * bass.amp_env
      end
    end

    Help.topic :files, 'Files, inputs, and outputs', group: :start do
      about <<~TEXT
        Read and write sound files (anything ffmpeg knows), play files and
        live input through graphs, and choose the output and its latency.
      TEXT
      commands :read, :write, :list, :file_input, :file_output, :input, :output, :use_output, :latency, :loopback, :close_outputs
      note :audio_io
      see :record
      example 'two bars of a drum file' do
        bg :try, file_input('sounds/drums.flac').at(-8.db).until(2.bars)
      end
    end

    Help.topic :tones, 'Oscillators and pitches', group: :sound do
      about <<~TEXT
        `440.hz` is a Pitch; oscillator methods make a Tone (antialiased by
        default, `a*` twins are naive).  Phases are in cycles.  Lengths
        (`250.ms`, `1.n8`) and intervals (`7.semitones`) work everywhere.
      TEXT
      commands :silence, :impulse
      dsl :ramp, :square, :triangle, :sine, :pulse, :pwm, :fm, :pm, :fm_feedback, :sync, :unison, :swarm,
        :wavetable, :harmonics, :noise, :lfo, :transpose, :glide
      note :oscillators, :numbers_lengths_phases
      see :envelopes, :filters, :random
      example 'detuned unison saws' do
        bg :try, 110.hz.unison(5, detune: 0.2) { |p| p.saw }.lp4(1200).at(-24.db).until(2.bars)
      end
      example 'FM bell' do
        bg :try, 440.hz.fm(660.hz.at(400) * env([[1, 0], [0, 1.5, 60]])).at(-16.db) * env([[1, 0.005], [0, 2, 40]])
      end
    end

    Help.topic :envelopes, 'Envelopes and curves', group: :sound do
      about <<~TEXT
        Envelopes land exactly on their targets at whole samples; curves
        are signed dB (+60 falls like a 60 dB exponential).  Without a gate
        they are one-shots.
      TEXT
      commands :adsr, :env, :amp_env, :filter_env, :fm_env, :sq80_env, :tween, :bounce_hits
      dsl :smooth, :ease
      note :envelopes, :curves
      example 'a plucked note' do
        bg :try, 220.hz.saw.at(-12.db).lp4(300 + env([[3000, 0.002], [0, 0.4, 40]])) * env([[1, 0.002], [0, 0.8, 60]])
      end
    end

    Help.topic :filters, 'Filters', group: :sound do
      about <<~TEXT
        Cookbook filters (`filter(:lowpass, cutoff:, quality:)`) build SVFs
        whose parameters can move every sample; `lp4` is a CEM3379-style
        four-pole, `diode` a 303-style ladder with the same knobs.
      TEXT
      dsl :filter, :lp4, :diode, :peq, :formant, :smooth
      note :filters
      see :knobs
      example 'a swept four-pole' do
        bg :try, 55.hz.ramp.at(-16.db).lp4(tween([200.hz, 4000.hz, 200.hz], 2.bars), resonance: 0.6).until(2.bars)
      end
    end

    Help.topic :effects, 'Effects', group: :sound do
      about <<~TEXT
        Delays (sinc-interpolated, tempo-synced lengths), feedback loops that
        run one sample at a time in C, the FDN reverb with presets, the
        Juno chorus, and antialiased shapers.
      TEXT
      dsl :delay, :multitap, :feedback, :reverb, :chorus, :softclip, :clip, :decimate, :quantize, :ease, :oversample
      note :delays, :feedback_loops, :reverbs, :chorus
      see :dynamics, :mixing
      example 'a dotted-eighth echo' do
        blip = seq(E5, rest, rest, rest, B4, rest, rest, rest).n8.loop
        bg :try, (blip.tone.triangle.at(-14.db) * blip.amp_env).delay(1.n8.dotted, feedback: 0.5)
      end
      example 'a plate' do
        clip = seq(E4, rest, B4, rest).n8.loop
        notes = clip.tone.saw.at(-16.db) * clip.amp_env
        bg :try, stereo(notes, notes).reverb(:plate)
      end
    end

    Help.topic :dynamics, 'Dynamics', group: :sound do
      about <<~TEXT
        One compander core: compress, expand, gates, ducking, compand
        curves, a true-peak limiter, crossover bands, and squeeze.
      TEXT
      dsl :compress, :expand, :noise_gate, :duck, :compand, :limit, :bands, :squeeze, :loudness_meter
      note :dynamics
      see :mixing
      example 'ducking a pad under a kick' do
        kick = tr808(grid(16, kick: 'x...x...x...x...').loop)
        bg :try, 110.hz.saw.at(-16.db).lp4(900).duck(kick.at(-12.db)) + kick.at(-12.db)
      end
    end

    Help.topic :stereo, 'Stereo and channels', group: :sound do
      about <<~TEXT
        Bundles (`stereo(l, r)`) broadcast DSL calls per channel; per-channel
        arguments come from bundles or `per_channel`.
      TEXT
      commands :stereo, :channels, :per_channel, :spread
      dsl :pan, :balance, :width, :mono, :mid_side, :matrix, :place, :left, :right
      note :multichannel
      example 'two detuned channels, narrowed' do
        bg :try, stereo(220.hz.saw, 220.5.hz.saw).lp4(1500).at(-20.db).width(0.6).until(2.bars)
      end
    end

    Help.topic :drums, 'Drums', group: :sound do
      about 'A TR-808-flavored kit driven by a grid (Sequence::Kit) or MIDI.'
      commands :tr808, :grid, :euclid
      note :drums
      example 'four on the floor' do
        bg :try, tr808(grid(16, kick: 'x...x...x...x...', hat: 'x.x.x.x.x.x.x.x.').loop).at(-14.db)
      end
    end

    Help.topic :random, 'Randomness and seeds', group: :sound do
      about <<~TEXT
        Everything random (phases, noise, unison layouts, synth lanes) draws
        from one root generator, so the same seed makes the same sounds.
      TEXT
      commands :seed, :with_seed, :next_seed, :random_seed
      dsl :rnd, :noise, :humanize, :chance
      see :tones
      example 'noise that repeats' do
        seed 42
        bg :try, 1000.hz.noise.lp4(3000).at(-12.db).until(1.bar)
      end
    end

    Help.topic :sequences, 'Clips and sequences', group: :time do
      about <<~TEXT
        Immutable clips in exact whole notes: `seq(C4, E4, G4).n8`,
        `grid('x...')`; a clip is a MIDI source (`clip.tone`, `clip.env`,
        `clip.synth`) and has transforms (transpose, swing, chance, ...).
      TEXT
      commands :seq, :grid, :events, :rest, :euclid, :melody, :acid, :chord, :arp, :strum, :echo, :scale
      dsl :loop, :n8, :n16, :transpose, :swing, :humanize, :chance, :every, :reverse, :synth, :tone, :amp_env, :swap
      note :sequences
      see :tempo, :sets
      example 'a looping arpeggio' do
        clip = seq(A3, C4, E4, G4).n16.loop
        bg :try, clip.tone.triangle.at(-12.db) * clip.amp_env
      end
    end

    Help.topic :tempo, 'Tempo, tuning, and the timeline', group: :time do
      about <<~TEXT
        One transport for everything: tempo, a meter map, and bar numbers
        that stay stable.  Durations (`1.n8.dotted`, `2.bars`) follow the
        tempo; `1.beat.hz` locks a tone to the beat; `tuning` moves every
        Note.
      TEXT
      commands :bpm, :meter, :rewind, :seek, :bar, :transport, :tuning
      note :tempo_sync, :numbers_lengths_phases
      see :schedule
      example 'a tempo-locked wobble' do
        bg :try, 55.hz.ramp.at(-16.db).lp4(400 + 1.beat.hz.lfo.triangle * 300 + 300).until(2.bars)
      end
    end

    Help.topic :schedule, 'Scheduling', group: :time do
      about <<~TEXT
        Blocks on the Session timeline: commands inside them land exactly at
        the block's time, and each block is one undo step.  `at_bar`,
        `after`, and `every` take launch points too (`at_bar in: 2.beats`,
        `every 1.n4, on: :beat`) and return a handle that prints when it
        runs and has `cancel`.  `reset_scheduler` (or `panic`, which also
        stops the players) cancels everything scheduled, stops a song
        form, and replaces a stuck scheduler.
      TEXT
      commands :at_bar, :after, :every, :scheduled, :cancel, :reset_scheduler, :marker, :at_marker
      note :method_modules
      example 'a note that answers itself' do
        bg :try, 330.hz.triangle.at(-20.db).until(1.bar)
        after(1) { bg :try2, 440.hz.triangle.at(-22.db).until(1.bar) }
      end
      example 'ticks you can cancel' do
        bg :try, 330.hz.triangle.at(-20.db).until(2.bars)
        ticks = every(1.n4, on: :beat) { bg :tick, 880.hz.triangle.at(-26.db).until(1.n16) }
        after(1) { ticks.cancel }
      end
    end

    Help.topic :sets, 'Tracks, scenes, and undo', group: :arrange do
      about <<~TEXT
        The Set layer: tracks remember a patch and a clip, scenes are the
        state of every track, `go` launches one at its launch point
        (`on:`, `in:`, `at: bar(n)`).  Every command is one undo step.
      TEXT
      commands :track, :tracks, :scene, :scenes, :go, :quant, :undo, :redo!, :changes, :swap
      note :arrangement
      see :flow, :knobs, :now
      example 'two scenes' do
        track(:try_bass, q: 1) { |c| c.tone.ramp.at(-10.db).lp4(500, resonance: 0.3) * c.amp_env }
        scene :try_a, try_bass: seq(A1, rest, A1, A2).n8.loop
        scene :try_b, try_bass: seq(F1, rest, F1, F2).n8.loop
        go :try_a
        go :try_b, in: 1.bar
      end
    end

    Help.topic :flow, 'Song forms', group: :arrange do
      about <<~TEXT
        `flow do intro 4; verse 8; ... end` plays sections (scenes of the
        same name) with labels, gotos, and picks decided at commit points;
        perform it with loop!, onward, goto, skip, finish, practice, seek.
      TEXT
      commands :flow, :play_form, :section, :loop!, :onward, :goto, :skip, :finish, :practice, :seek, :marker, :meter
      note :arrangement
      see :sets
    end

    Help.topic :genres, 'Genre templates', group: :arrange do
      about <<~TEXT
        `genre :dnb` is a template of a genre: tempo, form, drum grids and
        fills, track roles with suggested presets, scenes, mix targets, and
        tips.  `genre(:dnb).short.play` plays it, `.setup` makes its tracks
        and scenes to play by hand, `.to_ruby` prints it, and a block or
        keywords change any part (:dnb, :jungle, :ambient, :funk; :house and
        :techno are stubs).
      TEXT
      commands :genre, :genres
      note :genres
      see :flow, :sets, :presets
      example 'a genre in numbers', sound: false do
        t = genre(:jungle)
        [t.tempo, t.form.steps.first(3), t.roles.keys, t.mix.summary]
      end
    end

    Help.topic :knobs, 'Knobs and snapshots', group: :perform do
      about <<~TEXT
        Named values that graphs read (`knob(:cut)`) and you turn, with
        ramps, launch points, MIDI learn, snapshots, and crossfades.  Turns
        are journaled and undoable.
      TEXT
      commands :knob, :knobs, :turn, :snap, :snaps, :recall, :xfade, :learn
      note :arrangement
      see :sets, :now
      example 'a filter knob' do
        knob :try_cut, 400, range: 100..8000, curve: :exp, unit: 'Hz'
        bg :try, 55.hz.ramp.at(-14.db).lp4(knob(:try_cut), resonance: 0.5)
        turn :try_cut, 4000, over: 2.bars
      end
    end

    Help.topic :mixing, 'Mute, solo, master', group: :perform do
      about <<~TEXT
        Mute and solo with a 5 ms declick or synced fades (muted players
        sleep); master effects run on the whole mix and swap at launch
        points.  The master gain comes before the master chain (a limiter
        keeps its ceiling); `master_gain 2.db, post: true` moves it after.
      TEXT
      commands :mute, :unmute, :solo, :unsolo, :mutes, :master, :master_gain, :monitor_gain
      note :arrangement, :master_effects
      see :buses, :dynamics
      example 'a quick master chain' do
        bg :try, 110.hz.saw.at(-20.db).until(2.bars)
        master { |mix| mix.softclip.limit(ceiling: -1.db) }
        after(3) { master nil }
      end
    end

    Help.topic :buses, 'Buses, sends, sidechains', group: :perform do
      about <<~TEXT
        Named buses with their own effects: tracks send to them (`send:`,
        `feed`) or play into them (`to:`), and they ring out on their own,
        sleeping when quiet.  `duck(:drums, only: :kick)` and `bus(:drums)`
        read a bus or track by name on the exact sample.  Buses mute and
        solo like tracks (a solo keeps the buses it feeds).
      TEXT
      commands :bus, :buses, :feed, :routes
      dsl :duck, :compress
      note :buses
      see :mixing, :dynamics
      example 'a shared reverb send' do
        bus(:try_verb) { |sig| sig.reverb(:room, mix: 1) }
        bg :try, seq(A3, C4, E4, rest).n8.loop.tone.triangle.at(-20.db).until(1.bar), send: { try_verb: -6.db }
      end
      example 'duck a pad by the kick of a drum track' do
        track(:try_drums) { |k| tr808(k).at(-14.db) }
        bg :try_drums, grid(16, kick: 'x...x...x...x...').loop
        bg :try, 110.hz.saw.at(-24.db).lp4(900).duck(:try_drums, only: :kick).until(1.bar)
      end
    end

    Help.topic :midi, 'MIDI', group: :perform do
      about <<~TEXT
        `midi` is a Notes on live input; `synth` allocates voices from any
        MIDI source; transforms (echo, arp, chord, strum, ...) work on
        Streams, Notes, and Clips; mod_sum and friends route modulation.
      TEXT
      commands :midi, :midi_file, :midi_stream, :synth, :per_voice, :close_midi, :mod_sum, :mod_scale
      dsl :gate, :trigger, :velocity, :amp_env, :hz, :cutoff, :reso, :arp, :echo, :chord
      note :midi
      see :record
    end

    Help.topic :record, 'Recording and takes', group: :keep do
      about <<~TEXT
        The take logs every line and where each change landed (`take.save`
        replays it exactly).  `rec`/`capture` record MIDI into armed tracks
        (loops follow the timeline's phase; `align: :launch` starts from
        what you played first); an armed track's live monitor is its own
        player, :"name/live", which `stop :name` leaves playing and
        `disarm` stops.  `rec_audio` records the master bus to a file;
        `render` bounces graphs offline.
      TEXT
      commands :take, :arm, :disarm, :armed, :rec, :capture, :captures, :rec_audio, :stop_rec_audio, :recordings, :render, :write
      note :arrangement
      see :midi, :presets
    end

    Help.topic :presets, 'Saving graphs and sets', group: :keep do
      about <<~TEXT
        Every graph prints itself back as Ruby (`ruby node`); `save` writes a
        graph document (or the whole set), `preset` loads one with new
        inputs and params.  mb-sound comes with presets too (`presets`
        lists them): drum & bass, jungle, ambient, and funk instruments,
        like `preset :dnb_reese, midi: midi` or `preset :ambient_tape, input: mic`.
      TEXT
      commands :ruby, :save, :preset, :presets, :set, :named_proc
      note :graph_io
      example 'print a graph back as Ruby', sound: false do
        ruby 110.hz.saw.at(-20.db).lp4(800, resonance: 0.3).softclip
      end
    end

    Help.topic :plots, 'Plots', group: :look do
      about <<~TEXT
        Pure-Ruby plots in the terminal (Braille, blocks, sparklines) or as
        images: waveforms, spectra, spectrograms, histograms, and chart
        builders; `vis` plots the live mix.
      TEXT
      commands :plot, :spectrum, :spectrogram, :time_freq, :hist, :density, :mag_phase, :overlay, :table, :chart, :figure, :vis
      note :plotting
      example 'one cycle of a pulse', sound: false do
        plot 100.hz.pulse, samples: 480
      end
    end

    Help.topic :analysis, 'Analysis', group: :look do
      about <<~TEXT
        Pitch, peaks, and correlation of sounds and arrays, and the form of
        a render or a file (tempo, beats, bars).
      TEXT
      commands :freq_estimate, :peaks, :autocorrelate, :crosscorrelate, :peak_correlation, :analyze_form, :loudness
      note :structure
      see :loudness, :plots
    end

    Help.topic :loudness, 'Loudness', group: :look do
      about 'BS.1770 loudness of files and graphs, live meters, and normalized renders.'
      commands :loudness, :render
      dsl :loudness_meter
      note :method_modules, :dynamics
    end

    Help.topic :now, 'Help and what is going on', group: :look do
      about <<~TEXT
        `now` shows what plays, knobs, scenes, the flow, and queued changes
        with the commands that apply; `help node` explains a graph;
        `lesson` teaches the newer layers step by step.
      TEXT
      commands :help, :now, :lesson, :players, :knobs, :scenes, :tracks, :mutes, :changes, :markers, :ruby
      see :sets, :knobs
    end
  end
end

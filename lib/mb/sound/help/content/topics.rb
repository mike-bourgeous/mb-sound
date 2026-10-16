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
        curves, a true-peak limiter, crossover bands, and squeeze.  Levels
        and gains in dB are written `-12.db` (`threshold: -18.db`,
        `makeup: 3.db`, `compand(-60.db => -80.db, 0.db => -12.db)`);
        bare numbers are linear gains.
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
      about <<~TEXT
        Drum machines driven by a grid (Sequence::Kit) or MIDI (GM notes):
        `tr808`, `tr909` (analog kick, snare, toms, clap; 6-bit sampled hats
        and cymbals; `shuffle:` 0..6, flams as note marks: 'f' in a grid or
        `D1.flam`), and kits of your own:
        `kit { voice :kick, tune: 50 do |h| h.body(h.tune, sweep: 3) +
        h.click end; choke :open_hat, by: :closed_hat }` with layers
        (body, noise, click, metal, sample, fm, bursts, env, sweep) and
        voices borrowed from the machines (`tr909 :clap`, `tr808 :cowbell`).
      TEXT
      commands :tr808, :tr909, :kit, :drum_kit, :grid, :euclid
      note :drums
      example 'four on the floor' do
        bg :try, tr808(grid(16, kick: 'x...x...x...x...', hat: 'x.x.x.x.x.x.x.x.').loop).at(-14.db)
      end
      example 'a 909 with shuffle' do
        bg :try, tr909(grid(16, kick: 'X...x...x...x...', clap: '....X.......X...', hat: 'x.xxx.xxx.xxx.xx', oh: '..x...x...x...x.').loop, shuffle: 2).at(-16.db)
      end
      example 'a kit of your own' do
        bg :try, kit(grid(16, kick: 'X..x..x...x..x..', snare: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.').loop) {
          voice(:kick, tune: 45) { |h| h.body(h.tune, decay: 0.4, sweep: 4).softclip(0.6) + h.click(0.3) }
          voice(:snare) { |h| h.fm(240, ratio: 2.3, index: 1, decay: 0.12, index_decay: 0.03) * 0.5 + h.noise(decay: 0.15, highpass: 2000) * 0.4 }
          tr909 :closed_hat
        }.at(-14.db)
      end
    end

    Help.topic :sampler, 'Sampler: bounce, slice, chop', group: :sound do
      about <<~TEXT
        Samples are sounds in memory: `Sample['kick.flac']`, `bounce(graph,
        2.bars, bpm:)` (any graph, offline, at its own tempo), or
        `capture_audio(4.bars)` (the master bus or a node, live).  Cut them
        with `rec.slices(16)` (or `slices(:onsets)`), name runs of slices
        (`brk.name(k: 0..1, s: 4..5)`), and edit them as values: `.rev`,
        `.at(7.n16)` (a tracker's 9xx offset), `.looped`, `.bits(12)`,
        `.lofi(:s950)`, `.stretch(1.25)`.  `brk.chop(:k, T, :s, [:s, 2],
        brk[:s].rev)` writes a chop clip: keys of `brk.keymap` (slices from
        C2) with a pitch mark on each hit, so `amen.transpose(2)` pitches
        every hit and a keyboard plays the same slices.  `brk.keymap(split:
        C4)` plays the last slice chromatically above C4.  Play with
        `clip.sampler(brk)` (one truncating voice), `sample.play(v)` in a
        synth, `sfz(path)` instruments, or `sample.node`.

        Converters: `.lofi(:mpc60)` is the cleanest (40 kHz, filtered: grit
        that sits in a mix), `:s950` darker (31.25 kHz, the jungle
        classic), `:sp1200` the dirtiest (26 kHz, no filters: crunchy hats);
        a whole song often wants none.  `:mpc60` reads clean
        (band-limited, interpolated); `:s950` and `:sp1200` read
        drop-sample with no band-limited levels, aliasing as hits pitch up
        like the hardware (`read: :clean` / `read: :drop`, or
        `.read_as(...)`, says otherwise).  `.stretch(2, cycle: 30.ms)` is
        the S950's cyclic stretch with each cycle fitted to the sound
        (whole periods, matching splices), so tones keep their pitch;
        `fit: :fixed` is the plain version (a buzz at 1 / cycle, stutter
        on breaks, and basses that sound lower).  Both crossfade 3 ms
        between cycles (`crossfade: 0` for the raw splices).  `mode: :spectral` and
        `mode: :paul` stretch in the frequency domain, and `.grains` plays
        a sample as a grain cloud: see `help :granular`.
      TEXT
      commands :bounce, :capture_audio, :chop, :sampler, :sfz
      dsl :bounce
      note :sampler
      see :drums, :sequences, :granular
      example 'a chopped break' do
        rec = bounce(2.bars, bpm: 138.75) {
          tr808(grid(16, kick: 'X.....x...X.....|X.x.......X..x..', snare: '....X..3.3..X..3|.3..X..3....X.3.', hat: 'x.x.x.x.x.xxx.x.|x.x.x.x.x.x.x.xx'))
        }
        brk = rec.slices(32).name(k: 0..1, h: 2..3, s: 4..5, g: 7)
        bg :try, brk.chop(:k, T, :h, :g, :s, T, [:g, 2], :k, T, :k, :h, T, :s, T, [:s, 3], brk[:s].rev).loop.transpose(3).sampler(brk).at(-14.db)
      end
      example 'a resampled bass, looped' do
        bass = 55.hz.ramp.lp4(700, resonance: 0.3).bounce(1.beat, root: A1).looped(0.1..0.4, mode: :ping_pong)
        bg :try, seq(A1, C2, E1, G1).n4.loop.sampler(bass).at(-12.db).until(2.bars)
      end
    end

    Help.topic :granular, 'Grains and spectral stretch', group: :sound do
      about <<~TEXT
        `sample.grains(...)` plays a Sample as a cloud of short windowed
        grains (a stereo bundle): `density:` grains per second, `size:`
        (100 ms), `position:` 0..1 (a number freezes, a node or knob
        scrubs), `scan:` (a moving playhead: 0.25 is a 4x granular
        stretch; 1 when no position is given), `spread:`, `pitch:`
        (semitones, or an Array to pick from: `[0, 12, 19]`),
        `pitch_spread:`, `pan_spread:`, `reverse:` (a chance), `window:`
        (:hann, :expodec for percussive grains, ...), `jitter:` (0 regular,
        1 Poisson), `seed:`, `read: :drop` for lofi reads.  Every option
        takes a number, a knob, or a node.  In a synth, `v.grains(pad,
        ...)` tracks the keys.  `max_grains:` caps the cost (32 for a
        cloud, 16 per synth voice): about 3% of realtime for a full mono
        cloud of 32, 6% stereo.

        Stretching keeps the pitch: `.stretch(4)` is the cyclic S950
        stretch (gritty; 3 ms `crossfade:` between cycles),
        `.stretch(4, mode: :spectral)` a phase vocoder with locked phases
        and sharp transients that land on the stretched beat (pads,
        chords, voices, bass, breaks), `.stretch(32, mode: :paul)`
        Paulstretch (endless washes).  They are one algorithm:
        `randomize:` 0..1 goes from the vocoder (0) to Paulstretch (1)
        (`mode: :spectral, randomize: 1`: Paulstretch phases in the
        vocoder's shorter 4096-sample window), with `window:`,
        `overlap:`, `shape: :paul` (the original's window), and `link:
        false` (random phases per channel) for both; for voices try the
        original's settings: `.stretch(8, mode: :paul, overlap: 2,
        shape: :paul, link: false)`.
        They are offline edits: a new Sample, made once; results over 30
        s read with `mips: :octave` (smaller playback tables).
      TEXT
      dsl :grains, :stretch
      note :granular
      see :sampler, :random
      example 'a frozen pad' do
        pad = bounce(1.bar) { (220.hz.ramp + 277.2.hz.ramp + 330.hz.ramp).lp4(1800) * 0.3 }
        bg :try, pad.grains(position: 0.5, size: 150.ms, density: 30, spread: 0.05, pitch: [0, 12], pan_spread: 0.8).at(-16.db)
      end
      example 'a 4x spectral stretch' do
        riff = bounce(1.bar) { seq(A3, C4, E4, G4).n8.loop.then { |c| c.tone.ramp.lp4(1500) * c.amp_env } }
        bg :try, riff.stretch(4, mode: :spectral).node.at(-12.db)
      end
      example 'Paulstretch phases in the vocoder (randomize: 1)' do
        riff = bounce(1.bar) { seq(A3, C4, E4, G4).n8.loop.then { |c| c.tone.ramp.lp4(1500) * c.amp_env } }
        bg :try, riff.stretch(8, mode: :spectral, randomize: 1).node.at(-12.db)
      end
      example "a voice Paulstretched the original's way" do
        voice = bounce(1.bar) { seq(A3.n4, C4.n4, E4.n4, D4.n4).legato(1).then { |c| c.tone.ramp.formant(:a, :o) * c.amp_env * 0.5 } }
        bg :try, voice.stretch(8, mode: :paul, overlap: 2, shape: :paul, link: false).node.at(-10.db)
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

    Help.topic :generative, 'Generative music', group: :time do
      about <<~TEXT
        Probability scales and generator clips.  `scale(:dorian, :d).weights`
        is a probability scale: layer it with `+` and `*`
        (`+ tones(D3, F3, A3) * 2`, or a named chord:
        `+ chord(:min7, root: :d).weights * 2`), `blur(0.2)` it so wrong
        notes sometimes hit, `blend` it toward another key, change it over
        time with `harmony(0 => a, 8.bars => b)` (keys are lengths), and
        spread it over notes with
        `over(A3..A5, around: E5)`.  `melody`, `strikes`, and
        `generate(1.bar) { |cycle, dice| rows }` make looping clips whose
        every cycle is a pure function of the seed and the cycle
        (counter-based `dice`), so they seek, replay in takes, and save.
      TEXT
      commands :tones, :chord, :weights, :harmony, :generate, :strikes, :dice, :melody
      note :generative
      see :sequences, :random
      example 'a melody that blurs and changes key' do
        h = harmony(0 => scale(:dorian, :d), 1.bar => scale(:major, :f), loop: 2.bars).blur(0.2)
        line = melody(h, 8, range: A3..A5, vary: true).loop
        bg :try, line.synth(voices: 2) { |v| v.hz.triangle * v.env(0.005, 0.2, 0.3, 0.2) }.at(-14.db)
      end
      example 'sparse bells over a drone' do
        bells = strikes(scale(:minor_pentatonic, :a).weights.over(A4..A6), every: 1.n8, chance: 0.5, gap: 2)
        bg :try, bells.synth(voices: 4) { |v| v.hz.sine * v.env(0.002, 0.8, 0, 0.8) }.at(-12.db) + 110.hz.triangle.at(-26.db)
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
        `render` bounces graphs offline.  No MIDI keyboard?  The tiles'
        virtual keyboard (`ui.keys`, see `help :ui`) plays into the same
        input, and Enter there captures.
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
        like `preset :dnb_reese, midi: midi` or `preset :ambient_tape, input: mic`,
        and electric pianos: `:tine_piano` clean, `:tine_crunch` with its amp
        pushed (`amp: 1..8`), `:reed_piano`.
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
      see :sets, :knobs, :ui
    end

    Help.topic :ui, 'Dashboard band and tiled screen', group: :look do
      about <<~TEXT
        `ui` puts a live dashboard band above the prompt (transport, form,
        tracks, queued changes, master meters, a scope); Pry keeps the
        rest of the screen.  `ui :deck` adds knobs and CPU per part, `ui
        :mini` is one line, `ui off` hides it.  Write your own panes with
        `pane :name do |c, s| ... end` (s is a snapshot of the session,
        c the pane's canvas), arrange them with `layout`, and keep a
        layout with `ui.save`.  The prompt shows bar:beat, armed or
        recording tracks, and load; Tab completes track, scene, and knob
        names after the commands that take them (`go :<Tab>`).

        `ui :tiles` (or `ui :studio`, or any layout with `repl` in it)
        takes the whole screen: panes tiled around the console, which keeps
        a 10 000-line scrollback of its own.  Ctrl-] is NAV mode: 1-9 or
        hjkl pick a pane, z zooms, s/v split, x closes, arrows resize
        (shift: 5), = evens out, u and Ctrl-R undo and redo, [ and ] switch
        tabs, PgUp/g/G scroll the console, / searches it, y copies (OSC 52),
        : runs a line of Ruby (`show :knobs`, `go :drop`), and Ctrl-], i,
        Esc, or Enter go back.  `ui.split :v`, `ui.zoom`, `ui.show :cpu`,
        `ui.save :mine` do the same from the prompt; `ui.on C1, :zoom` maps
        a pad.  Ctrl-Z hides the tiles (the set plays on and the console
        carries on in the normal screen); Ctrl-Z or `ui` brings them back
        as they were.  `ui.theme :mono`, `ui.nav_esc 0.3` (a lone Esc enters NAV),
        `ui.mouse` (wheel scrolls, clicks focus).  Themes, pane files, and
        layouts are data files in the ui folder, reloaded when they
        change.  `bin/ui_check.rb` reports what your terminal supports.

        The keyboard: in the tiles, NAV then p (or `ui.keys`, or `ui :keys`)
        turns the computer keyboard into a piano, laid out like
        jack-keyboard: z s x d c v ... from C3 and q 2 w 3 e ... from C4;
        - and + (or Left/Right) move octaves, Up/Down the velocity, Shift
        accents, Space is the sustain pedal, Esc all notes off, Ctrl-]
        back.  Notes go into the session's MIDI input, so `arm :lead`
        plays the lead and Enter captures what you just played into it
        (with nothing armed a default patch plays).  Most terminals send no
        key-up, so notes hold while a key repeats (` cycles :hold, :tap,
        :legato); with the kitty keyboard protocol (kitty, WezTerm with
        enable_kitty_keyboard, Ghostty, foot, iTerm2 with its setting)
        notes end on key-up.  Tab is step entry: lower-row notes, 1-7
        lengths (whole to 64th), 8 dotted, 9 triplet, r rest, t tie, a
        accent, ` slide, Backspace undo, p plays it, Enter puts the clip's
        Ruby (`seq(C3, E3, G3.n4).n8`) on the console line and in
        `ui.keyboard.clip`.
      TEXT
      commands :ui, :off, :pane, :layout
      note :terminal_ui
      see :now, :plots
    end
  end
end

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
        (waits until the sound ends; Ctrl-C to stop).  Commands return
        journal entries that say where they land.  Sounds end through
        envelopes, clips, `until` (alias `for`: `.for(2.bars)`), or `stop`.  `play`, `bg`, and `render`
        take graphs and more: files, audio arrays, Samples (once), Slices
        (one by one), clips (on their instrument, e.g. a chop's slices, or
        a soft saw), grids (a TR-909, or a TR-808 for its own voices like
        cowbell), envelopes (on a triangle with noise), instruments and SF2/SFZ files (a
        demo phrase), wavetables (one note), and presets by name.  A plain
        Ruby file gets every console command and note name at its top level
        with `require 'mb/sound/dsl'` (run it with `ruby song.rb`; at its end
        it waits for what plays in the background, like `wait`).
      TEXT
      commands :bg, :stop, :outro, :panic, :players, :stopped, :resume, :forget, :play, :wait, :master_gain, :monitor_gain, :warm_up
      dsl :at, :until, :for, :and_then
      note :method_modules, :scripts
      see :sets, :now, :files
      example 'a quiet triangle that stops itself' do
        bg :try, 220.hz.triangle.at(-20.db).until(2.bars)
      end
      example 'a pattern on the next bar' do
        bass = seq(A1, A1, rest, A2, A1, rest, G1, E1).n8.loop
        bg :try, bass.tone.saw.at(-12.db).lp4(600, resonance: 0.4) * bass.amp_env
      end
      example 'play a clip on the default patch' do
        play seq(A3, C4, E4, A4, E4, C4, A3.n4).n8, gain: -14.db
      end
      example 'play two seconds of a drum file as a Sample', bars: 1 do
        play Sample['sounds/drums_short.flac'].trim(...2.seconds), gain: -8.db
      end
      example 'play a grid on a TR-909' do
        play grid(16, kick: 'X...x...', snare: '....x...', hat: 'x.x.x.x.'), gain: -13.5.db
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

    # (omnibus15: "No help for pitch?" from the maintainer's take)
    Help.topic :pitch, 'Pitches, notes, and tuning', group: :sound do
      about <<~TEXT
        `440.hz` is a Pitch: used as a signal it plays a sine, and
        oscillator methods make a Tone (`440.hz.saw`).  `C4` (60, middle C;
        C3 is 48) is a Note, a Pitch that follows the session's `tuning`
        (`tuning b4: 480`).  Change pitches by name, not arithmetic:
        `pitch.transpose(7)` (semitones, or `7.semitones`, `1.octaves`,
        `50.cents`), `up`/`dn`/`oct` for octaves, `(f * 2).hz` from a
        number; `440.hz * 2` doubles the sine's amplitude.  `pitch.period`
        is a length (one cycle), `pitch.frequency` the number in Hz,
        `40.constant` a fixed value for arithmetic.
      TEXT
      commands :tuning
      dsl :transpose, :up, :dn, :oct, :period, :frequency
      note :numbers_lengths_phases
      see :tones, :tempo, :key
      example 'a fifth above, by name' do
        bg :try, (220.hz.triangle + 220.hz.transpose(7).triangle).at(-24.db).until(1.bar)
      end
      example 'an octave below a note' do
        bg :try, A4.dn.saw.lp4(800).at(-24.db).until(1.bar)
      end
    end
    Help::TOPIC_ALIASES.merge!(pitches: :pitch, note: :pitch, hz: :pitch, tuning_and_notes: :pitch)

    Help.topic :wavetables, 'Wavetables and shape morphs', group: :sound do
      about <<~TEXT
        `pitch.wavetable(t, scan: x)` plays a table, morphing through its
        frames as `scan` moves 0..1 (a number, an LFO, a knob).  Library
        tables: `Wavetable[:basic]` (sine, triangle, saw, square),
        `:organ`, `:pulses`, ... (`Wavetable.names`).  `wavetable_of`
        builds a scan table from a list of frames: table names, harmonic
        amplitudes (`[1, 0.5, 0.33]`), functions of the phase in cycles
        (`->(p) { ... }`), tables, and sample arrays (`normalize: :peak`
        by default, `:loudness` for even levels); it saves and prints as
        the call.  Turn a knob to change the shape while it plays:
        `110.hz.wavetable(t, scan: knob(:shape))`.
      TEXT
      commands :wavetable_of
      dsl :wavetable, :harmonics
      note :oscillators
      see :tones, :knobs
      example 'a shape morph on a knob' do
        knob :try_shape, 0.0, range: 0.0..1.0
        t = wavetable_of(:sine, [1, 0.5, 0.33, 0.25], :saw, ->(p) { Math.sin(2 * Math::PI * p)**3 }, normalize: :loudness)
        bg :try, 110.hz.wavetable(t, scan: knob(:try_shape)).at(-22.db).until(2.bars)
        turn :try_shape, 1, over: 2.bars
      end
    end

    Help.topic :unison, 'Unison and supersaws', group: :sound do
      about <<~TEXT
        Three spellings, the same sound bit for bit:
        `110.hz.unison(5, spread: 0.5) { |p| p.saw }` (the block form, any
        oscillator per copy), `110.hz.unison(5, spread: 0.5).saw` (shape
        methods on a blockless unison; used as a signal it is saws), and
        `110.hz.saw.unison(5, spread: 0.5)` (a tone made again on every
        copy).  In synth voices: `v.hz.saw.unison(5) * v.amp_env`.
        `detune:`, `spread:` (0..1, stereo above 0), `mix:` (side copies),
        `swarm` for gliding copies.
      TEXT
      dsl :unison, :swarm
      note :oscillators
      see :tones
      example 'three spellings, one supersaw' do
        bg :try, 110.hz.saw.unison(5, detune: 0.2, spread: 0.5).lp4(1200).at(-24.db).until(2.bars)
      end
    end

    Help.topic :envelopes, 'Envelopes and curves', group: :sound do
      about <<~TEXT
        Envelopes land exactly on their targets at whole samples; curves
        are signed dB (+60 falls like a 60 dB exponential).  Without a gate
        they are one-shots.  `tween(values, step)` moves through keyframes
        with `step` between each two (not the whole length):
        `tween([100.hz, 5000.hz, 100.hz], 2.bars)` takes 4 bars to come
        back down, then (looping) takes 2 more back to its first value;
        `tween([100.hz, 5000.hz], 2.bars)` is up and down in 4 bars.
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
      example 'a swept four-pole (one bar up, one bar down: the length is per step)' do
        bg :try, 55.hz.saw.at(-16.db).lp4(tween([200.hz, 4000.hz], 1.bar), resonance: 0.6).until(2.bars)
      end
    end

    Help.topic :effects, 'Effects', group: :sound do
      about <<~TEXT
        Sums ring until their last input ends (a gong past its click, a
        dry part plus its reverb); `(drone + hit).ring(:first)` (or
        `render(..., ring: :first)`) ends with the first.
        Delays (sinc-interpolated, tempo-synced lengths; regenerating
        multitaps, ping-pong, Haas), tape echoes with presets (`L.fx.delay`:
        :reel, :slapback, :ping_pong, :dub), feedback loops that run one
        sample at a time in C, the FDN reverb with presets, the Juno chorus,
        and antialiased shapers.
      TEXT
      dsl :delay, :multitap, :ping_pong, :haas, :tape_echo, :feedback, :reverb, :chorus, :softclip, :clip, :decimate, :quantize, :ease, :oversample, :ring
      note :delays, :feedback_loops, :reverbs, :chorus
      see :dynamics, :mixing
      example 'a dotted-eighth echo' do
        blip = seq(E5, rest, rest, rest, B4, rest, rest, rest).n8.loop
        bg :try, (blip.tone.triangle.at(-14.db) * blip.amp_env).delay(1.n8.dotted, feedback: 0.5)
      end
      example 'a dub tape echo' do
        blip = seq(E5, rest, rest, rest, B4, rest, rest, rest).n8.loop
        bg :try, (blip.tone.triangle.at(-14.db) * blip.amp_env).tape_echo(:dub)
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

    Help.topic :blend, 'Mixing an effect in (wet and dry)', group: :sound do
      about <<~TEXT
        `sig.blend(0.3) { |s| s.resonate(:plate) }` mixes the effect the
        block makes from `sig` with `sig` itself: 0 is all dry, 1 all wet,
        the same law as the effects' own `mix:` (dry * (1 - mix) + wet *
        mix).  The mix can be a number, a knob's name (`blend(:wet)`, turned
        with `turn :wet, 0.8`), or any node (an LFO, an envelope).
        `curve: :power` keeps the loudness of effects that don't correlate
        with the dry sound (reverb tails); effects with lookahead
        (compressors, limiters) get their dry path delayed to match.  A
        stereo bundle goes to the block whole.

        The same by hand: `sig * 0.7 + sig.resonate(:plate) * 0.3` (using
        `sig` twice is fine: the graph branches it).  Some effects mix
        themselves: `reverb(mix: 0.3)`, `chorus(mix:)`, `delay(dry:, wet:)`
        or `delay(mix:)` (delays, `ping_pong`, and `tape_echo` crossfade at
        equal power), and the dynamics' `mix:` (parallel compression).  For one effect
        shared by several tracks, send them to a bus (`bus(:verb) { |s|
        s.reverb(:hall, mix: 1) }`, then `track(:keys, send: { verb: -12.db
        })` or `feed :keys, :verb, -6.db`): the bus is all wet, and each
        send sets how much goes in.
      TEXT
      commands :bus, :feed, :knob
      dsl :blend, :resonate, :reverb, :chorus, :delay
      see :effects, :buses, :knobs
      example 'drums into a swept resonator, mixed in' do
        beat = tr808(grid(16, kick: 'x...x...x...x...', snare: '....x.......x...', hat: 'x.x.x.x.x.x.x.x.').loop)
        # (the resonator rings far louder than its strikes)
        bg :try, beat.blend(0.4) { |s| s.resonate(:plate, 0.25.hz.lfo.at(110..440), decay: 1.5).at(-22.db) }.at(-11.db)
      end
    end
    Help::TOPIC_ALIASES.merge!(wet: :blend, dry: :blend, mix: :blend, wetdry: :blend, dry_wet: :blend)

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

    Help.topic :sq80, 'SQ-80 voice and patches', group: :sound do
      about <<~TEXT
        `sq80` is an Ensoniq SQ-80-flavored synth built from the library's
        pieces (original wave tables, nothing from the SQ-80's ROM): OSC1
        a formant wave whose vowel stays put across the keyboard, OSC2 a
        SYNTH 3-style table, OSC3 a PRIME-style table an octave down
        blipped by ENV1, into a driven four-pole (lp4); SQ-80 panel units
        on the envelopes (`sq80_env`: times 0..63, levels -63..+63), a
        delayed vibrato, and two oddities: chop (octaves; a looping
        32nd-note filter envelope) and flutter (octaves; each key's poly
        pressure sets its own sample-and-hold filter flutter).  It takes
        any MIDI source (none: live `midi`), a patch, and settings, as in
        `sq80(clip, :chop)` or `sq80(:glass, cutoff: 900)`.  Patches:
        :classic (the defaults, an octave down), :flutter_pad, :chop, :vox_lead,
        :prime_bass, :glass (`sq80_patches` lists them).  Settings:
        voices, cutoff (Hz), reso (0..1), drive_mode (:feedback or
        :input), drive, chop, flutter, second_release, osc1..osc3 (wave,
        semitones, level, vibrato, env1), env1, env2, env4 (sq80_env panel
        values), lfo1 (rate in Hz, depth in semitones, delay, wheel,
        pressure), filter (env2, key, velocity, aftertouch, in octaves),
        transpose (semitones, every oscillator), level; Hash settings change only the keys given
        (`env4: { t4: 50 }`).  Each patch is a preset too
        (`preset :sq80_glass, midi: midi`), and the shell plays them with
        bin/synths/sq80_voice.rb -p glass.
      TEXT
      commands :sq80, :sq80_patches, :sq80_env
      note :sq80, :envelopes
      see :midi, :presets, :envelopes
      example 'the chop patch on a chord' do
        bg :try, sq80(seq(A3, F3).n2 & seq(C4, A3).n2 & seq(E4, C4).n2, :chop).at(-16.db)
      end
      example 'a vowel lead, darker, with a longer release' do
        bg :try, sq80(seq(A4, C5, E5.n4, D5, C5, B4.n4).n8, :vox_lead, cutoff: 900, env4: { t4: 40 }).at(-16.db)
      end
    end

    Help.topic :sampler, 'Sampler: bounce, slice, chop', group: :sound do
      about <<~TEXT
        Samples are sounds in memory: `Sample['kick.flac']`, `bounce(graph,
        2.bars, bpm:)` (any graph, offline, at its own tempo),
        `capture_audio(4.bars)` (the master bus or a node, live), or
        `breakbeat(:jungle)` (a synthesized break that ships with mb-sound,
        two bars at 138.75 BPM).  Cut them
        with `rec.slices(16)` (or `slices(:onsets)`), name runs of slices
        (`brk.name(k: 0..1, s: 4..5)`), and edit them as values: `.rev`,
        `.at(7.n16)` (a tracker's 9xx offset), `.looped`, `.bits(12)`,
        `.lofi(:s950)`, `.stretch(1.25)`.  `brk.chop(:k, T, :s, [:s, 2],
        brk[:s].rev)` writes a chop clip: keys of `brk.keymap` (slices from
        C2) with a pitch mark on each hit, so `amen.transpose(2)` pitches
        every hit and a keyboard plays the same slices.  `brk.keymap(split:
        C4)` plays the last slice chromatically above C4.  Play with
        `clip.sampler(brk)` (one truncating voice), `sample.play(v)` in a
        synth, `sfz(path)` and `sf2(path, preset)` instruments (`help
        :soundfonts`), or `sample.node`.  A synth that runs out of voices
        steals one, fading it over 3 ms from the steal (`steal_fade: 10.ms`
        for longer; `sample.play(v, steal_fade: false)` or `.sampler(brk,
        voices: 3, steal_fade: false)` lets it ring on under the new notes).

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
      commands :bounce, :capture_audio, :chop, :sampler, :sfz, :breakbeat
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
        bass = 55.hz.saw.lp4(700, resonance: 0.3).bounce(1.beat, root: A1).looped(0.1..0.4, mode: :ping_pong)
        bg :try, seq(A1, C2, E1, G1).n4.loop.sampler(bass).at(-12.db).until(2.bars)
      end
    end

    Help.topic :soundfonts, 'SoundFonts (.sf2)', group: :sound do
      about <<~TEXT
        `font = sf2('GM.sf2')` opens a SoundFont 2 file; `font.presets`
        lists its presets (bank:program name).  Choose one with
        `sf2('GM.sf2', 0)` (a GM program in bank 0: 0 is the piano),
        `sf2(path, preset: 'Strings')` (a name, or the one name containing
        it), `sf2(path, preset: [128, 0])` (bank 128: GM drum kits), or
        `font[48]`, `font['Pad']`, `font[128, 0]`.  Each is a sampler
        Instrument: `synth(midi) { |v| piano.play(v) }`,
        `beat.sampler(kit, voices: 8)`, or a track's patch.  Only the
        chosen preset's samples are read (a 30 MB GM font opens in a few
        hundredths of a second).

        What carries over: key and velocity zones, root keys and tuning,
        loops, stereo pairs, pans, attenuation, the volume envelope,
        filters, the modulation envelope and LFOs (to pitch, filter, and
        volume), the mod wheel and aftertouch vibrato (`wheel: false`
        leaves it out), and per-zone settings (each note gets its own
        zone's envelope and filter; overlapping zones play as layers,
        each sleeping in synth voices while it has no zone for the note),
        and exclusive classes (a drum kit's closed and pedal hats cut its
        open hat over 3 ms in synth voices; `i.region(s, choke: :hat)`
        does the same in your own instruments, `group:`/`off_by:` like
        SFZ).  What doesn't (extra modulators, ROM samples) is listed once
        per preset when it loads.  Levels follow FluidSynth's
        attenuation scale (`attenuation: 1.0` for the specification's).
        `mips: :default` reads smoother tables (more memory) than the
        `:octave` default.
      TEXT
      commands :sf2, :soundfont
      see :sampler, :sequences
    end

    Help.topic :loops, 'Loop files and tempo-following loops', group: :sound do
      about <<~TEXT
        Loop libraries: `Sample['Funk/break_98bpm.wav']` reads a loop with
        its metadata: ACID chunks (tempo, beats, meter, root, one-shot),
        `smpl` (root, loop points), cue points (`sample.markers`), FLAC
        tags, then tempo and key words in file and folder names ("98bpm",
        "98 BPM", "Am_120"; a name's tempo counts only when the file is a
        whole number of its beats).  Loops loop the whole file; one-shots
        (ACID's flag, words like kick or hit, short files, one hit
        decaying away) keep no name tempo.  `sample.bpm`, `.beats`,
        `.bars`, `.key`, `.meta_source` and `.meta[:why]` (where each came
        from, and why); `Sample[path, detect:
        true]` (or `.detect_tempo`, `.detect_key`) finds a missing tempo
        and key (`sample.key_analysis` shows the key's scores).  `loops
        '~/Loops/Funk'` lists a folder (headers and names only, nothing
        decoded or written), filtered by `bpm: 90..100`, `key: :Am`,
        `beats: 8`; `detect: :key` decodes files without a key and
        detects it; `list[3].sample` reads one.

        `sample.follow` plays a loop in time with the session: its beats
        fill the same span at any tempo, lined up with bar 1 (`align:
        :launch` counts from the launch), restretched when `bpm` changes.
        `follow` keeps the pitch: drums with the slice stretch, notes and
        pads with the phase vocoder (`sample.material` decides from name
        words or how noisy it sounds; `stretch: :slice` or `:spectral`
        to say); `follow(:resample)` lets the pitch follow
        the tempo like a varispeed.  `.stretch(r, mode: :slice)` cuts at
        the hits (markers, else onsets, else the 16th grid) and starts
        each slice at its stretched time, attacks copied exactly:
        slowing down leaves REX-style gaps (`fill: :stretch` draws each
        decay out instead), speeding up truncates with a 4 ms fade.
      TEXT
      commands :loops
      dsl :follow
      note :loops
      see :sampler, :granular, :tempo
      example 'a break that follows the tempo' do
        brk = bounce(2.bars, bpm: 100) { tr909(grid(16, kick: 'X...x...x..xx...', clap: '....X.......X...', hat: 'x.x.x.x.x.x.x.x.', oh: '..x...x...x...x.')) }
        bg :try, brk.follow.at(-16.db).until(2.bars)
      end
      example 'slice stretch vs varispeed' do
        brk = bounce(1.bar, bpm: 100) { tr909(grid(16, kick: 'X..x..X...X.....', snare: '....X.......X..x', hat: 'xxxxxxxxxxxxxxxx')) }
        bg :try, (brk.follow * 0.5 + brk.follow(:resample).pan(0.6) * 0.5).at(-14.db).until(2.bars)
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
        pad = bounce(1.bar) { (220.hz.saw + 277.2.hz.saw + 330.hz.saw).lp4(1800) * 0.3 }
        bg :try, pad.grains(position: 0.5, size: 150.ms, density: 30, spread: 0.05, pitch: [0, 12], pan_spread: 0.8).at(-16.db)
      end
      example 'a 4x spectral stretch' do
        riff = bounce(1.bar) { seq(A3, C4, E4, G4).n8.loop.then { |c| c.tone.saw.lp4(1500) * c.amp_env } }
        bg :try, riff.stretch(4, mode: :spectral).node.at(-12.db)
      end
      example 'Paulstretch phases in the vocoder (randomize: 1)' do
        riff = bounce(1.bar) { seq(A3, C4, E4, G4).n8.loop.then { |c| c.tone.saw.lp4(1500) * c.amp_env } }
        bg :try, riff.stretch(8, mode: :spectral, randomize: 1).node.at(-12.db)
      end
      example "a voice Paulstretched the original's way" do
        voice = bounce(1.bar) { seq(A3.n4, C4.n4, E4.n4, D4.n4).legato(1).then { |c| c.tone.saw.formant(:a, :o) * c.amp_env * 0.5 } }
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
        `seq([C3, E3, G3], chord(:min7, root: :d)).n2` (chord steps),
        `grid('x...')` (sixteenths; `grid(8, 'x.x.')`); a clip is a MIDI source (`clip.tone`, `clip.env`,
        `clip.synth`) and has transforms (transpose, swing, chance, ...).
        `rotate(1.n8)` wraps notes around the clip, `shift(1.n8)` moves
        them without wrapping (notes that leave drop out; live streams only
        shift later).  Grid kits take the same transforms, row by row
        (`beat.reverse`, `beat.swing(0.6)`, `beat.humanize`).
        `clip.show` prints a clip as text: `:grid` (grid characters, so a
        kit's `show.rows` parse back), `:roll` (a piano roll), or
        `:degrees` (scale degrees in the session key).
      TEXT
      commands :seq, :grid, :events, :rest, :euclid, :melody, :acid, :chord, :arp, :strum, :echo, :scale
      dsl :loop, :n8, :n16, :transpose, :swing, :humanize, :chance, :every, :reverse, :rotate, :shift, :halftime, :doubletime, :synth, :tone, :amp_env, :swap
      note :sequences
      see :tempo, :sets
      example 'a looping arpeggio' do
        clip = seq(A3, C4, E4, G4).n16.loop
        bg :try, clip.tone.triangle.at(-12.db) * clip.amp_env
      end
      example 'a beat turned around, swung, and printed as a grid', sound: false do
        beat = grid(16, kick: 'X...x...x..x....', snare: '....X.......X..?', hat: 'x.x.x.x.x.x.x.x.')
        puts beat.rotate(1.n8).swing(0.6).show
      end
      example 'a riff as scale degrees in A minor', sound: false do
        puts seq(A3, C4, E4, G4, A4.n4, E4.n4).n8.show(:degrees, scale: scale(:minor, :a))
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
        `motifs(h, 8, form: %i[a a b a], answer: { b: :a })` remembers its
        phrases: motifs come back (through key changes), `b` answers `a`
        and lands home, repeats vary a little, and every `evolve:` passes
        the motifs mutate a step here and there; `range:`/`around:` set
        the register.  `beats(16) { kick [1, 0, 0, 0] * 4; hat euclid(10, 16),
        mutate: 0.5 }` is an evolving rhythm for any drum kit: rows drift,
        Euclidean rows mutate, `energy:` thins or fills (raising it only
        adds hits), `hold: 2` repeats each random bar, `fill every: 8`
        fills phrase ends (`energy: true` grows the fill with the
        energy); `rhythm(field, [1, 0, 0.5, 0] * 4)` is one
        melodic row.  Steer them live: options like `density:`, `mutate:`,
        `energy:`, `chance:` take knobs (`knob(:busy)`, `cc(1)`,
        `knob(:reg).choose(A2..A4, A3..A5)` for `range:`), read once per
        cycle a `lead:` (one beat) before it starts, so a `turn` steers the
        next cycle and takes replay it; `generate(1.bar, busy: knob(:busy))
        { |cycle, dice, busy:| }` hands them to your block.
      TEXT
      commands :tones, :chord, :weights, :harmony, :generate, :strikes, :dice, :melody, :motifs, :beats, :rhythm
      note :generative
      see :sequences, :random, :long_form
      example 'a melody that blurs and changes key' do
        h = harmony(0 => scale(:dorian, :d), 1.bar => scale(:major, :f), loop: 2.bars).blur(0.2)
        line = melody(h, 8, range: A3..A5, vary: true).loop
        bg :try, line.synth(voices: 2) { |v| v.hz.triangle * v.env(0.005, 0.2, 0.3, 0.2) }.at(-14.db)
      end
      example 'a tune with phrase memory: a a b a, b answering a' do
        h = scale(:dorian, :d).weights + chord(:min7, root: :d).weights * 1.5
        tune = motifs(h, 8, form: %i[a a b a], answer: { b: :a }, range: A3..A5, around: D4)
        bg :try, tune.synth(voices: 2) { |v| v.hz.triangle * v.env(0.005, 0.2, 0.3, 0.2) }.at(-14.db)
      end
      example 'an evolving beat steered by a knob' do
        knob :energy, 0.3
        groove = beats(16, hold: 2, energy: knob(:energy)) do
          kick [1, 0, 0, 0] * 4, keep: [0, 4, 8, 12]
          clap [0, 0, 0, 0, 1, 0, 0, 0] * 2, keep: [4, 12]
          hat euclid(10, 16), mutate: 0.5, drift: 0.15, level: 0.7
          fill every: 4, snare: 0.7
        end
        bg :try, tr909(groove).at(-18.db)
        turn :energy, 0.9, over: 4
      end
      example 'sparse bells over a drone' do
        bells = strikes(scale(:minor_pentatonic, :a).weights.over(A4..A6), every: 1.n8, chance: 0.5, gap: 2)
        bg :try, bells.synth(voices: 4) { |v| v.hz.sine * v.env(0.002, 0.8, 0, 0.8) }.at(-12.db) + 110.hz.triangle.at(-26.db)
      end
    end

    Help.topic :tempo, 'Tempo, tuning, and the timeline', group: :time do
      about <<~TEXT
        One transport for everything: tempo (`bpm 174`, also `tempo 174`),
        a meter map, and bar numbers that stay stable.  Durations (`1.n8.dotted`, `2.bars`) follow the
        tempo; `1.beat.hz` locks a tone to the beat; `tuning` moves every
        Note.

        Tempo moves too: `bpm 140, over: 4.bars` ramps from where the
        tempo is (`accel`/`rit` say the same; `curve: :smooth`; `over:
        10.seconds`), with launch points (`bpm 90, over: 2, on: :bar`).
        `bpm :tempo` follows a knob (`knob :tempo, (90.bpm..180.bpm)
        .at(140.bpm)`), `bpm 4.bars.lfo.at(150..180)` a tempo LFO, read
        every 800 frames.  Scenes and sections take `bpm: [160, over:
        4]`.  These are journaled and undoable, and takes replay them
        exactly; a plain `bpm 120` sets one tempo right away and ends a
        ramp.  Bars, launches, clips, delays, and LFOs all follow.
      TEXT
      commands :bpm, :tempo, :accel, :rit, :meter, :rewind, :seek, :bar, :transport, :tuning
      note :tempo_sync, :numbers_lengths_phases
      see :schedule, :clocks, :knobs
      example 'a tempo-locked wobble' do
        bg :try, 55.hz.saw.at(-16.db).lp4(400 + 1.beat.hz.lfo.triangle * 300 + 300).until(2.bars)
      end
      example 'an arpeggio speeding up' do
        bg :try, seq(C4, E4, G4, C5).n16.loop.tone.triangle.at(-24.db).until(4.bars)
        bpm 180, over: 3.bars
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
        Each track keeps the clips it has played as numbered slots (the
        clip matrix): `launch :bass, :bass_b` (or a slot number) plays one,
        and `tweak :bass, transpose: 2` (legato:, swing:, quantize:,
        :reverse, :halftime, :doubletime, :double, :half) plays a changed
        copy as a new slot, named with a version mark (`:bass_b_v2`, then
        `_v3`; `launch :bass, :bass_b_v2` plays it again); the clip pane
        shows what made it.

        A library instrument is a patch too: `track :bass, L.inst.dnb.dnb_reese`
        (or `track :bass, :dnb_reese`, or with its clip: `track :bass, riff,
        :dnb_reese`).  A preset's params become the track's knobs
        (`turn :"bass/cutoff", 900.hz`; scenes take `"bass/cutoff": 3000`),
        `bind :bass, cutoff: :cut` makes one follow another knob, and
        `track :bass, L.inst.jungle_reese` again changes the instrument at
        its launch point (one undo step).  Track knobs take their params'
        full names (`:"bass/resonance"`); a short one (`:"bass/reso"`,
        `/freq`, `/q`) finds it too, with a note.
      TEXT
      commands :track, :tracks, :scene, :scenes, :go, :launch, :tweak, :quant, :undo, :redo!, :changes, :swap
      note :arrangement
      see :flow, :knobs, :now, :library
      example 'two scenes' do
        track(:try_bass, q: 1) { |c| c.tone.saw.at(-10.db).lp4(500, resonance: 0.3) * c.amp_env }
        scene :try_a, try_bass: seq(A1, rest, A1, A2).n8.loop
        scene :try_b, try_bass: seq(F1, rest, F1, F2).n8.loop
        go :try_a
        go :try_b, in: 1.bar
      end
      example 'a library instrument on a track, its cutoff a knob (at the library\'s level: loud)', sound: false do
        track :try_bass, :dnb_sub, q: 1
        bg :try_bass, seq(A1, rest, A1, A2).n8.loop
        turn :"try_bass/cutoff", 80.0, over: 2
      end
      example 'launch and tweak a clip' do
        track(:try_bass, q: 1) { |c| c.tone.saw.at(-10.db).lp4(500, resonance: 0.3) * c.amp_env }
        bg :try_bass, seq(A1, rest, A1, A2).n8.loop.named(:try_riff)
        tweak :try_bass, transpose: 12
        launch :try_bass, :try_riff, in: 1.bar
      end
    end

    Help.topic :flow, 'Song forms', group: :arrange do
      about <<~TEXT
        `flow do intro 4; verse 8; ... end` plays sections (scenes of the
        same name) with labels, gotos, and picks decided at commit points;
        perform it with loop!, onward, goto, skip, finish, practice, seek.
        `flow` alone shows it (where it is, what comes next, how to end
        it); `start` (or `play`, `go` with nothing) plays the loaded flow
        and `pause` (NAV Space) toggles.  `outro in: 4.bars` and `stop
        :all` end the flow too; `go :scene` during it seeks the flow to
        the next section playing that scene (else the nearest behind;
        `go :drop, section: :drop2` picks one; a scene no section plays
        ends the flow: you're driving).
      TEXT
      commands :flow, :start, :pause, :play_form, :section, :loop!, :onward, :goto, :skip, :finish, :practice, :seek, :marker, :meter
      note :arrangement
      see :sets, :long_form
      example 'a tiny song form' do
        track(:try_lead, q: 1) { |c| c.tone.triangle.at(-12.db) * c.amp_env }
        scene :try_intro, try_lead: seq(A4, E4).n4.loop
        scene :try_verse, try_lead: seq(A4, C5, E5, C5).n8.loop
        scene :try_outro, try_lead: seq(A4).n2.loop
        flow do
          try_intro 1
          label :top
          try_verse 2
          goto :top, times: 1
          try_outro 1
        end
      end
    end

    Help.topic :long_form, 'Long forms: markov, lsystem, generate', group: :arrange do
      about <<~TEXT
        Forms that write themselves.  `markov(still: { drift: 3, hush: 1 },
        drift: { bloom: 3, still: 1 }, ...)` is a chain of section names
        (weights pick what follows; `outro: {}` ends it and the next draw
        starts over; `[a, b] => { ... }` rules make it second order;
        weights may be knobs, read where the flow decides).  `lsystem(%i[intro
        body outro], body: { %i[build drop body] => 2, %i[build drop] => 1 })`
        rewrites a word a few `generations:`, so the song grows self-similar.
        Both are pure functions of their seed.  `chain.flow(still: 6, drift:
        4..8)` plays forever (`sections: 12` writes the first 12 out);
        `lsys.flow(...)` writes the word out.  Inside a flow, `generate
        chain, still: 6, drift: 4..8` plays one drawn section per pass,
        decided at each commit point (Ranges and Arrays draw lengths per
        occurrence; `sections: 4` per visit; `goto :hush` forces a state;
        `length: 128` bounds a run: past 128 bars the chain heads for its
        end the shortest way, as `genre(:techno).endless(length:
        600.seconds)` does).  A section may play for different lengths (`chorus 16` ... `chorus
        8`).  `seek 1000` in a generated flow plays what an uninterrupted
        run plays there (`form.plan(seed: 1).at(999)` shows it).
      TEXT
      commands :markov, :lsystem
      note :generative
      see :flow, :generative, :genres
      example 'a chain and a growing word', sound: false do
        moods = markov(still: { drift: 3, hush: 1 }, drift: { bloom: 3, still: 1 }, bloom: { hush: 2, drift: 1 }, hush: { still: 1 }, seed: 7)
        song = lsystem(%i[intro body outro], body: { %i[verse chorus body] => 2, %i[bridge chorus] => 1 }, generations: 3, seed: 2)
        [moods.take(8), song.word]
      end
      example 'a form that decides itself as it plays' do
        track(:try_lead, q: 1) { |c| c.tone.triangle.at(-12.db) * c.amp_env }
        scene :try_low, try_lead: seq(A3, E4).n4.loop
        scene :try_high, try_lead: seq(A4, C5, E5, C5).n8.loop
        scene :try_end, try_lead: seq(A4).n2.loop
        ways = markov(try_low: { try_high: 2, try_low: 1 }, try_high: { try_low: 1, try_end: 1 }, try_end: {}, seed: 4)
        flow do
          generate ways, try_low: 1, try_high: 1..2, try_end: 1
        end
      end
    end

    Help.topic :demo, 'A demo set to explore', group: :arrange do
      about <<~TEXT
        `demo` loads a whole set into the session, paused at bar 1: Night
        Bus (bin/songs/night_bus_flow.rb), tech house at 126 BPM with 12
        tracks, 12 scenes, 5 knobs, a master chain, and its song form.
        Nothing plays until you do something: `go :groove` launches a
        scene, `turn :cut, 3000, over: 2` opens the hook's filter, `play_form
        demo.form` plays the whole song (steer it with `loop!`, `onward`,
        `finish`), and `tracks`, `scenes`, `knobs`, `ui :tiles` show what
        is there.  With something already playing, `demo` asks first
        (`demo :night_bus, replace: true` stops it).  `demos` lists the
        sets.  The set is a set document in mb-sound's presets/ (saved by
        bin/save_presets.rb), so `save :mine, set` keeps your changes.
      TEXT
      commands :demo, :demos
      note :arrangement
      see :sets, :flow, :knobs, :presets
      example 'the demo sets', sound: false do
        demos.keys
      end
    end

    Help.topic :genres, 'Genre templates', group: :arrange do
      about <<~TEXT
        `genre :dnb` is a template of a genre: tempo, form, drum grids and
        fills, track roles with suggested presets, scenes, mix targets, and
        tips.  `genre(:dnb).short.play` plays it, `.setup` makes its tracks,
        buses, and scenes to play by hand, `.to_ruby` prints it, and a block
        or keywords change any part (:dnb, :jungle, :ambient, :funk, :house,
        :techno).  Templates route roles into buses (`bus :hall, [:reverb,
        :hall, { mix: 1 }]`, `role :pad, ..., send: { hall: -12.db }`, `to:`)
        and duck from the drums' own kick (`sidechain :drums, only: :kick`;
        `duck: -8.db` on a role); jungle chops `breakbeat(:jungle)` with
        `brk.chop`, ambient's bowls loop on clocks in seconds and its
        weather (rain, wind) runs through a hiss bus.  `save :x, set` after
        `.setup` keeps the buses and routes.
      TEXT
      commands :genre, :genres
      note :genres
      see :flow, :sets, :presets
      example 'a genre in numbers', sound: false do
        t = genre(:jungle)
        [t.tempo, t.form.steps.first(3), t.roles.keys, t.mix.summary]
      end
      example 'the techno template, its routing', sound: false do
        t = genre(:techno)
        [t.sidechain, t.buses.keys, t.roles[:stab].sends, t.form.bars]
      end
    end

    Help.topic :knobs, 'Knobs and snapshots', group: :perform do
      about <<~TEXT
        Named values that graphs read (`knob(:cut)`) and you turn, with
        ramps, launch points, MIDI learn, snapshots, and crossfades.  Turns
        are journaled and undoable.  Read a knob before defining it and it
        starts at 0.5 of 0..1 (with a note); `knob :cut,
        (100.hz..8000.hz).at(800.hz)` later sets it up, and whatever reads
        it keeps reading.

        Values bring their units: `knob :cut, (150.hz..8000.hz).at(2400.hz)`
        (or `2400.hz.in(150.hz..8000.hz)`) is in Hz and turns in octaves,
        and `turn :cut, 3000.hz` works; -12.db knobs turn in dB.  Common
        names bring a range: `knob :pan, 0.0` is -1..1, `knob :mix, 0.3`
        0..1, `knob :cutoff, 800.hz` 20 Hz..20 kHz.  A turn past the
        range is limited to it, with a warning; `clamp: false` lets a knob
        go out of bounds (the range still scales MIDI and the screen).
        Float ranges are continuous, Integer ranges with Integer values
        (1..8) click in steps.

        Keyframes move a knob through values over time: `turn :space, 0 =>
        0.3, 1.n8 => 0.5, 1.n4 => 0.62` (a monotone cubic through them in
        the knob's scale; `curve: :linear`, `:step`, or a Curve name).  A
        held key in the racks pane prints its gesture this way, fitted to
        the fewest keys within 1/1000 of the knob's range (knobs read with
        `choose` keep their steps).  Takes keep the raw steps, so a replay
        sounds as you played it; `smooth_gesture` makes the last gesture the
        fitted curve on purpose (undoable).
      TEXT
      commands :knob, :knobs, :turn, :snap, :snaps, :recall, :xfade, :learn, :smooth_gesture
      note :arrangement
      see :sets, :now
      example 'a filter knob' do
        knob :try_cut, (100.hz..8000.hz).at(400.hz)
        bg :try, 55.hz.saw.at(-14.db).lp4(knob(:try_cut), resonance: 0.5)
        turn :try_cut, 4000, over: 2.bars
      end
      example 'a gesture in keyframes' do
        knob :try_cut, (100.hz..8000.hz).at(400.hz)
        bg :try, 55.hz.saw.at(-14.db).lp4(knob(:try_cut), resonance: 0.5)
        turn :try_cut, 0 => 400, 1.n4 => 3000, 1.n2 => 900, 1.bar => 2400
      end
    end

    Help.topic :mixing, 'Levels, mute, solo, master', group: :perform do
      about <<~TEXT
        Each track's level is its fader: `level :bass, -6.db` (now, at a
        launch point, or `over: 4`), unity until set, after its fades and
        before its mute; scenes take `bass: -6.db` and `turn :bass, 0.5`
        works too (the level is the knob :"bass/level").  Mute and solo
        with a 5 ms declick or synced fades (muted players sleep); master
        effects run on the whole mix and swap at launch points.  The
        master gain comes before the master chain (a limiter keeps its
        ceiling); `master_gain 2.db, post: true` moves it after.
      TEXT
      commands :level, :mute, :unmute, :solo, :unsolo, :mutes, :master, :master_gain, :monitor_gain
      note :arrangement, :master_effects
      see :buses, :dynamics, :mastering
      example 'a level down over a bar' do
        bg :try, 110.hz.saw.at(-20.db).until(2.bars)
        level :try, -12.db, over: 1
      end
      example 'a quick master chain' do
        bg :try, 110.hz.saw.at(-20.db).until(2.bars)
        master { |mix| mix.softclip.limit(ceiling: -1.db) }
        after(3) { master nil }
      end
    end

    Help.topic :mastering, 'Mastering presets and loudness targets', group: :perform do
      about <<~TEXT
        `master :club` (also :streaming, :quiet, :vinyl, :hot) ends the master
        chain with a mastering preset: mono lows, glue, limiter, and a
        loudness target.  Renders reach the target exactly (two passes);
        live, `ride: true` rides the gain toward it.  `masters` lists them,
        `master(:club) { |mix| fx }` puts your effects first, and
        `render 'x.flac', master: :streaming { song }` or a song's
        `--master club` masters any song.  `:club` reaches its target with
        the loudest 16 bars (`loudest_bars:`; windows on bar lines) instead
        of the whole song, so breakdowns stay under the drops; `measure:
        :integrated` targets the whole song, and `measure: :bars` (`:hot`'s
        default) the level the quieter quarter of the bars sit at
        (`percentile: 0.25`), so a clipping chain closes the gap from the
        drops to the breakdown.  `measure: :sections` gives each section of
        the song form its own trim: the loudest reaches the target, the
        others keep `energy:` (0..1) of their distance under it in the mix.
        `master :vinyl, clip: true` rounds off peaks so a kick-led mix can
        reach its target; options a preset would ignore raise.  `master
        :match, reference: 'their_track.flac'` masters like a reference:
        its loudness and true peak, and renders turn the mix's spectral
        tilt toward the reference's (scripts: `--reference FILE`;
        `Mastering.reference(path)` shows what it measured).  Its
        `measure:` reads the song and the reference alike: `:integrated`
        (the default), `:loudest` (the loudest `loudest_bars:` bars), or
        `:histogram` (the center of the bars' loudness distribution).
        Without a master chain the live output (not renders or recordings)
        ends in a transparent safety limiter at -1 dBFS; `master` says so,
        and any chain or preset replaces it.
      TEXT
      commands :masters, :master, :render
      dsl :master, :ride
      note :master_effects, :dynamics
      see :mixing, :loudness
      example 'a preset at the listening level (drive: keeps the level fixed)' do
        bg :try, 110.hz.saw.at(-20.db).until(2.bars)
        master :quiet, lufs: -35, drive: 0.db
        after(3) { master nil }
      end
    end

    Help.topic :buses, 'Buses, sends, sidechains', group: :perform do
      about <<~TEXT
        Named buses with their own effects: tracks send a level to them
        (`send:`, `feed`) or play all of their sound into them (`to:`): one
        kind of bus for reverbs, groups, and returns alike.  They ring out on their own,
        sleeping when quiet.  `duck(:drums, only: :kick)` and `bus(:drums)`
        read a bus or track by name on the exact sample.  Buses mute and
        solo like tracks (a solo keeps the buses it feeds).  A trigger track
        (`sidechain :pump, grid(16, 'x...x...').loop`) is a sidechain line
        nobody hears: `duck(:pump)` reads it, scenes and `launch` play it
        like any track, and it never reaches the mix, stems, or CUE
        (`shape: env(0, 0.08)`, or a block: closed hats as the key; also
        `pump`).  `level :pump, 0` turns the pump off (its level, like any
        track's; scenes and sections take `pump: 0`, `pump: 1`), or `stop
        :pump`.  In a kit,
        `voice :trigger, silent: true` plays a row only for
        `duck(:drums, only: :trigger)`.
      TEXT
      commands :bus, :buses, :feed, :routes, :sidechain, :sidechains
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
      example 'duck a pad by a trigger track nobody hears' do
        sidechain :try_pump, grid(16, 'x...x...x...x.x.').loop
        bg :try, 110.hz.saw.at(-14.db).lp4(900).duck(:try_pump, amount: -12.db).until(1.bar)
      end
    end

    Help.topic :cue, 'CUE: audition in the phones, then launch', group: :perform do
      about <<~TEXT
        `cue :acid, sound` plays a part in the headphones only, in time with
        the set (player :"acid/cue"); `launch :acid` brings that same graph
        to MAIN at the launch point (a track's `q:`, else the next bar),
        crossfading over `fade:` and replacing what played as :acid.  `cue
        :bass, clip` cues a track's patch on another clip; `cue :drums`
        pre-listens a playing part without touching MAIN.  `uncue` ends
        them, `cues` lists them.  The phones mix: `turn :phones, -6.db`,
        `cue_mix 0.5` (0 CUE only, 1 MAIN only; `save: true` keeps it).
        `cue :drop` cues a scene's changed tracks, `launch :drop` launches
        the scene with them.  A 4-channel output (`CUE_OUTPUT=ports`, JACK
        ports cue_1/cue_2) gives CUE its own channels; on 2 channels CUE
        splits them (MAIN mono left, phones right) from the first cue, or
        `cue_output :phones` / `:off`.  Renders never include CUE.
      TEXT
      commands :cue, :launch, :uncue, :cues, :cue_output, :cue_mix
      note :cue
      see :sets, :knobs, :mixing
      example 'pre-listen a part, then launch a cued one' do
        bg :try, 110.hz.saw.at(-20.db).lp4(900).until(2.bars)
        cue :try
        cue :try_hi, 330.hz.triangle.at(-26.db).until(2.bars)
        launch :try_hi, on: :beat
      end
    end

    Help.topic :racks, 'Racks: reusable graphs with typed ports', group: :perform do
      about <<~TEXT
        A rack is a piece of graph you can reuse, like a Proc: `mrack` takes
        notes, `irack` notes and makes audio, `arack` audio, `lrack` audio
        and makes notes or control, `modrack` control (`rack(in:)` is the
        general form).  Apply it with `then`, `.()`, or `through`; each use
        builds a fresh copy.  Extra ports are keywords (`arack :dub, side:
        :audio do |sig, side:|`), bound with `with` (bus, track, and knob
        names work as values).  `>>` chains racks; note streams merge with
        `+`.  Named racks list in `racks` and print with `rack(:x).to_ruby`.
        `knob :space, 0.3` inside a rack block is a knob scoped to the rack
        (`turn :"dub/space", 0.6`; per player, `:"bass/dub/space"`, when the
        rack plays in several, and `:"dub/space"` turns them all); `share: true` joins the session knob
        `:space`, `follow: :space` maps it onto this knob's range, and
        `.mod(lfo, depth: 0.2)` swings around it.  `rack(:dub).snap :wide`
        and `recall :"dub/wide", only: [:space]` keep variations.  `help
        rack(:dub)` shows ports, knobs, and latency.  `save :dub,
        rack(:dub)` writes a rack document: `preset :dub` gives the rack
        back, `preset :dub, sig: mic` plays it on an input (try the library
        rack `preset :dub_echo`); a saved rack that differs from the
        session's asks, or takes `racks: :session`, `:saved`, or `:rename`.
      TEXT
      commands :rack, :racks, :mrack, :irack, :arack, :lrack, :modrack
      note :racks
      see :buses, :midi, :presets
      example 'a note rack: an anonymous value' do
        wobble = mrack { it.arp(:up, 16).echo(3.n16, 2, pitch: 7) }
        bg :try, seq(A3, C4, E4, G4).n4.loop.then(&wobble).synth { |v| v.hz.triangle.at(-17.db) * v.amp_env(0.005, 0.1, 0.3, 0.1) }.until(1.bar)
      end
      example 'an effect rack with a sidechain port' do
        arack(:try_pump, side: :audio) { |sig, side:| sig.duck(side, amount: 12.db, threshold: -24.db).softclip }
        track(:try_kick) { |k| tr808(k).at(-14.db) }
        bg :try_kick, grid(16, kick: 'x...x...x...x...').loop
        bg :try, 55.hz.saw.at(-24.db).lp4(700).then(&rack(:try_pump).with(side: :try_kick)).until(1.bar)
      end
    end

    Help.topic :midi, 'MIDI', group: :perform do
      about <<~TEXT
        `midi` is a Notes on live input; `synth` allocates voices from any
        MIDI source; transforms (echo, arp, chord, strum, ...) work on
        Streams, Notes, and Clips; mod_sum and friends route modulation.
        Stuck note on live input (a keyboard dropped a note-off)?  Press
        the key again and let go: live input restrikes held keys
        (`same_key: :restrike`; files and clips count overlaps,
        `same_key: :count`).
      TEXT
      commands :midi, :midi_file, :midi_stream, :synth, :per_voice, :close_midi, :mod_sum, :mod_scale
      dsl :gate, :trigger, :velocity, :amp_env, :hz, :cutoff, :reso, :arp, :echo, :chord
      note :midi
      see :record, :midi_files
    end

    Help.topic :midi_files, 'MIDI files as clips and kits', group: :perform do
      about <<~TEXT
        `midi_tracks 'song.mid'` lists a file's tracks (notes, range, mono
        legato or chords, controller lanes).  `midi_clip 'song.mid',
        track: 'Bass'` is that track as a looping clip in exact note
        positions from the file's ticks (files without a tempo play at the
        session tempo), over whole bars of the file's meter: `from: 16,
        bars: 8` cuts a phrase.  A mono legato line keeps its overlaps as
        slides (`~`); chords and ringing arpeggios stay notes.  The track's
        CCs, bend (with its RPN range), and pressure come along as lanes
        that voices read (`v.mod`, `v.cc(74)`, `v.bend`): `cc: :fit` turns
        dense recorded steps into a few smooth keys, `cc: false` drops
        them; a lane turns a knob too (`turn :vol,
        clip.control(7).keyframes(0.0..1.0)`).  `timing: :performed`
        keeps a rubato file's tempo map.
        `midi_kit 'beat.mid'` makes the drum tracks a grid-like Kit for
        tr808/tr909.  Saved graph documents keep the notes and lanes as
        `events(...)`, not the file.
      TEXT
      commands :midi_tracks, :midi_clip, :midi_kit, :midi_file
      note :midi
      see :midi, :sequences
    end

    Help.topic :templates, 'Rhythm and feel templates', group: :perform do
      about <<~TEXT
        Any clip lends its rhythm or its feel.  `clip.rhythm` is which
        steps play, how long and how loud, with accents and slides:
        `.notes(C1, F1, [A1, E2], nil)` pours pitches in, cycling (Arrays
        are chords, nil rests a hit), `.pitches(0, 2, 4, scale:
        scale(:minor))` scale degrees, `.to_clip(36)` one note.
        `take.groove` measures a played clip against a 16th grid (`grid:
        8`, `triplets: true`): each step's mean timing offset and level;
        `beat.groove(feel, amount: 0.6)` moves another clip or kit onto
        those positions and levels (the quantize core; `velocity: 0` for
        timing only), and `midi.groove(feel)` delays live notes the same
        way.  Printed grooves and rhythms read back as `groove_template`
        and `rhythm` calls.
      TEXT
      commands :rhythm_template, :groove_template, :midi_clip
      dsl :rhythm, :groove, :quantize
      note :sequences
      see :midi_files, :sequences
    end

    Help.topic :key, 'The session key and modes', group: :time do
      about <<~TEXT
        The session has a key: `key :ab` sets the root (also 'F#', a Note
        like Ab2, or 0..11), `mode :phrygian` the scale (any scale name),
        `key :d, :dorian` both, and bare `key` / `mode` read them back.
        Changes take launch points (`mode :lydian, on: :bar`), work in
        scheduled blocks, scenes (`scene :drop, key: [:a, :minor]`), and
        sections (`drop 8, key: :d, mode: :dorian`), and are undoable.
        `scale(:dorian)` without a root uses the key's root; bare `scale`
        is the key's scale; `degrees`, `snap`, and `lock` follow the key
        as it changes.  `mode knob(:dark)` walks the modes from Lydian to
        Locrian, one note at a time (`modes(:dorian..:phrygian, by:
        knob(:dark))` for part of the walk).
      TEXT
      commands :key, :mode, :modes, :scale
      dsl :degrees, :snap, :lock
      note :midi
      see :lock, :params, :sequences
      example 'a riff that follows the key' do
        key :d, :dorian
        riff = seq(C4, D4, E4, G4, A4, G4, E4, D4).n8.loop
        bg :try, riff.stream.lock(:play).synth(voices: 4) { |v| v.hz.triangle * v.env(0.005, 0.2, 0.3, 0.2) }.at(-14.db)
        mode :lydian, on: 2
      end
    end

    Help.topic :lock, 'Keyboard locks: play in key', group: :perform do
      about <<~TEXT
        `lock :play` maps live MIDI and the virtual keyboard into the
        session key: the root on every C, black keys passing notes between
        their neighbours.  `lock :mash` makes every white key the next
        scale degree and silences black keys (mash anything), `lock
        :along` snaps each key to the nearest scale note, `lock :chord`
        plays the current chord's tones (`from:` a clip of chords or
        degrees like [1, 6, 4, 5]; `extend: :above` stacks 7ths and 9ths
        above the chord, `bass: :root_fifth` below it), `lock :off`.
        Keywords override one option (`lock :chord, extend: true`), and
        streams take the same styles: `riff.stream.lock(:mash)`,
        `midi.degrees(:minor_pentatonic, layout: :fit)`, `midi.snap(:chord,
        from: chords)`.  A knob can pick the style: `lock
        knob(:style).choose(:mash, :play, :chord)`.  The virtual keyboard's
        own scale lock (`ui.keyboard.scale = ...`) is :mash unless
        `ui.keyboard.scale_mode` says otherwise.  Cents scales give whole
        notes with pitch marks (`micro: :mark`, sent as MIDI bends); `v.hz`
        and samplers play the marks, so they sound in tune everywhere
        (`v.freq(marks: false)` leaves them out); `micro: :note` gives
        fractional note numbers instead (no MIDI bytes).
      TEXT
      commands :lock, :key
      dsl :degrees, :snap
      note :midi
      see :key, :midi, :ui
      example 'the same keys in three locks' do
        key :a, :minor
        keys = seq(48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59).n16.loop
        voice = proc { |v| v.hz.triangle * v.env(0.003, 0.15, 0.2, 0.1) }
        bg :try, keys.stream.lock(:mash).synth(voices: 4, &voice).at(-14.db)
        bg :try2, keys.stream.lock(:chord, from: [1, 6]).transpose(12).synth(voices: 4, &voice).at(-20.db)
      end
    end

    Help.topic :params, 'Parameters that move', group: :perform do
      about <<~TEXT
        MIDI transforms read moving parameters at each decision (each
        note-on, arp step, or bar): `cc(1, 0.5..0.7)` (a controller on the
        transform's own input, else the session's MIDI input), knobs
        (`knob(:swing)`, `knob(:rate).choose(8, 16, 32)`), tempo LFOs
        (`4.bars.lfo.at(0.5..0.66)`), clips (`transpose(seq(0, 5, -2,
        3).n1.loop)`: a step per bar), and arithmetic on them (`0.5 +
        cc(1) * 0.2`), all printing back as Ruby.  humanize, quantize,
        swing, chance, transpose, every, arp rates, and ratchets take them,
        on streams and clips.  A knob read ahead (a generator's next cycle)
        answers what is known when it is asked, including turns queued with
        launch points; takes record those answers so replays match.
      TEXT
      commands :cc, :knob, :modes
      dsl :swing, :humanize, :chance, :transpose, :arp, :ratchet, :every, :quantize
      note :midi
      see :knobs, :key, :sequences
      example 'swing that breathes and a transpose by a clip' do
        riff = seq(A3, C4, E4, G4, A4, G4, E4, C4).n16.loop
        steps = seq(0, 5, -2, 3).n1.loop
        bg :try, riff.stream.swing(4.bars.lfo.triangle.at(0.5..0.68)).transpose(steps).synth(voices: 4) { |v| v.hz.triangle * v.env(0.003, 0.2, 0.2, 0.1) }.at(-14.db)
      end
      example 'an arp whose rate a knob picks' do
        knob :try_rate, 0
        chords = (seq(A3, F3).n1 & seq(C4, A3).n1 & seq(E4, C4).n1).loop
        bg :try, chords.stream.arp(:up, knob(:try_rate).choose(8, 16, 32)).synth(voices: 4) { |v| v.hz.triangle * v.env(0.003, 0.1, 0.2, 0.05) }.at(-14.db)
        turn :try_rate, 1, over: 2
      end
    end

    Help.topic :record, 'Recording and takes', group: :keep do
      about <<~TEXT
        The take logs every line and where each change landed (`take.save`
        replays it exactly).  `rec`/`capture` record MIDI into armed tracks
        (loops follow the timeline's phase; `align: :launch` starts from
        what you played first; `cc: true` keeps the mod wheel, other CCs,
        bend, and pressure in the clip, `cc: :split` in a clip of their own,
        `captures[:lead_1_cc]`); an armed track's live monitor is its own
        player, :"name/live", which `stop :name` leaves playing and
        `disarm` stops.  `rec_audio` records the master bus to a file;
        `render` bounces graphs offline (`render 'drop.flac', from: :drop,
        bars: 8 { song }` renders one section, exactly as in the whole
        song; scripts take `--from drop --to breakdown`, and `--take
        take.rb` saves a run as a replay script).  No MIDI keyboard?  The tiles'
        virtual keyboard (`ui.keys`, see `help :ui`) plays into the same
        input, and Enter there captures.
      TEXT
      commands :take, :arm, :disarm, :armed, :rec, :capture, :captures, :rec_audio, :stop_rec_audio, :recordings, :render, :write
      note :arrangement
      see :midi, :presets
    end

    Help.topic :presets, 'Saving graphs and sets', group: :keep do
      about <<~TEXT
        Every graph prints itself back as Ruby (`ruby node`; aliases print
        as their official names: `saw` as `ramp`); `save` writes a
        graph document (or the whole set) and never replaces one (`save!`
        does; `bump: true` saves `:name_v2`; `tags:` and `about:` describe
        it for `find`), `preset` loads one with new inputs and params.

        mb-sound comes with presets too (`presets`
        lists them): drum & bass, jungle, ambient, and funk instruments,
        like `preset :dnb_reese, midi: midi` or `preset :ambient_tape, input: mic`,
        and electric pianos: `:tine_piano` clean, `:tine_crunch` with its amp
        pushed (`amp: 1..8`), `:reed_piano`, the SQ-80 voice's patches
        (`:sq80_glass` and friends; see `help :sq80`), and three wavetable
        voices: `:square_bass`, `:organ_reso`, `:digibrass` (`grit: 1` holds
        their oscillators at 38.46 kHz, aliasing on purpose).
      TEXT
      commands :ruby, :save, :preset, :presets, :set, :named_proc
      note :graph_io
      example 'print a graph back as Ruby', sound: false do
        ruby 110.hz.saw.at(-20.db).lp4(800, resonance: 0.3).softclip
      end
    end

    Help.topic :library, 'The library: find, heads, shelves', group: :keep do
      about <<~TEXT
        Every named thing (reverb and chorus presets, resonator banks,
        envelope curves, mastering chains, instruments, effect chains,
        drum machines, graph documents, clips) is an entry in one library.
        `find 'dark bass'` lists the best matches with why each matched;
        `L.fx.reverb.hall` reaches one by words, each narrowing the last
        (`L.inst.reese` lists both Reeses, Tab shows what is left), and
        `.(sig)` uses it: `sig.then(&L.fx.hall)`.  Heads: `L.inst`,
        `L.fx`, `L.kit`, `L.seq`, `L.master`, `L.set`, `L.env`, `L.edit`,
        `L.all`.

        Entries come from shelves, searched in order: the session's racks,
        the project's presets/ (your song), the user shelf (a git
        repository every save commits to), gems, then mb-sound's own
        (`shelves` lists them).  A library file on a shelf holds entries as
        lines: `reverb :big_plate, decay: 3.5, tags: %i[bright big]`,
        `instrument :keys do |midi| ... end`, `chain :dub do |sig| ...
        end`, `clip :walk, seq(A2, C3).n8.loop`.  `collect` copies the
        presets a song used into its presets/, `promote :x, to: :user` a
        song's preset onto your shelf.

        Instruments play on tracks (`track :bass, L.inst.dnb.dnb_reese`;
        `help :sets`) and from `play L.inst.x` (a demo phrase).  Effects
        go after a sound: `sig.then(&L.fx.hall)`, or on a bus; `play
        L.fx.hall` plays a demo phrase through one.  `audition L.inst.x`
        plays an entry as the player :audition: on CUE when the output has
        it, else on MAIN 6 dB down; another replaces it, `audition off`
        stops it.  In `ui :sound` the library picker (NAV l) does the same
        from the keys: / finds as you type, a auditions, Enter loads the
        entry into the inspected track at its launch point (knobs you
        turned carry), e puts the line on the console to edit.  The
        resonator effects are instruments too: `L.inst.bar` strikes the
        :bar resonator from notes (`struck(clip, :bar)`; every resonator
        preset has one, built from it), `L.fx.bar.ping(C5)` strikes it
        once, `play L.fx.bar` plays a strike, and a library file line
        `struck :my_bell, resonator: :bell, decay: 8` makes another.

        Judging presets by ear: `L.fx.reverb.bench` renders every reverb on
        the Listening Bench's material (the A7 arp, the jungle break, a saw
        pad; instruments on phrases for their role and their genre
        template's phrase), each matched to -20 LUFS, into a Bench set
        folder (`bin/preset_bench.rb reverb` from a shell; `--vs master-ai`
        for before/after, `--notes` reads the verdicts back).
        `play L.fx.reverb.hall.audition(:break)` plays one of them;
        `.auditions` lists an entry's materials, and `play L.fx.hall`
        plays an effect on the arp.
      TEXT
      commands :find, :audition, :shelves, :save, :save!, :collect, :promote, :promote!, :struck
      note :library
      see :presets, :racks
      example 'find bright effects', sound: false do
        find :bright, kind: :effect
      end
      example 'walk the heads', sound: false do
        L.fx.reverb
      end
      example 'a struck resonator from notes' do
        bg :try, struck(seq(C5, E5, G5, C6).n8.loop, :marimba).at(-12.db)
      end
      example 'a plate reverb on the Bench arp' do
        bg :try, L.fx.reverb.plate.audition(:arp).at(-14.db)
      end
    end

    Help.topic :plots, 'Plots', group: :look do
      about <<~TEXT
        Pure-Ruby plots in the terminal (Braille, blocks, sparklines) or as
        images: waveforms, spectra, spectrograms, histograms, and chart
        builders; `vis` plots the live mix.
      TEXT
      commands :plot, :spectrum, :spectrogram, :time_freq, :hist, :density, :mag_phase, :overlay, :overlay_chart, :table, :chart, :figure, :vis
      note :plotting
      example 'one cycle of a pulse', sound: false do
        plot 100.hz.pulse, samples: 480
      end
    end

    Help.topic :analysis, 'Analysis', group: :look do
      about <<~TEXT
        Pitch, peaks, and correlation of sounds and arrays, and the form of
        a render or a file: tempo, beats, bars, and sections with letter
        labels (`s = analyze_form('song.flac')`, `s.sections`, `puts
        s.flow_ruby`, `s.markers!` for `seek :"analysis/b_1"`, and
        `s.compare(take.form)` to check a render against the flow that
        played).  Keys: `Sample['pad.wav'].key_analysis`.
      TEXT
      commands :freq_estimate, :peaks, :autocorrelate, :crosscorrelate, :peak_correlation, :analyze_form, :loudness
      note :structure
      see :loudness, :plots
    end

    Help.topic :loudness, 'Loudness', group: :look do
      about <<~TEXT
        BS.1770 loudness of files and graphs, live meters, and normalized
        renders.  `render 'mix.flac', bars: 64, report: :tracks { song }`
        (scripts: `--report`) prints LUFS, short-term max, true peak, and
        PLR per track and the mix, and each section pass's loudness.
      TEXT
      commands :loudness, :render
      dsl :loudness_meter
      note :method_modules, :dynamics
      see :mastering
    end

    Help.topic :now, 'Help and what is going on', group: :look do
      about <<~TEXT
        `now` shows what plays, knobs, scenes, the flow, and queued changes
        with the commands that apply; `help node` explains a graph;
        `lesson` teaches the newer layers step by step.  When something
        goes wrong live, `debug_dump` writes the state (players, changes,
        graphs as Ruby, the screen, the take, recent MIDI, threads) to a
        folder to read or send along.
      TEXT
      commands :help, :now, :lesson, :players, :knobs, :scenes, :tracks, :mutes, :changes, :markers, :ruby, :debug_dump
      see :sets, :knobs, :ui
    end

    Help.topic :ui, 'Dashboard band and tiled screen', group: :look do
      about <<~TEXT
        `ui` puts a live dashboard band under the prompt (transport, form,
        tracks, queued changes, master meters, a scope); Pry keeps the rest
        of the screen, and scrolled lines stay in the terminal's scrollback.
        `ui :deck` adds knobs and CPU, `ui :mini` is one line, `ui off`
        hides it.

        `ui :tiles` (or `:studio`, `:keys`, `:wall`) takes the whole screen:
        panes tiled around the console, which keeps a 10 000-line scrollback
        of its own.  Ctrl-] is NAV mode (`?` there lists its keys): numbers
        and arrows pick a pane, Enter goes into it (the REPL, KEYS on the
        keyboard, a pane's own keys until Esc), and a pane's letter beside
        its number jumps straight in (i the REPL, k the keyboard, a the
        clips).  Ctrl-W is NAV for one key: Ctrl-W z zooms and comes back,
        Ctrl-W a goes into the clips, Ctrl-W Ctrl-W swaps between the last
        two panes, Ctrl-W Ctrl-] stays in NAV.  F2 or
        `keys` is the keyboard, Ctrl-Z hides the tiles while the set plays
        on (`fg` brings them back, `jobs` lists what runs).

        Warnings go to a messages pane while a screen is up (NAV m shows
        it; `ui off` sums them up).  NAV f shows the frame rate and each
        pane's rate beside its number (`ui.fps` is what was drawn,
        `ui.target_fps` the painter's rate; meters and scopes run at it and
        everything slows in steps when the CPU is busy).

        `ui.note 'the cutoff turns too slowly'` keeps a note for the next
        UI refinement round with the screen as text, the layout and focused
        pane, what plays, and your last console lines (one Markdown file a
        day; NAV # opens a prompt for one while the set plays); `ui.notes`
        lists today's.

        Your own panes: `pane :name do |c, s| ... end` (s a snapshot of the
        session, c the pane's canvas); arrange them with `layout`, keep a
        layout with `ui.save`.  `ui.split :v`, `ui.zoom`, `ui.show :cpu`,
        `ui.save :mine` change the tiles from the prompt; `ui.on C1, :zoom`
        maps a pad; `ui.theme :mono`.  Themes, pane files, and layouts are
        data files in the ui folder, reloaded when they change;
        `bin/ui_check.rb` reports what your terminal supports.

        The keyboard plays notes into the session's MIDI input, so
        `arm :lead` plays the lead and Enter captures what you just played
        into it (with nothing armed a default patch plays).  Most terminals
        send no key-up, so notes are a fixed length there
        (`ui.keyboard.tap = 0.5`); with the kitty keyboard protocol (kitty,
        WezTerm, Ghostty, foot, iTerm2 with its setting) they end on
        key-up.  Tab is step entry: Enter puts the clip's Ruby
        (`seq(C3, E3, G3.n4).n8`) on the console line.  Notes from a MIDI
        keyboard light the piano too, in a second color.
        `ui.keyboard.scale = scale(:dorian, :d)` locks the keys in mash
        style (every white key the next degree, black keys silent: never a
        wrong note); `ui.keyboard.scale_mode = :play` fits the scale to the
        octave instead (see `help :lock`); PgUp/PgDn cycle scales and roots.

        `ui :session` shows the set: the clip matrix (`clips`: a row per
        track, a column per scene, then each track's other slots; ▶ plays
        (in one column: the current scene's, else the first giving it), a
        dim ▷ marks the other scenes that would keep it playing if launched,
        ◆ is queued with its countdown in beats), the clip under its cursor
        (`clip`: a piano roll and the Ruby that made it), racks with their
        knobs, buses with meters.  Focus a pane in NAV (its number, or a
        for clips, r racks, b buses) and press Enter for its keys: arrows
        move, Enter launches the cell (`launch :bass, 3`), g its scene (`go
        :drop`), x stops the track, + - > < transpose, L legato, S swing, Q
        quantize, D double, H half, R reverse (`tweak :bass, transpose: 1`),
        u undo; in racks Left/Right turn the picked knob (Shift: fine;
        a held key is one `turn :x, 0 => 0.3, 1.n8 => 0.5` line when you let
        go: its fitted keyframes; the take keeps the raw steps).
        Every key runs one console line, printed in the console: journaled,
        undoable, in your take.  `ui :mixer` shows buses beside the master.
      TEXT
      section do |d|
        rows = UI.layout_table.map do |name, kind, desc, size, panes, current|
          label = "#{current ? '* ' : ''}#{kind == :script ? '--ui' : 'ui'} #{name.inspect}"
          what = "#{desc}#{size ? " (#{size})" : ''}. #{kind == :band ? 'Band' : kind == :script ? 'Script screen' : 'Tiles'}: #{panes.join(' ')}"
          [label, what]
        end
        d.heading('Layouts  (* on screen now)').rows(rows, max_label: 18, wrap: true)
      end
      section do |d|
        # (The pane catalog, ui.panes: ux-1 r3 item 40)
        d.heading('Panes  (ui.panes; ui.list: what is on screen; ui.size)')
        d.rows(UI.pane_catalog.entries.map { |e| [e.name.inspect, "#{e.description} (#{e.open})"] }, max_label: 12, wrap: true)
        d.heading('Sizes  (one decision per terminal size: UI::Density)')
        d.rows(UI::Density.table.map { |t| t.split(': ', 2) }, max_label: 20)
      end
      section do |d|
        UI::Tiles::KEY_HELP.each do |mode, groups|
          groups.each do |group, keys|
            d.heading("#{group} keys  #{Help::Text.c(:dim, { nav: '(NAV: Ctrl-])', grab: '(KEYS: F2, keys)', step: '(step entry: Tab in KEYS)' }[mode])}")
            d.rows(keys, max_label: 20)
          end
        end
      end
      commands :ui, :off, :pane, :layout, :keys, :fg, :jobs
      note :terminal_ui
      see :now, :plots
    end

    Help.topic :inspector, 'Sound design: the patch inspector', group: :look do
      about <<~TEXT
        `design :bass` opens a track for sound design: `ui :sound` with the
        inspector on the track's filter and its keys live, the track playing
        on MAIN (`design :bass, L.inst.dnb.dnb_reese, riff` makes the track
        first; `design :lead` alone starts a new track from the init voice:
        two morphing oscillators, FM, AM, and sync, a filter, every number a
        knob; `design off` puts the screen back).  The inspector shows the
        voice in sections, the way a synth's panel is laid out: SOURCE
        (oscillators, samples, glide), FILTER, AMP (drive, the amp
        envelope), MOD (LFOs), FX, each envelope in the section it shapes.
        s f a o x jump to a section (again: its next row), n/N step rows,
        Up/Down pick the open row's params, Left/Right turn the knob a
        param reads (Shift or H/L fine; a held key is a live sweep, one
        `turn` line when you let go), Enter types a value, 0 its default, m
        learns a MIDI controller.  P flips to the front panel (only the
        knobs and literals, side by side; the default at 80x24), p shows
        every node, plumbing too; a kit picks its voice with v/V.

        A number no knob drives (`resonance: 0.25`, an envelope's attack, a
        point of `env([[1, 0.01], [0.6, 0.3]])`, a chained `.curve(release:
        30)`) shows dim with a dot: Enter offers `bind :bass, lp4:
        :resonance` (`env: :t2`, `curve: :release`), a knob at that value
        and the patch rebuilt reading it at the track's launch point (the
        same sound until you turn it; held notes play on with their phases
        and envelope levels; undo brings the number back), and Left/Right
        bind it right away and turn it: an envelope's points move under
        your arrows, the preview marking the picked one.  A preset's numbers are fixed;
        its params are the track's knobs already.  Every change is one
        console line: journaled, undoable, in your take.  The preview draws
        the picked row: a filter's response (lp4 and diode too, with their
        resonance and tuning), a shaper's curve, an envelope's note with a
        playhead.  The code pane (NAV c) shows the knob lines and the
        graph's Ruby; the render pane (NAV w) plays one note through a copy
        of the voice (a settled cycle, its spectrum, half a second of
        envelope) after the knobs stop moving.  Small screens get fewer
        panes: the voice, its preview, and the console at 80x24.
      TEXT
      commands :design, :ui, :knob, :turn, :learn, :bind
      note :sound_design_ui
      see :ui, :knobs, :cue, :presets
    end
  end
end

#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Small Talk": a bass house track at 125 BPM in G minor, about 90 bars
# (2:50), built around a talking bass: the vocal lead patch from
# bin/synths/vocal_lead.rb (a kick drum as a wavetable -> a tenor formant
# filter in parallel with a resonant lp4 -> a key-tracked sample-rate
# crusher, 40% wet) in the bass octave, its vowels and peak swept by a
# 4-bar triangle skewed to 0.9 (rising 3.6 bars, falling 0.4), with notes
# before rests diving two octaves like a tape stop.  The bass carries the
# melody; a silent chord progression underneath (Clip#ghost_chords,
# natural minor i-iv-VII-VI, Gm Cm F Eb) moves it bar by bar, and the
# second drop changes the progression to i-VI-III-VII (Gm Eb Bb F).
#
# Written for small speakers as well as big ones: closed hats on every
# 16th (offbeats accented) and a bright clap carry the grid, the talking
# bass is mostly harmonics (formants and crusher aliasing, 300 Hz-3 kHz)
# over a sine sub, and the groove's "bong" bass is saturated so its pitch
# reads without the sub.  Everything with sixteenths (hats, shaker, ride,
# bongs, the talking bass) shares one swing.
#
#   intro     8  drums only: kick, offbeat hats, a soft/accented shaker,
#                a clap roll turnaround every 8 bars, toms every 4
#   groove    8  clap on 2 and 4, open hats, the "bong" bass (a saturated
#                sub tom on the offbeats, ducked by the kick)
#   tease     8  the talking bass enters through a lowpass (the :cut knob
#                opening 300 Hz -> 2.2 kHz), a bandpass noise riser in the
#                last 4 bars (maintainer, 2026-10-12: risers sound better
#                as a bandpass sweep than a highpass)
#   drop      8  dry: the talking bass wide open, hats on every 16th, a
#                crash and a sub "boom" on the downbeat
#   pickup    8  the same bass through the ghost chords i-iv-VII-VI, a
#                ride, a second boom
#   breakdown 8  kick and low end out (the master's :air highpass up to
#                220 Hz), hats and shaker keep going; a pad (root and
#                fifth, leading the beat by half its attack) and a
#                "Delay Lama" chant (a tenor formant on a pair of saws in
#                the 100 Hz range, sliding "oo-ah" on every note) singing
#                the same ghost chords; a delay throw on the last 2 beats
#   lift      8  the chant and pad go on over a light kick (still no low
#                end: it all comes back at once in drop2), the riser again
#   gap       1  one bar of 2/4: everything rings out for a half-bar breath
#   drop2     8  low end back, the talking bass on i-VI-III-VII, boom
#   pickup2   8  a seeded pick: usually the ride pickup, one time in three
#                the chant answers the bass (a swap-up: call and response)
#   outro     8  the bass closing into its filter, simple drums
#   tail      8  kick and hats for the DJ, then the end rings out
#
# The mix: the kick ducks the bass parts -18 dB (Dynamics#duck from a
# ghost kick: the same 808 kick, inside each ducked track), the drums get
# parallel compression, and the master runs a gentle glue compressor into a
# true-peak limiter at -1 dBTP with the master bus at 0 dB (this is a
# mastered track: -14.2 LUFS integrated, -1.0 dBTP, as rendered).
#
# Usage:
#     bin/songs/small_talk.rb                    # plays live in the background session
#     bin/songs/small_talk.rb small_talk.flac    # renders to a file instead (-f to overwrite)
#     bin/songs/small_talk.rb --seed 3 out.flac  # the other branch of the pick (the chant answers)
#     bin/songs/small_talk.rb -m 1 out.flac      # fully crushed talking bass
#     bin/songs/small_talk.rb --help             # all options
#
# Or in bin/sound.rb:
#     load 'bin/songs/small_talk.rb'
#     small_talk                  # tracks and scenes only (go :drop etc. by hand), then
#     small_talk_form             # play the form and steer it yourself
#     small_talk(perform: true)   # or the whole performance
#
# Try (while it plays):
#     go :drop                    # straight to the talking bass
#     swap :talk, SMALL_TALK_HOOK.ghost_chords(1, 4, 7, 6, scale: scale(:minor, :g), harmonic: true)  # harmonic minor
#     swap :talk, SMALL_TALK_HOOK.ghost_chords(1, 4, per: 2.beats, scale: scale(:minor, :g))          # two chords a bar
#     turn :cut, 500, over: 2     # close the bass's filter over 2 bars (turn :cut, 16000 to open)
#     turn :space, 1, over: 1.n16; turn :echo, 0.7, over: 1.n16   # throw the chant's delay...
#     turn :space, 0.3, over: 1.n8; turn :echo, 0.3, over: 1.beat  # ...and back
#     move :air, 220; undo        # the low end out, then back at the next bar
#     practice :drop2             # stay in the second drop
#     finish                      # the outro next
#
# Listening notes: the talking bass's vowels open over 3.6 bars and snap
# back in the last 0.4 of every 4 (so each 4-bar phrase "says" one long
# word); the dives after the rests reach ~12-15 Hz, where each wavetable
# cycle is nearly a single kick.  On laptop speakers listen for the bass's
# pitch in the 200-600 Hz formants: it should follow the ghost chords.
#
# Cost (whole render through the Session and master chain, YJIT, the Mac's
# container, 2026-10-12): 512-sample buffers mean 18% of realtime, p99
# 53%, worst steady-state buffer ~80%; 128-sample buffers mean 37%, p99
# 87%.  Scene changes build graphs: scheduled blocks up to 0.75 s (the
# breakdown's chant and pad) against the scheduler's half-bar (0.96 s)
# lookahead, and render-thread spikes up to ~200 ms where they land
# (night_bus_flow measures 1.56 s and ~270 ms the same way).

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/vocal_lead'
require_relative '../synths/fifth_pad'

module MB::Sound
  # The length of the performance in bars (to the end of the tail's ring
  # out, with the default seed).
  SMALL_TALK_BARS = 92

  # One swing for every part that plays sixteenths.
  SMALL_TALK_SWING = 0.54

  # The 808 kick's knobs (the drums and the ghost kicks that duck the bass
  # parts share them, so the duck follows the kick heard).
  SMALL_TALK_KICK = { tune: 49, decay: 0.45, tone: 0.45 }.freeze

  # The talking bass's hook: two bars of sixteenths in the bass octave
  # (G1-D2), mostly off the kicks, notes before rests diving.
  SMALL_TALK_HOOK = seq(
    R, R, G1, T, T, T, G1, T, R, R, Bb1, T, G1, T, T, R,
    R, R, G1, T, T, T, D2, T, T, R, C2, T, Bb1, T, G1, T,
  ).n16.swing(SMALL_TALK_SWING).loop(align: :launch)

  # The chant's motif: one bar on the G minor triad (repeated and moved by
  # the ghost chords).
  SMALL_TALK_CHANT = seq(D3, T, T, Bb2, T, T, C3, Bb2).n8.loop(align: :launch)

  # A drum Kit with every row (empty rows are rests), so scenes swap kits
  # without rebuilding the drums.  Hat, shaker, and ride rows swing.  With
  # +crash: true+, a crash on the first bar of every 8 from the launch.
  def self.small_talk_kit(crash: false, **rows)
    all = { kick: '', clap: '', hat: '', open_hat: '', shaker: '', ride: '', crash: '', low_tom: '', mid_tom: '' }.merge(rows)
    all[:crash] = 'X...............' if crash
    kit = grid(16, **all.transform_values { |p| p.empty? ? '.' * 16 : p })
    Sequence::Kit.new(kit.rows.to_h { |name, clip|
      clip = clip.swing(SMALL_TALK_SWING) if [:hat, :shaker, :ride].include?(name)
      clip = clip.every(8) if name == :crash
      [name, clip]
    })
  end

  # The kits, each with fills: a clap roll in the last bar of every 8 (the
  # :turn phrase fill; the plain clap and open hats step aside) and a tom
  # answer in the last bar of every 4 (:toms).
  def self.small_talk_kits
    turn = ->(kit) {
      kit
        .nofill(:clap, :open_hat, name: :turn)
        .fill(:turn, clap: grid(16, '....X...x.x.xXXX', value: 39))
        .fill(:toms, low_tom: grid(16, '...........x..x.', value: 45), mid_tom: grid(16, '............x..x', value: 48))
    }
    kick = 'X...x...X...x...'
    clap = '....X.......X...'
    shaker = '3735373537353735'
    sixteenths = 'xxXxxxXxxxXxxxXx' # every 16th, offbeat eighths accented: the grid on small speakers
    {
      intro: turn.(small_talk_kit(kick: kick, hat: '..x...x...x...x.', shaker: shaker)),
      groove: turn.(small_talk_kit(kick: kick, clap: clap, hat: '..x...x...x...x.', open_hat: '..x.......x.....', shaker: shaker)),
      tease: turn.(small_talk_kit(kick: kick, clap: clap, hat: sixteenths, shaker: shaker)),
      drop: turn.(small_talk_kit(kick: kick, clap: clap, hat: sixteenths, open_hat: '..x...x...x...x.', crash: true)),
      pickup: turn.(small_talk_kit(kick: kick, clap: clap, hat: sixteenths, shaker: shaker, ride: '6.4.6.4.6.4.6.4.', crash: true)),
      cut: turn.(small_talk_kit(clap: clap, hat: sixteenths, shaker: shaker)),
      lift: turn.(small_talk_kit(kick: 'x...x...x...x...', clap: clap, hat: sixteenths, shaker: shaker)),
      outro: turn.(small_talk_kit(kick: kick, clap: clap, hat: '..x...x...x...x.', shaker: shaker)),
      tail: small_talk_kit(kick: kick, hat: '..x...x...x...x.'),
    }.transform_values { |kit| kit.loop(align: :launch) }.each { |name, kit| kit.named(:"kit_#{name}") }
  end

  # The clips of the song, by name.
  def self.small_talk_clips
    gm = scale(:minor, :g)
    {
      # The talking bass: the hook alone (implying Gm), then through two
      # silent progressions (natural minor; the maintainer's pick of
      # 2026-10-11 over harmonic minor)
      talk: SMALL_TALK_HOOK,
      talk_ghost: SMALL_TALK_HOOK.ghost_chords(1, 4, 7, 6, scale: gm).loop(align: :launch),
      talk_ghost2: SMALL_TALK_HOOK.ghost_chords(1, 6, 3, 7, scale: gm).loop(align: :launch),
      # The chant on i-iv-VII-VI (breakdown), and answering the bass in
      # the second drop: rests where the bass talks (bars 1 and 3 of 4),
      # the second progression in bars 2 and 4
      chant: SMALL_TALK_CHANT.ghost_chords(1, 4, 7, 6, scale: gm).loop(align: :launch),
      answer: seq(R.n1, D3.n4.d, Bb2.n4.d, C3.n8, Bb2.n8, R.n1, F3.n4.d, D3.n4.d, Eb3.n8, D3.n8).loop(align: :launch),
      # The groove's bong bass: offbeats with a swung 16th push
      bong: seq(R, R, G1, R, R, R, G1, R, R, R, G1, R, R, R, G1, G1).n16.swing(SMALL_TALK_SWING).loop(align: :launch),
      # The pad: root and fifth (fifth_pad), i-iv-VII-VI
      pad: seq(G2, C3, F2, Eb2).n1.legato(0.98).loop(align: :launch),
      # The impact on the first bar of every 8
      boom: seq(G1, R, R, R, R, R, R, R).n1.loop(align: :launch),
      # A placeholder clip for clipless patches (the riser)
      bar: seq(R).n1.loop,
    }.each { |name, clip| clip.named(name) }
  end

  # A ghost kick for sidechains: the drums' 808 kick on every beat, never
  # heard (the drum kits all keep four on the floor while the ducked parts
  # play).
  def self.small_talk_ghost_kick
    tr808(grid(16, kick: 'X...X...X...X...').loop(align: :launch), kick: SMALL_TALK_KICK)
  end

  # The talking bass: vocal_lead_patch with the settings agreed on the
  # Listening Bench (2026-10-11): kick wavetable, crusher key tracking 1
  # mixed 40% wet, a 4-bar LFO skewed to 0.9, two-octave dives, plus a
  # sine sub on the same notes.  +cutoff+ (the :cut knob) is a lowpass
  # over the whole part, +crush_mix+ the crusher's wet share.
  def self.small_talk_bass(clip, cutoff: 16000, crush_mix: 0.4, skew: 0.9)
    talk = vocal_lead_voice(clip, wobble: 4.bars, skew: skew, drop: 2, crush_mix: crush_mix, crush_track: 1.0, gain: 1.15)
    sub = synth(clip, voices: 1) { |v| v.hz.glide(0.04, legato: true).sine * v.env(0.004, 0.3, 0.8, 0.08, gm: false).legato }
    echo = talk.delay(1.n8.dotted, feedback: 0.25, wet: 1, dry: 0).filter(:highpass, cutoff: 500, quality: 0.7) * 0.12
    low = ((talk + echo) * 0.6 + sub * 0.34).filter(:lowpass, cutoff: cutoff, quality: 0.8)
    low.duck(small_talk_ghost_kick).reverb(:hall, mix: 0.07, highpass: 300, output_channels: 2)
  end

  # The groove's bong: a sub tom on the offbeats (a pitch bump, a short
  # decay), saturated so its harmonics carry the pitch on small speakers,
  # ducked by the kick.
  def self.small_talk_bong(clip)
    synth(clip, voices: 1) { |n|
      bump = n.env(0.0005, 0.035, 0, 0.02, curve: :linear, gm: false)
      freq = n.freq * (bump * 0.7 + 1)
      fenv = n.env(0.001, 0.07, 0, 0.04, gm: false)
      amp = n.env(0.001, 0.16, 0, 0.05, gm: false) * (n.velocity * 0.4 + 0.6)
      saw = freq.tone.ramp.lp4((2 ** (fenv * 2)) * 420, resonance: 0.3)
      ((saw * 0.7 + freq.tone) * amp * 1.6).softclip(0.4, 0.95)
    }.duck(small_talk_ghost_kick) * 0.55
  end

  # The chant ("Delay Lama"): a pair of slightly detuned saws through the
  # tenor formant table, each note sliding from "oo" through "oh" to "ah"
  # and settling between them, with a delayed vibrato.  Dry on the grid;
  # +send+ and +feedback+ (the :space and :echo knobs) are its
  # dotted-eighth delay send.
  def self.small_talk_chant(clip, send: 0.3, feedback: 0.3, level: 0.36)
    chant = synth(clip, voices: 1) { |v|
      pitch = v.hz.glide(0.07, legato: true).vibrato(5.3, depth: 22.cents, delay: 0.25)
      saws = pitch.saw * 0.5 + pitch.transpose(0.1).saw * 0.5
      vowel = v.env(0.22, 0.5, 0.65, 0.3, curve: :smooth, gm: false)
      sung = saws.formant(:u, :o, :a, voice: :tenor, morph: vowel)
      (sung * v.env(0.03, 0.4, 0.8, 0.25, gm: false).legato).filter(:highpass, cutoff: 140, quality: 0.7)
    }
    (chant * level).delay(1.n8.dotted, feedback: feedback, wet: send, dry: 1).reverb(:hall, mix: 0.22, output_channels: 2)
  end

  # The impact: a sine falling two octaves to the root, with a short
  # click, into a hall.
  def self.small_talk_boom(clip)
    synth(clip, voices: 1) { |n|
      dive = n.env(0, 0.3, 0, 0.1, curve: :linear, gm: false)
      freq = n.freq * (2 ** (dive * 2))
      (freq.tone * n.env(0.001, 1.4, 0, 0.3, gm: false) * 1.3).softclip(0.5, 0.95)
    }.reverb(:hall, mix: 0.2, highpass: 200, output_channels: 2) * 0.35
  end

  # A white-noise riser: a resonant bandpass sweeping up over 4 bars with a
  # swell (maintainer, 2026-10-12: "noise risers better with a bandpass
  # sweep than a highpass").
  def self.small_talk_riser
    sweep = tween([300, 9000], 4.bars, log: true, loop: false)
    noise.filter(:bandpass, cutoff: sweep, quality: 2.5) * tween([0.04, 0.22], 4.bars, loop: false)
  end

  # Sets up the song on the current session: tempo, knobs, master, tracks,
  # scenes (each section of the form launches the scene of its name).
  # With +perform: true+, also plays the form and schedules the performer's
  # commands.  Returns the clips.  +crush_mix+ is the talking bass's
  # crusher share, +pad_lead+ the pad's lead (half its attack by default),
  # +drive+ the gain in dB into the master limiter.
  def self.small_talk(perform: false, seed: 3, crush_mix: 0.4, skew: 0.9, pad_lead: 0.5.attack, drive: 4.0)
    c = small_talk_clips
    k = small_talk_kits
    bpm 125
    quant 1

    knob :cut, 16000, range: 200..16000, curve: :exp, unit: 'Hz' # the talking bass's lowpass
    knob :space, 0.3, range: 0..1                              # the chant's delay send
    knob :echo, 0.3, range: 0..0.85                            # the chant's delay feedback
    knob :air, 20, range: 20..400, curve: :exp, unit: 'Hz'     # a master highpass (the breakdown's "cut")

    # A mastered track: the master bus at 0 dB, glue, a true-peak limiter
    master_gain 1
    master { |mix|
      glued = mix.filter(:highpass, cutoff: knob(:air), quality: 0.8)
        .compress(threshold: -16, ratio: 2, knee: 8, attack: 0.02, release: 0.2)
      (glued * drive.db).limit(ceiling: -1, release: 0.08)
    }

    track(:drums) { |kit|
      beat = tr808(
        kit,
        kick: SMALL_TALK_KICK, clap: { decay: 0.3, tone: 0.75, level: 0.75 },
        closed_hat: { decay: 0.035, tone: 0.6, level: 0.4 }, open_hat: { decay: 0.22 }, cymbal: { decay: 1.0, tone: 0.65 },
        maracas: { level: 0.3 }, low_tom: { decay: 0.5 }, mid_tom: { decay: 0.45 }, accent: 6
      )
      # Parallel ("New York") compression: the hits keep their shape, the
      # room between them comes up
      beat.compress(threshold: -26, ratio: 4, attack: 0.003, release: 0.08, makeup: 8, mix: 0.3)
    }
    track(:bong) { |clip| small_talk_bong(clip) }
    track(:talk) { |clip| small_talk_bass(clip, cutoff: knob(:cut), crush_mix: crush_mix, skew: skew) }
    track(:chant) { |clip| small_talk_chant(clip, send: knob(:space), feedback: knob(:echo)) }
    track(:answer) { |clip| small_talk_chant(clip, level: 0.3) }
    track(:pad, lead: pad_lead) { |clip| stereo(*fifth_pad(clip, voices: 2, cutoff: 1100, release: 2)) * 0.5 }
    track(:boom) { |clip| small_talk_boom(clip) }
    track(:riser, fade: 1/8r) { |_clip| small_talk_riser } # a tween, not notes: fades instead of ringing

    scene :intro, drums: k[:intro], cut: 16000, air: 20
    scene :groove, drums: k[:groove], bong: c[:bong]
    scene :tease, drums: k[:tease], talk: c[:talk], cut: [1000, from: 150, over: 8, curve: :smooth]
    scene :drop, drums: k[:drop], talk: c[:talk], boom: c[:boom], cut: 16000
    scene :pickup, drums: k[:pickup], talk: c[:talk_ghost], boom: c[:boom]
    scene :breakdown, drums: k[:cut], pad: c[:pad], chant: c[:chant], air: [220, over: 1.beat], space: 0.3, echo: 0.3
    scene :lift, drums: k[:lift], pad: c[:pad], chant: c[:chant]
    scene(:gap) { meter 2, 4 }
    scene(:drop2, drums: k[:drop], talk: c[:talk_ghost2], boom: c[:boom], cut: 16000, air: 20) { meter 4, 4 }
    scene :pickup2, drums: k[:pickup], talk: c[:talk_ghost2], boom: c[:boom]
    scene :callback, drums: k[:pickup], talk: c[:talk_ghost2], answer: c[:answer], boom: c[:boom]
    scene :outro, drums: k[:outro], talk: c[:talk_ghost], cut: [350, over: 8, curve: :smooth]
    scene :tail, drums: k[:tail]
    scene :riser, riser: c[:bar], others: :keep # a fill: adds the riser

    small_talk_performance(seed: seed) if perform
    c
  end

  # The song form (sections launch the scenes of their names).  With
  # +play: false+, builds the Form without playing it.
  def self.small_talk_form(seed: 3, play: true)
    flow(seed: seed, play: play) do
      fill :turn, every: 8
      fill :toms, every: 4
      intro     8
      groove    8
      tease     8, fill: [:riser, 4]
      drop      8
      pickup    8
      breakdown 8
      lift      8, fill: [:riser, 4]
      gap       1
      drop2     8
      pick do |p|                    # usually the ride pickup...
        p.option(2) { pickup2 8 }
        p.option(1) { callback 8 }   # ...sometimes the chant answers the bass
      end
      outro     8
      tail      8
    end
  end

  # The performance: the form, plus what the performer types (printed as
  # it runs).
  def self.small_talk_performance(seed: 3)
    say = ->(bar, line) { puts format("\e[2mbar %-5s\e[0m \e[36m›\e[0m %s", bar, line) }

    say[1, 'flow do ... end   # the form starts']
    small_talk_form(seed: seed)
    at_marker(:breakdown) {
      session = Session.current
      bar = session.transport.bar_at(session.now).floor + 7
      at_bar(bar, beat: 3) {
        say["#{bar}.3", 'turn :space, 1, over: 1.n16; turn :echo, 0.7, over: 1.n16   # throw the chant']
        turn :space, 1, over: 1.n16
        turn :echo, 0.7, over: 1.n16
      }
      at_bar(bar + 1, beat: 2) {
        say["#{bar + 1}.2", 'turn :space, 0.3, over: 1.n8; turn :echo, 0.3, over: 1.beat   # and back']
        turn :space, 0.3, over: 1.n8
        turn :echo, 0.3, over: 1.beat
      }
    }
  end

  if main_script?(__FILE__)
    song_script(
      bars: SMALL_TALK_BARS,
      seed: [3, 'Seed for the form\'s pick (the second pickup; 3 the call and response, 2 the ride pickup)', '-s', Integer, 0..1_000_000],
      crush_mix: [0.4, Float, '-m', 'Talking bass crusher wet share 0..1', 0.0..1.0],
      skew: [0.9, Float, '-k', 'Talking bass LFO skew (rising fraction; 0.5 a plain triangle)', 0.01..0.99],
      drive: [4.0, Float, '-D', 'Gain in dB into the master limiter', -20.0..20.0],
    ) { |p| small_talk(perform: true, seed: p.seed, crush_mix: p.crush_mix, skew: p.skew, drive: p.drive) }
  end
end

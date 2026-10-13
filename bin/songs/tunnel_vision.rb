#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# "Tunnel Vision" by Kez Volta: a neuro-leaning drum & bass roller at 174 BPM in F minor.
#
# Kez Volta is a fictional producer-DJ written for the persona panel
# experiment (2026-10-13: four musician personas reviewed the API and each
# wrote a 2-3 minute demo with it; research branch research-persona-edm,
# research/persona-panel/edm/, with Kez's review, friction log, and a
# performed take).  The song moved here from that branch; its patches live
# in bin/synths/dnb.rb (playable from MIDI, and saved as presets).
#
# A drum & bass roller at 174 BPM in F minor,
# 112 bars (about 2:37).  Everything is synthesized with the public
# mb-sound API (no samples): an 808-derived two-step kit pushed up to DnB
# tunings, a Reese (detuned saw unison through a moving lowpass and a
# softclipper, highpassed off the sub), a separate clean mono sub, a
# "switch-up" neuro bass in the second drop (diode ladder + talking
# formants on 16ths + a key-tracked crusher, squeezed), minor 9th pads
# and a liquid pluck in the breakdown.  Mastered loud: a softclipper into
# a true-peak limiter (clip-then-limit, the club way).
#
#   (bars: intro 1-16, build 17-24, drop 25-56, breakdown 57-71, pullup
#   72, drop2 73-88 and 89-96, outro 97-104, tail 105-112.  A club edit
#   would run the intro to 32 and drop at bar 33; the 2-3 minute brief
#   cut it to 16 + 8.)
#
#   intro     16  DJ intro: kick two-step, rim, 16th hats and shaker, the
#                 pad far away (no bass: mix me in)
#   build      8  full two-step with ghost snares, the Reese creeping up
#                 through its filter (:cut 250 -> 2500 over 8 bars),
#                 noise riser and a snare roll in the last 4
#   drop      32  Reese + sub, ducked by the kick; crash every 8 bars; a
#                 snare roll turnaround at the end of every 16
#   breakdown 16  low end out (the master :air highpass to 180 Hz), Fm9
#                 Dbmaj9 Bbm9 Cm7 pads, the liquid pluck through a
#                 dotted-eighth delay; riser in the last 8, and a one-bar
#                 pull-up (everything rings out except the riser and a
#                 reverse-ish swell) at the end
#   drop2     24  the switch-up: the neuro bass talks on the same riff
#                 (16th formant wobble), busier ghost snares, the Reese
#                 back underneath for the last 8 (:grit up)
#   outro     16  DJ outro: drums and sub only, then kick and hats
#
# As rendered by Kez on the research branch (2026-10-13, measured; nobody
# had listened yet): -7.5 LUFS
# integrated, -0.5 dBTP; drop -6.8 LUFS (short-term max -6.4, crest
# factor 7.1 dB), drop2 -6.2 (-5.9, 6.3 dB); below 120 Hz the side
# channel is 28-62 dB under the mid.  320k mp3s of the -0.5 dBTP master
# decode at +0.4 dBTP: trim 1.2 dB for lossy copies.  Stems peak +8 dB
# pre-master (drums): --stem-gain -9.
#
# Usage:
#     bin/songs/tunnel_vision.rb                 # plays live in the background session
#     bin/songs/tunnel_vision.rb tv.flac         # renders (-f to overwrite)
#     bin/songs/tunnel_vision.rb --stems stems/ tv.flac
#     bin/songs/tunnel_vision.rb -D 8 -C -1 tv.flac   # gentler master
#     bin/songs/tunnel_vision.rb --no-buses tv.flac   # Kez's original ambience (no buses)
#
# Or in bin/sound.rb:
#     load 'bin/songs/tunnel_vision.rb'
#     tunnel_vision                 # tracks, knobs, scenes (go :drop by hand)
#     tunnel_vision_form            # the whole form
#
# Try (while it plays):
#     go :drop; turn :cut, 600, over: 2; turn :cut, 5000, over: 1.n4   # Reese filter ride
#     turn :grit, 0.6, over: 4      # more crusher on the neuro bass
#     move :air, 180; undo          # low end out, then back next bar
#     feed :pad, :hall, 1, over: 2  # drown the pad in the hall (buses)
#     solo :hall                    # just the reverb return (and what feeds it)
#     mute :echo; unmute :echo, on: :bar

require 'bundler/setup'
require 'mb-sound'
require_relative '../synths/dnb'

module MB::Sound
  # Length of the form in bars (plus a ring-out).
  TV_BARS = 114

  # Master drive (dB into the clipper/limiter) and true-peak ceiling (dBTP).
  TV_DRIVE = 11.0
  TV_CEILING = -0.5

  # The :hall bus's return gain in dB (buses): its reverb is wet only and
  # energy-normalized (about 20 dB under its input), so the return needs
  # this to sit around -30 dBFS RMS in the breakdown (maintainer, round 2
  # of buses-1: "way more hall (-30dBFS or more?)").
  TV_HALL = 24.0

  # The kick, shared by the drums and the ghost kicks that duck the bass.
  TV_KICK = dnb_kick_settings.freeze

  # The two-step (one bar of 16ths): kick on 1 and the "and" of 3.
  TV_TWO_STEP = 'X.........X.....'

  # The bass riff: two bars of 16ths in F minor (F1 = 43.7 Hz), rolling
  # off the kick.  R rests, T ties.
  TV_RIFF_STEPS = [
    F1, T, T, T, T, T, R, F1, T, R, Ab1, T, F1, T, R, R,
    F1, T, T, T, T, T, R, C2, T, R, Bb1, T, Ab1, T, Eb1, T,
  ].freeze
  TV_RIFF = seq(*TV_RIFF_STEPS).n16.loop(align: :launch)

  # The neuro version: the same notes chopped into 16th stabs.
  TV_NEURO = seq(
    F1, R, F1, F1, R, F1, R, F1, T, R, Ab1, R, F1, F1, R, Eb1,
    F1, R, F1, F1, R, F1, R, C2, T, R, Bb1, Ab1, R, Ab1, Eb1, T,
  ).n16.loop(align: :launch)

  # The kit: every row present (empty rows rest), so scenes swap kits
  # without rebuilding the drums.  `crash: true` puts a crash on the first
  # bar of every 8.
  def self.tv_kit(crash: false, **rows)
    all = { kick: '', snare: '', clap: '', rim: '', hat: '', open_hat: '', shaker: '', crash: '', low_tom: '' }.merge(rows)
    all[:crash] = 'X...............' if crash
    kit = grid(16, **all.transform_values { |p| p.empty? ? '.' * 16 : p })
    Sequence::Kit.new(kit.rows.to_h { |name, clip|
      clip = clip.swing(0.52) if [:hat, :shaker].include?(name) # a hair of shuffle on the tops
      clip = clip.every(8) if name == :crash
      [name, clip]
    })
  end

  # The kits by section, with a snare-roll turnaround (fill :roll) in the
  # last bar of every 16.
  def self.tv_kits
    roll = ->(kit) {
      kit.nofill(:snare, :clap, :open_hat, name: :roll)
         .fill(:roll, snare: grid(16, '2.3.4.5.5656778X'), low_tom: grid(16, '............5.7.'))
    }
    hats = '7.4.7.4.7.4.7.45'
    shaker = '3524352435243524'
    snare = '....X.......X...'
    ghosts = '....X..2.2..X..2'
    busy = '....X.2..2..X.2.' + '....X..2.2.2X..3'
    {
      intro: tv_kit(kick: TV_TWO_STEP, rim: '....6.......6...', hat: hats, shaker: shaker),
      build: roll.(tv_kit(kick: TV_TWO_STEP, snare: ghosts, hat: hats, open_hat: '..5...5...5...5.', shaker: shaker)),
      drop: roll.(tv_kit(kick: TV_TWO_STEP, snare: ghosts, clap: snare, hat: hats, open_hat: '..4.......4.....', shaker: shaker, crash: true)),
      breakdown: tv_kit(hat: '4.2.4.2.4.2.4.2.', shaker: shaker),
      drop2: roll.(tv_kit(kick: TV_TWO_STEP + 'X.........X..x..', snare: busy, clap: snare * 2, hat: hats, open_hat: '..4.......4.....', shaker: shaker, crash: true)),
      outro: tv_kit(kick: TV_TWO_STEP, snare: snare, hat: hats, shaker: shaker),
      tail: tv_kit(kick: TV_TWO_STEP, hat: hats),
    }.transform_values { |kit| kit.loop(align: :launch) }.each { |name, kit| kit.named(:"kit_#{name}") }
  end

  def self.tv_clips
    {
      riff: TV_RIFF,
      neuro: TV_NEURO,
      # Fm9 Dbmaj9 Bbm9 Cm7, one bar each (built by the chord transform)
      pad: seq(F2.n1, Db2.n1, Bb1.n1, C2.n1).bake(chord(0, 7, 15, 19, 26)).legato(0.97).loop(align: :launch),
      # The liquid pluck: an eighth-note figure over the chords
      pluck: seq(C5, Ab4, F4, Eb5, R, C5, Ab4, G4).n8.ghost_chords(1, 6, 4, 5, scale: scale(:minor, :f)).loop(align: :launch),
      boom: seq(F1, R, R, R, R, R, R, R).n1.loop(align: :launch),
      bar: seq(R).n1.loop,
    }.each { |name, clip| clip.named(name) }
  end

  # A ghost kick for sidechains: the drums' kick on the two-step, never
  # heard (every ducked part plays over a two-step kit).
  def self.tv_ghost_kick
    dnb_ghost_kick(grid(16, kick: TV_TWO_STEP).loop(align: :launch), kick: TV_KICK)
  end

  # A noise riser: a resonant bandpass sweeping up over +bars+ with a
  # swell.
  def self.tv_riser(bars = 8)
    sweep = tween([250, 10000], bars.bars, log: true, loop: false)
    noise.filter(:bandpass, cutoff: sweep, quality: 3) * tween([0.03, 0.25], bars.bars, loop: false)
  end

  # Sets up the song on the current session.  Returns the clips.
  #
  # +buses+ (default; buses-1, 2026-10-13) plays the ambience through
  # shared buses: the pad and pluck dry, sending to a :hall reverb bus
  # (ducked by the kick) and the pluck to an :echo bus (dotted eighths,
  # the :space knob as its send), and the basses duck by the drums'
  # own kick (`duck(:drums, only: :kick)`) instead of a ghost kick.
  # +buses: false+ is Kez's original (reverbs inside each patch, a ghost
  # kick for the ducks).
  def self.tunnel_vision(drive: TV_DRIVE, ceiling: TV_CEILING, buses: true, hall: TV_HALL)
    c = tv_clips
    k = tv_kits
    bpm 174
    quant 1

    knob :cut, 2400, range: 150..8000, curve: :exp, unit: 'Hz' # the Reese lowpass
    knob :grit, 0.25, range: 0..1                              # the neuro crusher's wet share
    knob :space, 0.4, range: 0..1                              # the pluck's delay send
    knob :air, 20, range: 20..400, curve: :exp, unit: 'Hz'     # a master highpass

    # A club master: glue, then clip-then-limit, master bus at 0 dB.
    master_gain 1
    master { |mix| dnb_master(mix, drive: drive, ceiling: ceiling, air: knob(:air)) }

    track(:drums) { |kit| dnb_drums(kit, kick: TV_KICK) }
    if buses
      # The sidechain: the drums' kick voice itself, read on the exact
      # sample (no ghost kick to keep in step with the kit)
      bus(:hall) { |sig| (sig.reverb(:hall, mix: 1) * hall.db).duck(:drums, only: :kick, amount: -6.db, release: 1.n8) }
      bus(:echo) { |sig| sig.delay(1.n8.dotted, feedback: 0.4) }
      duck = ->(node, amount) { node.duck(:drums, only: :kick, amount: amount, release: 1.n16) }
      # (dry levels as the original's reverb mixes left them: 0.65 and 0.75)
      track(:pad, send: { hall: 0.35 }) { |clip| dnb_pad_voice(clip, hall: nil) * (0.6 * 0.65) }
      track(:pluck, send: { echo: :space, hall: 0.25 }) { |clip| dnb_pluck_voice(clip, send: nil, plate: nil) * (0.45 * 0.75) }
    else
      duck = ->(node, amount) { node.duck(tv_ghost_kick, amount: amount, release: 1.n16) }
      track(:pad) { |clip| dnb_pad_voice(clip) * 0.6 } # (no lead: 0.3.attack: a lead at the form start broke exact take replay on the research branch)
      track(:pluck) { |clip| dnb_pluck_voice(clip, send: knob(:space)) * 0.45 }
    end
    track(:reese) { |clip| duck.(dnb_reese_voice(clip, cutoff: knob(:cut)) * 1.0, -8.db) }
    track(:sub) { |clip| duck.(dnb_sub_voice(clip) * 0.5, -12.db) }
    track(:neuro) { |clip| duck.(dnb_neuro_voice(clip, grit: knob(:grit)) * 0.85, -8.db) }
    track(:boom) { |clip| dnb_boom_voice(clip) }
    track(:riser, fade: 1/8r) { |_clip| tv_riser(8) }

    scene :intro, drums: k[:intro], pad: c[:pad], reese: c[:bar], neuro: c[:bar], cut: 250, air: 20
    scene :build, drums: k[:build], reese: c[:riff], neuro: c[:bar], cut: [2500, from: 250, over: 8, curve: :smooth]
    scene :drop, drums: k[:drop], reese: c[:riff], sub: c[:riff], neuro: c[:bar], boom: c[:boom], cut: 2400, air: 20
    scene :breakdown, drums: k[:breakdown], pad: c[:pad], pluck: c[:pluck], reese: c[:bar], neuro: c[:bar], air: [180, over: 1.beat]
    scene :pullup, riser: c[:bar], reese: c[:bar], neuro: c[:bar]
    scene :drop2, drums: k[:drop2], neuro: c[:neuro], sub: c[:riff], reese: c[:bar], boom: c[:boom], air: 20, grit: 0.25
    scene :drop2b, drums: k[:drop2], neuro: c[:neuro], sub: c[:riff], reese: c[:riff], cut: 1600, grit: [0.6, over: 8]
    scene :outro, drums: k[:outro], sub: c[:riff], reese: c[:bar], neuro: c[:bar]
    scene :tail, drums: k[:tail]
    scene :riser, riser: c[:bar], others: :keep # a fill: adds the riser
    c
  end

  # The form: DJ-friendly 8s and 16s.
  def self.tunnel_vision_form(play: true)
    flow(play: play) do
      fill :roll, every: 16
      intro     16
      build     8, fill: [:riser, 4]
      drop      32
      breakdown 15, fill: [:riser, 8]
      pullup    1
      drop2     16
      drop2b    8
      outro     8
      tail      8
    end
  end

  if main_script?(__FILE__)
    song_script(
      bars: TV_BARS,
      drive: [TV_DRIVE, Float, '-D', 'Gain in dB into the master clipper and limiter', -20.0..24.0],
      ceiling: [TV_CEILING, Float, '-C', 'Master limiter true-peak ceiling in dBTP', -12.0..0.0],
      hall: [TV_HALL, Float, '-H', 'Return gain of the :hall bus in dB (with buses)', -20.0..40.0],
      buses: [true, 'Shared reverb and echo buses, ducks by the drums\' kick (--no-buses: reverbs in each patch, a ghost kick)'],
    ) { |p|
      tunnel_vision(drive: p.drive, ceiling: p.ceiling, buses: p.buses, hall: p.hall)
      tunnel_vision_form
    }
  end
end

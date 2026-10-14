#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# FM electric pianos that aim at the physical instruments: a tine piano
# (Rhodes-style) and a reed piano (Wurlitzer-style), playable from MIDI.
#
# Where they came from: the maintainer's listening notes on the jungle
# keys (jungle_keys_voice in bin/synths/jungle.rb, 2026-10-13: "As a separate patch can we try
# another FM version of this to get closer to a physical Rhodes or
# Wurlitzer sound?"); patches-2, 2026-10-13.
#
# Patches (-p):
#   tine  a tine piano: a 1:1 FM body whose index (the bark) grows with
#         the square of velocity and falls over a second, a short 14:1 bell
#         ping of the tine's attack, a tonebar partial an octave up, and an
#         asymmetric pickup (a squared term: even harmonics, more for
#         harder strikes), into a gentle amp (--drive into a softclipper),
#         with a suitcase-style stereo tremolo
#   reed  a reed piano: a 2:1 FM pair (odd harmonics only, like the reed's
#         near-square motion) whose index grows with velocity, through a
#         symmetric electrostatic-pickup softclipper driven harder by
#         harder strikes (the bark), a mid honk, and a mono amplitude
#         tremolo
#   crunch  the tine piano with its amp pushed to TINE_PIANO_CRUNCH (4): a
#         broken-up suitcase on hard notes and chords, soft notes as
#         clean as the tine's (--amp still sets it: 2 is a lighter crunch)
#
# Both play velocity: soft notes are round and nearly sine-like, hard ones
# bark.  --bark scales the velocity-driven growl, --pickup the pickup's
# drive (the tine's even-harmonic growl, the reed's saturation), --tremolo
# the tremolo depth (0 for none).  The pickup drive follows velocity
# (pickup_velocity: 1, or 0 to ignore it) and, with pickup_key:, grows on
# low keys (doubling every 1 / pickup_key octaves below C4; the reed's
# default 1.5 drives F2 about 5.2 times as hard as C4).  The tine's --amp
# pushes its amp (1 clean, 1.5 a warm edge, 2 crunch, 4-8 broken up).  Methods:
# tine_piano_voice(midi, bark:, tremolo:, pickup:, pickup_velocity:,
# pickup_key:, drive:, amp:), reed_piano_voice(midi, bark:, tremolo:,
# pickup:, pickup_velocity:, pickup_key:); presets :tine_piano and
# :reed_piano (`preset :tine_piano, midi: midi, bark: 1.5, pickup: 0.7, amp: 4`).
#
# patches-3 (2026-10-13; maintainer: "The tine pickup needs less
# distortion by default at high velocity, the reed pickup could use a
# tiny bit more by default on lower keys"): the tine's distortion at high
# velocity was its output softclipper, which the voices hit about 8 dB
# over its knee on one hard note and 16 dB on a hard four-note chord
# (residue -5.5 dB under the chord); the voices now go in at drive: 0.25
# (patches-2: 1.0 at level 0.5; residue -23.6 dB), so it only catches
# hard chords, at level 1.3 (hard notes louder, soft ones 3.7 dB quieter
# than before: the old clipper had squeezed the velocity range).  The reed's pickup grows below C4 (pickup_key: 0.5;
# patches-2: 0).
#
# patches-4 (2026-10-13; maintainer: "Still a tiny bit of crunch at 0.6;
# would like default to be a little easier but with the option to crank
# down the pressure on the amp", and on the reed's low phrase "Could use
# even more low drive"): the tine's pickup defaults to 0.5 (was 1.0), with
# --amp / amp: to push the amp; the reed's pickup_key to 1 (was 0.5).
# The amp's clipper still touched a hard four-note chord struck at once
# (residue -27.6 dB under the clean chord), so the voices go in at
# drive: 0.18 (was 0.25) at level 1.8 (was 1.3): the same level below the
# clipper's knee, the chord clean (-84 dB), peaks up to about +3.6 dBFS
# (the master's headroom takes them); `drive: 0.25, level: 1.3` is
# patches-3's amp.
#
# patches-5 (2026-10-13; maintainer on patches-4's tine: "After and amp 4
# are the two extremes that are both useful"): the clean tine stays the
# default, and -p crunch (preset :tine_crunch, `tine_piano_voice(midi,
# amp: TINE_PIANO_CRUNCH)`) is the other extreme; the reed's pickup_key
# defaults to 1.5 (the maintainer's pick; was 1).
#
# Usage:
#     bin/synths/electric_pianos.rb                              # live MIDI, the tine piano
#     bin/synths/electric_pianos.rb -p reed spec/test_data/note_velocity.mid reed.flac
#     bin/synths/electric_pianos.rb -p tine --bark 1.6 --tremolo 0 song.mid tine.flac
#     bin/synths/electric_pianos.rb -p crunch song.mid crunch.flac   # the crunchy extreme (the tine at --amp 4)
#
# Snippets (bin/sound.rb, after `load 'bin/synths/electric_pianos.rb'`):
#     bpm 90
#     bg :keys, tine_piano_voice(seq([F3, A3, C4, E4].map(&:n2).reduce(:&), [E3, G3, B3, D4].map(&:n2).reduce(:&)).loop)
#     bg :wurli, reed_piano_voice(seq(A3, C4, E4, G4).n8.vel(1.0).loop, tremolo: 0.2)
#     bg :keys, tine_piano_voice(chords, drive: 1, level: 0.5)            # patches-2's hot amp
#     bg :wurli, reed_piano_voice(chords, pickup: 1.5, pickup_key: 2)      # a dirtier reed, much grittier low down
#     knob :amp, 1, range: 1..8; bg :keys, tine_piano_voice(chords, amp: knob(:amp))   # turn :amp, 6 for a crunchy suitcase
#     bg :keys, preset(:tine_crunch, midi: chords)                        # the crunchy extreme (amp 4); preset :tine_piano is clean

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # A tine piano (Rhodes-style; see the header): +bark+ scales the
  # velocity-driven FM index and pickup growl, +pickup+ (a number or a
  # node; TINE_PIANO_PICKUP by default), +pickup_velocity+, and
  # +pickup_key+ the pickup's drive (see .electric_piano_pickup), +drive+
  # the gain of the voices' sum into the amp's softclipper, +amp+ (a
  # number or a node, 1 by default) how hard the amp is pushed: it
  # multiplies +drive+ and divides the output level, so quiet passages
  # stay as loud and only the clipping grows (on a hard four-note chord:
  # clean at 1, a warm edge at 1.3-1.5 (residue -30 to -25 dB under the
  # clean chord), crunch at 2 (-18 dB), a broken-up suitcase at 4-8 (-8
  # to -4 dB)), +tremolo+ the stereo tremolo depth at +rate+ Hz.  Stereo.
  def self.tine_piano_voice(midi, bark: 1.0, tremolo: 0.3, rate: 4.8, level: 1.8, voices: 8, drive: 0.18, amp: 1.0, pickup: TINE_PIANO_PICKUP, pickup_velocity: 1.0, pickup_key: 0.0)
    keys = synth(midi, voices: voices, retrigger: :string) { |v|
      f = v.hz
      vel2 = v.velocity * v.velocity
      # The body: 1:1 FM; the bark is the index (cycles), mostly velocity
      index = v.env(0, 1.2, 0.1, 0.4, gm: false).no_velocity * (vel2 * (0.3 * bark) + 0.03)
      body = f.sine.free.pm(f.sine.free * index)
      # The tine's attack: a 14:1 ping, gone in a fraction of a second
      bell = f.sine.free.pm(f.transpose(12 * Math.log2(14)).sine.free * v.env(0, 0.12, 0, 0.05, gm: false).no_velocity * (v.velocity * 0.25))
      # The tonebar: a quiet partial an octave up that dies sooner
      bar = f.transpose(12).sine.free * v.env(0.001, 1.4, 0, 0.3, gm: false).no_velocity * 0.12
      x = (body + bell * 0.3 + bar) * v.amp_env(0.001, 4.5, 0, 0.35, curve: [12, 40, 40])
      # The pickup: an asymmetric (squared) term, larger for harder strikes
      x * (x * (electric_piano_pickup(v, pickup, pickup_velocity, pickup_key) * (0.5 * bark)) + 1)
    }
    clean = amp.is_a?(Numeric) && amp == 1
    out = (keys.filter(:highpass, cutoff: 30, quality: 0.7) * (clean ? drive : amp * drive)).softclip(0.8, 0.95) * (clean ? level : level / amp)
    tremolo > 0 ? out.pan(rate.hz.lfo.at(tremolo)) : stereo(out, out)
  end

  # The tine piano's default pickup drive: patches-4 (2026-10-13;
  # maintainer: "Still a tiny bit of crunch at 0.6; would like default to
  # be a little easier but with the option to crank down the pressure on
  # the amp") lowered it from 1.0 (patches-3 rendered 0.6 too); the amp's
  # clipper doesn't act on the velocity phrase, so the remaining growl is
  # the pickup's squared term, and +amp+ adds the amp's own drive.
  TINE_PIANO_PICKUP = 0.5

  # The crunch patch's amp drive (-p crunch, preset :tine_crunch): the
  # maintainer's other useful extreme of the tine (patches-5, 2026-10-13:
  # "After and amp 4 are the two extremes that are both useful").
  TINE_PIANO_CRUNCH = 4.0

  # A reed piano (Wurlitzer-style; see the header): +bark+ scales the
  # velocity-driven FM index and pickup drive, +pickup+ (a number or a
  # node), +pickup_velocity+, and +pickup_key+ the pickup's drive (see
  # .electric_piano_pickup), +tremolo+ the amplitude tremolo depth at
  # +rate+ Hz.  Mono.
  def self.reed_piano_voice(midi, bark: 1.0, tremolo: 0.3, rate: 5.6, level: 0.4, voices: 8, pickup: 1.0, pickup_velocity: 1.0, pickup_key: REED_PIANO_PICKUP_KEY)
    keys = synth(midi, voices: voices, retrigger: :string) { |v|
      f = v.hz
      vel2 = v.velocity * v.velocity
      # 2:1 FM: sidebands at 1, 3, 5, ... times the note (odd harmonics)
      index = v.env(0, 0.8, 0.25, 0.3, gm: false).no_velocity * (vel2 * (0.22 * bark) + 0.04)
      reed = f.sine.free.pm(f.transpose(12).sine.free * index)
      amp = v.amp_env(0.002, 2.6, 0, 0.18, curve: [12, 30, 40])
      # The pickup: symmetric saturation (odd harmonics), driven by velocity
      drive = electric_piano_pickup(v, pickup, pickup_velocity, pickup_key) * (2.5 * bark) + 1
      (reed * amp * drive).softclip(0.4, 0.95) * (1.0 / 1.6)
    }
    honk = keys.peq(1000.hz => [4.db, 1.2]).filter(:highpass, cutoff: 60, quality: 0.7)
    honk = honk * (1 - tremolo + rate.hz.lfo.at(0..tremolo)) if tremolo > 0
    honk * level
  end

  # The reed piano's default key scaling of its pickup drive (doubling
  # every 2/3 octave below C4: F2 5.2 times C4's): patches-5 (2026-10-13;
  # the maintainer picked 1.5 on patches-4's low phrase); patches-4 had 1
  # (maintainer on 1: "Could use even more low drive"), patches-3 0.5,
  # patches-2 0.
  REED_PIANO_PICKUP_KEY = 1.5

  # The pickup drive of an electric piano voice +v+ (a Notes): +pickup+
  # (a number or a node) times the velocity scaling (+velocity+ 0..1: 1
  # follows velocity fully, 0 ignores it) times the key scaling (+key+:
  # the drive doubles every 1 / +key+ octaves below C4, not changing
  # above it; 0 for none).
  def self.electric_piano_pickup(v, pickup, velocity, key)
    drive = velocity == 1 ? v.velocity : v.velocity * velocity + (1 - velocity)
    drive *= 2 ** ((60 - v.number).aclip(0, nil) * (key / 12.0)) unless key == 0
    pickup == 1 ? drive : drive * pickup
  end

  # The script's patches by name (see the header), with the script's
  # parameters as named Constants (so --save makes them preset params).
  # +pickup+ nil is the patch's own default (TINE_PIANO_PICKUP, or the
  # reed's 1.0); +amp+ is the tine's amp drive (nil: 1 for :tine,
  # TINE_PIANO_CRUNCH for :crunch).
  def self.electric_pianos_patch(midi, patch = :tine, bark: 1.0, tremolo: 0.3, pickup: nil, amp: nil)
    bark = bark.constant.named('bark')
    pickup = (pickup || (patch == :reed ? 1.0 : TINE_PIANO_PICKUP)).constant.named('pickup')
    case patch
    when :tine, :crunch
      amp ||= patch == :crunch ? TINE_PIANO_CRUNCH : 1.0
      tine_piano_voice(midi, bark: bark, tremolo: tremolo, pickup: pickup, amp: amp.constant.named('amp'))
    when :reed then reed_piano_voice(midi, bark: bark, tremolo: tremolo, pickup: pickup)
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  # What each patch is, for preset descriptions (--save writes it into the
  # document): +what+ is the patch (a Symbol) or a phrase.
  def self.electric_pianos_description(what)
    what = {
      tine: 'Tine piano (Rhodes-style FM)', reed: 'Reed piano (Wurlitzer-style FM)',
      crunch: 'Tine piano (Rhodes-style FM) through a crunchy amp (amp 4)',
    }.fetch(what, "Patch :#{what}") if what.is_a?(Symbol)
    "#{what} from bin/synths/electric_pianos.rb, made in patches-2 (2026-10-13) as a closer-to-physical " \
      'alternative to the jungle keys (jungle_keys_voice in bin/synths/jungle.rb, from the persona panel experiment).'
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { electric_pianos_description(p.patch) },
      patch: [:tine, Symbol, '-p', 'Patch to play (crunch: the tine at --amp 4)', [:tine, :reed, :crunch]],
      bark: [1.0, Float, '-b', 'Velocity-driven bark (FM index and pickup growl) scale', 0.0..2.0],
      tremolo: [0.3, Float, '-t', 'Tremolo depth 0..1 (0 for none)', 0.0..1.0],
      pickup: [nil, Float, '-k', 'Pickup drive scale (follows velocity; the reed also grows on low keys; default tine 0.5, reed 1.0)', 0.0..3.0],
      amp: [nil, Float, '-a', 'Tine amp drive: 1 clean, 1.5 a warm edge, 2 crunch, 4-8 broken up (quiet notes keep their level; default tine 1, crunch 4)', 0.25..8.0],
    ) { |midi, p|
      electric_pianos_patch(midi, p.patch, bark: p.bark, tremolo: p.tremolo, pickup: p.pickup, amp: p.amp)
    }
  end
end

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
#
# Both play velocity: soft notes are round and nearly sine-like, hard ones
# bark.  --bark scales the velocity-driven growl, --pickup the pickup's
# drive (the tine's even-harmonic growl, the reed's saturation), --tremolo
# the tremolo depth (0 for none).  The pickup drive follows velocity
# (pickup_velocity: 1, or 0 to ignore it) and, with pickup_key:, grows on
# low keys (doubling every 1 / pickup_key octaves below C4; the reed's
# default 0.5 drives F2 about 1.7 times as hard as C4).  Methods:
# tine_piano_voice(midi, bark:, tremolo:, pickup:, pickup_velocity:,
# pickup_key:, drive:), reed_piano_voice(midi, bark:, tremolo:, pickup:,
# pickup_velocity:, pickup_key:); presets :tine_piano and :reed_piano
# (`preset :tine_piano, midi: midi, bark: 1.5, pickup: 0.7`).
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
# Usage:
#     bin/synths/electric_pianos.rb                              # live MIDI, the tine piano
#     bin/synths/electric_pianos.rb -p reed spec/test_data/note_velocity.mid reed.flac
#     bin/synths/electric_pianos.rb -p tine --bark 1.6 --tremolo 0 song.mid tine.flac
#
# Snippets (bin/sound.rb, after `load 'bin/synths/electric_pianos.rb'`):
#     bpm 90
#     bg :keys, tine_piano_voice(seq([F3, A3, C4, E4].map(&:n2).reduce(:&), [E3, G3, B3, D4].map(&:n2).reduce(:&)).loop)
#     bg :wurli, reed_piano_voice(seq(A3, C4, E4, G4).n8.vel(1.0).loop, tremolo: 0.2)
#     bg :keys, tine_piano_voice(chords, drive: 1, level: 0.5)            # patches-2's hot amp
#     bg :wurli, reed_piano_voice(chords, pickup: 1.5, pickup_key: 1)      # a dirtier reed, much grittier low down

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # A tine piano (Rhodes-style; see the header): +bark+ scales the
  # velocity-driven FM index and pickup growl, +pickup+ (a number or a
  # node), +pickup_velocity+, and +pickup_key+ the pickup's drive (see
  # .electric_piano_pickup), +drive+ the gain of the voices' sum into the
  # amp's softclipper, +tremolo+ the stereo tremolo depth at +rate+ Hz.
  # Stereo.
  def self.tine_piano_voice(midi, bark: 1.0, tremolo: 0.3, rate: 4.8, level: 1.3, voices: 8, drive: 0.25, pickup: 1.0, pickup_velocity: 1.0, pickup_key: 0.0)
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
      x + x * x * (electric_piano_pickup(v, pickup, pickup_velocity, pickup_key) * (0.5 * bark))
    }
    out = (keys.filter(:highpass, cutoff: 30, quality: 0.7) * drive).softclip(0.8, 0.95) * level
    tremolo > 0 ? out.pan(rate.hz.lfo.at(tremolo)) : stereo(out, out)
  end

  # A reed piano (Wurlitzer-style; see the header): +bark+ scales the
  # velocity-driven FM index and pickup drive, +pickup+ (a number or a
  # node), +pickup_velocity+, and +pickup_key+ the pickup's drive (see
  # .electric_piano_pickup), +tremolo+ the amplitude tremolo depth at
  # +rate+ Hz.  Mono.
  def self.reed_piano_voice(midi, bark: 1.0, tremolo: 0.3, rate: 5.6, level: 0.4, voices: 8, pickup: 1.0, pickup_velocity: 1.0, pickup_key: 0.5)
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
  def self.electric_pianos_patch(midi, patch = :tine, bark: 1.0, tremolo: 0.3, pickup: 1.0)
    bark = bark.constant.named('bark')
    pickup = pickup.constant.named('pickup')
    case patch
    when :tine then tine_piano_voice(midi, bark: bark, tremolo: tremolo, pickup: pickup)
    when :reed then reed_piano_voice(midi, bark: bark, tremolo: tremolo, pickup: pickup)
    else raise ArgumentError, "Unknown patch #{patch.inspect}"
    end
  end

  # What each patch is, for preset descriptions (--save writes it into the
  # document): +what+ is the patch (a Symbol) or a phrase.
  def self.electric_pianos_description(what)
    what = { tine: 'Tine piano (Rhodes-style FM)', reed: 'Reed piano (Wurlitzer-style FM)' }.fetch(what, "Patch :#{what}") if what.is_a?(Symbol)
    "#{what} from bin/synths/electric_pianos.rb, made in patches-2 (2026-10-13) as a closer-to-physical " \
      'alternative to the jungle keys (jungle_keys_voice in bin/synths/jungle.rb, from the persona panel experiment).'
  end

  if main_script?(__FILE__)
    synth_script(
      description: ->(p) { electric_pianos_description(p.patch) },
      patch: [:tine, Symbol, '-p', 'Patch to play', [:tine, :reed]],
      bark: [1.0, Float, '-b', 'Velocity-driven bark (FM index and pickup growl) scale', 0.0..2.0],
      tremolo: [0.3, Float, '-t', 'Tremolo depth 0..1 (0 for none)', 0.0..1.0],
      pickup: [1.0, Float, '-k', 'Pickup drive scale (follows velocity; the reed also grows on low keys)', 0.0..3.0],
    ) { |midi, p|
      electric_pianos_patch(midi, p.patch, bark: p.bark, tremolo: p.tremolo, pickup: p.pickup)
    }
  end
end

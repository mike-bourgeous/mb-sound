#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A TB-303-style acid bass voice built from the library's general pieces.
#
# Usage: $0 [options] [midi_file_or_port [output_file]]
#
# One mono voice (a one-voice Synth: last-note priority), from the 303's panel:
# - VCO: saw or square (--wave), gliding 60 ms between overlapping notes
#   (slides: `~A1` in a seq, or legato playing on a keyboard).
# - VCF: the diode ladder (GraphNode#diode, --filter diode) or lp4 to
#   compare, with drive; cutoff (CC 74 brightness moves it +-2 octaves) and
#   resonance (CC 71).
# - MEG: Notes#acid_env, an exponential fall (curve 30) over --decay
#   (1.56 s, passing half-way when a linear 0.6 s fall would; accented
#   notes use the shortest, 0.52 s), times --env-mod octaves on the cutoff.
# - Accent: velocity >= 0.8 (Notes#accent; `!A1` in a seq) adds level and
#   the accent sweep (Notes#accent_sweep: the 303's capacitor, so runs of
#   accents open the filter further), --accent sets how much.
# - VEG: a gate-cut 3.5 s decay, not retriggered by slides.
#
# Examples:
#     $0                                               # live MIDI (play legato for slides, hard for accents)
#     $0 spec/test_data/c_major.mid acid.flac
#     $0 --filter lp4 --reso 0.5 spec/test_data/c_major.mid lp4.flac
#     $0 --wave square --decay 0.3 --cutoff 200 spec/test_data/c_major.mid square.flac
#
# In bin/sound.rb (see also bin/songs/acid_song.rb):
#     load 'bin/synths/acid.rb'
#     bpm 128
#     line = acid(A1, !A1, ~A2, A1, R, C2, !A1, T, ~D2, E2, A1.up, R, !G1, ~A1, A2, R).loop
#     bg :acid, acid_voice(line)
#     swap :acid, line.transpose(-2)                    # next bar, same voice
#     bg :acid, acid_voice(line, cutoff: 0.25.bars.lfo.at(150..900), reso: 0.8)  # a knob tweak
#     bg :acid, acid_voice(line.permute(seed: 3), filter: :lp4)                   # lp4 to compare
#     bg :acid, acid_voice(midi)                        # a keyboard
#     bg :acid, acid_voice(line, decay: 2.6)            # a longer MEG (exponential, curve 30; times x2.6 a linear fall's)
#     bg :acid, acid_voice(line, env_curve: :linear, decay: 0.6, accent_decay: 0.2)  # the earlier linear MEG (same half-way times)
#     bg :acid, acid_voice(line, decay: 1.17, accent_decay: 0.39)   # curve 30 with linear's average sweep (equal area, x1.95)
#
# Building blocks on their own (any Notes n: clip.notes, midi, or a synth voice):
#     n.accent                                    # 1 on accented notes, else 0
#     meg = n.acid_env(decay: 1.3)                # the MEG (curve 30); accented notes decay in 0.52 s
#     n.accent_sweep(meg, resonance: 0.7)         # accents build up: 0.57, 0.78, 0.86
#     n.hz.glide(60.ms, legato: true).saw.diode(2 ** (meg * 3) * 250, resonance: 0.7, drive: 1.5)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # Accent sweep depth in octaves at +accent+ 1 (the prototype's 3 octaves
  # of its x2.8 sweep, for Notes#accent_sweep's x1.6).
  ACID_SWEEP_OCTAVES = 5.25

  # Makeup gain before the output soft clipper.
  ACID_GAIN = 3.0

  # A mono TB-303-style voice playing +midi+ (a Notes, a Clip, a MIDI
  # file, or another MB::Sound.synth source): a one-voice Synth (last-note
  # priority; overlapping notes glide), so tails ring out.  Options as in
  # the script's parameters; +cutoff+ and +reso+ may be graph nodes (e.g.
  # LFOs).
  def self.acid_voice(midi, **options)
    synth(midi, voices: 1) { |v| acid_patch(v, **options) }
  end

  # The 303-style patch for one Notes voice +n+ (see .acid_voice).
  def self.acid_patch(
    n, wave: :saw, cutoff: 300, reso: 0.6, env_mod: 3.0, decay: Notes::ACID_ENV_DECAY, accent: 0.8,
    filter: :diode, drive: 1.5, glide: 0.06, sweep: true, env_curve: Notes::ACID_ENV_CURVE,
    accent_decay: Notes::ACID_ENV_ACCENT_DECAY
  )
    pitch = n.hz.glide(glide, legato: true)
    osc = wave.to_sym == :square ? pitch.square : pitch.saw

    acc = n.accent
    meg = n.acid_env(decay: decay, accent_decay: accent_decay, curve: env_curve)
    knob = reso.respond_to?(:sample) ? 0.6 : reso.to_f
    sw = sweep ? n.accent_sweep(meg, resonance: knob) : meg * acc

    # Accented notes trade some envelope depth for the sweep, as on the 303
    octaves = meg * (1 - acc * 0.5) * env_mod + sw * (accent * ACID_SWEEP_OCTAVES)
    cut = ((2 ** octaves) * cutoff * n.brightness).clip(20, 16000)
    res = reso.respond_to?(:sample) ? reso : n.reso(reso)

    filtered = case filter.to_sym
               when :diode then osc.diode(cut, resonance: res, drive: drive)
               when :lp4 then osc.lp4(cut, resonance: res, drive: drive)
               else raise ArgumentError, "Unknown acid filter #{filter.inspect} (use :diode or :lp4)"
               end

    # VEG: a gate-cut decay (slides keep it going); accents add level
    veg = n.env(0.002, 3.5, 0.0, 0.008, sensitivity: 1.0..1.0, curve: [0, 30, 0], gm: false).legato
    amp = veg * (acc * (accent * 0.45) + sw * (accent * 0.14) + 0.55)

    # Makeup gain into a soft clipper: about -27 dB RMS on c_major.mid, near
    # the other synth scripts' -24 (the half-step gates leave gaps)
    (filtered * amp * ACID_GAIN).filter(:highpass, cutoff: 35, quality: 0.7).softclip(0.6, 0.95)
  end

  if main_script?(__FILE__)
    synth_script(
      wave: [:saw, Symbol, 'Oscillator wave', [:saw, :square]],
      cutoff: [300.0, Float, 'Filter cutoff in Hz before the envelopes (CC 74 moves it)', 20.0..5000.0],
      reso: [0.6, Float, 'Resonance 0..1 (CC 71 moves it)', 0.0..1.0],
      env_mod: [3.0, Float, '-e', 'Filter envelope depth in octaves', 0.0..8.0],
      decay: [Notes::ACID_ENV_DECAY, Float, 'Filter envelope decay in seconds, exponential (accents: 0.52; x2.6 a linear fall with the same half-way time)', 0.05..10.0],
      accent: [0.8, Float, '-a', 'Accent amount 0..1 (level and sweep)', 0.0..1.0],
      filter: [:diode, Symbol, '-F', 'Filter: diode ladder or lp4', [:diode, :lp4]],
      drive: [1.5, Float, 'Filter drive', 0.1..10.0],
      glide: [0.06, Float, 'Slide time in seconds', 0.0..1.0],
      sweep: [true, 'Accent sweep (--no-sweep for plain accents)'],
    ) { |midi, p|
      acid_voice(
        midi, wave: p.wave, cutoff: p.cutoff, reso: p.reso, env_mod: p.env_mod, decay: p.decay,
        accent: p.accent, filter: p.filter, drive: p.drive, glide: p.glide, sweep: p.sweep
      )
    }
  end
end

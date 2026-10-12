#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A vocal-ish tech-house / bass-house lead (the maintainer's sound-design
# reference, paraphrased): moving resonant peaks independent of the note's
# pitch make a synth sound like it's singing.
#
# The patch:
# 1. A bright, asymmetric source: a kick drum turned into a wavetable (its
#    first 2048-sample frame: the click and the start of the pitch drop, a
#    lopsided cycle full of irregular harmonics), a narrow pulse, or a saw.
# 2. Two filters in parallel: a formant filter morphing between vowels
#    (`formant(:a, :o, morph:)`) and a resonant lp4 whose cutoff wobbles,
#    both moving with a tempo-synced LFO.
# 3. A sample-rate crusher (`decimate`) whose aliasing folds the upper peaks
#    toward and away from each other, the "yoyo" vowel motion.  Its rate
#    follows the note exactly by default (key tracking 1, the maintainer's
#    pick over 0.5 on 2026-10-11: every note folds alike); below 1
#    (+--crush-track+) low notes get relatively more crushing and high
#    notes less, as in the reference's inverted crush tracking.
# 4. A little delay and reverb (in the song script).
#
# Cost (graph_profile, spec/test_data/dense_modulated.mid, one voice):
# 5.5% of realtime at 128-sample buffers, 4.5% at 800 (the formant filter
# with a moving vowel is the largest part, ~30 us per 128 samples).
#
# Usage:
#     bin/synths/vocal_lead.rb                       # live MIDI
#     bin/synths/vocal_lead.rb song.mid lead.flac    # render a MIDI file
#     bin/synths/vocal_lead.rb -S pulse -c 3000 -t 0.3 song.mid lead.flac
#     bin/synths/vocal_lead.rb -w 2 -k 0.9 song.mid lead.flac    # a ramp-like wobble
#     bin/synths/vocal_lead.rb --help
#
# Snippets (bin/sound.rb, after `load 'bin/synths/vocal_lead.rb'`):
#     bpm 126
#     hook = seq(A4, R, C5, A4, R, E5, R, C5, A4, R, B4, C5, R, A4, E5, R).n16.loop
#     bg :lead, vocal_lead_voice(hook.ghost_chords(1, 4, 7, 6, scale: scale(:minor, :a)))
#     bg :lead, vocal_lead_voice(hook, source: :pulse, vowels: [:i, :a, :u])     # brighter vowels
#     bg :lead, vocal_lead_voice(hook, crush: 0, formant_mix: 1)                  # no crusher: plain formants
#     bg :lead, vocal_lead_voice(hook, crush_track: 0.5)                          # low notes crush more
#     bg :lead, vocal_lead_voice(hook.transpose(-36), skew: 0.9)                   # bass octave, ramp-like wobble
#     # The two building blocks alone:
#     play 110.hz.ramp.formant(:a, :e, :i, :o, :u, morph: 0.25.hz.lfo.at(0..1))
#     play 110.hz.ramp.lp4(0.5.hz.lfo.at(400..2400), resonance: 0.8).decimate(2900)

require 'bundler/setup'
require 'mb-sound'

module MB::Sound
  # The frame size and frame count of the kick wavetable.
  VOCAL_KICK_FRAME = 2048
  VOCAL_KICK_FRAMES = 4

  # A kick drum as a wavetable (frames of one synthesized kick, sliced every
  # VOCAL_KICK_FRAME samples like a sampler's wavetable import): a sine
  # sweeping from 320 Hz down to 48 Hz with a clicky attack.  Frame 0 is
  # the brightest and most lopsided; later frames are rounder.  Registered
  # as Wavetable[:vocal_kick] (so graphs using it print and load back while
  # this script is loaded).
  def self.vocal_kick_frames
    n = VOCAL_KICK_FRAME * VOCAL_KICK_FRAMES
    t = Numo::DFloat.new(n).seq / 48000.0
    freq = Numo::NMath.exp(-t / 0.018) * 272 + 48
    phase = (freq / 48000.0).cumsum
    body = Numo::NMath.sin(phase * 2 * Math::PI) * Numo::NMath.exp(-t / 0.25)
    click = Numo::NMath.exp(-t / 0.0015) * 0.6
    (body + click).clip(-1, 1).reshape(VOCAL_KICK_FRAMES, VOCAL_KICK_FRAME)
  end

  Wavetable.register(:vocal_kick) {
    Wavetable.from_samples(vocal_kick_frames, align: false, normalize: :loudness, name: 'vocal_kick')
  } unless Wavetable.names.include?(:vocal_kick)

  # The kick wavetable (see .vocal_kick_frames).
  def self.vocal_kick_table
    Wavetable[:vocal_kick]
  end

  # A mono vocal lead playing +midi+ (a Notes, a Clip, a MIDI file, or
  # another MB::Sound.synth source): a one-voice Synth (last-note priority;
  # overlapping notes glide).  Options as in .vocal_lead_patch.
  def self.vocal_lead_voice(midi, voices: 1, **options)
    synth(midi, voices: voices) { |v| vocal_lead_patch(v, **options) }
  end

  # The vocal lead patch for one Notes voice +v+:
  # - +source+: :kick (kick wavetable, +scan+ 0..1 across its frames),
  #   :pulse (+width+), or :saw.
  # - +vowels+ and +wobble+: the formant filter's vowels, morphed by a
  #   triangle LFO at +wobble+ (a Duration such as 1.n4 follows the tempo,
  #   or Hz), +voice+ the formant table's voice; +formant_track+ shifts the
  #   formants by that fraction of the note's distance from C4.  +skew+
  #   is the LFO's rising fraction (Notes#lfo; 0.5 a plain triangle, 0.9
  #   nearly a rising ramp); a skewed LFO starts from its low point, on
  #   the beat for a tempo rate.
  # - +cutoff+ and +reso+: the parallel lp4's cutoff (wobbling an octave
  #   either side with the same LFO) and resonance.
  # - +formant_mix+: 0 only the lp4, 1 only the formants.
  # - +crush+: the crusher's rate in Hz at C4 (0 for none), +crush_track+
  #   its key tracking (1, the default = rate proportional to the note, 0 =
  #   fixed; below 1, low notes crush relatively more), +jitter+ its clock
  #   jitter, +crush_mix+ its wet share (decimate's mix:, 1 all crushed, 0
  #   none; maintainer, 2026-10-11: "Decimation wet/dry is too strong").
  # - +glide+: legato glide time in seconds.
  # - +drop+: octaves the pitch dives after each note-off, over +drop_time+
  #   seconds (the release stretches to match), so a note before a rest
  #   bends down like a tape stop; from A1 two octaves reach 14 Hz, where
  #   the kick wavetable's cycles are almost single kicks (maintainer,
  #   2026-10-11: "kick sample benefits from slower notes with pitch bend
  #   drops as well so individual kicks are momentarily almost audible").
  #   0 for none.
  # - +transpose+: semitones (a number or a node, e.g. an envelope) added
  #   to the pitch, for bends and dives on held notes (Small Talk's riser
  #   dive: `v.env(1.bar, ...) * -60`).
  def self.vocal_lead_patch(
    v, source: :kick, scan: 0.0, width: 0.12, vowels: [:a, :o], voice: :tenor, wobble: 1.n4, skew: 0.5, formant_track: 0.3,
    cutoff: 1400, reso: 0.75, formant_mix: 0.6, crush: 4200, crush_track: 1.0, crush_mix: 0.5, jitter: 0.0, glide: 0.04,
    drop: 0, drop_time: 0.25, gain: 1.0, transpose: nil
  )
    pitch = v.hz.glide(glide, legato: true)
    pitch = pitch.transpose(transpose) if transpose
    if drop > 0
      # 0 while the note is held, falling linearly (in octaves) after it
      fall = v.env(0, 0, 1, drop_time, curve: :linear, sensitivity: 1.0..1.0, gm: false) - 1
      pitch = pitch.transpose(fall * (12 * drop))
    end
    osc = case source.to_sym
          # Free-running: a key-synced wavetable's band-limited reset steps
          # cost ~170 us per 128-sample buffer on dense MIDI (their harmonic
          # derivatives are summed in Ruby, Wavetable::KernelRuby), and a
          # lead's onsets don't need them
          when :kick then pitch.wavetable(vocal_kick_table, scan: scan).free
          when :pulse then pitch.pulse(width)
          when :saw then pitch.saw
          else raise ArgumentError, "Unknown vocal lead source #{source.inspect} (use :kick, :pulse, or :saw)"
          end

    # One LFO moves the vowel and the resonant peak together
    lfo = v.lfo(wobble, shape: :triangle, unipolar: true, skew: skew, phase: skew == 0.5 ? nil : 1 - skew / 2.0)
    vox = osc.formant(*vowels, voice: voice, morph: lfo, shift: (v.number - 60) * formant_track)
    peak = osc.lp4(v.cutoff(cutoff, env: false, keytrack: 0.5, gm: false) * (2 ** (lfo * 2 - 1)), resonance: reso)
    mix = vox * formant_mix + peak * (1 - formant_mix)

    crushed = if crush.to_f > 0 && crush_mix > 0
                mix.decimate(v.cutoff(crush, env: false, keytrack: crush_track, gm: false), jitter: jitter, mix: crush_mix)
              else
                mix
              end

    # With a drop the release lasts the dive and fades gently, so the
    # slow end of it is heard
    amp = drop > 0 ? v.env(0.004, 0.3, 0.75, drop_time, curve: [12, 60, 6]).legato : v.env(0.004, 0.3, 0.75, 0.12).legato
    (crushed * amp * gain).filter(:highpass, cutoff: 90, quality: 0.7).softclip(0.7, 0.98)
  end

  if main_script?(__FILE__)
    synth_script(
      source: [:kick, Symbol, '-S', 'Oscillator: kick wavetable, narrow pulse, or saw', [:kick, :pulse, :saw]],
      scan: [0.0, Float, 'Kick wavetable position (0 the clickiest frame)', 0.0..1.0],
      vowels: ['a,o', String, '-V', 'Vowels to morph between (a, e, i, o, u, comma separated)'],
      voice: [:tenor, Symbol, 'Formant table voice', MB::Sound::GraphNode::Formant::VOICES.keys],
      wobble: [4.0, Float, '-w', 'Vowel LFO rate in Hz', 0.05..40.0],
      skew: [0.5, Float, '-k', 'Vowel LFO skew: rising fraction of each cycle (0.5 triangle, 0.9 nearly a ramp)', 0.01..0.99],
      cutoff: [1400.0, Float, 'Resonant filter cutoff at C4 in Hz', 100.0..8000.0],
      reso: [0.75, Float, 'Resonant filter resonance 0..1', 0.0..1.0],
      formant_mix: [0.6, Float, '-x', 'Formant filter share of the mix 0..1', 0.0..1.0],
      crush: [4200.0, Float, '-c', 'Crusher rate at C4 in Hz (0 for none)', 0.0..48000.0],
      crush_track: [1.0, Float, '-t', 'Crusher key tracking (1 follows the note exactly)', -1.0..2.0],
      crush_mix: [0.5, Float, '-m', 'Crusher wet share 0..1', 0.0..1.0],
      drop: [0.0, Float, '-d', 'Octaves the pitch dives after each note-off (0 for none)', 0.0..4.0],
      jitter: [0.0, Float, '-j', 'Crusher clock jitter 0..0.95', 0.0..0.95],
    ) { |midi, p|
      vowels = p.vowels.split(',').map { |s| s.strip.downcase.to_sym }
      vocal_lead_voice(
        midi, source: p.source, scan: p.scan, vowels: vowels, voice: p.voice, wobble: p.wobble, skew: p.skew, cutoff: p.cutoff,
        reso: p.reso, formant_mix: p.formant_mix, crush: p.crush, crush_track: p.crush_track, crush_mix: p.crush_mix,
        drop: p.drop, jitter: p.jitter
      )
    }
  end
end

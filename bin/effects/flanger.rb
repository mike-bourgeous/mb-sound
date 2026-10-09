#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 RUBY_YJIT_ENABLE=1 ruby
# A simple flanger effect, to demonstrate using a signal node as a delay time.
# (C)2022 Mike Bourgeous
#
# Usage: $0 [options] [input_filename [output_filename]]
#
# Plays a sound file (or live input, stereo unless -c says otherwise) through
# the flanger, letting it ring out after the file ends.  With live MIDI
# (JACK), CC 1 (the mod wheel) sweeps the LFO rate, depth, and dry level
# together.  Run with --help for all options.
#
# Examples:
#     $0 --dry 0.5 --delay 0.002 --feedback 0.85 --hz 0.2 --depth 0.5 sounds/drums.flac
#
# Cool effects (omit the filename for live input):
#     # Arpeggio
#     $0 --smoothing 0.5 --delay 0.035 --feedback 0 --hz 3 --depth 2 sounds/transient_synth.flac
#     # Slow arp
#     $0 --smoothing 1.5 --delay 0.15 --feedback 0 --hz 3 --depth 2 sounds/transient_synth.flac
#     # Metal drums
#     $0 --smoothing 12.1 --wet 1 --dry 0 --delay 0.02 --feedback -0.3 --hz 343 --depth -6 sounds/drums.flac
#     # Water drums
#     $0 --smoothing 4 --wet 1 --dry 0 --delay 0.02 --feedback -0.3 --hz 46 --depth 6 sounds/drums.flac
#     # Space warp
#     $0 --smoothing 10 --wet 1 --dry 0 --delay 0.2 --feedback -0.8 --hz 15 --depth 6 sounds/drums.flac
#     # Time warp
#     $0 --wet 1 --dry 0 --delay 0.2 --feedback -0.8 --hz 0.3 --depth 6 sounds/drums.flac
#     # Bass comb
#     $0 --smoothing 0.7 --dry 0 --delay 0.04 --feedback 0.95 --hz 150 --depth 1 sounds/drums.flac
#     # Bass beat
#     $0 --spread 10 --delay 0.006 --feedback -0.98 --hz 0.4 --depth 2 sounds/drums.flac
#     # Gritty overtone
#     $0 --dry 0.5 --delay 0.0029 --feedback 0.85 --hz 60 --depth 0.1 sounds/synth0.flac
#     # Decimation
#     $0 --dry 0 --delay 0.0058 --feedback -0.85 --hz 3300 --depth 0.2 sounds/synth0.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.effect_script(
  delay: [0.02193, 'Center delay in seconds'],
  feedback: [-0.3, 'Feedback gain'],
  hz: [-0.7, 'LFO frequency (negative runs the waveform backward)'],
  depth: [0.35, 'LFO depth as a fraction of the delay'],
  wave: [:sine, 'LFO waveform', MB::Sound::Tone::WAVE_TYPES],
  smoothing: [nil, Float, 'Max delay change rate in seconds per second (default: none)'],
  dry: [1.0, 'Dry (input) level'],
  wet: [1.0, 'Wet (flanged) level'],
  spread: [180.0, 'LFO phase spread across channels in degrees'],
  oversample: [2.0, 'Oversampling factor'],
) { |input, p|
  # Delays below are in samples at the oversampled processing rate
  sample_rate = 48000 * p.oversample
  channels = input.channel_count

  # FIXME: This doesn't work with a filter like 1000.hz.lowpass1p; maybe there's overshoot or something?
  delay_smoothing = p.smoothing
  delay_smoothing2 = delay_smoothing

  # CC 1 sweeps the LFO rate, depth, and dry level together
  lfo_freq = p.midi_cc(1, :hz, range: 0.0..6.0)
  depthconst = p.midi_cc(1, :depth, range: 0.0..2.0)
  dryconst = p.midi_cc(1, :dry, range: 1.0..0.0)
  delayconst = p.delay.constant.named('delay')
  wetconst = p.wet.constant.named('wet')

  # TODO: Maybe want a graph-wide spy function that either prints stats, draws
  # meters, or plots graphs of multiple nodes by name or reference

  input.outputs.map.with_index { |inp, idx|
    # Resampled so --oversample runs the flanger at the higher rate
    inp = inp.resample(mode: :libsamplerate_fastest)

    phase = channels > 1 ? idx * p.spread / (360.0 * (channels - 1)) : 0 # cycles
    lfo = lfo_freq.tone.with_phase(phase).send(p.wave).at(0..1)

    # Delay in samples
    samples = (delayconst * sample_rate).aclip(0, nil).named('Delay in samples')

    # Delay LFO
    lfo_scale = depthconst * samples
    lfo_base = samples - lfo_scale * 0.5
    lfo_mod = (lfo * lfo_scale + lfo_base).aclip(0, nil)

    # The input through the swept delay
    inp_delayed = inp.delay(lfo_mod.samples, smoothing: delay_smoothing)

    # The flanged signal feeds back through the same sweep, one sample at a
    # time (GraphNode#feedback), so the loop's period is exactly the swept
    # delay at any delay or block size (the delay absorbs the softclip's
    # half sample).  Until 2026-10-09 this ran in internal blocks with a
    # spy, the feedback delay shortened by a block.
    wet = inp.feedback { |fb, _|
      (p.feedback * fb.delay(lfo_mod.samples, smoothing: delay_smoothing2) - inp_delayed).softclip(0.85, 0.95)
    }.named('flanger loop')

    (inp * dryconst + wet * wetconst)
      .softclip(0.85, 0.95).named('final_softclip')
      .filter(15000.hz.lowpass)
      .oversample(p.oversample, mode: :libsamplerate_fastest).named('final_oversample')
  }.channels
}

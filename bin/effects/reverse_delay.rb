#!/usr/bin/env -S RUBY_THREAD_TIMESLICE=10 ruby
# A reverse delay effect.  This works by playing a delay buffer in reverse.
# (C)2022 Mike Bourgeous
#
# Usage: $0 [options] [input_filename [output_filename]]
#
# Plays a sound file (or live input, stereo unless -c says otherwise) through
# the delay, letting it ring out after the file ends.  With live MIDI (JACK),
# CC 1 (the mod wheel) controls the delay time.  Run with --help for all
# options.
#
# Runs at 48 kHz by default: oversampling barely changes the sound here
# (1x is -80 dB from an 8x render, 2x -85 dB; measured 2026-10-03) but
# roughly doubles the CPU cost per step.  Pass --oversample 2 to compare.
#
# Examples:
#     $0 --dry 0 --delay 0.2 --feedback 0 sounds/drums.flac
#     $0 --oversample 2 spec/test_data/arp_a7.flac

require 'bundler/setup'
require 'mb-sound'

MB::Sound.effect_script(
  delay: [0.6, 'Delay (and reverse loop) length in seconds'],
  feedback: [-0.25, 'Feedback gain'],
  dry: [0.25, 'Dry (input) level'],
  wet: [0.75, 'Wet (reversed) level'],
  oversample: [1.0, 'Oversampling factor (2 or 4 barely changes the sound here; see the header)'],
) { |input, p|
  processing_sample_rate = 48000 * p.oversample
  # The feedback comes back one internal buffer late; scaling the buffer with
  # oversampling keeps that latency (1.3 ms) the same, so every oversampling
  # factor sounds alike, and keeps the per-buffer overhead from growing.
  internal_buffer = [(64 * p.oversample).round, 16].max
  internal_buftime = internal_buffer.to_f / processing_sample_rate

  # TODO: Allow base delay and loop length? or mindelay and maxdelay?
  # TODO: It would be cool to be able to crossfade the delay time jump; this
  # could be possible with a multi-tap delay (e.g. fade out from t1 while
  # fading in from t2)
  # The smoothing filter starts at the delay time instead of rising from zero.
  # The LFOs below integrate 1 / delay_time, so a rise from zero would race
  # through thousands of cycles (faster with more oversampling, as the clip
  # floor is one internal buffer) and leave the reverse loop at an arbitrary
  # phase.
  delay_time = p.midi_cc(1, :delay, range: 0.0..2.0)
    .filter(:lowpass, cutoff: 10).tap { |f| f.reset(p.delay) }
    .clip(internal_buftime, nil)

  lfo_freq = (1.0 / delay_time).named('LFO Frequency')

  channels = input.channel_count
  input.outputs.map.with_index { |inp, idx|
    inp = inp.with_buffer(800).resample(mode: :libsamplerate_fastest)

    # Feedback buffers, overwritten by later calls to #spy
    a = Numo::SFloat.zeros(internal_buffer)

    # The amplitude LFO mutes the sound while the delay buffer jumps back to the present
    amp_lfo = lfo_freq.tone.sine.at(0..1000).with_phase((idx + 0.5) * 2.0 * Math::PI / channels).clip(0, 1).named('Amp LFO')

    # The delay LFO controls the position in the delay buffer
    delay_lfo = lfo_freq.tone.ramp.at(0..2).with_phase(idx * 2.0 * Math::PI / channels).named('Delay LFO') * delay_time

    delayed = inp.delay(seconds: delay_lfo, smoothing: false) * amp_lfo

    # TODO: create a better way to do feedback in node graphs, ideally while
    # automatically compensating for buffer size
    # TODO: implement cross-channel feedback
    d_fb = (delay_lfo - internal_buftime).clip(0, nil).named('d_fb')
    d_fb_amp = amp_lfo.multitap(d_fb)[0] # delay the amp lfo to match the feedback delay (FIXME: this seems to be off; it lets through some aliasing noise on each cycle; or maybe it's in both LFOs)
    fb_return = 0.constant.proc { a }.multitap(d_fb)[0] * d_fb_amp
    wet = (p.feedback * fb_return + delayed).softclip(0.85, 0.95).spy { |z| a[] = z if z }

    dryconst = p.dry.constant.named('Dry level')
    wetconst = p.wet.constant.named('Wet level')
    (inp * dryconst + wet * wetconst).softclip(0.85, 0.95).with_buffer(internal_buffer).oversample(p.oversample, mode: :libsamplerate_fastest)
  }.channels
}

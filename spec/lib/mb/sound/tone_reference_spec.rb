require 'json'
require_relative '../../../test_data/make_tone_reference'

# Null tests for oscillators: every case in spec/support/tone_reference_cases.rb
# must give exactly the samples recorded before the Tone/Oscillator
# consolidation (spec/test_data/tone_reference.json; regenerate or diff with
# spec/test_data/make_tone_reference.rb).
#
# Intended differences (each re-recorded with a reason) are listed in
# INTENDED.
RSpec.describe('Tone null-test reference') do
  REFERENCE = JSON.parse(File.read(File.expand_path('../../../test_data/tone_reference.json', __dir__)))

  # Case name => why its reference was re-recorded.
  INTENDED = {
    # Bug fix 2026-10-06: wraps landing exactly on a sample (a whole number
    # of cycles) were lost to rounding; now a pulse of 1 on that sample
    'tone_ports' => 'wraps: adds the pulse lost at sample 960 (1500 Hz + 200 Hz FM, whole cycles); 2026-10-13: running phase (last bits)',
    'tone_ports_negative' => 'wraps: adds the pulse lost at sample 480 (-1700 Hz, 17 whole cycles); 2026-10-07: no backward-edge spikes; 2026-10-13 (fixes-7): constant-frequency phase grid (last bits)',
    'phasor_ports' => 'wraps: adds the pulse lost at sample 288 (900 Hz, whole cycles); 2026-10-13: running phase, the phasor reads 0 (not 1.0) at that wrap',
    'phasor_wraps_only' => 'new at_2000 output (2000 Hz, every wrap on a sample; had no pulses); main unchanged',
    # Fix 2026-10-07: synced ramps, triangles, and parabolas are exactly the
    # minimum-phase filtered naive waveform (segments delayed with the
    # minBLEP), removing a DC offset that grew with the master's pitch
    'sync_ratio' => 'sync: delayed segments, no DC drift (ramp)',
    'sync_ratio_node' => 'sync: delayed segments, no DC drift (ramp)',
    'sync_trigger' => 'sync: delayed segments, no DC drift (ramp)',
    'softsync' => 'sync: delayed segments, exact slope corners (triangle)',
    # Fix 2026-10-07: a band-limited edge landing exactly on a sample while
    # the phase moves backward was corrected as crossed and then never
    # crossed (a full-jump spike, peak 1 instead of 0.5, at each one)
    'negative_freq' => 'free-running backward edges on samples: no spikes (-440 Hz ramp)',
    # Fix 2026-10-07: phase jumps (resets, key sync, timeline locks) get
    # the area of an ideal step on the sample (no DC drift at audio-rate
    # resets), and a reset on a jump in value starts from its left side
    'clip_key_sync_variants' => 'phase jumps: ideal step area; 2026-10-08: first sample as if the tone had always run',
    'clip_synth' => 'phase jumps: ideal step area',
    'clip_tone' => 'phase jumps: ideal step area',
    'reset' => 'phase jumps: ideal step area',
    'reset_edges' => 'phase jumps: ideal step area; 2026-10-08: first sample as if the tone had always run',
    'reset_fm_pm' => 'phase jumps: ideal step area; 2026-10-10: PM in cycles (last bits, residual below -130 dB)',
    'reset_pwm' => 'phase jumps: ideal step area; 2026-10-08: first sample as if the tone had always run',
    'reset_random' => 'phase jumps: ideal step area',
    'reset_to' => 'phase jumps: ideal step area',
    'reset_to_node' => 'phase jumps: ideal step area; 2026-10-10: reset targets in cycles (a radians node scaled; last bits, -130 dB)',
    'rnd_reset' => 'phase jumps: ideal step area',
    'tempo_audio_rate_seek' => 'phase jumps: ideal step area',
    'tempo_lfo_changes' => 'phase jumps: ideal step area; 2026-10-13 (fixes-7): constant-frequency phase grid (last bits)',
    'tone_ports_reset' => 'phase jumps: ideal step area',
    # 2026-10-08: complex shapes with phase modulation, warps, or sync play
    # from complex wavetables (Tone#complex_table?) instead of the naive
    # closed forms
    'complex_ramp_pm' => 'complex shapes: PM from a complex table (was the naive acomplex_saw); 2026-10-10: PM in cycles (last bits, residual below -130 dB)',
    # Fix 2026-10-08: a band-limited (PolyBLEP) tone's first sample is
    # corrected as if the tone had always run, so a square or pulse starting
    # on its edge at phase 0 plays the edge's midpoint (0), not +1; only
    # sample 0 changes (warp corners at phase 0 get their small kink term)
    'pulse_dc' => 'first sample as if the tone had always run',
    'pulse' => 'first sample as if the tone had always run',
    'pm_index' => 'first sample as if the tone had always run; 2026-10-10: PM in cycles (last bits, residual below -130 dB)',
    'square_110' => 'first sample as if the tone had always run',
    'rate_96000_fm' => 'first sample as if the tone had always run; 2026-10-13: running phase (last bits)',
    'notes' => 'first sample as if the tone had always run',
    'ramp_pwm' => 'first sample as if the tone had always run; 2026-10-13 (fixes-7): constant-frequency phase grid (last bits)',
    'reset_lfo' => 'first sample as if the tone had always run',
    'drumramp' => 'first sample as if the tone had always run',
    'sine_pwm' => 'first sample as if the tone had always run',
    'sync_tone_master' => 'first sample as if the tone had always run',
    'pwm_node' => 'first sample as if the tone had always run',
    'lfo_square_20' => 'first sample as if the tone had always run',
    'square_3520' => 'first sample as if the tone had always run; 2026-10-13 (fixes-7): constant-frequency phase grid (last bits)',
    'skew_triangle' => 'first sample as if the tone had always run',
    'negative_amp' => 'first sample as if the tone had always run',
    'parabola_pwm' => 'first sample as if the tone had always run',
    # 2026-10-10: noise tones keep a running phase wrapped every sample, so
    # the output no longer depends on block sizes (last-bit differences;
    # RMS and peak equal to 9 digits)
    # 2026-10-13: naive jumps landing exactly on a sample (3520 Hz is 11/150
    # cycles per sample) snap onto the jump (the value after it), so they
    # land on the same sample at any block size; 1-2 samples each
    'aramp_3520' => 'naive edges on samples snap to the jump (sample 1125); 2026-10-13 (fixes-7): constant-frequency phase grid (last bits)',
    'asquare_3520' => 'naive edges on samples snap to the jump (samples 1050, 1125)',
    'gauss_3520' => 'naive edges on samples snap to the jump (sample 1125); 2026-10-13 (fixes-7): constant-frequency phase grid (last bits)',
    'noise_root_seed' => 'noise: block-size independent phase (last bits)',
    'noise_seeded_blend' => 'noise: block-size independent phase (last bits)',
    # 2026-10-10: phase modulation is in cycles (kernels add it to the phase
    # in cycles; the cases' radians modulators are scaled by 1 / 2pi), so
    # PM renders differ in the last bits (residuals -130 to -145 dB, max
    # sample difference 1.3e-6)
    'pm' => 'PM in cycles (last bits)',
    'pm_chain' => 'PM in cycles (last bits)',
    # 2026-10-13 (fixes-6): tones with a frequency signal keep a running
    # phase wrapped every sample (mb_phase.h), so they give the same samples
    # at any block size; FM renders differ in the last bits (residuals
    # -256 to -323 dB), and phasors whose wraps land exactly on a sample
    # read 0 there instead of a float32 1.0 (tempo phasors every 1500
    # samples at 32 Hz)
    'fm_stack' => 'running phase (last bits)',
    'fm_through_zero' => 'running phase (last bits)',
    'freq_node' => 'running phase (last bits)',
    'tuning_480' => 'running phase (last bits)',
    'tempo_lfo' => 'running phase (last bits)',
    'tempo_late_start' => 'running phase (last bits)',
    'tempo_phasor' => 'running phase: 0 (not 1.0) at wraps exactly on samples',
    'tempo_pitch_freewheel' => 'running phase: the phasor part reads 0 (not 1.0) at wraps exactly on samples',
    # 2026-10-13 (fixes-7): tones with a constant frequency count their
    # phases from an 800-sample grid of their own time (mb_phase.h), so
    # they give the same samples at any block size; these cases, rendered
    # in irregular blocks, differ in the last bits (residuals -237 to
    # -329 dB)
    'atriangle_3520' => 'constant-frequency phase grid (last bits)',
    'complex_ramp_330' => 'constant-frequency phase grid (last bits)',
    'lfo_ramp_100' => 'constant-frequency phase grid (last bits)',
    'parabola_3520' => 'constant-frequency phase grid (last bits)',
    'ramp_3520' => 'constant-frequency phase grid (last bits)',
    'rate_44100' => 'constant-frequency phase grid (last bits)',
    'sine_3520' => 'constant-frequency phase grid (last bits)',
    'triangle_3520' => 'constant-frequency phase grid (last bits)',
  }.freeze

  it 'has a reference for every case' do
    expect(REFERENCE.keys.sort).to eq(ToneReferenceCases::CASES.keys.sort)
  end

  # The references are exact renders; plans' default fast sines (Plan.precision
  # :fast) are within -100 dB but not bit-identical (see
  # spec/lib/mb/sound/plan/tone_op_spec.rb)
  around do |ex|
    old = MB::Sound::Plan.precision
    MB::Sound::Plan.precision = :exact
    ex.run
  ensure
    MB::Sound::Plan.precision = old
  end

  ToneReferenceCases::CASES.each_key do |name|
    it "matches the reference for #{name}" do
      expected = REFERENCE.fetch(name)
      actual = ToneReference.run(name).transform_values { |d| ToneReference.digest(d) }

      expect(actual.keys.sort).to eq(expected.keys.sort)
      actual.each do |out, d|
        e = expected.fetch(out)
        expect(d['length']).to eq(e['length']), "#{name}.#{out}: length #{d['length']}, expected #{e['length']}"
        next if d['sha256'] == e['sha256']

        raise RSpec::Expectations::ExpectationNotMetError, format(
          "%s.%s differs: rms %.9g (expected %.9g), peak %.9g (expected %.9g), head %s (expected %s)",
          name, out, d['rms'], e['rms'], d['peak'], e['peak'], d['head'].first(4), e['head'].first(4)
        )
      end
    end
  end
end

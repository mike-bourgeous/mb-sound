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
    'tone_ports' => 'wraps: adds the pulse lost at sample 960 (1500 Hz + 200 Hz FM, whole cycles)',
    'tone_ports_negative' => 'wraps: adds the pulse lost at sample 480 (-1700 Hz, 17 whole cycles); 2026-10-07: no backward-edge spikes',
    'phasor_ports' => 'wraps: adds the pulse lost at sample 288 (900 Hz, whole cycles)',
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
    'reset_fm_pm' => 'phase jumps: ideal step area',
    'reset_pwm' => 'phase jumps: ideal step area; 2026-10-08: first sample as if the tone had always run',
    'reset_random' => 'phase jumps: ideal step area',
    'reset_to' => 'phase jumps: ideal step area',
    'reset_to_node' => 'phase jumps: ideal step area',
    'rnd_reset' => 'phase jumps: ideal step area',
    'tempo_audio_rate_seek' => 'phase jumps: ideal step area',
    'tempo_lfo_changes' => 'phase jumps: ideal step area',
    'tone_ports_reset' => 'phase jumps: ideal step area',
    # 2026-10-08: complex shapes with phase modulation, warps, or sync play
    # from complex wavetables (Tone#complex_table?) instead of the naive
    # closed forms
    'complex_ramp_pm' => 'complex shapes: PM from a complex table (was the naive acomplex_ramp)',
    # Fix 2026-10-08: a band-limited (PolyBLEP) tone's first sample is
    # corrected as if the tone had always run, so a square or pulse starting
    # on its edge at phase 0 plays the edge's midpoint (0), not +1; only
    # sample 0 changes (warp corners at phase 0 get their small kink term)
    'pulse_dc' => 'first sample as if the tone had always run',
    'pulse' => 'first sample as if the tone had always run',
    'pm_index' => 'first sample as if the tone had always run',
    'square_110' => 'first sample as if the tone had always run',
    'rate_96000_fm' => 'first sample as if the tone had always run',
    'notes' => 'first sample as if the tone had always run',
    'ramp_pwm' => 'first sample as if the tone had always run',
    'reset_lfo' => 'first sample as if the tone had always run',
    'drumramp' => 'first sample as if the tone had always run',
    'sine_pwm' => 'first sample as if the tone had always run',
    'sync_tone_master' => 'first sample as if the tone had always run',
    'pwm_node' => 'first sample as if the tone had always run',
    'lfo_square_20' => 'first sample as if the tone had always run',
    'square_3520' => 'first sample as if the tone had always run',
    'skew_triangle' => 'first sample as if the tone had always run',
    'negative_amp' => 'first sample as if the tone had always run',
    'parabola_pwm' => 'first sample as if the tone had always run',
    # 2026-10-10: noise tones keep a running phase wrapped every sample, so
    # the output no longer depends on block sizes (last-bit differences;
    # RMS and peak equal to 9 digits)
    'noise_root_seed' => 'noise: block-size independent phase (last bits)',
    'noise_seeded_blend' => 'noise: block-size independent phase (last bits)',
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

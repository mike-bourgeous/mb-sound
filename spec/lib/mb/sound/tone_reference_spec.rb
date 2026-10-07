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
    'clip_key_sync_variants' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'clip_synth' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'clip_tone' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'reset' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'reset_edges' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'reset_fm_pm' => 'phase jumps: ideal step area',
    'reset_pwm' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'reset_random' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'reset_to' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'reset_to_node' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'rnd_reset' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'tempo_audio_rate_seek' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    'tempo_lfo_changes' => 'phase jumps: ideal step area',
    'tone_ports_reset' => 'phase jumps: ideal step area; 2026-10-08: resets as clean as sync',
    # 2026-10-08: band-limited ramps, squares, triangles, and warped shapes
    # with a reset input or a timeline (and no phase modulation or LFO
    # fade) play through the synced kernel, each reset a hard sync event on
    # its sample (Tone#reset_sync?): the minimum-phase filtered waveform
    # (about 2.8 samples of delay, minBLEP edges with their ringing: peaks
    # up to 1.38x those of PolyBLEP), harmonic error against the ideal reset
    # waveform -72 to -86 dB instead of -19 to -38 (reset_fm_pm and
    # tempo_lfo_changes have phase modulation or an LFO fade: unchanged)
  }.freeze

  it 'has a reference for every case' do
    expect(REFERENCE.keys.sort).to eq(ToneReferenceCases::CASES.keys.sort)
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

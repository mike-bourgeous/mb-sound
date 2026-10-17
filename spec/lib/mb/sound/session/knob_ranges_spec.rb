# Knobs never clamp silently (ux-1 item 30): a default outside the
# default 0..1 range without range: is a live_error with a range to give,
# and a turn past a knob's range warns once per knob.
RSpec.describe('knob ranges', :aggregate_failures) do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false) }

  after { session.close }

  it 'raises for a default outside 0..1 without range: (warns in live mode) with the range to give' do
    MB::Sound::Session.with_context(session: session) do
      expect { MB::Sound.knob(:spec_drive, 10) }.to raise_error(ArgumentError, /starts at 10, outside the default range 0\.\.1.*range: 0\.\.100/)
      expect(MB::Sound.knob(:spec_ok, 0.5).spec.range).to eq(0.0..1.0)
      expect(MB::Sound.knob(:spec_wide, 10, range: 0..20).value).to eq(10)
      live = MB::Sound.live?
      MB::Sound.live = true
      k = nil
      expect { k = MB::Sound.knob(:spec_live, -3) }.to output(/outside the default range.*range: -10\.\.0/).to_stderr
      expect(k.value).to eq(0)
    ensure
      MB::Sound.live = live
    end
  end

  it 'warns once per knob when a turn is limited to its range' do
    MB::Sound::Session.with_context(session: session) do
      MB::Sound.knob(:spec_gain, 0.5)
      MB::Sound.knob(:spec_cut, 800, range: 100..8000, curve: :exp)
      expect { MB::Sound.turn(:spec_gain, 100) }.to output(/turn :spec_gain, 100: limited to 1 \(knob :spec_gain goes 0\.\.1; knob :spec_gain, 0\.5, range: 0\.\.100 widens it\)/).to_stderr
      expect { MB::Sound.turn(:spec_gain, 50) }.not_to output.to_stderr
      expect { MB::Sound.turn(:spec_cut, 12000) }.to output(/range: 100\.\.20000 widens it/).to_stderr
      expect { MB::Sound.turn(:spec_cut, 4000) }.not_to output.to_stderr
    end
  end
end

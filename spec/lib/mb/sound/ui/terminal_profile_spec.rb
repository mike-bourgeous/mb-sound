# When a terminal shows what the screen writes (UI::TerminalProfile,
# konsole-pacing 2026-11-21): Konsole before 26.04 restarts a 10 ms timer
# at each chunk of output and caps it with a 40 ms one (src/Emulation.cpp),
# so frames under 10 ms apart show at about 25 a second; the maintainer
# confirmed it on his screen (95 vs 105 fps).
RSpec.describe(MB::Sound::UI::TerminalProfile, :aggregate_failures) do
  let(:konsole) { described_class.detect(xtversion: 'Konsole 23.08.5', env: {}) }

  def steady(fps, seconds = 1.0) = (0...(fps * seconds).round).map { |i| i / fps.to_f }

  it 'shows steady frames over 10 ms apart one by one and closer ones about 25 times a second (Konsole before 26.04)' do
    expect(konsole.kind).to eq(:bulk)
    expect(konsole.presents(steady(60)).length).to eq(60)
    expect(konsole.presents(steady(90)).length).to eq(90)
    expect(konsole.presents(steady(120)).length).to be_between(23, 25)
    expect(konsole.presents(steady(240)).length).to be_between(23, 25)
    # (each frame 10 ms after it arrived; three frames 8.3 ms apart wait for the last)
    expect(konsole.presents([0.0, 0.05]).map { (_1 * 1000).round(3) }).to eq([10.0, 60.0])
    expect(konsole.presents([0.0, 0.0083, 0.0167]).map { (_1 * 1000).round(3) }).to eq([26.7])
    # (a frame within 10 ms of the one before holds both back: the hitch at any rate)
    expect(konsole.presents([0.0, 0.016, 0.0333, 0.040, 0.0667]).length).to eq(4)
  end

  it 'gives the pacer a gap a little over the short timer, and says when a rate collapses' do
    expect(konsole.min_gap).to be_within(1e-9).of(0.012)
    expect(konsole.max_shown_fps.floor).to eq(83)
    expect(konsole.collapsed_fps).to eq(25.0)
    expect(konsole.collapses?(1 / 120.0)).to eq(true)
    expect(konsole.collapses?(1 / 60.0)).to eq(false)
  end

  it 'detects Konsole from XTVERSION or KONSOLE_VERSION, synchronized output from 26.04, nothing behind tmux or for other terminals' do
    expect(described_class.detect(env: { 'KONSOLE_VERSION' => '230805' })).to eq(described_class.konsole_bulk('Konsole 23.08'))
    sync = described_class.detect(xtversion: 'Konsole 26.04.1', env: {})
    expect(sync.kind).to eq(:sync)
    expect(sync.min_gap).to be_nil
    expect(sync.presents(steady(120)).length).to eq(120)
    expect(described_class.detect(env: { 'KONSOLE_VERSION' => '230805', 'TMUX' => '/tmp/x' })).to be_nil
    expect(described_class.detect(xtversion: 'kitty(0.39.1)', env: { 'KONSOLE_VERSION' => '230805' })).to be_nil # (the answer wins over a leftover variable)
    expect(described_class.detect(env: { 'TERM_PROGRAM' => 'iTerm.app' })).to be_nil
  end

  it 'parses the bench models' do
    expect(described_class.parse('konsole')).to eq(described_class.konsole_bulk)
    expect(described_class.parse('cadence:60').presents([0.001, 0.002, 0.020]).map { (_1 * 60).round }).to eq([1, 2])
    expect(described_class.parse('interval:10').presents([0.0, 0.001, 0.003, 0.011]).map { (_1 * 1000).round(3) }).to eq([0.0, 10.0, 20.0])
    expect(described_class.parse('bulk:0.5,8.333').short).to be_within(1e-9).of(0.0005)
    expect { described_class.parse('fast') }.to raise_error(ArgumentError, /konsole/)
    expect(described_class.shown_by([0.0, 0.005, 0.03], [0.015, 0.04])).to eq([0, 0, 1])
  end
end

require_relative '../../../../support/ui_helpers'

# `design` (sound-design-nav-1): one command from an instrument and a clip
# (or an existing track) to the sound screen on its filter, the track on
# MAIN, and `design off` back to the screen before.  The screen calls are
# stubbed (no terminal); the session is real.
RSpec.describe(MB::Sound::UI::Design, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  before do
    @shown = []
    allow(ui).to receive(:show) { |name = nil, **| @shown << name; nil }
    allow(ui).to receive(:off) { @shown << :off; nil }
    allow(described_class).to receive(:terminal?).and_return(true) # (no terminal shows nothing: the lesson's case)
    described_class.instance_variable_set(:@before, nil)
    described_class.instance_variable_set(:@last, nil)
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
  end

  after do
    ui::Inspect.target = nil
    @session&.close
    MB::Sound.rewind
  end

  def run(&block) = MB::Sound::Session.with_context(session: @session) { MB::Sound.instance_eval(&block) }

  it 'makes the track with an instrument, plays its clip on MAIN, and opens ui :sound on its filter' do
    riff = MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop.named(:riff)
    r = run { design :bass, :dnb_reese, riff }
    expect(r.to_s).to start_with('design :bass: dnb_reese on track :bass (new), plays riff on MAIN')
    expect(r.to_s).to include('knobs bass/glide', 'FILTER lp4 picked')
    expect(@session.arrangement.tracks).to have_key(:bass)
    expect(@session.playing_after_queue?(:bass)).to eq(true)
    expect(@shown).to eq([:sound])
    expect(ui::Inspect.target).to eq({ track: :bass, node: nil })

    # Again: opens it (no new track, no restart); alone: the last one
    expect(run { design :bass }.to_s).to start_with('design :bass: track :bass, playing;')
    expect(run { design }.track).to eq(:bass)
    expect(run { design off }).to eq('design off: ui off; :bass plays on (stop :bass)')
    expect(@shown.last).to eq(:off)
  end

  it 'plays a track without a clip on its role\'s note, and says when its knobs show' do
    r = run { design :pad, :dnb_pad }
    expect(r.to_s).to include('plays C3 (its role\'s note) on MAIN')
    run { stop :pad, on: :now }
    @session.process_buffer
  end

  it 'starts a new track without an instrument on the init voice (sound-design-2)' do
    r = run { design :lead }
    expect(r.to_s).to start_with('design :lead: init on track :lead (new), plays G4 (its role\'s note) on MAIN')
    expect(@session.arrangement.tracks[:lead].patch?).to eq(true)
    expect(@session.knobs.keys).to include(:"lead/wave1", :"lead/sync", :"lead/cutoff", :"lead/glide")
    run { stop :lead, on: :now }
    @session.process_buffer
  end

  it 'refuses design without a track name and with two instruments' do
    expect { run { design } }.to raise_error(ArgumentError, /design names a track/)
    expect { run { design :bass, :dnb_reese, :dnb_pad } }.to raise_error(ArgumentError, /one instrument/)
  end
end

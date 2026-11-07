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
    # (an example that leaves `design` open makes later specs' rebuilds of
    # a track of that name land on the next buffer: editability-1 found
    # literal_binding_spec's :pad binds landing now after `design :pad`)
    described_class.instance_variable_set(:@open, false)
    described_class.instance_variable_set(:@last, nil)
    @session&.close
    MB::Sound.rewind
  end

  def run(&block) = MB::Sound::Session.with_context(session: @session) { MB::Sound.instance_eval(&block) }

  # fix-batch-1106: the track's patch check built the instrument for the
  # test clip, then the play built it again for the clip (~130 ms each for
  # the init voice); now the check builds for the clip and the play takes
  # that build, with the same samples (Arrangement#building_for)
  it 'builds a new track\'s instrument once, for the clip it plays, and an existing silent track\'s new one once too' do
    riff = MB::Sound.seq(MB::Sound::E1, MB::Sound::G1).n8.loop.named(:riff)
    builds = 0
    allow(MB::Sound::GraphIO).to receive(:load).and_wrap_original { |m, *a, **k| builds += 1; m.call(*a, **k) }
    run { design :bass, :init, riff }
    expect(builds).to eq(1)
    expect(@session.playing_after_queue?(:bass)).to eq(true)
    expect(@session.arrangement.instance_variable_get(:@checked_build)).to be_nil

    run { stop :bass, ring: false }
    @session.process_buffer
    builds = 0
    run { design :bass, :dnb_reese }
    expect(builds).to eq(1)
    expect(@session.playing_after_queue?(:bass)).to eq(true)
  end

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
    # (ux-notes-1: with sync off the graph has no synced tone, so the walk
    # alone didn't know sync is a build knob, and a held key made a gesture
    # its turn refused; the inspector turns it a step a key)
    4.times { @session.process_buffer }
    info = MB::Sound::UI::Inspect::Gatherer.new.call(@session, { track: :lead, node: nil })
    expect(info.build_knobs).to include(:"lead/sync")
    run { stop :lead, on: :now }
    @session.process_buffer
  end

  it 'refuses design without a track name and with two instruments' do
    expect { run { design } }.to raise_error(ArgumentError, /design names a track/)
    expect { run { design :bass, :dnb_reese, :dnb_pad } }.to raise_error(ArgumentError, /one instrument/)
  end
end

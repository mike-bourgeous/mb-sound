# Build knobs (sound-design-2): a track knob its patch reads while building
# (the init voice's sync, through Tone#sync's enabled:) rebuilds the track
# when turned, at its launch point, as one undo step; ramps and follows of
# one are refused (a structure can't move between two values).
RSpec.describe(MB::Sound::Arrangement::BuildKnobs, :aggregate_failures) do
  after do
    @session&.close
    MB::Sound.rewind
  end

  def run(&block) = MB::Sound::Session.with_context(session: @session) { MB::Sound.instance_eval(&block) }

  def start
    @session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
    run do
      track :lead, :init
      bg :lead, seq(MB::Sound::A3, MB::Sound::C4).n4.loop
    end
    4.times { @session.process_buffer }
  end

  def synced
    MB::Sound::UI::Inspect.roots(@session.ui_graphs[:lead]).flat_map(&:graph).count { |n| n.is_a?(MB::Sound::Tone) && n.sync_source }
  end

  it 'rebuilds the track on its launch point when the knob turns, and undo brings the old graph back' do
    start
    expect(@session.arrangement.build_knob?(:"lead/sync")).to eq(true)
    expect(@session.arrangement.build_knob?(:"lead/cutoff")).to eq(false)
    expect(synced).to eq(0)
    old = @session.ui_graphs[:lead]

    entries = run { turn :"lead/sync", 1 }
    expect(Array(entries).map(&:to_s).join).to include('lands 2:1')
    expect(@session.knobs[:"lead/sync"].build_value).to eq(0) # (the value until the turn lands: the rebuild read 1)
    130.times { @session.process_buffer } # (bar 2 at 120 bpm: 2 s)
    expect(@session.ui_graphs[:lead]).not_to equal(old)
    expect(synced).to be > 0
    expect(@session.knobs[:"lead/sync"].value).to eq(1)

    run { undo(on: :now) }
    4.times { @session.process_buffer }
    expect(synced).to eq(0)
    expect(@session.knobs[:"lead/sync"].value).to eq(0)
  end

  it 'refuses ramps and follows of a build knob, naming the plain turn' do
    start
    expect { run { turn :"lead/sync", 1, over: 1 } }.to raise_error(ArgumentError, /read when lead builds, so it takes plain values \(turn :"lead\/sync", 0\)/)
    expect { run { turn :"lead/sync", follow: :"lead/mix" } }.to raise_error(ArgumentError, /takes plain values/)
  end
end

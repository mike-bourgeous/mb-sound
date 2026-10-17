RSpec.describe(MB::Sound::DemoMethods) do
  # (its own transport: the set sets the tempo and meter of the Session's transport)
  let(:session) { MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, transport: MB::Sound::Sequence::Transport.new(bpm: 120)) }

  after { session.close }

  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  it 'loads the Night Bus set paused at bar 1, saying what to try, and returns it again' do
    doc = nil
    expect { doc = within { MB::Sound.demo } }.to output(/demo :night_bus.*paused at bar 1.*tracks  drums sub bass.*scenes  intro groove.*Try:.*go :groove/m).to_stdout
    expect(doc.kind).to eq(:set)
    expect(doc.form).to be_a(MB::Sound::Form)
    expect(session.players).to be_empty
    expect(session.transport.position).to eq(0)
    expect(session.arrangement.tracks.keys).to include(:drums, :hook, :pad)
    expect(within { MB::Sound.demo }).to equal(doc)

    within { MB::Sound.go(:drop) }
    20.times { session.process_buffer(800) }
    expect(session.players.keys).to include(:drums, :hook)
  end

  it 'asks before loading over players, and replace: true stops them' do
    within { MB::Sound.bg(:hum, 110.hz.at(0.1), on: :now) }
    session.process_buffer(800)
    expect { within { MB::Sound.demo(:night_bus) } }.to raise_error(ArgumentError, /:hum is playing \(stop :all, fade: 0 first, or demo :night_bus, replace: true\)/)
    expect { within { MB::Sound.demo(:night_bus, replace: true) } }.to output(/paused at bar 1/).to_stdout
    expect(session.players).to be_empty
    expect(session.transport.position).to eq(0)
  end

  it 'suggests names for unknown demos and lists the demos' do
    expect { within { MB::Sound.demo(:night_buss) } }.to raise_error(ArgumentError, /No demo :night_buss.*night_bus/)
    expect { MB::Sound.demos }.to output(/:night_bus +"Night Bus: Last Stop"/).to_stdout
  end

  it 'is not taken by Pry or another MB::Sound method' do
    require 'pry'
    expect(Pry::Commands.keys.map(&:to_s)).not_to include('demo', 'demos')
    expect(MB::Sound.method(:demo).owner).to eq(MB::Sound::DemoMethods)
    expect(MB::Sound.method(:demos).owner).to eq(MB::Sound::DemoMethods)
  end
end

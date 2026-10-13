RSpec.describe('bin/songs/night_bus_set.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/night_bus_set.rb', __dir__) } # require: other scripts require_relative it (a second load redefines constants)

  after { MB::Sound.rewind }

  it 'performs the first 14 bars: scenes, a riser, a mistake undone on the next bar, and the drop' do
    session = nil
    path = tmp_path('night_bus.flac')
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out
    begin
      MB::Sound.render(path, bars: 14) do
        MB::Sound.night_bus_set(perform: true)
        session = MB::Sound::Session.current
      end
    ensure
      $stdout = old_stdout
    end

    expect(out.string).to include('go :intro', 'go :build', 'swap :bass, wrong', 'undo', 'go :drop')

    bar = session.transport.bar_length
    landed = session.journal.changes.select { |e| e.status == :landed }
    at = ->(kind, subject) { landed.select { |e| e.kind == kind && e.subject == subject }.map { |e| e.lands.pos / bar + 1 } }

    expect(at.(:scene, :intro)).to eq([1])
    expect(at.(:scene, :build)).to eq([5])
    expect(at.(:scene, :lift)).to eq([9])
    expect(at.(:swap, :bass)).to include(11) # the mistake
    expect(at.(:restore, :bass)).to eq([12]) # undone on the next bar
    expect(at.(:scene, :drop)).to eq([13])
    expect(at.(:bg, :drums)).to eq([5, 13]) # a new kit with a clap is built again
    expect(at.(:stop, :riser)).to eq([13])

    data = MB::Sound.read(path)
    rate = 48000
    bar_frames = (session.transport.seconds(bar) * rate).round
    rms = ->(b) { s = data[0][((b - 1) * bar_frames)...(b * bar_frames)]; Math.sqrt((Numo::DFloat.cast(s)**2).mean) }
    expect(rms.(1)).to be > 0.005           # the pad
    expect(rms.(5)).to be > rms.(1) * 2     # bass and kick join
    expect(rms.(13)).to be > rms.(5)        # the drop
    expect(data[0].abs.max).to be < 0.9
  end
end

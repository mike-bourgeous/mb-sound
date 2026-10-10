RSpec.describe('bin/songs/night_bus_flow.rb') do
  before(:all) { load File.expand_path('../../../bin/songs/night_bus_flow.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'performs the form through the first drop: loop!/onward, a riser fill, a 2/4 gap that rings out' do
    session = nil
    path = tmp_path('last_stop.flac')
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out
    begin
      MB::Sound.render(path, bars: 35) do
        MB::Sound.last_stop(perform: true)
        session = MB::Sound::Session.current
      end
    ensure
      $stdout = old_stdout
    end

    expect(out.string).to include('flow do ... end', 'loop!', 'onward')
    t = session.transport
    expect(session.arrangement.playback.history).to eq([:intro, :groove, :groove, :build, :gap, :drop])
    expect(t.meters.map(&:to_s)).to eq(['bar 1: 4/4', 'bar 33: 2/4', 'bar 34: 4/4'])

    landed = session.journal.changes.select { |e| e.status == :landed }
    at = ->(kind, subject) { landed.select { |e| e.kind == kind && e.subject == subject }.map { |e| t.bar_at(e.lands.pos) } }
    expect(at.(:scene, :groove)).to eq([9, 17])
    expect(at.(:scene, :riser)).to eq([29]) # the build's 4-bar fill
    expect(at.(:scene, :gap)).to eq([33])
    expect(at.(:scene, :drop)).to eq([34])
    expect(t.bar_position(34)).to eq(32.5r)

    # Tracks the gap drops ring out (the drums' tail ends within the gap
    # and its quiet second), the riser fades
    rung = landed.select { |e| e.kind == :rung_out }.map(&:subject)
    expect(rung).to include(:drums, :tension, :hook_rise)
    expect(rung).not_to include(:riser)

    data = MB::Sound.read(path)
    bar_frames = (t.seconds(1) * 48000).round
    rms = ->(from, to) { s = data[0][(from * bar_frames).round...(to * bar_frames).round]; Math.sqrt((Numo::DFloat.cast(s)**2).mean) }
    expect(rms.(0, 8)).to be > 0.01            # the drums
    expect(rms.(8, 16)).to be > rms.(0, 8)     # groove: sub and hook join
    expect(rms.(32, 32.5)).to be < rms.(24, 32) # the gap breathes
    expect(rms.(32.5, 34.4)).to be > rms.(24, 32) # the drop
    expect(data[0].abs.max).to be < 0.9
  end
end

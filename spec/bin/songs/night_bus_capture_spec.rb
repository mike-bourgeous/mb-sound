RSpec.describe('bin/songs/night_bus_capture.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/night_bus_capture.rb', __dir__) } # require: other scripts require_relative it (a second load redefines constants)

  after { MB::Sound.rewind }

  it 'captures the riff at bar 7, records the answer into bar 13, and learns the filter knob' do
    session = nil
    path = tmp_path('capture.flac')
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out
    begin
      MB::Sound.render(path, bars: 15) do
        MB::Sound.night_bus_capture
        session = MB::Sound::Session.current
      end
    ensure
      $stdout = old_stdout
    end

    expect(out.string).to include('arm :keys', 'capture :keys, 2', 'rec 4', 'learn :cut')
    t = session.transport
    landed = session.journal.changes.select { |e| e.status == :landed }
    at = ->(kind, subject) { landed.select { |e| e.kind == kind && e.subject == subject }.map { |e| t.bar_at(e.lands.pos) } }
    expect(at.(:arm, :keys)).to eq([3])
    expect(at.(:capture, :keys)).to eq([7, 13])
    expect(at.(:learn, :cut)).to eq([13])
    expect(landed.find { |e| e.kind == :cc }&.subject).to eq(:cut)

    clips = session.arrangement.captures
    expect(clips.keys).to eq([:keys_1, :keys_2])
    expect(clips[:keys_1].length).to eq(2r)
    expect(clips[:keys_1].events.length).to eq(11)
    expect(clips[:keys_2].length).to eq(4r)
    expect(clips[:keys_2].events.length).to eq(21)

    data = MB::Sound.read(path)
    bar = (240.0 / 126 * 48000).round
    # The captured loop plays in bars 7-8, where the hands rest
    expect(data[0][(6 * bar)...(8 * bar)].abs.max).to be > 0.05
  end
end

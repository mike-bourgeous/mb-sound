RSpec.describe('bin/songs/night_bus_capture.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/night_bus_capture.rb', __dir__) } # require: other scripts require_relative it (a second load redefines constants)

  after { MB::Sound.rewind }

  # The everyday run's case: the first 7 bars (arm at bar 3, the riff
  # captured at bar 7 and looping there)
  it 'arms the keys at bar 3 and captures the riff at bar 7' do
    session = nil
    path = tmp_path('capture7.flac')
    expect {
      MB::Sound.render(path, bars: 7, loudness: false) do
        MB::Sound.night_bus_capture
        session = MB::Sound::Session.current
      end
    }.to output(/arm :keys.*capture :keys, 2/m).to_stdout

    t = session.transport
    landed = session.journal.changes.select { |e| e.status == :landed }
    expect(landed.select { |e| e.kind == :arm && e.subject == :keys }.map { |e| t.bar_at(e.lands.pos) }).to eq([3])
    expect(landed.select { |e| e.kind == :capture && e.subject == :keys }.map { |e| t.bar_at(e.lands.pos) }).to eq([7])
    clip = session.arrangement.captures[:keys_1]
    expect(clip.length).to eq(2r)
    expect(clip.events.length).to eq(11)

    data = MB::Sound.read(path)
    bar = (240.0 / 126 * 48000).round
    expect(data[0][(6 * bar)..].abs.max).to be > 0.05 # (bar 7, to the end)
  end

  # The whole performance (slow tier, SLOW=1)
  it 'captures the riff at bar 7, records the answer into bar 13, and learns the filter knob', :slow do
    session = nil
    path = tmp_path('capture.flac')
    out = StringIO.new
    old_stdout = $stdout
    $stdout = out
    begin
      # (loudness: false: one pass; the song's mastering preset would render
      # it twice to reach its loudness target, which mastering_spec covers)
      MB::Sound.render(path, bars: 15, loudness: false) do
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

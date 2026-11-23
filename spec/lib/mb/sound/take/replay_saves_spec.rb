# Take replays skip library writes (the maintainer, 2026-11-23: "Make
# replays skip save"): save, save!, collect, and promote write nothing and
# commit nothing while a take replays, and later lines still find what the
# take saved (Take::Replay::Saves).
RSpec.describe(MB::Sound::Take::Replay::Saves) do
  let(:transport) { MB::Sound::Sequence::Transport.new(bpm: 120) }
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), transport: transport, channels: 2, buffer_size: 800, realtime: false, raise_errors: true) }
  let(:live_user) { File.dirname(tmp_path('live_user/x')) }
  let(:replay_user) { File.dirname(tmp_path('replay_user/x')) }
  let(:replay_presets) { File.dirname(tmp_path('replay_presets/x')) }

  after { session.close }

  around do |ex|
    old = ENV.to_h.slice('MB_SOUND_USER_PRESETS', 'MB_SOUND_PRESETS')
    ex.run
  ensure
    %w[MB_SOUND_USER_PRESETS MB_SOUND_PRESETS].each { |k| ENV.delete(k) }
    old.each { |k, v| ENV[k] = v }
    MB::Sound::Library.reload!
  end

  # Shelves: the live take saves to +user+ (the user shelf, a git
  # repository its first save makes); a replay gets empty ones.
  def shelves(user:, presets: nil)
    ENV['MB_SOUND_USER_PRESETS'] = user
    presets ? ENV['MB_SOUND_PRESETS'] = presets : ENV.delete('MB_SOUND_PRESETS')
    MB::Sound::Library.reload!
  end

  def lines
    {
      0 => ['x = 330.hz.triangle.at(-12.db)', 'save :rs_t1, x', 'bg :b, preset(:rs_t1)'],
      40 => ['save! :rs_t2, 220.hz.saw.lp4(800).at(-12.db)', 'bg :c, preset(:rs_t2)'],
    }
  end

  # Plays #lines live, recording a take; returns [left channel, take].
  def perform(buffers: 90)
    b = MB::Sound::Take.console_binding
    out = []
    MB::Sound.seed(5)
    t = MB::Sound::Take.new(session: session)
    buffers.times do |i|
      lines.fetch(i, []).each { |code| MB::Sound::Session.with_context(session: session) { t.line(code, b) } }
      out << session.process_buffer[0].dup
    end
    [SpecBuffers.join(out), t]
  end

  def render(replay)
    out = []
    MB::Sound.seed(5)
    replay.render(MB::Sound::NullOutput.new(channels: 2, sleep: false), buffer_sizes: [800], tail: 0) { |mix| out << mix[0].dup }
    SpecBuffers.join(out)
  end

  def files(dir)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).reject { |f| File.basename(f).match?(/\A\.\.?\z/) }
  end

  it 'replays saves into memory: the same samples, nothing written under either shelf, no git, one dim line per skipped line' do
    shelves(user: live_user)
    live = nil
    t = nil
    expect { live, t = perform }.to output(/Saved rs_t1 .*Saved rs_t2 /m).to_stdout
    expect(live.abs.max).to be > 0.01
    expect(File.directory?(File.join(live_user, '.git'))).to eq(true) if MB::Sound::Library::Git.git?

    text = t.to_ruby
    expect(text).to include("  # save skipped in replay (a replay does not write to your library): save :rs_t1, x\n")
    expect(text).to include("  # save skipped in replay (a replay does not write to your library): save! :rs_t2, 220.hz.saw")
    expect(text).to include('choices: [[:save, :rs_t1, :rs_t1]]')
    path = tmp_path('take.rb')
    File.write(path, text)

    shelves(user: replay_user, presets: replay_presets)
    load path
    r = MB::Sound::Take::Replay.last
    data = nil
    printed = capture_stdout { data = render(r) }
    expect(printed.scan('skipped in replay: save :rs_t1, x (a replay does not write to your library)').length).to eq(1)
    expect(printed.scan('skipped in replay: save! :rs_t2').length).to eq(1)
    expect(printed).not_to include('Saved')
    expect(files(replay_user)).to eq([])
    expect(files(replay_presets)).to eq([])
    expect(data.length).to be >= live.length
    expect((data[0...live.length] - live).abs.max).to eq(0)
    expect(MB::Sound::Take::Replay::SAVES.key?(session)).to eq(false)
  end

  it 'keeps a save from a take saved before replays skipped saves (no choices) under the name it gives' do
    shelves(user: replay_user, presets: replay_presets)
    r = MB::Sound::Take::Replay.new(bpm: 120, bar_length: 1, master_gain: 0.5, fade_in: 0, fade_out: 0, rng: nil, ends: 1r) do |rr|
      rr.line(0r, [], "save :rs_old, 440.hz.sine.at(-20.db)\n")
      rr.line(0r, [0r], "bg :a, preset(:rs_old)\n")
    end
    data = nil
    expect { data = render(r) }.to output(/skipped in replay: save :rs_old/).to_stdout
    expect(data.abs.max).to be > 0.01
    expect(files(replay_user)).to eq([])
    expect(files(replay_presets)).to eq([])
  end

  it 'skips collect and promote in replays' do
    shelves(user: replay_user, presets: replay_presets)
    dir = File.join(File.dirname(tmp_path('collect/x')), 'presets')
    r = MB::Sound::Take::Replay.new(bpm: 120, bar_length: 1, master_gain: 0.5, fade_in: 0, fade_out: 0, rng: nil, ends: 1/4r) do |rr|
      rr.line(0r, [], "collect to: #{dir.inspect}\n")
      rr.line(0r, [], "promote :nothing_here\n")
    end
    printed = capture_stdout { render(r) }
    expect(printed).to include('skipped in replay: collect to:')
    expect(printed).to include('skipped in replay: promote :nothing_here')
    expect(File.exist?(dir)).to eq(false)
    expect(files(replay_user)).to eq([])
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end
end

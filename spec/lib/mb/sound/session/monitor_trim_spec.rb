# The monitor trim (Session::MonitorTrim): a live-only listening gain after
# the master chain, the limiter, and the master gain, which renders,
# recordings, taps, and takes never see.
RSpec.describe(MB::Sound::Session::MonitorTrim) do
  around do |ex|
    old = MB::Sound::Session.monitor_gain
    ex.run
  ensure
    MB::Sound::Session.monitor_gain = old
  end

  # Keeps every buffer written to it.
  let(:out_class) {
    Class.new(MB::Sound::NullOutput) {
      def written = @written ||= []
      def write(data)
        written << data.map(&:dup)
        super
      end
      def channel(c) = written.map { |b| b[c] }.reduce(:concatenate)
    }
  }

  let(:keep_class) {
    Class.new {
      attr_reader :buffers
      def initialize = @buffers = []
      def write(bufs) = @buffers << bufs.map(&:dup)
      def close = nil
      def channel(c) = @buffers.map { |b| b[c] }.reduce(:concatenate)
    }
  }

  let(:sessions) { [] }
  after { sessions.each(&:close) }

  def new_session(output:, monitor: nil, realtime: false, master_gain: 1)
    MB::Sound::Session.new(
      output: output, transport: MB::Sound::Sequence::Transport.new(bpm: 120), master_gain: master_gain,
      channels: 2, buffer_size: 800, realtime: realtime, raise_errors: true, monitor: monitor
    ).tap { |s| sessions << s }
  end

  def peak(a) = 20 * Math.log10(a.abs.max)

  it 'is off by default and applies only to sessions that monitor (realtime ones by default)' do
    expect(MB::Sound::Session.monitor_gain).to eq(1)
    expect(new_session(output: out_class.new(channels: 2, sleep: false)).monitor).to eq(false)
    expect(new_session(output: out_class.new(channels: 2, sleep: false), realtime: true).monitor).to eq(true)
    expect(new_session(output: out_class.new(channels: 2, sleep: false), realtime: true, monitor: false).monitor).to eq(false)
  end

  it 'scales only what is written to the output: not the returned mix, taps, or audio recordings' do
    MB::Sound::Session.monitor_gain = 6.db
    out = out_class.new(channels: 2, sleep: false)
    keep = keep_class.new
    s = new_session(output: out, monitor: true)
    tapped = []
    s.add_tap { |mix| tapped << mix[0].dup }
    s.add(100.hz.sine.at(-20.db), name: :tone, on: :now)
    s.record_audio('unused.flac', output: keep)
    mix = Array.new(30) { s.process_buffer(800)[0].dup }.reduce(:concatenate)
    s.stop_recording
    s.process_buffer(800)
    s.recordings.first.wait

    expect(peak(mix)).to be_within(0.05).of(-20)
    expect(peak(out.channel(0)[0...mix.length])).to be_within(0.05).of(-14)
    expect(out.channel(0)[0...mix.length]).to eq(mix * 6.db)
    expect(peak(tapped.reduce(:concatenate))).to be_within(0.05).of(-20)
    expect(peak(keep.channel(0))).to be_within(0.05).of(-20)
  end

  it 'applies after the master chain and its limiter' do
    MB::Sound::Session.monitor_gain = 3.db
    out = out_class.new(channels: 2, sleep: false)
    s = new_session(output: out, monitor: true)
    s.master { |l, r| [l.limit(ceiling: -6, true_peak: false), r.limit(ceiling: -6, true_peak: false)] }
    s.add(100.hz.square, name: :loud, on: :now)
    mix = Array.new(60) { s.process_buffer(800)[0].dup }.reduce(:concatenate)
    tail = 24000...mix.length
    expect(peak(mix[tail])).to be_within(0.2).of(-6)
    expect(peak(out.channel(0)[tail])).to be_within(0.2).of(-3)
  end

  it 'clips peaks it pushes over full scale on the way out, with one warning, and counts them' do
    MB::Sound::Session.monitor_gain = MB::Sound::Session::MonitorTrim::MAX_MONITOR_GAIN
    MB::Sound::Session.instance_variable_set(:@monitor_warned_at, nil)
    out = out_class.new(channels: 2, sleep: false)
    s = new_session(output: out, monitor: true)
    s.add(100.hz.sine.at(-20.db), name: :tone, on: :now) # +27 dB: peaks at +7 dBFS
    expect {
      5.times { s.process_buffer(800) }
    }.to output(/Monitor trim \+27\.0 dB clipped a peak 7\.0 dB over full scale/).to_stderr
    expect(out.channel(0).abs.max).to eq(1)
    expect(s.monitor_clips).to eq(5)
  end

  it 'leaves renders alone' do
    a = tmp_path('a.flac')
    b = tmp_path('b.flac')
    MB::Sound.render(a, 100.hz.sine.at(-20.db), seconds: 0.5)
    MB::Sound::Session.monitor_gain = 12.db
    MB::Sound.render(b, 100.hz.sine.at(-20.db), seconds: 0.5)
    expect(MB::Sound.read(b)).to eq(MB::Sound.read(a))
  end

  it 'is a console command that takes replays skip' do
    expect(MB::Sound.monitor_gain(-6.db).to_db).to be_within(1e-9).of(-6)
    expect(MB::Sound.monitor.to_db).to be_within(1e-9).of(-6)
    expect { MB::Sound.monitor_gain(40.db) }.to raise_error(ArgumentError, /0 to 27 dB/)
    expect { MB::Sound.monitor_gain(-1) }.to raise_error(ArgumentError)
    expect(MB::Sound::Take::FOREGROUND).to include('monitor_gain', 'monitor')
  end

  it 'reaches foreground play only on the live output' do
    MB::Sound::Session.monitor_gain = 6.db
    given = out_class.new(channels: 2, sleep: false, buffer_size: 800)
    MB::Sound.play(100.hz.sine.at(-20.db).until(0.1), output: given, plot: false, quiet: true)
    expect(peak(given.channel(0))).to be_within(0.05).of(-20 + MB::Sound.master_gain.to_db)

    live = out_class.new(channels: 2, sleep: false, buffer_size: 800)
    allow(MB::Sound).to receive(:output).and_return(live)
    MB::Sound.play(100.hz.sine.at(-20.db).until(0.1), plot: false, quiet: true)
    expect(peak(live.channel(0))).to be_within(0.05).of(-14 + MB::Sound.master_gain.to_db)
  end
end

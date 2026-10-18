# The live output's safety limiter (Session::SafetyLimiter, omnibus9).
RSpec.describe(MB::Sound::Session::SafetyLimiter, :aggregate_failures) do
  # A NullOutput that keeps what the Session wrote.
  let(:output) {
    Class.new(MB::Sound::NullOutput) {
      attr_reader :written

      def write(data)
        (@written ||= []) << data.map(&:dup)
        super
      end
    }.new(channels: 2, sleep: false)
  }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def session(**opts)
    MB::Sound::Session.new(
      master_gain: 1, output: output, transport: MB::Sound::Sequence::Transport.new(bpm: 120),
      buffer_size: 800, realtime: false, raise_errors: true, **opts
    ).tap { |s| sessions << s }
  end

  # The written output and the returned mix of +buffers+ buffers.
  def run(s, buffers)
    mixes = Array.new(buffers) { s.process_buffer.map(&:dup) }
    [output.written.last(buffers).transpose.map { |c| c.reduce(:concatenate) }, mixes.transpose.map { |c| c.reduce(:concatenate) }]
  end

  let(:ceiling) { described_class::SAFETY_CEILING.to_f }

  it 'is on by default for realtime Sessions only' do
    expect(session.safety_limiter).to eq(false)
    rt = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: true).tap { |s| sessions << s }
    expect(rt.safety_limiter).to eq(true)
    expect(rt.master_info).to eq('bypass (live output: a safety limiter at -1 dBFS until a master chain is set)')
  end

  it 'holds the live output under -1 dBFS without a master chain, leaving the mix it returns (renders, recordings, taps) alone' do
    s = session(safety_limiter: true)
    s.add([220.hz.sine.at(2), 330.hz.sine.at(0.5)])
    written, mix = run(s, 10)
    expect(mix[0].abs.max).to be > 1.9
    expect(written.map { |c| c.abs.max }.max).to be <= ceiling + 1e-6
    expect(written[0].abs.max).to be > ceiling - 0.01
    # One gain for both channels: the quiet channel comes down as much
    expect(written[1].abs.max).to be < 0.45
  end

  it 'is bit-transparent below the ceiling, and off without safety_limiter (renders)' do
    s = session(safety_limiter: true)
    s.add([220.hz.sine.at(0.8), 330.hz.sine.at(0.5)])
    written, mix = run(s, 5)
    expect(written).to eq(mix)

    plain = session
    plain.add([2.constant, 2.constant])
    w, = run(plain, 1)
    expect(w[0].to_a.uniq).to eq([2.0])
  end

  it 'steps aside for a master chain and comes back with master nil' do
    s = session(safety_limiter: true)
    s.add([2.constant, 2.constant])
    s.master(on: :now) { |mix| mix * 1 }
    w, = run(s, 2)
    expect(w[0].to_a.uniq).to eq([2.0])
    expect(s.safety_limiting?).to eq(false)
    expect(s.master_info).not_to include('safety')

    s.master(on: :now, fade: 0)
    run(s, 2)
    w, = run(s, 2)
    expect(w[0].abs.max).to be <= ceiling + 1e-6
    expect(s.safety_limiting?).to eq(true)
    expect(s.master_info).to include('safety limiter')
  end

  it 'comes after a post-chain master gain and before the monitor trim' do
    old = MB::Sound::Session.monitor_gain
    MB::Sound::Session.monitor_gain = 0.5
    s = session(safety_limiter: true, monitor: true, master_gain_post: true)
    s.master_gain = 4
    s.add([0.5.constant, 0.5.constant])
    w, mix = run(s, 2)
    expect(mix[0][-1]).to eq(2.0)
    expect(w[0][-1]).to be_within(1e-6).of(ceiling * 0.5)
  ensure
    MB::Sound::Session.monitor_gain = old
  end
end

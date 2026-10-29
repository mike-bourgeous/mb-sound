require_relative '../../examples/share_repl'

# The network REPL prototype (examples/share_repl.rb) on localhost: tokens,
# roles, frames and raw viewers, late joiners.
RSpec.describe(ShareRepl::Host, :aggregate_failures) do
  after do
    @socks&.each { |s| s.close rescue nil }
    @host&.stop
  end

  def wait_for(timeout = 10)
    d = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.01 until yield || Process.clock_gettime(Process::CLOCK_MONOTONIC) > d
    yield
  end

  # A viewer on a socket: its own VT replays what it receives.
  def join(token, mode: 'frames')
    s = TCPSocket.new('127.0.0.1', @host.port)
    (@socks ||= []) << s
    ShareRepl::Wire.write(s, 'H', [ShareRepl::PROTOCOL, token, mode, 'truecolor'].join("\n"))
    type, payload = ShareRepl::Wire.read(s)
    return [s, type, payload] unless type == 'S'
    vt = MB::Term::VT.new(8, 40)
    Thread.new do
      while (msg = ShareRepl::Wire.read(s))
        vt.feed(msg[1]) if msg[0] == 'F'
      end
    rescue IOError, SystemCallError
      nil
    end
    [s, vt, payload]
  end

  before do
    @host = described_class.new(command: ['sh', '-c', 'while read line; do echo "said $line"; done'], rows: 8, cols: 40, port: 0, view_token: 'look', fps: 60, log: nil)
    @host.start
  end

  it 'refuses a wrong token' do
    _, type, payload = join('wrong')
    expect([type, payload]).to eq(['E', 'bad token or protocol'])
  end

  it 'sends frames and raw bytes that rebuild the screen, takes keys from read-write viewers only, and gives late joiners the screen' do
    s, frames, size = join(@host.token)
    expect(size).to eq('8 40 rw frames')
    _, raw, = join(@host.token, mode: 'raw')
    v, viewer, vsize = join('look')
    expect(vsize).to eq('8 40 ro frames')

    ShareRepl::Wire.write(s, 'K', "hello\r")
    expect(wait_for { frames.text.include?('said hello') }).to eq(true)
    expect(wait_for { raw.text.include?('said hello') }).to eq(true)
    expect(wait_for { viewer.text.include?('said hello') }).to eq(true)

    ShareRepl::Wire.write(v, 'K', "from the viewer\r") # (read-only: dropped)
    ShareRepl::Wire.write(s, 'K', "again\r")
    expect(wait_for { frames.text.include?('said again') }).to eq(true)
    expect(frames.text).not_to include('viewer')

    _, late, = join(@host.token)
    _, late_raw, = join(@host.token, mode: 'raw')
    expect(wait_for { late.text.include?('said again') && late_raw.text.include?('said again') }).to eq(true)
    expect(late.lines.map(&:rstrip)).to eq(frames.lines.map(&:rstrip))
    expect(late_raw.lines.map(&:rstrip)).to eq(frames.lines.map(&:rstrip))
  end
end

RSpec.describe('ShareRepl.same?') do
  it 'compares tokens' do
    expect(ShareRepl.same?('abc', 'abc')).to eq(true)
    expect(ShareRepl.same?('abc', 'abd')).to eq(false)
    expect(ShareRepl.same?('abc', 'abcd')).to eq(false)
    expect(ShareRepl.same?(nil, 'a')).to eq(false)
  end
end

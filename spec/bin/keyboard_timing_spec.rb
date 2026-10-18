require 'pty'
require 'json'
load File.expand_path('../../bin/keyboard_timing.rb', __dir__) unless defined?(MB::Sound::KeyboardTiming)

# bin/keyboard_timing.rb (ui-api-1 round 3; maintainer, 2026-10-18: "a live
# test that asks me to press chords and fast arps and measures the
# difference")
RSpec.describe('bin/keyboard_timing.rb', :aggregate_failures) do
  it 'reports a synthetic player as a real process (--simulate), with a suggested window' do
    json = tmp_path('timing.json')
    text = `bin/keyboard_timing.rb --simulate -n 4 --json #{json} 2>&1`
    expect($?).to be_success, text
    expect(text).to include('Timer (1 ms sleeps): median', 'Read-loop wake:', 'chord  n   8', 'Suggested chord window:')
    data = JSON.parse(File.read(json))
    expect(data['trials'].keys).to eq(%w[chord arp run])
  end

  it 'says it needs a terminal without one' do
    expect(`bin/keyboard_timing.rb < /dev/null 2>&1`).to include('Not a terminal')
  end

  it 'reads trials from a terminal, keys in one read counted, and stops on q' do
    r, w, pid = PTY.spawn('bin/keyboard_timing.rb', '-n', '1')
    out = +''
    reader = Thread.new { loop { out << r.readpartial(4096) } rescue nil }
    wait = ->(pat) { d = MB::U.clock_now + 30; sleep 0.05 until out.match?(pat) || MB::U.clock_now > d; out.match?(pat) }
    expect(wait.(/chord 1\/1/)).to eq(true), out
    w.write('zcb') # (one write: the keys share a read)
    expect(wait.(/3 keys, gaps 0 0 ms/)).to eq(true), out
    expect(wait.(/arp 1\/1/)).to eq(true), out
    %w[z c b].each { |c| w.write(c); sleep 0.06 }
    expect(wait.(/run 1\/1/)).to eq(true), out
    w.write('q')
    expect(wait.(/Suggested chord window|Can't separate/)).to eq(true), out
    Process.wait(pid)
    expect(out).to include('Keys sharing a read: 3')
  ensure
    reader&.kill
    [r, w].each { |io| io&.close rescue nil }
  end

  it 'separates well-apart gaps and refuses overlapping ones' do
    kt = MB::Sound::KeyboardTiming
    window, overlap = kt.suggest(chord: [0.01, 0.02], arp: [0.06, 0.08], run: [0.07])
    expect(window).to be_within(1e-9).of((0.02 + 0.06) / 2)
    expect(overlap).to eq(0)
    window, overlap = kt.suggest(chord: [0.01, 0.07], arp: [0.05, 0.08], run: [])
    expect(window).to be_nil
    expect(overlap).to be > 0
  end
end

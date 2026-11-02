require 'pty'
require 'open3'
require_relative '../support/module_writer'

# bin/play.rb (play-ui-1): the player screen by file type at 120x40 and
# 80x24, its keys, the plain lines without a terminal or with --no-ui, and a
# narrow terminal (the old text meters raised under 22 columns).
RSpec.describe('bin/play.rb', :aggregate_failures) do
  # (a module stops at its first pattern break: rows of 32 make 3.8 s
  # sections, the whole song 11.5 s)
  let(:mod) {
    w = ModuleWriter
    p0 = w.pattern(4, { [0, 0] => { note: 60, sample: 1 }, [16, 1] => { note: 64, sample: 1, effect: 12, param: 40 }, [31, 0] => { effect: 13, param: 0 } })
    p1 = w.pattern(4, { [0, 2] => { note: 67, sample: 1 }, [31, 0] => { effect: 13, param: 0 } })
    w.mod(tmp_path('play.mod'), samples: [{ name: 'saw', data: w.saw(2000), loop: [1000, 2000] }], patterns: [p0, p1, p0], orders: [0, 1, 2])
  }

  # A one-section module of 1.9 s (16 rows, then a pattern break).
  let(:short_mod) {
    w = ModuleWriter
    p0 = w.pattern(4, { [0, 0] => { note: 60, sample: 1 }, [15, 0] => { effect: 13, param: 0 } })
    w.mod(tmp_path('short.mod'), samples: [{ name: 'saw', data: w.saw(2000), loop: [1000, 2000] }], patterns: [p0], orders: [0])
  }

  # Runs bin/play.rb with +args+ in a +rows+ x +cols+ pty read by a
  # MB::Term::VT.  Yields [text, writer, wait]; returns the exit status.
  def in_pty(*args, rows: 40, cols: 120)
    vt = MB::Term::VT.new(rows, cols, scrollback: 0)
    lock = Mutex.new
    r, w, pid = PTY.spawn({ 'OUTPUT_TYPE' => 'null', 'COLUMNS' => cols.to_s, 'LINES' => rows.to_s }, 'bin/play.rb', *args)
    w.winsize = [rows, cols]
    reader = Thread.new do
      loop do
        d = r.readpartial(65_536)
        lock.synchronize do
          vt.feed(d)
          x = vt.take_replies
          w.write(x) unless x.empty?
        end
      end
    rescue IOError, SystemCallError
      nil
    end
    text = -> { lock.synchronize { vt.text } }
    wait = lambda { |what, t = 40|
      d = MB::U.clock_now + t
      until MB::U.clock_now > d
        return true if what.is_a?(Regexp) ? text.call.match?(what) : text.call.include?(what)
        sleep 0.05
      end
      false
    }
    yield text, w, wait
    status = nil
    d = MB::U.clock_now + 30
    status = Process.wait2(pid, Process::WNOHANG)&.last until status || MB::U.clock_now > d || !sleep(0.05)
    reader.join(1)
    status
  ensure
    if pid && !status
      Process.kill(:KILL, pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  it "shows a module's pattern rows and VUs, and acts on the player's keys" do
    status = in_pty(mod, 'spec/test_data/arp_a7.flac') do |text, w, wait|
      %w[PATTERN MASTER FILE PLAYLIST play.mod].each { |s| expect(wait.(s)).to eq(true), "#{s}\n#{text.call}" }
      expect(wait.(/C-4 01/)).to eq(true), text.call
      expect(wait.('MOD, musical')).to eq(true), text.call
      expect(text.call).to include('played of 4')
      w.write(' ')
      expect(wait.('paused (Space plays on)')).to eq(true), text.call
      w.write(' ')
      expect(wait.(/ playing/)).to eq(true), text.call
      w.write("\e[B") # Down: the next section
      expect(wait.(/p01 \(section 2 of 3\)/)).to eq(true), text.call
      w.write("\e[C") # Right: a bar
      expect(wait.(/bar \d+/)).to eq(true), text.call
      w.write('-')
      expect(wait.('volume -2 dB')).to eq(true), text.call
      w.write('+')
      w.write('+')
      expect(wait.('0 dB is the top')).to eq(true), text.call
      w.write('?')
      expect(wait.(/Player.*q Esc +quit/m)).to eq(true), text.call # the key list, the player's own
      w.write("\e") # (closes it: back to the player's keys)
      w.write('n') # the next file: an audio file's screen
      expect(wait.('OVERVIEW')).to eq(true), text.call
      w.write('q')
    end
    expect(status).to be_success
  end

  it "shows an audio file's overview and info at 80x24, and ends at the end of the playlist" do
    status = in_pty('spec/test_data/arp_a7.flac', rows: 24, cols: 80) do |text, _w, wait|
      %w[OVERVIEW MASTER PLAYLIST arp_a7.flac].each { |s| expect(wait.(s)).to eq(true), "#{s}\n#{text.call}" }
    end
    expect(status).to be_success # (it exits by itself after the file)
  end

  it "shows a MIDI file's notes as a piano roll" do
    status = in_pty('spec/test_data/c_major.mid') do |text, w, wait|
      %w[NOTES FILE c_major.mid].each { |s| expect(wait.(s)).to eq(true), "#{s}\n#{text.call}" }
      expect(wait.('▬')).to eq(true), text.call
      w.write('q')
    end
    expect(status).to be_success
  end

  it "plays in a terminal too narrow for its screen without raising" do
    status = in_pty('spec/test_data/arp_a7.flac', rows: 10, cols: 20) { |_text, _w, _wait| nil }
    expect(status).to be_success
  end

  it 'prints plain lines without a terminal, and with --no-ui' do
    out, err, status = Open3.capture3({ 'OUTPUT_TYPE' => 'null' }, 'bin/play.rb', 'spec/test_data/arp_a7.flac', short_mod)
    expect(status).to be_success, err
    expect(MB::U.remove_ansi(err)).to include('Playing arp_a7.flac', 'Playing short.mod (0:01', 'MOD, musical')
    expect(out).not_to include("\e[?1049h") # (no screen)

    status = in_pty('--no-ui', 'spec/test_data/arp_a7.flac') do |text, _w, wait|
      expect(wait.('Playing arp_a7.flac')).to eq(true), text.call
    end
    expect(status).to be_success
  end

  it "says which files it couldn't play" do
    _, err, status = Open3.capture3({ 'OUTPUT_TYPE' => 'null' }, 'bin/play.rb', 'nope.flac', 'spec/test_data/arp_a7.flac')
    expect(status).to be_success
    expect(MB::U.remove_ansi(err)).to include("Can't play nope.flac", 'Playing arp_a7.flac')
  end
end

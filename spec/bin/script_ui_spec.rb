require 'pty'

# Scripts' --ui screens (ux-1 item 18): a song plays in a screen without a
# console and stays on its final meters until q; a synth starts with the
# screen's keyboard playing it (no MIDI device in the container).
RSpec.describe('bin/ scripts with --ui', :aggregate_failures) do
  # Runs +args+ in a 40x140 pty read by a UI::VT.  Yields [text, writer,
  # wait]; returns the exit status.
  def in_pty(*args)
    vt = MB::Sound::UI::VT.new(40, 140, scrollback: 0)
    lock = Mutex.new
    r, w, pid = PTY.spawn({ 'OUTPUT_TYPE' => 'null', 'COLUMNS' => '140', 'LINES' => '40' }, *args)
    w.winsize = [40, 140]
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
    _, status = Process.wait2(pid)
    reader.join(1)
    status
  ensure
    if pid && !status
      Process.kill(:KILL, pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  it 'plays a song in the :show screen, keeps the final meters until q' do
    status = in_pty('bin/songs/tempo_song.rb', '--ui', '-b', '1') do |text, w, wait|
      expect(wait.(' PLAY ')).to eq(true), text.call
      # (panes draw at their own rates after the status line: wait for each, a loaded machine is slower)
      %w[TRACKS MASTER frequency\ (Hz) q\ quit\ \ Space\ pause].each { |s| expect(wait.(s)).to eq(true), "#{s}\n#{text.call}" }
      w.write(' ')
      expect(wait.('paused: Space plays on')).to eq(true), text.call
      w.write(' ')
      expect(wait.('ended: q quits')).to eq(true), text.call
      expect(text.call).to match(/S -\d+\.\d LUFS/) # the final meters stay
      w.write('q')
    end
    expect(status).to be_success
  end

  it 'steps bars with Right and Left and quits a song screen with Esc (ux-r3 items 42, 43)' do
    status = in_pty('bin/songs/tempo_song.rb', '--ui', '-b', '8') do |text, w, wait|
      expect(wait.(' PLAY ')).to eq(true), text.call
      w.write("\e[C")
      expect(wait.('bar 2')).to eq(true), text.call
      sleep 0.1
      w.write("\e[C")
      expect(wait.('bar 3')).to eq(true), text.call # from the previous target
      sleep 0.1
      w.write("\e[D")
      expect(wait.(/bar [23]\b/)).to eq(true), text.call
      sleep 0.7
      w.write("\e")
    end
    expect(status).to be_success
  end

  it "starts a synth's screen in KEYS mode, the keyboard playing it" do
    status = in_pty('bin/synths/acid.rb', '--ui') do |text, w, wait|
      expect(wait.(' KEYS ')).to eq(true), text.call
      6.times { w.write('z'); sleep 0.15 }
      expect(wait.(/L █/, 10)).to eq(true), text.call # the master meter moved
      w.write("\x03") # keys off, back to PLAY
      expect(wait.(' PLAY ')).to eq(true), text.call
      w.write('q')
    end
    expect(status).to be_success
  end
end

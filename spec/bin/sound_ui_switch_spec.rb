require_relative '../support/ui_helpers'

# Switching screens in the console (ux-r3 item 41): tiles -> band ->
# tiles -> off, typed at the prompt and from the palette.  Each time the
# prompt is on screen with the cursor on it, the REPL lines the tiles
# held are printed again on the normal screen, and a line being edited
# survives a switch made from the palette.
RSpec.describe('bin/sound.rb switching between ui :tiles and the band', :aggregate_failures) do
  it 'keeps the REPL history and the prompt through tiles -> band -> tiles -> off' do
    require 'pty'
    rows, cols = 30, 110
    vt = MB::Term::VT.new(rows, cols, scrollback: 200)
    lock = Mutex.new
    env = { 'MB_SOUND_HELP_DIR' => tmp_path('help'), 'COLUMNS' => cols.to_s, 'LINES' => rows.to_s, 'OUTPUT_TYPE' => 'null' }
    r, w, pid = PTY.spawn(env, 'bin/sound.rb')
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
    wait = lambda { |what, t = 20|
      d = MB::U.clock_now + t
      until MB::U.clock_now > d
        s = text.call
        return true if what.is_a?(Regexp) ? s.match?(what) : s.include?(what)
        sleep 0.03
      end
      false
    }
    type = ->(s) { s.each_char { |c| w.write(c); sleep 0.003 } }
    cursor_line = -> { lock.synchronize { vt.lines[vt.row].to_s } }
    prompt = /sound\.rb \[\d+\] MB::Sound\(0\) > /

    expect(wait.(prompt, 60)).to eq(true), text.call

    # Tiles, with some history in the REPL pane
    type.("ui :tiles\r")
    expect(wait.(' REPL ')).to eq(true), text.call
    type.("puts 'alpha ' * 3\r")
    expect(wait.('alpha alpha alpha')).to eq(true), text.call
    type.("puts 'beta ' * 3\r")
    expect(wait.('beta beta beta')).to eq(true), text.call

    # Typed at the prompt: tiles -> band.  The pane's lines come back on
    # the normal screen above the band, and the prompt follows them
    type.("ui :mini\r")
    d = MB::U.clock_now + 10
    sleep 0.05 while lock.synchronize { vt.alt? } && MB::U.clock_now < d
    expect(lock.synchronize { vt.alt? }).to eq(false)
    expect(wait.(/=> #<UI::Band :mini/)).to eq(true), text.call
    expect(text.call).to include('alpha alpha alpha', 'beta beta beta')
    expect(wait.(/ui :mini *\n=> #<UI::Band :mini[^\n]*\n#{prompt.source} *\n/)).to eq(true), text.call
    expect(cursor_line.call).to match(prompt)

    # Band -> tiles -> (palette) band: the console runs the switch (see
    # UI::Switch), and a half-typed line survives
    type.("ui :tiles\r")
    expect(wait.(' REPL ')).to eq(true), text.call
    type.("puts 'gamma'\r")
    expect(wait.(/^gamma\b/)).to eq(true), text.call
    type.('1 + 4')
    sleep 0.3
    w.write("\x1d") # NAV
    expect(wait.(' NAV ')).to eq(true), text.call
    type.(':')
    sleep 0.3
    type.("ui :mini\r")
    d = MB::U.clock_now + 10
    sleep 0.05 while lock.synchronize { vt.alt? } && MB::U.clock_now < d
    expect(lock.synchronize { vt.alt? }).to eq(false), text.call
    expect(wait.(/#{prompt.source}1 \+ 4/)).to eq(true), text.call
    expect(text.call).to include('gamma')
    expect(cursor_line.call).to match(/#{prompt.source}1 \+ 4/)
    type.("\r")
    expect(wait.('=> 5')).to eq(true), text.call

    # Tiles -> off
    type.("ui :tiles\r")
    expect(wait.(' REPL ')).to eq(true), text.call
    type.("puts 'delta'\r")
    expect(wait.(/^delta\b/)).to eq(true), text.call
    type.("ui off\r")
    d = MB::U.clock_now + 10
    sleep 0.05 while lock.synchronize { vt.alt? } && MB::U.clock_now < d
    expect(wait.(/^delta *\n.*ui off *\n=> nil *\n#{prompt.source}/m)).to eq(true), text.call
    expect(cursor_line.call).to match(prompt)

    type.("exit\r")
    _, status = Process.wait2(pid)
    expect(status).to be_success
  ensure
    Process.kill(:KILL, pid) rescue nil if pid && status.nil?
    reader&.kill
    [r, w].each { |io| io&.close rescue nil }
  end
end

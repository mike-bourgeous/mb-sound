require_relative '../../../../support/ui_helpers'
require 'pty'
require 'io/console'
require 'pry'
require 'mb/sound/ui/nudge_keys'

# The prompt's number nudge in Reline's multiline editor (a pty running
# Reline alone, as prompt_spec does) and its history entries.  The whole
# console in a pty, with a set playing, is spec/bin/sound_nudge_spec.rb; the
# tiles' REPL pane is in tiles_nudge_spec.rb.
RSpec.describe(MB::Sound::UI::NudgeKeys, :aggregate_failures) do
  # Reline reading +lines+ lines in a pty with EnterSubmits and NudgeKeys;
  # +keys+ typed (:wait waits past the nudge's settle time).  Returns
  # [what each readmultiline returned, refusal reasons].
  def read_lines(*keys, lines: 3)
    script = <<~RUBY
      $LOAD_PATH.unshift #{File.expand_path('../../../../../lib', __dir__).inspect}, #{File.expand_path('../../../../../gems/mb-term/lib', __dir__).inspect}
      require 'reline'
      require 'prism'
      require 'mb/term'
      require 'mb/sound/ui/prompt'
      require 'mb/sound/ui/nudge_keys'
      MB::Sound::UI::EnterSubmits.install!
      MB::Sound::UI::NudgeKeys.install!
      MB::Sound::UI::NudgeKeys.handler = ->(r) { $stdout.puts "REFUSED:\#{r}" }
      $stdout.sync = true
      #{lines}.times do
        text = Reline.readmultiline('> ', false) { |t| Prism.parse(t).success? }
        puts "RESULT:\#{text.inspect}"
      end
      puts 'DONE'
    RUBY
    path = tmp_path('nudge.rb')
    File.write(path, script)
    r, w, pid = PTY.spawn({ 'TERM' => 'xterm', 'INPUTRC' => '/dev/null' }, RbConfig.ruby, path)
    w.winsize = [24, 80]
    out = +''
    lock = Mutex.new
    reader = Thread.new { loop { d = r.readpartial(4096); lock.synchronize { out << d }; w.write("\e[1;1R") if d.include?("\e[6n") } rescue nil }
    wait_until!('the script\'s prompt') { lock.synchronize { out.include?('> ') } }
    keys.each { |k| k == :wait ? sleep(0.4) : (w.write(k); sleep 0.05) }
    wait_until!("DONE or #{lines} results", timeout: 15) { lock.synchronize { out.include?('DONE') || out.scan('RESULT:').length >= lines } }
    text = lock.synchronize { out.dup }
    [text.scan(/RESULT:(.*)/).flatten.map(&:strip), text.scan(/REFUSED:(.*)/).flatten.map(&:strip)]
  ensure
    Process.kill(:KILL, pid) rescue nil
    Process.wait(pid) rescue nil
    reader&.join(1)
  end

  up = "\e[1;3A"
  down = "\e[1;3B"
  prev_number = "\e[1;4D"
  next_number = "\e[1;4C"

  it 'steps the number at the cursor and runs the line; the line comes back with the cursor on the same digit' do
    # Typed, then the cursor to 10's last digit (end of line: 20 first)
    results, refused = read_lines('f(10, 20)', prev_number, prev_number, up, :wait, '_', "\r", lines: 2)
    expect(results).to eq(['"f(11, 20)"', '"f(1_1, 20)"']) # (the _ typed before the last digit)
    expect(refused).to eq([])
  end

  it 'runs the line once for keys arriving together (a held key, type-ahead), with the last text' do
    results, = read_lines('f(10, 20)', prev_number, down + down + down + down, :wait, "\e[1;7A", :wait, lines: 2)
    expect(results).to eq(['"f(10, 16)"', '"f(10, 26)"']) # (Ctrl-Alt-Up: coarse, 10 steps)
  end

  it 'moves to the nearest number first when the cursor is on none, and jumps between numbers' do
    results, = read_lines('g(1.5, :h13, "7")', "\e[H", up, :wait, up, :wait, lines: 1)
    expect(results).to eq(['"g(1.6, :h13, \\"7\\")"']) # (Home, then the first press only moved)

    # Home, the first number, the second; then back to the first
    results, = read_lines('h(1, 2, 3)', "\e[H", next_number, next_number, up, :wait, prev_number, down, :wait, lines: 2)
    expect(results).to eq(['"h(1, 3, 3)"', '"h(0, 3, 3)"'])
  end

  it 'takes the fallback key forms: Esc then an arrow, and the "meta" forms' do
    results, = read_lines('k(5)', "\e[D", "\e\e[A", :wait, "\e[1;9B", :wait, "\e[1;9B", :wait, lines: 3)
    expect(results).to eq(['"k(6)"', '"k(5)"', '"k(4)"'])
  end

  it 'only edits an incomplete buffer, and refuses where there is no number or no finer step' do
    results, refused = read_lines('f(1, ', up, :wait, up, :wait, "\x05", "3)\r", lines: 1)
    expect(results).to eq(['"f(2, 3)"'])
    expect(refused).to eq([])

    results, refused = read_lines('seq(A1, A4)', up, :wait, 'x(2)', "\e[D", "\e[1;4A", :wait, "\x05\x15", "1\r", lines: 1)
    expect(results).to eq(['"1"'])
    expect(refused).to eq(['no number on this line', '2 is an Integer: write 2.0 for finer steps'])
  end

  describe MB::Sound::UI::NudgeHistory do
    it 'keeps one entry for a run of nudges beside the recalled line, and saves the latest when the next line comes' do
      saved = []
      h = Pry::History.new(history: [])
      h.saver = ->(line) { saved << line }
      MB::Sound::UI::NudgeKeys.install!
      h.push('fx :d, ->{ it.lp4(300) }')
      %w[301 302 303].each do |v|
        MB::Sound::UI::NudgeKeys.submitting("fx :d, ->{ it.lp4(#{v}) }")
        h << "fx :d, ->{ it.lp4(#{v}) }" # (as Pry::Instance pushes)
      end
      expect(h.to_a).to eq(['fx :d, ->{ it.lp4(300) }', 'fx :d, ->{ it.lp4(303) }'])
      expect(saved).to eq(['fx :d, ->{ it.lp4(300) }'])
      h.push('changes')
      expect(h.to_a.last(2)).to eq(['fx :d, ->{ it.lp4(303) }', 'changes'])
      expect(saved).to eq(['fx :d, ->{ it.lp4(300) }', 'fx :d, ->{ it.lp4(303) }', 'changes'])

      # A later run starts a new entry
      MB::Sound::UI::NudgeKeys.submitting('changes 1')
      h.push('changes 1')
      expect(h.to_a.length).to eq(4)
      MB::Sound::UI::NudgeHistory.flush
      expect(saved.last).to eq('changes 1')

      # Lines Reline already added (readline with add_history: the tiles'
      # own Pry thread) aren't added twice
      h.push('f(1)')
      %w[2 3].each do |v|
        h.instance_variable_get(:@history) << "f(#{v})"
        MB::Sound::UI::NudgeKeys.submitting("f(#{v})")
        h << "f(#{v})"
      end
      expect(h.to_a.last(2)).to eq(['f(1)', 'f(3)'])
    ensure
      MB::Sound::UI::NudgeHistory.pending = nil
    end

    # followups-1 (the maintainer: "up-arrow, page-up, and ^r search order
    # not returning recent commands first"): consoles append to one file as
    # lines are typed, interleaved; a line typed again, and every exit,
    # stood in many places
    it 'keeps each line at its newest place, from the file of interleaved sessions and when typed again' do
      MB::Sound::UI::NudgeKeys.install!
      path = tmp_path('pry_history')
      # (three consoles' lines as typed, a1 rerun in between, each ending with exit)
      File.write(path, ['a1 = 1', 'b1 = 1', 'track(:t) { 1 }', 'a2 = 2', 'exit', 'b2 = 2', 'a1 = 1', 'track(:t) { 1 }', 'exit', 'b3 = 3', 'exit'].join("\n") + "\n")
      h = Pry::History.new(history: [], file_path: path)
      h.load
      expect(h.to_a).to eq(['b1 = 1', 'a2 = 2', 'b2 = 2', 'a1 = 1', 'track(:t) { 1 }', 'b3 = 3', 'exit'])

      # Typed again: moved to the end, and appended to the file as typed
      h.push('a2 = 2')
      expect(h.to_a.last(2)).to eq(['exit', 'a2 = 2'])
      expect(h.to_a.count('a2 = 2')).to eq(1)
      expect(File.readlines(path, chomp: true).last).to eq('a2 = 2')
      h.push('a2 = 2') # (a repeat of the last: as before, nothing more)
      expect(h.to_a.count('a2 = 2')).to eq(1)

      # A nudged line equal to an older entry: one copy, at the end
      MB::Sound::UI::NudgeKeys.submitting('b2 = 2')
      h.push('b2 = 2')
      expect(h.to_a.last).to eq('b2 = 2')
      expect(h.to_a.count('b2 = 2')).to eq(1)
    ensure
      MB::Sound::UI::NudgeHistory.flush
      MB::Sound::UI::NudgeHistory.pending = nil
    end
  end
end

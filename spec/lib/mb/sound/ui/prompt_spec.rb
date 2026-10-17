require 'pty'

# The console's prompts and Enter (ux-1 items 5-7).
RSpec.describe(MB::Sound::UI::Prompt, :aggregate_failures) do
  let(:prompt) { described_class }

  it 'lists open constructs, outermost first' do
    expect(prompt.open_constructs("[1, 2].each do |x|\n  foo(x, {a: 1,\n")).to eq(['do', '(', '{'])
    expect(prompt.open_constructs("def f\n  if x\n    y = 1 if z\n")).to eq(%w[def if])
    expect(prompt.open_constructs("while x do\n  a = <<~T\n")).to eq(%w[while <<~T])
    expect(prompt.open_constructs("x = \"abc\n")).to eq(['"'])
    expect(prompt.open_constructs("s = \"a\#{b\n")).to eq(['"', '#{'])
    expect(prompt.open_constructs("x = 1 unless y\nbegin\nend\n")).to eq([])
    expect(prompt.open_constructs("y = if x\n")).to eq(['if'])
    expect(prompt.open_constructs(":sym; %w[a\n")).to eq(['%w['])
  end

  it 'aligns the continuation prompt to the main prompt, dim, naming what is open' do
    pry = double(input_ring: double(count: 12))
    main = prompt.main('MB::Sound', 0, pry)
    expect(main).to include('[12]')
    expect(main).not_to match(/\d+:\d+ \d+%/) # no position or load
    width = prompt.visible_width(main)
    cont = prompt.continuation("x.each do |y|\n  z(\n", main)
    expect(prompt.visible_width(cont)).to eq(width)
    expect(cont).to start_with("\1\e[2m\2").and end_with("\1\e[0m\2")
    expect(cont).to match(/do \( (…|\.\.) > /)
    expect(prompt.lines(['a do', 'b', 'c'])).to eq([prompt.last, prompt.continuation("a do\n"), prompt.continuation("a do\nb\n")])
  end

  # Reline's multiline editor in a pty with EnterSubmits: +keys+ typed,
  # returning what readmultiline returned.
  def readmultiline(*keys)
    script = <<~RUBY
      $LOAD_PATH.unshift #{File.expand_path('../../../../../lib', __dir__).inspect}
      require 'reline'
      require 'prism'
      require 'mb/sound/ui/prompt'
      MB::Sound::UI::EnterSubmits.install!
      $stdout.sync = true
      text = Reline.readmultiline('> ', false) { |t| Prism.parse(t).success? }
      puts "RESULT:\#{text.inspect}"
    RUBY
    path = tmp_path('rl.rb')
    File.write(path, script)
    r, w, pid = PTY.spawn({ 'TERM' => 'xterm', 'INPUTRC' => '/dev/null' }, RbConfig.ruby, path)
    w.winsize = [24, 80]
    out = +''
    reader = Thread.new { loop { d = r.readpartial(4096); out << d; w.write("\e[1;1R") if d.include?("\e[6n") } rescue nil }
    sleep 0.05 until out.include?('> ') || reader.join(0) && true
    keys.each { |k| w.write(k); sleep 0.08 }
    deadline = MB::U.clock_now + 5
    sleep 0.02 until out.include?('RESULT:') || MB::U.clock_now > deadline
    out[/RESULT:(.*)/, 1]&.strip
  ensure
    Process.kill(:KILL, pid) rescue nil
    Process.wait(pid) rescue nil
  end

  it 'runs a complete buffer on Enter from any line and column; Alt-Enter and an incomplete buffer get a new line' do
    # Edit the 2 on the first line of a two-line command, then Enter there
    expect(readmultiline("[1,\r", "2].sum", "\e[A", "\e[D", "\r")).to eq('"[1,\n2].sum"')
    # Enter mid-line in one line
    expect(readmultiline('6 * 7', "\e[D\e[D", "\r")).to eq('"6 * 7"')
    # A line typed ahead while a command ran (the tty's ICRNL made its Enter "\n")
    expect(readmultiline("6 * 7\n")).to eq('"6 * 7"')
    # Alt-Enter: a new line even in a complete buffer
    expect(readmultiline('1', "\e\r", '2', "\r")).to eq('"1\n2"')
  end
end

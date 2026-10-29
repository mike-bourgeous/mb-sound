# Records what a Pry session writes to its terminal (Reline's redraws,
# colored results, a ls listing, an exception) into fixtures/pry_session.bin,
# the "Pry transcript" input of term_bench.rb.  Typing goes one key at a
# time, so the bytes include Reline's per-key redraws.
#
#     ruby bench/capture_pry.rb [OUT]
require 'pty'
require 'io/console'

out_path = ARGV[0] || File.join(__dir__, 'fixtures', 'pry_session.bin')
lines = [
  '1 + 2',
  'x = (1..20).map { |i| i * i }',
  'x.select(&:even?).sum',
  '{ name: "bass", cutoff: 800.0, notes: %w[a c e] }',
  'ls Comparable',
  'def hello(name) = "hello, #{name}"',
  'hello("terminal")',
  '"long " * 30',
  'raise ArgumentError, "oops"',
  'Array.instance_methods.first(40)',
  'exit',
]

env = { 'TERM' => 'xterm-256color', 'COLUMNS' => '100', 'LINES' => '30', 'PAGER' => 'cat' }
code = 'require "pry"; Pry.config.pager = false; Pry.config.history_file = File::NULL; Pry.start'
captured = +''.b
PTY.spawn(env, RbConfig.ruby, '-e', code) do |r, w, pid|
  r.winsize = [30, 100] rescue nil
  reader = Thread.new do
    loop do
      captured << r.readpartial(65536)
    rescue EOFError, Errno::EIO
      break
    end
  end
  # Answer cursor position queries (Reline asks) as a terminal would
  answer = Thread.new do
    seen = 0
    loop do
      sleep 0.01
      n = captured.scan("\e[6n").length
      (n - seen).times { w.write("\e[1;1R") }
      seen = n
      break unless reader.alive?
    end
  end
  sleep 1.5
  lines.each do |line|
    line.each_char do |c|
      w.write(c)
      sleep 0.004
    end
    w.write("\r")
    sleep 0.3
  end
  Process.wait(pid)
  reader.join(2)
  answer.kill
end
File.binwrite(out_path, captured)
puts "#{captured.bytesize} bytes, #{captured.count("\e")} escape sequences -> #{out_path}"

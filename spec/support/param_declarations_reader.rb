# Reads the param declarations of the bin/ scripts named on the command
# line for spec/bin/param_declarations_spec.rb: one fork per script (so
# the scripts' constants stay apart), forked from this small process
# rather than the spec process (fix-batch-1101: a fork costs about its
# parent's size, 3 ms at 92 MB and 20 ms at 488 MB, and the spec processes
# of a parallel run grow past 1 GB, so the 141 scripts took 17.4 s at
# PARALLEL=8 against 3.6 s alone; this process stays near 100 MB, 4.2 s
# with its start).  Writes a Marshal dump of
# { file => nil | [:error, message] | [kind, [[problems, built, text], ...]] }
# to stdout.
$LOAD_PATH.unshift(File.expand_path('../../lib', __dir__))
require 'mb/sound'
require_relative 'param_guard'
require 'pry' # (16 scripts load it: once here instead of in each fork, 0.13 s each)

out = $stdout.dup
$stdout.reopen(File::NULL)

results = ARGV.to_h do |file|
  rd, wr = IO.pipe
  pid = fork do
    rd.close
    result = begin
      found = MB::Sound::ScriptRunner.declarations_of(file)
      found && [found[0], found[1].map { |sp| [*ParamGuard.check(sp.param), sp.param.to_ruby] }]
    rescue Exception => e # rubocop:disable Lint/RescueException
      [:error, "#{e.class}: #{e.message}"]
    end
    wr.write(Marshal.dump(result))
    wr.close
    exit!(0)
  end
  wr.close
  data = rd.read
  rd.close
  Process.wait(pid)
  [file, data.empty? ? [:error, "the fork for #{file} exited with #{$?.inspect}"] : Marshal.load(data)]
end

out.write(Marshal.dump(results))
out.close

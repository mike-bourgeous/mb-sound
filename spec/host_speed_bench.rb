# A fixed workload that measures a machine's speed for spec time budgets
# (spec/parallel_specs.rb, #host_speed; omnibus11, 2026-10-22).  rake
# spec:parallel runs PARALLEL copies at once, as the suite's processes would
# run, and scales the budgets in spec/time_budgets.yml by the median time
# over the reference machine's.  Prints the fastest of three passes in
# seconds.  Keep the workload fixed: changing it changes every host's
# calibration (then update `reference:` in spec/time_budgets.yml and remove
# tmp/spec_host_speed.json).
#
# The work is what specs spend their time on: graph sampling (Ruby
# dispatch plus C kernels) and plain Ruby objects (Hashes, Arrays, Strings).
$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'mb/sound'

def pass
  MB::Sound.seed(1)
  graph = (110.hz.saw.filter(:lowpass, cutoff: 3.hz.lfo.at(300..2000), quality: 2) + 220.hz.triangle * 0.3).softclip
  env = MB::Sound.adsr(0.01, 0.1, 0.5, 0.2)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  2000.times { graph.sample(800) }
  1000.times { env.sample(800) }
  objects = 300_000.times.map { |i| { i => [i.to_s, i * 2.5, :"k#{i % 97}"] } }
  objects.sort_by! { |h| -h.keys.first }
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end

pass # warm up
puts format('%.4f', 3.times.map { pass }.min)

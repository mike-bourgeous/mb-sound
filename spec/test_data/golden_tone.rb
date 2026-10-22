# A stand-in "song script" for spec/lib/mb/sound/sound_guard_spec.rb: writes
# 1.5 s of a stereo saw chord with a click every half second, taking the
# script runner's -q -f -o OUT options plus --gain DB.
#   ruby -Ilib spec/test_data/golden_tone.rb -q -f -o out.flac --gain -1
require 'mb-sound'

out = nil
gain = 0.0
args = ARGV.dup
until args.empty?
  case (a = args.shift)
  when '-q', '-f' then nil
  when '-o' then out = args.shift
  when '--gain' then gain = Float(args.shift)
  else abort "golden_tone.rb: unknown option #{a}"
  end
end
abort 'golden_tone.rb: -o OUT is required' unless out

n = 72000
t = Numo::DFloat.new(n).seq / 48000
saw = ->(f) { 2 * ((t * f) % 1) - 1 }
l = saw.(220) * 0.2 + saw.(330) * 0.1
r = saw.(220) * 0.2 + saw.(277.2) * 0.1
(0...3).each { |i| s = i * 24000; l[s...(s + 200)] += 0.5; r[s...(s + 200)] += 0.5 }
g = 10**(gain / 20)
MB::Sound.write(out, [l * g, r * g], sample_rate: 48000, overwrite: true)

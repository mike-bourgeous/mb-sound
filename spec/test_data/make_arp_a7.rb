# Generates spec/test_data/arp_a7.flac: a 0.4 s triangle arp, Am7 then Amaj7
# from A4, 50 ms per note with a fast attack and 30 dB decay, alternate
# notes panned slightly left and right, 1 ms fades at each end.
require 'mb/sound'

notes = %w[A4 C5 E5 G5 A4 Cs5 E5 Gs5].map { |n| MB::Sound.const_get(n) }
len = 2400 # 50 ms at 48 kHz
env = Numo::SFloat.linspace(0, 1, 48).concatenate(Numo::SFloat.linspace(0, -30, len - 48).map { |db| 10 ** (db / 20) })
env[-48..] *= Numo::SFloat.linspace(1, 0, 48) # 1 ms fade so notes don't click

l = []
r = []
notes.each_with_index do |n, i|
  wave = n.frequency.hz.triangle.at(0.5).sample(len).dup * env
  angle = ((i.even? ? -0.3 : 0.3) + 1) * Math::PI / 4 # equal-power pan
  l << wave * (Math.cos(angle) * Math.sqrt(2))
  r << wave * (Math.sin(angle) * Math.sqrt(2))
end

data = [l.reduce(:concatenate), r.reduce(:concatenate)]
MB::Sound.write('spec/test_data/arp_a7.flac', data, sample_rate: 48000, overwrite: true)
puts "notes: #{notes.map { |n| "#{n.name} #{n.frequency.round(1)} Hz" }.join(', ')}"
puts format('length %.3f s, peaks L %.3f R %.3f', data[0].length / 48000.0, data[0].abs.max, data[1].abs.max)

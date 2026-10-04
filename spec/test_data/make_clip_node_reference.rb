# Records the old ClipNode outputs used as the reference in notes_spec and
# clip_source_spec (spec/support/clip_node_reference.rb).  Kept for the
# record: ClipNode was removed after this ran at fbc075d, so it only runs
# on that commit:
#     bundle exec ruby -Ilib spec/test_data/make_clip_node_reference.rb spec/test_data/clip_node_reference.json
require 'mb/sound'
require 'json'
S = MB::Sound
CN = S::Sequence::ClipNode

def rle(narray)
  out = []
  narray.to_a.each_with_index { |v, i| out << [i, v] if out.empty? || out.last[1] != v }
  { 'length' => narray.length, 'runs' => out }
end

def run(nodes, buffer:, buffers:)
  out = nodes.transform_values { [] }
  buffers.times do |b|
    yield b if block_given?
    nodes.each { |k, n| out[k] << n.sample(buffer).dup }
  end
  out.transform_values { |l| rle(l.reduce(:concatenate)) }
end

def cnodes(clip, t)
  {
    gate: CN::Gate.new(clip, transport: t),
    trigger: CN::Trigger.new(clip, range: 0.0..1.0, transport: t),
    number: CN::Number.new(clip, transport: t),
    velocity: CN::Velocity.new(clip, range: 0.0..1.0, transport: t),
  }
end

fx = {}
nclip = S.seq(S::C4, S.seq(S::E4).vel(0.4), S::G4.n16).n8.t.legato(0.7).loop
[441, 800, 1000].each do |buffer|
  t = S::Sequence::Transport.new(bpm: 120)
  fx["notes_edges_#{buffer}"] = run(cnodes(nclip, t), buffer: buffer, buffers: 48000 * 3 / buffer)
end
t = S::Sequence::Transport.new(bpm: 120)
fx['notes_tempo'] = run(cnodes(nclip, t), buffer: 800, buffers: 150) { |b| t.bpm = { 20 => 97, 50 => 143.5, 90 => 61 }.fetch(b, t.bpm) }
t = S::Sequence::Transport.new(bpm: 120)
c = cnodes(nclip, t)
jumps = { 7 => 5/16r, 20 => 1/3r, 33 => 0r, 41 => 17/24r }
fx['notes_jumps'] = run(c, buffer: 600, buffers: 60) { |idx| c.each_value { |n| n.start_at(jumps[idx]) } if jumps.key?(idx) }
t = S::Sequence::Transport.new(bpm: 120)
c = cnodes(nclip, t)
other = S.seq(S::D4, S::A3).n4.legato(0.5).loop
fx['notes_swap'] = run(c, buffer: 500, buffers: 40) { |b| c.each_value { |n| n.swap_clip(other, time: 1/6r) } if b == 3 }

# clip_source_spec
sclip = S.seq(S::C4, S::E4, S::G4).n8.t.legato(0.7).loop
[441, 800, 1000].each do |buffer|
  t = S::Sequence::Transport.new(bpm: 120)
  fx["source_edges_#{buffer}"] = run(cnodes(sclip, t).slice(:trigger, :gate), buffer: buffer, buffers: 48000 * 3 / buffer)
end
tclip = S.seq(S::C4, S::E4.n16, S::G4).n8.loop
t = S::Sequence::Transport.new(bpm: 120)
fx['source_tempo'] = run(cnodes(tclip, t).slice(:trigger, :gate), buffer: 800, buffers: 150) { |b| t.bpm = { 20 => 97, 50 => 143.5, 90 => 61 }.fetch(b, t.bpm) }
eclip = S.seq(S::C4, S::E4).n8
t = S::Sequence::Transport.new(bpm: 120)
g = CN::Gate.new(eclip, transport: t)
bufs = Array.new(30) { (g.sample(800) || Numo::SFloat.zeros(800)).dup }
fx['source_end_gate'] = rle(bufs.reduce(:concatenate))

File.write(ARGV[0], JSON.generate(fx))
puts fx.keys.inspect

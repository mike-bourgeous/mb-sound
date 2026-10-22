# Calibrates the sound guards' thresholds (MB::Sound::SoundGuard::Comparison::THRESHOLDS)
# on changes known to be inaudible and known to be audible
# (design/notes/sound_guards.md).  Renders every golden piece (or the ones
# named) as approved now and with perturbations, then prints each distance
# per piece and change, and writes golden/calibration/results.json.
#
#   bundle exec ruby -Ilib golden/calibration/calibrate.rb [--out DIR] [--reuse] [piece ...]
#
# Inaudible: a second render (determinism), 128-sample render buffers (800
# by default), noise 80 dB under the render's RMS, +0.1 dB.
# Audible: +1 dB, lp4/diode tuning: :hardware (filters-1's change, undone),
# every lp4/diode cutoff x1.1 (+1.65 semitones).
# Render changes go through golden/calibration/perturb.rb (RUBYOPT -r).
# --reuse fingerprints renders already in DIR instead of rendering.
require 'mb/sound/sound_guard'
require 'digest'

include MB::Sound::SoundGuard
SoundGuard = MB::Sound::SoundGuard

out = File.join(SoundGuard.golden_dir, 'calibration')
reuse = false
names = []
args = ARGV.dup
until args.empty?
  case (a = args.shift)
  when '--out' then out = File.expand_path(args.shift)
  when '--reuse' then reuse = true
  else names << a
  end
end

set = GoldenSet.load
pieces = set.select(names)
runner = Runner.new(set)
perturb = File.expand_path('perturb.rb', __dir__)
rubyopt = ->(spec) { { 'RUBYOPT' => "#{ENV['RUBYOPT']} -r#{perturb}", 'MB_SOUND_GUARD_PERTURB' => spec } }

RENDERED = {
  rerender: [:inaudible, {}],
  buffer128: [:inaudible, rubyopt.('buffer:128')],
  tuning_hw: [:audible, rubyopt.('tuning:hardware')],
  cutoff_1_1: [:audible, rubyopt.('cutoff:1.1')],
}.freeze

base = runner.render(pieces, dir: File.join(out, 'base'), reuse: reuse).to_h { |r| [r.piece.name, r] }
variants = {}
RENDERED.each do |name, (_kind, env)|
  variants[name] = runner.render(pieces, dir: File.join(out, name.to_s), env: env, reuse: reuse).to_h { |r| [r.piece.name, r] }
end

# Changes applied to the base render's samples
POST = {
  noise_80: [:inaudible, ->(ch) {
    rms = Math.sqrt(ch.sum { |c| (c.to_f * c).sum } / ch.sum(&:length))
    Numo::NArray.srand(1)
    ch.map { |c| c + Numo::SFloat.new(c.length).rand_norm * rms * 10**(-80 / 20.0) }
  }],
  gain_0_1: [:inaudible, ->(ch) { ch.map { |c| c * 10**(0.1 / 20) } }],
  gain_1: [:audible, ->(ch) { ch.map { |c| c * 10**(1 / 20.0) } }],
}.freeze

rows = []
kinds = RENDERED.transform_values(&:first).merge(POST.transform_values(&:first))
pieces.each do |piece|
  b = base[piece.name]
  next warn("#{piece.name}: #{b.error}") unless b.ok?
  data = MB::Sound.read(b.path)
  md5 = Digest::MD5.file(b.path).hexdigest
  RENDERED.each_key do |v|
    r = variants[v][piece.name]
    next warn("#{piece.name} #{v}: #{r.error}") unless r.ok?
    same = Digest::MD5.file(r.path).hexdigest == md5
    rows << { piece: piece.name, change: v, kind: kinds[v], identical: same, distances: b.fingerprint.compare(r.fingerprint).distances }
  end
  POST.each do |v, (_kind, fn)|
    fp = Fingerprint.extract(fn.(data), name: piece.name)
    rows << { piece: piece.name, change: v, kind: kinds[v], identical: false, distances: b.fingerprint.compare(fp).distances }
  end
end

metrics = Comparison::THRESHOLDS.keys
puts format('%-14s %-11s %s', 'piece', 'change', metrics.map { |m| format('%9s', m.to_s[0, 9]) }.join)
rows.each do |r|
  flag = r[:identical] ? ' (identical render)' : ''
  vals = metrics.map { |m| v = r[:distances][m]; format('%9.3f', v) }.join
  pass = metrics.all? { |m| r[:distances][m] <= Comparison::THRESHOLDS[m] }
  puts format('%-14s %-11s %s  %s%s', r[:piece], r[:change], vals, pass ? 'pass' : 'FAIL', flag)
end

puts
puts 'Per metric: largest inaudible distance, smallest audible distance among changed renders, threshold'
summary = metrics.to_h { |m|
  inaudible = rows.select { |r| r[:kind] == :inaudible }.map { |r| r[:distances][m] }
  [m, { max_inaudible: inaudible.max, threshold: Comparison::THRESHOLDS[m] }]
}
metrics.each { |m| puts format('  %-15s max inaudible %8.3f  limit %g', m, summary[m][:max_inaudible], summary[m][:threshold]) }

puts
puts 'Per change: pieces passing (inaudible should all pass; audible should fail where the render changed)'
kinds.each do |v, kind|
  rs = rows.select { |r| r[:change] == v }
  changed = rs.reject { |r| r[:identical] }
  failing = changed.select { |r| metrics.any? { |m| r[:distances][m] > Comparison::THRESHOLDS[m] } }
  puts format('  %-11s %-9s %2d pieces, %2d with a changed render, %2d fail (%s)', v, kind, rs.length, changed.length, failing.length,
    failing.map { |r| r[:piece] }.join(' '))
end

json = { calibrated: Time.now.utc.iso8601, commit: SoundGuard.commit, thresholds: Comparison::THRESHOLDS, rows: rows.map { |r|
  r.merge(distances: r[:distances].transform_values { |v| v.finite? ? v.round(4) : v.to_s })
} }
File.write(File.expand_path('results.json', __dir__), JSON.pretty_generate(json) + "\n")

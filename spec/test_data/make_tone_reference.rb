# Records the Tone null-test reference (spec/test_data/tone_reference.json)
# from the cases in spec/support/tone_reference_cases.rb, first run on the
# code before the Tone/Oscillator consolidation (tone-consolidation branch,
# 2026-10-06).  The JSON keeps a digest of each output (length, SHA-256 of
# the float32 samples, RMS, peak, and the first samples), so it stays small;
# --dump DIR also writes each output's samples (float32 .bin) for diffing two
# trees with --compare.
#
#     bundle exec ruby -Ilib spec/test_data/make_tone_reference.rb spec/test_data/tone_reference.json
#     bundle exec ruby -Ilib spec/test_data/make_tone_reference.rb --dump /tmp/new [--only reset,tempo]
#     bundle exec ruby -Ilib spec/test_data/make_tone_reference.rb --compare /tmp/old /tmp/new
require 'mb-sound'
require 'json'
require 'digest'
require 'fileutils'
require_relative '../support/tone_reference_cases'

module ToneReference
  module_function

  # Float32 little-endian bytes of a real NArray.
  def bytes(narray)
    Numo::SFloat.cast(narray).to_binary
  end

  def digest(narray)
    d = Numo::DFloat.cast(narray)
    {
      'length' => d.length,
      'sha256' => Digest::SHA256.hexdigest(bytes(narray)),
      'rms' => d.length > 0 ? Math.sqrt((d**2).mean) : 0.0,
      'peak' => d.length > 0 ? d.abs.max : 0.0,
      'head' => Numo::SFloat.cast(d[0...[16, d.length].min]).to_a,
    }
  end

  # Runs case +name+ with the same root seed and tuning as the specs.
  def run(name)
    MB::Sound.seed(0)
    MB::Sound.tuning.reset
    MB::Sound::Sequence.transport.rewind if MB::Sound::Sequence.transport.respond_to?(:rewind)
    ToneReferenceCases::CASES.fetch(name).call
  ensure
    MB::Sound.tuning.reset
  end
end

if $0 == __FILE__
  only = nil
  if (i = ARGV.index('--only'))
    only = ARGV[i + 1].split(',')
    ARGV.slice!(i, 2)
  end
  names = ToneReferenceCases::CASES.keys
  names = names.select { |n| only.any? { |o| n.include?(o) } } if only

  case ARGV[0]
  when '--dump'
    dir = ARGV[1]
    FileUtils.mkdir_p(dir)
    names.each do |name|
      ToneReference.run(name).each do |out, data|
        File.binwrite(File.join(dir, "#{name}.#{out}.bin"), ToneReference.bytes(data))
      end
    end

  when '--compare'
    old_dir, new_dir = ARGV[1..2]
    Dir[File.join(old_dir, '*.bin')].sort.each do |path|
      file = File.basename(path)
      next if only && only.none? { |o| file.include?(o) }

      a = Numo::SFloat.from_binary(File.binread(path))
      new_path = File.join(new_dir, file)
      unless File.exist?(new_path)
        puts "#{file}: missing"
        next
      end
      b = Numo::SFloat.from_binary(File.binread(new_path))
      if a.length != b.length
        puts "#{file}: length #{a.length} vs #{b.length}"
      elsif a == b
        puts "#{file}: identical" if ENV['VERBOSE']
      else
        diff = Numo::DFloat.cast(a) - Numo::DFloat.cast(b)
        rms = Math.sqrt((Numo::DFloat.cast(a)**2).mean)
        err = Math.sqrt((diff**2).mean)
        first = diff.ne(0).where[0]
        puts format('%s: max %.3g, residual %.1f dB, first difference at %d', file, diff.abs.max, 20 * Math.log10(err / rms), first)
      end
    end

  else
    path = ARGV[0] or abort 'Give an output .json path (or --dump DIR / --compare OLD NEW)'
    ref = File.exist?(path) && only ? JSON.parse(File.read(path)) : {}
    names.each do |name|
      ref[name] = ToneReference.run(name).transform_values { |d| ToneReference.digest(d) }
    end
    File.write(path, JSON.pretty_generate(ref.sort.to_h, array_nl: '', object_nl: "\n", indent: ' ').gsub(/\[\s+/, '[').gsub(/,\s+(?=[-\d])/, ', '))
    puts "#{names.length} cases written to #{path}"
  end
end

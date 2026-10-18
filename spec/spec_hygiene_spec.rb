# Patterns that made specs slow without testing anything more, kept out of
# the code (test-speed-2; see the Testing paragraph of CLAUDE.md).
RSpec.describe('spec hygiene') do
  root = File.expand_path('..', __dir__)
  files = Dir.chdir(root) { Dir['{lib,bin,spec}/**/*.rb'] - Dir['spec/test_data/**/*.rb'] }

  # [pattern, why, what to write instead]
  rules = [
    [
      /\.(reduce|inject)\(\s*:concatenate\s*\)/,
      'joins buffers in quadratic time (each step copies the growing result: 12000 64-sample buffers took 2.2 s)',
      'SpecBuffers.join(list) in specs, first.concatenate(*rest) in lib',
    ],
  ]

  rules.each do |pattern, why, instead|
    it "has no #{pattern.source} (#{why})" do
      hits = files.flat_map { |f|
        File.foreach(File.join(root, f)).with_index(1).filter_map { |line, n| "#{f}:#{n}" if !line.lstrip.start_with?('#') && line.match?(pattern) }
      }
      expect(hits).to eq([]), "#{hits.join("\n")}\n#{why}; write #{instead}"
    end
  end
end

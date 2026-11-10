# What the mb-sound gem ships and needs (release-1; design/notes/release.md):
# the files an installed gem runs from, none of the checkout's own, and a
# runtime dependency for every gem lib/ and the console require.  The
# clean-room smoke test (rake release:local, release:smoke) installs it for
# real; this is the cheap guard.
RSpec.describe('mb-sound.gemspec') do
  root = File.expand_path('../..', __dir__)
  let(:spec) { Dir.chdir(root) { Gem::Specification.load('mb-sound.gemspec') } }

  it 'ships lib/, bin/, ext/, presets/, matrices/, and the example sounds' do
    files = spec.files
    %w[lib/mb/sound.rb lib/mb/sound/dsl.rb bin/sound.rb bin/play.rb presets/init.mbg.rb sounds/drums_short.flac sounds/synth0.flac
       ext/mb/sound/fast_ui/extconf.rb ext/mb/sound/include/mb_ext_helpers.h].each do |f|
      expect(files).to include(f)
    end
    expect(files.grep(%r{\Amatrices/})).not_to be_empty
    expect(spec.extensions).to include('ext/mb/sound/fast_ui/extconf.rb')
  end

  it "leaves out the checkout's own files" do
    expect(spec.files.grep(%r{\A(spec|tmp|gems|design|golden|experiments|research|release|\.claude|\.github)/})).to eq([])
    expect(spec.files & %w[CLAUDE.md Gemfile Gemfile.lock Rakefile Dockerfile dock.sh .gitignore]).to eq([])
  end

  it 'installs the console as its executable' do
    expect(spec.executables).to eq(['sound.rb'])
    expect(File.executable?(File.join(root, 'bin', 'sound.rb'))).to eq(true)
  end

  # Features required by lib/ and bin/sound.rb that may stay undeclared, with
  # reasons
  optional = {
    'pry-byebug' => 'bin/sound.rb loads it when installed (a development gem)',
    'ruby_memcheck' => 'memcheck tooling',
  }

  it 'declares every non-default gem that lib/ and bin/sound.rb require' do
    declared = spec.runtime_dependencies.map(&:name)
    closure = declared.dup
    todo = declared.dup
    until todo.empty?
      dep = Gem.loaded_specs[todo.shift] || next
      dep.runtime_dependencies.map(&:name).each { |n| (closure << n; todo << n) unless closure.include?(n) }
    end

    files = Dir[File.join(root, 'lib', '**', '*.rb')] + [File.join(root, 'bin', 'sound.rb')]
    features = files.flat_map { |f| File.read(f).scan(/^\s*(?:begin\s+)?require\s*\(?\s*['"]([^'"]+)['"]/).flatten }.uniq
    missing = features.reject { |f| f.start_with?('mb/', 'mb-sound') || optional.key?(f) }.filter_map do |feature|
      gem = Gem::Specification.find_by_path(feature)
      next if gem.nil? || gem.default_gem? || closure.include?(gem.name) || gem.name == 'mb-sound' || gem.name == 'bundler'
      "#{feature} (#{gem.name})"
    end
    expect(missing).to eq([]), "required but not runtime dependencies: #{missing.join(', ')}"
  end
end

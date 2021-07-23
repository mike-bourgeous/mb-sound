require_relative 'lib/mb/sound/version'

Gem::Specification.new do |spec|
  spec.name          = "mb-sound"
  spec.version       = MB::Sound::VERSION
  spec.authors       = ["Mike Bourgeous"]
  spec.email         = ["mike@mikebourgeous.com"]

  spec.summary       = %q{A library of simple Ruby tools for processing sound.}
  spec.description   = %q{
    A library of simple Ruby tools for processing sound. This is a companion library
    to an educational video series about sound.
  }
  spec.homepage      = "https://github.com/mike-bourgeous/mb-sound"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.7.1")

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/mike-bourgeous/mb-sound"
  #spec.metadata["changelog_uri"] = "TODO: Put your gem's CHANGELOG.md URL here."

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features|sounds|tmp|coverage)/}) }
  end
  spec.bindir        = "bin"
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency 'cmath', '~> 1.0.0'
  spec.add_runtime_dependency 'numo-narray', '~> 0.9.1.8'
  spec.add_runtime_dependency 'numo-pocketfft', '~> 0.2.2'

  spec.add_runtime_dependency 'midi-nibbler', '~> 0.2.4'

  spec.add_runtime_dependency 'mb-math', '>= 0.1.3.2.usegit'
  spec.add_runtime_dependency 'mb-util', '>= 0.1.4.usegit'

  spec.add_development_dependency 'pry', '~> 0.13.1'
  spec.add_development_dependency 'pry-byebug', '~> 3.9.0'

  spec.add_development_dependency 'simplecov', '~> 0.21.2'
end

require_relative 'lib/mb/term/version'

Gem::Specification.new do |spec|
  spec.name          = 'mb-term'
  spec.version       = MB::Term::VERSION
  spec.authors       = ['Mike Bourgeous']
  spec.email         = ['mike@mikebourgeous.com']

  spec.summary       = 'A terminal toolkit: cell grids, a VT model, input decoding, pty hosting, split layouts'
  spec.description   = <<~DESC
    The generic terminal layers of mb-sound's live UI as a library: a cell
    grid with SGR encoding and changed-cell frames, a VT100/xterm terminal
    model with scrollback, an input decoder and mode router, a pty host
    for a REPL or any command, split-tree layouts with undo, color themes,
    and a Prism walker for data files (never eval).
  DESC
  spec.homepage      = 'https://github.com/mike-bourgeous/mb-sound'
  spec.license       = 'BSD-2-Clause'
  spec.required_ruby_version = '>= 4.0'

  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*.rb', 'ext/**/*.{c,h,rb}', 'ext/**/depend', 'examples/**/*', 'README.md']
  end
  spec.require_paths = ['lib']
  spec.extensions = Dir.chdir(__dir__) { Dir['ext/**/extconf.rb'] }

  spec.add_runtime_dependency 'prism'
  spec.add_runtime_dependency 'reline'

  spec.add_development_dependency 'rspec', '~> 3.13'
  spec.add_development_dependency 'pry', '~> 0.16.0'
  spec.add_development_dependency 'rake', '~> 13.0.1'
  spec.add_development_dependency 'rake-compiler', '~> 1.1'
end

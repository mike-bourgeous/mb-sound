require 'prism'
require 'rbconfig'

# mb-term stands alone: its code reads no constant it doesn't define
# besides Ruby's own (and Pry, loaded only by ReplHost's :thread mode),
# requires nothing outside itself but the standard library and its
# dependencies, and loads in a process without mb-sound.  (This was
# mb-sound's gem_boundary_spec.rb while the layers lived in mb-sound.)
RSpec.describe('mb-term boundary') do
  lib = File.expand_path('../lib', __dir__)
  let(:files) { Dir[File.join(lib, '**/*.rb')].sort }

  # Gems and libraries mb-term may require.
  ALLOWED_REQUIRES = %w[prism reline pty io/console pry tmpdir socket openssl json etc fcntl].freeze
  # Constants from outside mb-term that may be read even if not loaded yet.
  ALLOWED_CONSTANTS = %w[Pry].freeze

  # Constant names a file defines (class/module names and assignments).
  def defined_names(node, out = [])
    case node
    when Prism::ClassNode, Prism::ModuleNode then out << node.constant_path.slice.split('::').last
    when Prism::ConstantWriteNode then out << node.name.to_s
    end
    node.compact_child_nodes.each { |c| defined_names(c, out) }
    out
  end

  # [name, line] of every constant read (paths whole, without their parts).
  def constant_reads(node, out = [])
    case node
    when Prism::ConstantPathNode
      out << [node.slice, node.location.start_line]
      return out
    when Prism::ConstantReadNode
      out << [node.name.to_s, node.location.start_line]
    when Prism::ClassNode, Prism::ModuleNode
      (node.respond_to?(:superclass) && node.superclass) && constant_reads(node.superclass, out)
      constant_reads(node.body, out) if node.body
      return out
    end
    node.compact_child_nodes.each { |c| constant_reads(c, out) }
    out
  end

  it 'finds its files' do
    expect(files.map { |f| f.delete_prefix("#{lib}/") }).to include('mb/term.rb', 'mb/term/vt.rb', 'mb/term/cells.rb', 'mb/term/input/decoder.rb', 'mb/term/viewports/tiler.rb', 'mb/term/data_file.rb')
  end

  it 'reads only its own constants and Ruby\'s, and requires only itself and the standard library' do
    trees = files.to_h { |f| [f, Prism.parse_file(f).value] }
    own = trees.values.flat_map { |t| defined_names(t) }.uniq + %w[MB Term]
    # (and what the C extension defines)
    own += Dir[File.expand_path('../ext/**/*.c', __dir__)].flat_map { |f| File.read(f).scan(/rb_define_(?:module|class)(?:_under)?\([^;]*?"(\w+)"/).flatten }

    problems = []
    trees.each do |file, tree|
      rel = file.delete_prefix("#{lib}/")
      constant_reads(tree).each do |name, line|
        parts = name.delete_prefix('::').split('::')
        if parts[0] == 'MB'
          problems << "#{rel}:#{line}: #{name}" unless parts[1].nil? || parts[1] == 'Term'
          next
        end
        head = parts[0]
        next unless head.match?(/\A[A-Z]\w*\z/) # (an expression::Constant: its head is checked as a read)
        next if own.include?(head) || ALLOWED_CONSTANTS.include?(head) || Object.const_defined?(head)

        problems << "#{rel}:#{line}: #{name}"
      end

      tree.slice.scan(/^\s*require\s+['"]([^'"]+)['"]/).flatten.each do |r|
        problems << "#{rel}: requires #{r}" unless r.start_with?('mb/term') || ALLOWED_REQUIRES.include?(r)
      end
      tree.slice.scan(/^\s*require_relative\s+['"]([^'"]+)['"]/).flatten.each do |r|
        problems << "#{rel}: require_relative #{r} leaves the gem" unless File.expand_path("#{r}.rb", File.dirname(file)).start_with?("#{lib}/")
      end
    end
    expect(problems).to eq([]), "mb-term reaches outside itself:\n#{problems.join("\n")}"
  end

  # (Without Bundler: the parent repository's bundle loads mb-sound's gemspec,
  # which defines MB::Sound::VERSION.)
  it 'loads in a Ruby without mb-sound or Bundler, without warnings' do
    code = 'require "mb/term"; abort "MB::Sound defined" if defined?(MB::Sound); MB::Term::VT.new(2, 4).feed("x"); print MB::Term::Grid.new(2, 1, native: false).class'
    run = -> { IO.popen([RbConfig.ruby, '-W2', '-I', lib, '-e', code, err: %i[child out]], &:read) }
    out = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
    expect(out).to eq('MB::Term::Cells')
  end

  it 'would catch a reference to mb-sound' do
    tree = Prism.parse('module MB; module Term; class X; def f = Session.existing || MB::Sound::UI::Panes; end; end; end').value
    reads = constant_reads(tree).map(&:first)
    expect(reads).to include('Session', 'MB::Sound::UI::Panes')
  end
end

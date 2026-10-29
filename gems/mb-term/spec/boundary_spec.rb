require 'prism'

# The terminal UI's generic layers (screen, input, viewports, themes, the
# data-file walker) are meant to become a gem of their own, so they must not
# reach into the rest of MB::Sound except through the adapters named here.
# Every constant they read is resolved: a constant of MB::Sound (other than
# the generic layers' own and ADAPTERS) fails, and so does requiring
# mb/sound or anything outside the generic layers.  The mb-sound side
# (panes, snapshots, Tiles, Band, console commands) may use both.
RSpec.describe('UI gem boundary') do
  ui_dir = File.expand_path('../../../../../lib/mb/sound/ui', __dir__)
  let(:ui_dir) { ui_dir }

  # The generic layers.
  let(:generic) {
    ['screen/*.rb', 'input/*.rb', 'viewports/*.rb', 'themes/*.rb', 'data_file.rb'].flat_map { |g| Dir.glob(File.join(ui_dir, g)) }.sort
  }

  # Constants of MB::Sound the generic layers may use, with the reason.
  # (Empty for now: Tiles, on the mb-sound side, passes everything in.)
  let(:adapters) { {} }

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
      # The name being defined is not a read
      (node.respond_to?(:superclass) && node.superclass) && constant_reads(node.superclass, out)
      constant_reads(node.body, out) if node.body
      return out
    end
    node.compact_child_nodes.each { |c| constant_reads(c, out) }
    out
  end

  it 'finds the generic files' do
    expect(generic.map { |f| f.delete_prefix("#{ui_dir}/") }).to include('screen/vt.rb', 'input/decoder.rb', 'input/repl_host.rb', 'viewports/tiler.rb', 'themes/theme_set.rb', 'data_file.rb')
  end

  it 'keeps the generic layers free of MB::Sound outside UI and the adapters' do
    trees = generic.to_h { |f| [f, Prism.parse_file(f).value] }
    own = trees.values.flat_map { |t| defined_names(t) }.uniq + %w[MB Sound UI]
    sound_names = MB::Sound.constants.map(&:to_s) + MB::Sound::UI.constants.map(&:to_s)

    problems = []
    trees.each do |file, tree|
      rel = file.delete_prefix("#{ui_dir}/")
      constant_reads(tree).each do |name, line|
        parts = name.delete_prefix('::').split('::')
        if parts[0] == 'MB'
          # Only MB::Sound::UI::<generic> paths
          ok = parts[1] == 'Sound' && parts[2] == 'UI' && (parts[3].nil? || own.include?(parts[3])) || adapters.key?(name)
          problems << "#{rel}:#{line}: #{name}" unless ok
          next
        end
        head = parts[0]
        next unless head.match?(/\A[A-Z]\w*\z/) # (an expression::Constant: its head is checked as a read)
        next if own.include?(head) || adapters.key?(head)
        next if Object.const_defined?(head) && !sound_names.include?(head)
        problems << "#{rel}:#{line}: #{name}" if sound_names.include?(head)
      end

      requires = tree.slice.scan(/^\s*require(?:_relative)?\s+['"]([^'"]+)['"]/).flatten
      requires.each do |r|
        bad = r.start_with?('mb/') || r == 'mb-sound' ||
          (tree.slice.include?("require_relative '#{r}'") && !generic.include?(File.expand_path("#{r}.rb", File.dirname(file))))
        problems << "#{rel}: requires #{r}" if bad
      end
    end
    expect(problems).to eq([]), "The generic UI layers reach into MB::Sound (use an adapter, or move the code to the mb-sound side):\n#{problems.join("\n")}"
  end

  it 'would catch a reference to the mb-sound side' do
    tree = Prism.parse("module MB; module Sound; module UI; class X; def f = Session.existing || Panes::Meters; end; end; end; end").value
    reads = constant_reads(tree).map(&:first)
    expect(reads).to include('Session', 'Panes::Meters')
  end
end

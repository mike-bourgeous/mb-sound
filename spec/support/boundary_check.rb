require 'prism'
require 'rbconfig'

# Boundary guards for parts of mb-sound that could become gems (test-infra-1,
# 2026-10-30; the maintainer's D4 = option 2: guards first, no code moved):
# like gems/mb-term/spec/boundary_spec.rb, but for files still inside
# mb-sound, so the crossings that exist today are listed (each spec's
# ADAPTERS) and a new one fails.
#
# A file of the part crosses the boundary when it
# - reads a constant (outside the names the part defines) that resolves,
#   lexically as Ruby would, in this process, to something defined in
#   mb-sound's lib/ outside the part's files, or in C by mb-sound outside
#   the part's extensions, or that doesn't resolve at all;
# - calls a method on MB::Sound itself (MB::Sound.live_error, ...);
# - requires a file of mb-sound outside the part, or a library not in its
#   requires list.
# Constants from Ruby, the standard library, and gems (Numo, mb-math,
# mb-util, mb-term) are the part's dependencies, not crossings.
#
# Crossings compare as "file: Name" strings (files relative to lib/), so
# moving code inside a file doesn't change the list.
module BoundaryCheck
  ROOT = File.expand_path('../..', __dir__)
  LIB = File.join(ROOT, 'lib')

  Crossing = Struct.new(:file, :name, :line, :why) do
    def key = "#{file}: #{name}"
    def to_s = "#{file}:#{line}: #{name} (#{why})"
  end

  module_function

  # Constant names a tree defines (class/module names and assignments).
  def defined_names(node, out = [])
    case node
    when Prism::ClassNode, Prism::ModuleNode then out << node.constant_path.slice.split('::').last
    when Prism::ConstantWriteNode then out << node.name.to_s
    end
    node.compact_child_nodes.each { |c| defined_names(c, out) }
    out
  end

  # Names the C sources in +ext_dirs+ (relative to the repository) define
  # as modules or classes.
  def c_names(ext_dirs)
    ext_dirs.flat_map { |d| Dir[File.join(ROOT, d, '**', '*.c')] }
      .flat_map { |f| File.read(f, encoding: 'binary').scan(/rb_define_(?:module|class)(?:_under)?\([^;]*?"(\w+)"/).flatten }.uniq
  end

  # Yields [kind, text, line, nesting] for every constant read (:const,
  # paths whole), method call on a constant (:call, "Const.name"), and
  # require (:require, :require_relative), with the lexical nesting (full
  # constant paths, innermost last) at that point.
  def walk(node, nesting = [], &block)
    case node
    when Prism::ClassNode, Prism::ModuleNode
      walk(node.superclass, nesting, &block) if node.respond_to?(:superclass) && node.superclass
      path = node.constant_path.slice
      full = path.start_with?('::') ? path.delete_prefix('::') : [nesting.last, path].compact.join('::')
      walk(node.body, nesting + [full], &block) if node.body
      return
    when Prism::ConstantPathNode
      yield :const, node.slice, node.location.start_line, nesting
      return
    when Prism::ConstantReadNode
      yield :const, node.name.to_s, node.location.start_line, nesting
    when Prism::CallNode
      first = node.arguments&.arguments&.first
      if node.receiver.nil? && %i[require require_relative].include?(node.name) && first.is_a?(Prism::StringNode)
        yield node.name, first.unescaped, node.location.start_line, nesting
      elsif node.receiver.is_a?(Prism::ConstantPathNode) || node.receiver.is_a?(Prism::ConstantReadNode)
        yield :call, "#{node.receiver.slice}.#{node.name}", node.location.start_line, nesting
      end
    end
    node.compact_child_nodes.each { |c| walk(c, nesting, &block) }
  end

  def const(path) = path.split('::').reduce(Object) { |m, n| m.const_get(n, false) }

  # [holder, last name] for a constant read +name+ from +nesting+: the
  # module that holds the constant, as Ruby's lexical lookup (then
  # Object) finds it, or nil.
  def holder(name, nesting)
    parts = name.delete_prefix('::').split('::')
    last = parts.pop
    if parts.empty? && !name.start_with?('::')
      scopes = nesting.reverse.filter_map { |n| const(n) rescue nil } + [Object]
      h = scopes.find { |m| m.const_defined?(last, false) } || scopes.find { |m| m.const_defined?(last) }
      return h && [h, last]
    end

    head, *rest = parts
    base = name.start_with?('::') ? Object : (nesting.reverse.filter_map { |n| const(n) rescue nil } + [Object]).find { |m| m.const_defined?(head, false) }
    return nil unless base

    h = ([head] + rest).reduce(base) { |m, n| m.const_get(n, false) }
    h.is_a?(Module) && h.const_defined?(last) ? [h, last] : nil
  rescue NameError
    nil
  end

  # The crossings of the part made of +files+ (paths relative to lib/),
  # whose C extensions are +ext_dirs+ and which may require +requires+
  # (library names) besides its own files; +external+ names constants of
  # those libraries that may not be loaded yet.
  def crossings(files, ext_dirs: [], requires: [], external: [])
    abs = files.map { |f| File.expand_path(f, LIB) }
    trees = abs.to_h { |f| [f, Prism.parse_file(f).value] }
    own_c = c_names(ext_dirs)
    own = trees.values.flat_map { |t| defined_names(t) }.uniq + own_c + external
    out = []
    trees.each do |file, tree|
      rel = file.delete_prefix("#{LIB}/")
      walk(tree) do |kind, name, line, nesting|
        case kind
        when :require
          next if requires.include?(name) || abs.include?(File.join(LIB, "#{name}.rb"))

          out << Crossing.new(rel, "require #{name}", line, 'a library or file outside the part')
        when :require_relative
          next if abs.include?(File.expand_path("#{name}.rb", File.dirname(file)))

          out << Crossing.new(rel, "require_relative #{name}", line, 'a file outside the part')
        when :call
          h = holder(name.split('.').first, nesting)
          out << Crossing.new(rel, name, line, 'a method of MB::Sound') if h && (h[0].const_get(h[1]) rescue nil).equal?(MB::Sound)
        when :const
          next if %w[MB Sound].include?(name.delete_prefix('::').split('::').last) && name.delete_prefix('::').split('::').all? { |p| %w[MB Sound].include?(p) }
          next if own.include?(name.split('::').last)
          next if external.include?(name.delete_prefix('::').split('::').first)

          h = holder(name, nesting)
          next out << Crossing.new(rel, name, line, 'does not resolve') unless h

          loc = h[0].const_source_location(h[1])
          if loc.nil? || loc.empty? || loc.first.end_with?(".#{RbConfig::CONFIG['DLEXT']}")
            # (defined in C: the part's own when its holder or value is a
            # module its extensions define)
            value = h[0].const_get(h[1]) rescue nil
            mb = value.is_a?(Module) ? value.name.to_s : "#{h[0].name}::#{h[1]}"
            next if own_c.include?(h[0].name.to_s.split('::').last) || own_c.include?(mb.split('::').last)

            out << Crossing.new(rel, name, line, "mb-sound's C (#{mb})") if mb.start_with?('MB::Sound::', 'MB::FastSound')
          elsif loc.first.start_with?("#{LIB}/") && !abs.include?(loc.first)
            out << Crossing.new(rel, name, line, loc.first.delete_prefix("#{LIB}/"))
          end
        end
      end
    end
    out.uniq(&:key).sort_by(&:key)
  end
end

require 'prism'

# Guard (proposed in sound-design-ui-1, omnibus14): Data.define members are
# public reader methods, so a member named after a public Object method
# (inspect, hash, send, class, method, display, ...) replaces it for every
# caller: `role.send(:x)`, RSpec's matchers, Recipe printing, and pp all
# call those.  Members named after private Kernel functions (format, loop,
# open, sleep, test, load) only shadow them inside the Data's own methods,
# so they are fine unless that block calls the function (`format('%d', x)`
# or `loop do ... end` would reach the reader instead).
RSpec.describe('Data.define member names') do
  root = File.expand_path('..', __dir__)
  public_names = (Object.public_instance_methods | BasicObject.public_instance_methods).map(&:to_s)
  private_names = (Object.private_instance_methods | Kernel.private_instance_methods).map(&:to_s) - public_names

  # Every Data.define in lib/ and bin/: [file:line, members, block node]
  defines = []
  Dir[File.join(root, '{lib,bin}/**/*.rb')].sort.each do |f|
    q = [Prism.parse_file(f).value]
    until q.empty?
      n = q.pop
      next unless n

      if n.is_a?(Prism::CallNode) && n.name == :define && n.receiver.is_a?(Prism::ConstantReadNode) && n.receiver.name == :Data
        members = (n.arguments&.arguments || []).filter_map { |a| a.unescaped if a.respond_to?(:unescaped) }
        defines << ["#{f.delete_prefix("#{root}/")}:#{n.location.start_line}", members, n.block]
      end
      q.concat(n.compact_child_nodes)
    end
  end

  it 'finds the Data definitions it checks' do
    expect(defines.length).to be > 50
  end

  it 'names no member after a public Object method' do
    bad = defines.flat_map { |where, members, _| (members & public_names).map { |m| "#{where} #{m}" } }
    expect(bad).to be_empty, "Data members hiding public Object methods (rename the member; a constructor keyword may keep the name): #{bad.join(', ')}"
  end

  it 'calls no shadowed private Kernel function inside the Data block' do
    bad = []
    defines.each do |where, members, block|
      shadowed = members & private_names
      next if shadowed.empty? || block.nil?

      q = [block]
      until q.empty?
        n = q.pop
        next unless n

        if n.is_a?(Prism::CallNode) && n.receiver.nil? && shadowed.include?(n.name.to_s) && (n.arguments || n.block)
          bad << "#{where}: #{n.name} at line #{n.location.start_line}"
        end
        q.concat(n.compact_child_nodes)
      end
    end
    expect(bad).to be_empty, "calls reaching a Data member instead of Kernel (write Kernel.#{bad.first&.split&.last} or rename): #{bad.join(', ')}"
  end
end

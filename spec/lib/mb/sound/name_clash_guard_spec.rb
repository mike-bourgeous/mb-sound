require 'prism'
require 'mb/sound/help' # (HelpMethods joins MB::Sound when loaded, as in bin/sound.rb)

# No two modules mixed into the same receiver define the same method
# (o-plumbing, test-infra-1, 2026-10-30): when two `*Methods` modules
# extended into MB::Sound both define a name, the later `extend` silently
# wins and the other module's method is never called.  That happened on
# 2026-10-29: midi-import-1 (SequenceMethods) and generative-g3
# (GenerativeMethods) each added a top-level `rhythm`, git merged them
# without a conflict, and only a unit spec that happened to run caught it.
#
# A shared name is allowed only when it is listed in ALLOWED with a reason,
# and the winning module's method calls `super` (so both run), unless its
# entry says `super: false` (a deliberate replacement).  Covers public,
# protected, and private methods of named MB:: modules (Recipe's generated
# recorders are anonymous and always call super); GraphNode's DSL surface
# has its own guard (graph_node/dsl_shadowing_spec.rb).
module NameClashGuard
  # Receivers whose mixed-in modules are compared, by label.
  TARGETS = {
    'MB::Sound' => -> { MB::Sound.singleton_class },
    'Integer' => -> { Integer },
    'Float' => -> { Float },
    'Rational' => -> { Rational },
    'Clip' => -> { MB::Sound::Sequence::Clip },
    'Notes' => -> { MB::Sound::Notes },
  }.freeze

  # [target label, method name] => { reason:, super: } for deliberate
  # overlaps; the first module in the receiver's ancestors (the one Ruby
  # calls) must call super unless super: false.
  ALLOWED = {
    ['MB::Sound', :launch] => { reason: 'CueMethods#launch with no clip launches a cued part, else calls ArrangementMethods#launch (the clip matrix)' },
    ['MB::Sound', :next_seed] => { reason: "Recipe::SeedRecording records each seed RandomMethods#next_seed draws while a call is recorded" },
    ['MB::Sound', :with_seed] => { reason: "Recipe::SeedRecording counts seeded scopes around RandomMethods#with_seed, so calls inside don't print seeds" },
    **%i[help now lesson].to_h { |name|
      [['MB::Sound', name], { reason: "HelpAutoload's stub loads mb/sound/help on first use, which extends HelpMethods with the real ##{name}", super: false }]
    },
    **%i[radians radian degrees degree].product(%w[Integer Float Rational]).to_h { |name, target|
      [[target, name], { reason: "NumericSoundMixins replaces mb-math's Numeric##{name} (plain radians) with oscillator Phases (user decision 2026-10-10; #degrees keeps mb-math's for complex numbers)", super: false }]
    },
  }.freeze

  module_function

  def modules_of(receiver)
    receiver.ancestors.take_while { |m| m != Object && m != BasicObject && m != Module }
      .select { |m| !m.is_a?(Class) && m.name&.start_with?('MB::') }
  end

  # { [label, name] => [modules defining it, in ancestor order] } for names
  # defined by more than one module.
  def overlaps
    TARGETS.each_with_object({}) do |(label, receiver), out|
      by = Hash.new { |h, k| h[k] = [] }
      modules_of(receiver.call).each do |m|
        (m.public_instance_methods(false) + m.protected_instance_methods(false) + m.private_instance_methods(false)).each { |n| by[n] << m }
      end
      by.each { |n, ms| out[[label, n]] = ms if ms.length > 1 }
    end
  end

  # True if +um+'s source (a def found by Prism at its source location)
  # calls super.
  def calls_super?(um)
    file, line = um.source_location
    return false unless file && File.exist?(file)

    @trees ||= {}
    tree = (@trees[file] ||= Prism.parse_file(file).value)
    find = ->(node) {
      return node if node.is_a?(Prism::DefNode) && node.name == um.original_name && node.location.start_line == line

      node.compact_child_nodes.each { |c| r = find.(c) and return r }
      nil
    }
    has_super = ->(node) { node.is_a?(Prism::SuperNode) || node.is_a?(Prism::ForwardingSuperNode) || node.compact_child_nodes.any?(&has_super) }
    d = find.(tree)
    !!(d && has_super.(d))
  end

end

RSpec.describe('method name clashes between mixed-in modules') do
  include NameClashGuard

  it 'compares the modules it should' do
    names = modules_of(MB::Sound.singleton_class).map(&:name)
    expect(names).to include('MB::Sound::SequenceMethods', 'MB::Sound::GenerativeMethods', 'MB::Sound::CueMethods', 'MB::Sound::ArrangementMethods')
    expect(names.length).to be > 40
    expect(modules_of(Integer).map(&:name)).to include('MB::Sound::NumericSoundMixins')
  end

  it 'finds no shared method names except the listed ones, whose winners call super' do
    found = overlaps
    problems = []
    found.each do |(label, name), mods|
      where = mods.map { |m| "#{m.name} (#{m.instance_method(name).source_location&.join(':')&.sub(%r{.*/(lib|gems)/}, '\1/')})" }.join(', ')
      entry = NameClashGuard::ALLOWED[[label, name]]
      if entry.nil?
        problems << "#{label}.#{name} is defined by #{where}: Ruby calls only the first.  Rename one, or call super from the first and list it in NameClashGuard::ALLOWED with a reason"
      elsif entry.fetch(:super, true) && !calls_super?(mods.first.instance_method(name))
        problems << "#{label}.#{name}: #{mods.first.name}'s method no longer calls super (#{where}); the other module's method is never called"
      end
    end
    (NameClashGuard::ALLOWED.keys - found.keys).each { |label, name| problems << "NameClashGuard::ALLOWED lists #{label}.#{name}, which no longer overlaps: remove the entry" }
    expect(problems).to eq([]), problems.join("\n")
  end

  it 'gives every entry a reason' do
    expect(NameClashGuard::ALLOWED.values.reject { |e| e[:reason].to_s.length >= 20 }).to eq([])
  end

  it 'would catch two modules defining one name' do
    a = Module.new { def self.name = 'MB::A'; def rhythm = :a }
    b = Module.new { def self.name = 'MB::B'; def rhythm = :b }
    c = Module.new { def self.name = 'MB::C'; def rhythm = super }
    obj = Object.new.extend(a).extend(b)
    by = modules_of(obj.singleton_class).flat_map { |m| m.instance_methods(false).map { |n| [n, m] } }.group_by(&:first)
    expect(by[:rhythm].map(&:last)).to eq([b, a])
    expect(calls_super?(b.instance_method(:rhythm))).to eq(false)
    expect(calls_super?(c.instance_method(:rhythm))).to eq(true)
  end
end

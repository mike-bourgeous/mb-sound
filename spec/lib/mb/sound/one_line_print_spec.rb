require 'pp'
require_relative '../../../support/library_files'

# Console results print as their classes' own inspect (sd-ux-fixes-1, the
# review's #6): Pry prints results with pp, and the pretty_print of Data,
# Struct, Array, Hash, Set, and Range ignore a subclass's #inspect, so
# `design :bass, ...` printed an 11-line `#<data ...Opened ...>` dump
# instead of its documented one line.  Every class under MB:: (lib/ and
# the vendored mb-term) that defines #inspect over one of those prints it
# through pp (MB::Sound::OneLinePrint), or is listed here with why.
RSpec.describe(MB::Sound::OneLinePrint) do
  # Core classes whose pretty_print ignores a subclass's #inspect.
  PP_DUMPERS = [Data, Struct, Array, Hash, Set, Range].freeze

  # Classes left printing pp's dump, with why.
  PRINT_ALLOWED = {}.freeze

  before(:all) { LibraryFiles.require_all }

  # [[class, file:line of its inspect], ...] that pp would print as a dump.
  def dumped
    ObjectSpace.each_object(Class).filter_map { |c|
      next unless c.name&.start_with?('MB::')
      base = PP_DUMPERS.find { |b| c < b } or next
      io = c.instance_method(:inspect).owner
      next if c.ancestors.index(io) >= c.ancestors.index(base) # (the core inspect)
      po = c.instance_method(:pretty_print).owner
      next unless c.ancestors.index(po) >= c.ancestors.index(base)
      next if PRINT_ALLOWED.key?(c.name)
      [c.name, c.instance_method(:inspect).source_location&.join(':')]
    }.sort
  end

  it 'prints every MB:: Data, Struct, and collection class with its own inspect through that inspect' do
    expect(dumped).to eq([]), "include MB::Sound::OneLinePrint in these (or list them in PRINT_ALLOWED with why):\n#{dumped.map { |n, l| "#{n} (#{l})" }.join("\n")}"
  end

  it 'prints the inspect in one line through pp, as Pry does' do
    opened = MB::Sound::UI::Design::Opened.instance_method(:inspect).owner
    expect(opened).to eq(MB::Sound::UI::Design::Opened)
    param = MB::Sound::Param.declare(:cutoff, (20.hz..20000.hz).at(2400.hz))
    expect(param.pretty_inspect).to eq("#{param.inspect}\n")
    expect(param.inspect).to start_with('#<MB::Sound::Param ')
    theme = MB::Term::Themes::Theme.new(name: :x, roles: {}, glyphs: {})
    expect(theme.pretty_inspect).to eq("#{theme.inspect}\n")
    expect(PP.pp([param], +'', 20)).to include(param.inspect) # (nested in a collection too)
  end
end

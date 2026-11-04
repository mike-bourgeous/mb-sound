# The library catalog (design/catalog.md, imported by CLAUDE.md) stays
# generated from the DSL's doc comments and the help topics, lists every
# public DSL method and help topic, and stays small (catalog-1;
# spec/catalog.rb).  A new DSL method fails here until it has a doc comment
# and a group in Catalog::GROUPS; then `rake docs:index` rewrites the file.
require_relative 'catalog'

RSpec.describe('library catalog') do
  let(:text) { Catalog.text }

  it 'is current in design/catalog.md (run `rake docs:index`)' do
    expect(Catalog.stale?).to eq(false), 'design/catalog.md is stale: run `bundle exec rake -f Rakefile docs:index`'
  end

  it 'has a group, a short description, and short lines for every DSL method, within its byte budget' do
    expect(Catalog.problems).to eq([])
  end

  it 'lists every public method of the GraphNode *Methods modules, aliases included' do
    names = Catalog.dsl_modules.flat_map { |m| m.public_instance_methods(false) }.uniq
    expect(names.length).to be > 100
    # names/aliases split at slashes between names (lp4/four_pole), not the / operator
    listed = text.scan(/^- `([^`(]+)/).flatten.flat_map { |s| s.split(%r{(?<=[\w?!])/(?=\w)}) }.map(&:to_sym)
    expect(names - listed).to eq([])
  end

  it 'lists every help topic with its title' do
    Catalog.topics.each do |t|
      expect(text).to include("- `:#{t.name}` #{t.title}")
    end
  end

  it 'reports methods without a group, without a doc comment, or with long descriptions' do
    um = MB::Sound::GraphNode::FilterMethods.instance_method(:lp4)
    line = Catalog::Line.new(names: [:lp4], owner: MB::Sound::GraphNode::FilterMethods, unbound: um, group: nil)
    allow(Catalog).to receive(:dsl_lines).and_return([line])
    expect(Catalog.problems).to include(/DSL method lp4 .* is in no Catalog::GROUPS entry/)

    allow(Catalog).to receive(:description).and_return('')
    expect(Catalog.problems).to include(/DSL method lp4 .* has no doc comment/)

    allow(Catalog).to receive(:description).and_return('x' * 81)
    expect(Catalog.problems).to include(/lp4's description is 81 characters \(at most 80\)/)
  end

  it 'shortens descriptions: first sentence, +arg+ markers, and parentheticals only when long' do
    comment = ->(c) { double(comment: c) }
    expect(Catalog.description(comment.("# Pans +x+ (a Pan).  More.\n"))).to eq('Pans x (a Pan)')
    long = "# Splits #{'a ' * 30}(#{'b ' * 20}) at +freq+ (Hz).  More.\n"
    expect(Catalog.description(comment.(long))).to eq("Splits #{'a ' * 29}a at freq")
    expect(Catalog.description(comment.("# A loudness meter (e.g. BS.1770).\n"))).to eq('A loudness meter (e.g. BS.1770)')
  end

  it 'shortens signatures to positional arguments, required keywords, a few others, and a block' do
    sig = Catalog.signature(Catalog.dsl_lines.find { |l| l.name == :delay })
    expect(sig).to eq('delay(time, seconds:, smooth:, ..., &block)')
  end
end

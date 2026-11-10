# Help describes how things work, not what inspired them (the maintainer,
# 2026-11-07: "make sure we generalize across references and sources of
# inspiration rather than just mimicking specific references, so the
# mention of the directx plugin (and similar mentions in the help) should
# be removed and just the general operating principle described";
# tuner-fixes-1).  Classic machine names that name the sound itself (303,
# 808, 909, tr808, SQ-80, ...) stay; software products and plugins cited
# as a source don't.  Design notes keep their sources.
#
# Scanned: the help topics, lessons, and sheets (lib/mb/sound/help/), the
# doc comments of the DSL and console method modules (`help :name` pages,
# design/catalog.md), Sample's (Sample#stretch, #grains), and the catalog.
RSpec.describe('help wording') do
  # Software products and plugins that must not explain a node in help.
  PRODUCTS = [
    'DirectX', 'Sonic Foundry', 'Sound Forge', 'OTT', 'Xfer', 'Serum', 'Csound', 'Paulstretch', 'Valhalla', 'Ableton', 'iZotope',
    'FabFilter', 'Soundtoys', 'Native Instruments', 'Kontakt', 'Reaktor', 'Max/MSP', 'Pure Data', 'SuperCollider', 'Sonic Pi',
    'FluidSynth', 'REX', 'ReCycle',
  ].freeze

  def sources
    root = File.expand_path('../../../..', __dir__)
    whole = Dir[File.join(root, 'lib/mb/sound/help/**/*.rb')] + [File.join(root, 'design/catalog.md')]
    commented = Dir[File.join(root, 'lib/mb/sound/**/*_methods.rb')] + [File.join(root, 'lib/mb/sound/sample.rb')]
    whole.to_h { |f| [f, File.read(f)] }.merge(commented.to_h { |f| [f, File.readlines(f).grep(/^\s*#/).join] })
  end

  it 'names no software product or plugin in help text' do
    pattern = /\b(#{PRODUCTS.map { |p| Regexp.escape(p) }.join('|')})\b/
    hits = sources.flat_map { |f, text| text.lines.each_with_index.select { |l, _| l.match?(pattern) }.map { |l, i| "#{f}:#{i + 1}: #{l.strip}" } }
    expect(hits).to eq([]), "describe the principle instead:\n#{hits.join("\n")}"
  end

  it 'keeps the classic machine names out of its list' do
    expect(PRODUCTS.grep(/303|808|909/)).to eq([])
  end
end

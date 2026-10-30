require_relative '../../../../support/boundary_check'

# Plotting as a possible gem ("mb-plot"; tests-gems.md B2/B3, the
# maintainer's D4 = option 2 on 2026-10-30: a guard now, the extraction
# after his native Mac check of mb-term).  A second user exists: mb-math's
# gnuplot MB::M::Plot.  The previews of mb-sound's nodes (panels.rb,
# envelope_view.rb, presets.rb) are mb-sound's side of the line; the rest
# reads only Ruby, Numo, mb-math, mb-util, mb-term, and the ADAPTERS below
# (spec/support/boundary_check.rb has the rules).
module PlotBoundary
  # mb-sound's side: node previews and signal presets, which would stay.
  MB_SOUND_SIDE = %w[mb/sound/plot/panels.rb mb/sound/plot/envelope_view.rb mb/sound/plot/presets.rb].freeze

  FILES = (['mb/sound/plot.rb'] + Dir[File.join(BoundaryCheck::LIB, 'mb/sound/plot/*.rb')].map { |f| f.delete_prefix("#{BoundaryCheck::LIB}/") }.sort - MB_SOUND_SIDE).freeze

  REQUIRES = %w[numo/narray zlib tmpdir mb/term].freeze

  ADAPTERS = {
    "the plot kernels in fast_ui (decimate, polyline, area, project) and its Grid subclass: the kernels would move into the gem's own extension, linked only against mb-term's fast_term" => [
      'mb/sound/plot.rb: require_relative fast_ui',
      'mb/sound/plot/mark.rb: FastUI', 'mb/sound/plot/raster.rb: FastUI', 'mb/sound/plot/text.rb: FastUI', 'mb/sound/plot/text.rb: FastUI::Grid',
    ],
    "the plot kernels' and cell grid's one switch (MB::Sound::Kernels, kernels-1): an extracted plot gem would keep a registry of its own that mb-sound's drives, as mb-term's Grid.native is" => [
      'mb/sound/plot/live.rb: Kernels', 'mb/sound/plot/mark.rb: Kernels', 'mb/sound/plot/raster.rb: Kernels', 'mb/sound/plot/text.rb: Kernels',
    ],
    "plot.rb loads mb-sound's previews (MB_SOUND_SIDE); mb-sound would require them itself" => [
      'mb/sound/plot.rb: require_relative plot/panels', 'mb/sound/plot.rb: require_relative plot/presets',
    ],
  }.freeze

  def self.crossings(files = FILES) = BoundaryCheck.crossings(files, requires: REQUIRES)
end

RSpec.describe('plot boundary') do
  it 'covers the plot files except the previews of mb-sound' do
    expect(PlotBoundary::FILES.length).to eq(18)
    expect(PlotBoundary::FILES).to include('mb/sound/plot.rb', 'mb/sound/plot/text.rb', 'mb/sound/plot/live.rb')
    PlotBoundary::MB_SOUND_SIDE.each { |f| expect(File.exist?(File.join(BoundaryCheck::LIB, f))).to eq(true), "#{f} is gone" }
  end

  it 'reads only the mb-sound names listed in ADAPTERS' do
    found = PlotBoundary.crossings
    listed = PlotBoundary::ADAPTERS.values.flatten
    new_ones = found.reject { |c| listed.include?(c.key) }
    gone = listed - found.map(&:key)
    expect(new_ones.map(&:to_s)).to eq([]), "plotting reaches into mb-sound (move the code to mb-sound's side, MB_SOUND_SIDE, or list it in ADAPTERS with what an extraction would do):\n#{new_ones.join("\n")}"
    expect(gone).to eq([]), "ADAPTERS lists crossings that are gone; remove them:\n#{gone.join("\n")}"
  end

  it 'would catch a new reference to mb-sound' do
    path = tmp_path('plot_probe.rb')
    File.write(path, "module MB; module Sound; module Plot; class Probe; def f = Tone.new(GraphNode::Constant.new(1)); end; end; end; end\n")
    found = PlotBoundary.crossings(PlotBoundary::FILES + [path]).select { |c| c.file.end_with?('plot_probe.rb') }
    expect(found.map(&:name)).to contain_exactly('Tone', 'GraphNode::Constant')
  end
end

require 'spec_helper'
require_relative '../../../../support/sf2_writer'

# What loading a SoundFont kit costs, counted, not timed (bg-latency-1,
# 2026-11-22: `track :drums, kit(:acoustic)` then `bg :drums,
# L.gen.beat.rock` took seconds twice over, because the font cache let go
# of the font during the first build's garbage collections and the second
# build read and built it all again).
RSpec.describe 'Loading SoundFont kits', :aggregate_failures do
  let(:sf2) { MB::Sound::Sampler::SF2 }
  let(:path) { SF2Writer.drum_kit(tmp_path('kit.sf2'), keys: [36, 38, 42, 46, 49], name: 'Spec Kit', velocity_layers: 2) }

  after do
    sf2.forget_recent
  end

  # The kit's instrument, made in a method of its own (so no stack slot
  # of the example keeps its Font).
  def kit_instrument
    MB::Sound.sf2(path, preset: [0, 0])
  end

  # A full collection with nothing recent kept.
  def collect
    sf2.forget_recent
    1000.times { Object.new }
    GC.start(full_mark: true, immediate_sweep: true)
  end

  it 'reads a font once while an instrument it made is used, across garbage collections' do
    inst = kit_instrument
    opened = sf2.opened
    3.times do
      collect
      expect(kit_instrument.regions.map(&:sample)).to eq(inst.regions.map(&:sample))
    end
    expect(sf2.opened).to eq(opened)
    expect(inst.regions.length).to eq(10)
  end

  it 'keeps the fonts opened last cached when nothing uses them' do
    MB::Sound.sf2(path, preset: [0, 0])
    opened = sf2.opened
    GC.start(full_mark: true, immediate_sweep: true)
    MB::Sound.sf2(path, preset: [0, 0])
    expect(sf2.opened).to eq(opened)
    expect(sf2::RECENT_FONTS).to eq(2)
  end
end

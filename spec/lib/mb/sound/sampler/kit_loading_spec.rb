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
    MB::Sound.rewind
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

  describe 'tables for the keys a clip plays (Sampler::Reach)' do
    let(:kit_path) { SF2Writer.drum_kit(tmp_path('gm_kit.sf2'), keys: [36, 38, 42, 46, 49, 51], name: 'Spec GM Kit', bank: 128, velocity_layers: 2) }
    let(:kit) { MB::Sound.sf2(kit_path, preset: [128, 0]) }
    let(:beat) { MB::Sound.grid(16, kick: 'x...x...x...x...', hat: 'x.x.x.x.x.x.x.x.').to_clip.loop }
    let(:more) { MB::Sound.grid(16, kick: 'x.......x.......', snare: '....x.......x...', ride: 'x.x.x.x.x.x.x.x.').to_clip.loop }

    # The samples of +inst+ whose tables are built.
    def built(inst)
      inst.regions.map(&:sample).uniq.select { |s| s.audio.table?(0, s.mips.nil? ? inst.mips : s.mips) }
    end

    # +count+ frames of +inst+ playing +clip+ in a Session (swapped to
    # +swap+ at frame 48000 when given), at +n+ frames a buffer.
    def render(inst, clip, n: 512, swap: nil, frames: 96_000)
      MB::Sound.rewind
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, buffer_size: n, sleep: false), realtime: false)
      out = []
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.bpm 120
        MB::Sound.track(:drums) { |c| inst.sampler(c, voices: 4) }
        MB::Sound.bg(:drums, clip)
      }
      (frames / n).times do |i|
        if swap && i == 48_000 / n
          MB::Sound::Session.with_context(session: s) { MB::Sound.swap(:drums, swap) }
          @after_swap = built(inst).length
        end
        out << s.process_buffer.map(&:dup)
        @after_landing = built(inst).length if swap && i == 48_000 / n + 24
      end
      out.map { |b| b.map(&:to_a) }
    ensure
      s&.close
    end

    # A fresh copy of the kit's font (its own samples and tables).
    def fresh_kit(name)
      MB::Sound.sf2(SF2Writer.drum_kit(tmp_path("#{name}.sf2"), keys: [36, 38, 42, 46, 49, 51], name: 'Spec GM Kit', bank: 128, velocity_layers: 2), preset: [128, 0])
    end

    # 4 s of +inst+ playing the beat, +change+ (a Proc run in the Session's
    # context) made at 0.5 s; returns the buffers and how many sample
    # tables were built inside #process_buffer (the render thread's work).
    def render_path(inst, change, frames: 192_000, n: 512)
      MB::Sound.rewind
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, buffer_size: n, sleep: false), realtime: false)
      rendering = false
      in_render = 0
      allow(MB::Sound::Wavetable::Builder).to receive(:sample_levels).and_wrap_original { |m, *a| in_render += 1 if rendering; m.call(*a) }
      out = []
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.bpm 120
        MB::Sound.track(:drums) { |c| inst.sampler(c, voices: 4) }
        MB::Sound.bg(:drums, beat)
      }
      (frames / n).times do |i|
        MB::Sound::Session.with_context(session: s) { change.call } if i == 24_000 / n
        rendering = true
        out << s.process_buffer.map(&:to_a)
        rendering = false
      end
      [out, in_render]
    ensure
      s&.close
    end

    # Each way notes other than the beat's can reach the kit (the
    # maintainer plays a kit track from the keyboard after a beat): what
    # it plays equals a full build's, and no table is built while
    # rendering.
    {
      'a swap to a clip with a new key' => -> { MB::Sound.swap(:drums, MB::Sound.grid(16, snare: '....x.......x...').to_clip.loop) },
      'a bg of a clip with a new key' => -> { MB::Sound.bg(:drums, MB::Sound.grid(16, snare: '....x.......x...').to_clip.loop) },
      'a transposed clip (36 -> 38)' => -> { MB::Sound.swap(:drums, MB::Sound.grid(16, kick: 'x...x...x...x...').to_clip.loop.transpose(2)) },
      'a transpose knob (keys unknown ahead: the whole kit)' => -> {
        MB::Sound.knob(:tr, 2, range: -12..12)
        MB::Sound.swap(:drums, MB::Sound.grid(16, kick: 'x...x...x...x...').to_clip.loop.transpose(MB::Sound.knob(:tr)))
      },
      'a morphed generator (both sides\' keys)' => -> { MB::Sound.swap(:drums, MB::Sound::L.gen.beat.rock.morph(:funk, morph: 0.5)) },
      'a generator without values: (the whole kit)' => -> { MB::Sound.swap(:drums, MB::Sound.generate(1.bar) { |_c, _d| [[0r, 1/16r, 36, 1.0], [1/4r, 1/16r, 38, 1.0]] }.loop) },
      'a beats clip with a role the kit plays through a fallback' => -> { MB::Sound.swap(:drums, MB::Sound.beats(16, seed: 3) { half_open_hat [1, 0] * 8; kick [1, 0, 0, 0] * 4 }) },
      'wire (the monitor builds the whole kit)' => -> { MB::Sound.wire(:drums, MB::Sound.grid(16, snare: '....x.......x...').to_clip.loop.stream) },
      'arm with an input stream (the monitor builds the whole kit)' => -> { MB::Sound.arm(:drums, input: MB::Sound.grid(16, snare: '....x...x...x...').to_clip.loop.stream) },
    }.each do |what, change|
      it "sounds every key it reaches after #{what}, with nothing built while rendering" do
        reached, in_render = render_path(kit, change)
        allow(MB::Sound::Sampler::Reach).to receive(:for).and_return(nil)
        full, = render_path(fresh_kit('full'), change)
        expect(reached).to eq(full)
        expect(in_render).to eq(0)
      end
    end

    it 'a note on a key nobody covered builds the rest of the kit and says so: the next hit sounds (the safety net)' do
      MB::Sound.live = true
      # (a generator that plays 38 though its values: say only 36)
      liar = -> { MB::Sound.swap(:drums, MB::Sound.generate(1.bar, values: [36]) { |_c, _d| [[0r, 1/16r, 36, 1.0], [1/4r, 1/16r, 38, 1.0]] }.loop) }
      reached = nil
      expect { reached, = render_path(kit, liar, frames: 192_000) }.to output(/Spec GM Kit: key 38 had no playback table yet; building the rest of the kit's tables/).to_stdout
      expect(built(kit).length).to eq(12) # (every key: the rest of the kit)
      MB::Sound.live = false
      allow(MB::Sound::Sampler::Reach).to receive(:for).and_return(nil)
      full, = render_path(fresh_kit('full_net'), liar, frames: 192_000)
      differ = reached.each_index.reject { |i| reached[i] == full[i] }
      expect(differ.length).to be_between(1, 2) # (the first hit's first buffer only)
    ensure
      MB::Sound.live = false
    end

    it 'builds only the tables of the regions on the clip\'s keys, and plays them as a full build does' do
      expect(kit.drum_map).not_to be_nil
      syn = kit.sampler(beat, voices: 4)
      expect(built(kit).length).to eq(4) # (kick and closed hat, two velocity layers each)
      expect(syn.clip_sources.length).to eq(1)

      reached = render(kit, beat)
      allow(MB::Sound::Sampler::Reach).to receive(:for).and_return(nil)
      full = render(MB::Sound.sf2(SF2Writer.drum_kit(tmp_path('gm_kit2.sf2'), keys: [36, 38, 42, 46, 49, 51], name: 'Spec GM Kit', bank: 128, velocity_layers: 2), preset: [128, 0]), beat)
      expect(reached).to eq(full)
      expect(reached.flatten.max).to be > 0.1
    end

    it 'builds the new keys\' tables when a swap is made, not where it lands, and plays the swap as a full build does' do
      reached = render(kit, beat, swap: more)
      expect(@after_swap).to eq(8) # (snare and ride added before the swap was queued)
      expect(@after_landing).to eq(8)

      allow(MB::Sound::Sampler::Reach).to receive(:for).and_return(nil)
      other = MB::Sound.sf2(SF2Writer.drum_kit(tmp_path('gm_kit3.sf2'), keys: [36, 38, 42, 46, 49, 51], name: 'Spec GM Kit', bank: 128, velocity_layers: 2), preset: [128, 0])
      full = render(other, beat, swap: more)
      expect(reached).to eq(full)
    end

    it 'a second bg of another clip on a playing kit track swaps the clip: no new patch build, no font read' do
      MB::Sound.rewind
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, buffer_size: 512, sleep: false), realtime: false)
      builds = 0
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.track(:drums) { |c| builds += 1; MB::Sound.sf2(kit_path, preset: [128, 0]).sampler(c, voices: 4) }
        MB::Sound.bg(:drums, beat)
      }
      20.times { s.process_buffer }
      before = builds
      opened = sf2.opened
      MB::Sound::Session.with_context(session: s) { MB::Sound.bg(:drums, more) }
      200.times { s.process_buffer }
      expect(builds).to eq(before)
      expect(sf2.opened).to eq(opened)
      expect(built(kit).length).to eq(8) # (the swap covered the snare and ride)
    ensure
      s&.close
    end

    it 'leaves kits played from a stream, and other instruments, building every table' do
      expect(MB::Sound::Sampler::Reach.for(kit, beat)).not_to be_nil
      expect(MB::Sound::Sampler::Reach.for(kit, beat.stream)).to be_nil
      expect(MB::Sound::Sampler::Reach.for(MB::Sound.sf2(path, preset: [0, 0], roles: false), beat)).to be_nil
    end

    it 'says at the console how many samples it is building tables for' do
      MB::Sound.live = true
      expect { kit.sampler(beat, voices: 2) }.to output(/Spec GM Kit: building playback tables for 4 samples \(first use\)/).to_stdout
      expect { kit.sampler(beat, voices: 2) }.not_to output.to_stdout
    ensure
      MB::Sound.live = false
    end
  end
end

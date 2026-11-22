require 'spec_helper'
require_relative '../../../../support/sf2_writer'

# The drum beat generators, L.gen.beat (drum-gen-1).  A sweep over every
# entry of the family: anchors at every energy above 0, energy only adds
# hits, hits per bar per role in a range, fills in the phrase's last bar,
# knobs, saving, and a short render on the 909 and on a synthetic kit.
RSpec.describe MB::Sound::Library::Generators, 'drum beats', :aggregate_failures do
  let(:lib) { MB::Sound::Library }
  let(:roles) { MB::Sound::Drums::Roles }
  let(:beats) { MB::Sound::L.gen.beat.entries }

  # The phase-1 beats (more may join the family; the sweeps take them all).
  let(:names) { %i[rock pop halftime funk house dnb techno] }

  # [step, key] of every hit of +clip+'s +cycle+ (16 steps a bar).
  def hits(clip, cycle)
    clip.events_for(cycle).map { |e| [(e.start * 16).floor, MB::Sound::Note.new(e.value).number.round] }.sort
  end

  def role_of(key) = roles::NAMES[key]

  it 'has the phase-1 beats, each with energy and swing knobs (techno energy only), tags, a tempo range, a kit, and an example' do
    expect(beats.map(&:name)).to include(*names)
    beats.each do |e|
      expect(e.family).to eq(:beat)
      expect(e.head_path).to eq("L.gen.beat.#{e.name}")
      expect(e.tags).to include(:drums)
      expect(e.about).to match(/\d+-\d+ BPM/), e.name.to_s
      expect(e.about).to include("L.gen.beat.#{e.name}"), e.name.to_s
      expect(MB::Sound::Arrangement::InstrumentPatch.entry_for(e.settings[:instrument], track: :x)).to be_a(lib::Entry)
      knobs = lib::Generators.knob_params(e)
      expect(knobs).to include(:energy)
      expect(knobs).to include(:swing) unless e.name == :techno
      expect(e.params[:swing].range).to eq(0.5..0.75) if e.params[:swing]
    end
    expect(%i[rock pop halftime funk dnb].map { |n| MB::Sound::L.gen.beat.word(n).settings[:instrument] }.uniq).to eq([:acoustic])
    expect(%i[house techno].map { |n| MB::Sound::L.gen.beat.word(n).settings[:instrument] }.uniq).to eq([:tr909])
  end

  it 'keeps its anchors at every energy above 0, and energy only adds hits (the knob contract)' do
    beats.each do |e|
      clips = [0.1, 0.3, 0.5, 0.75, 1.0].map { |en| e.call(seed: 3, energy: en) }
      8.times do |cycle|
        sets = clips.map { |c| hits(c, cycle) }
        sets.each_cons(2) { |lo, hi| expect(lo - hi).to eq([]), "#{e.name} bar #{cycle + 1}: more energy dropped #{(lo - hi).inspect}" }
        # anchors: the kick on the one at the lowest energy
        expect(sets[0]).to include([0, roles.note(:kick)]), "#{e.name} bar #{cycle + 1}"
      end
    end
  end

  # The maintainer, 2026-11-22: "energy acted kind of like a density
  # control on the techno beat": on every beat energy is density with the
  # techno beat's law, on any kit (velocity, hat openness, and cymbal
  # choice are other knobs).
  it 'treats energy as density, as on the techno beat: anchors near 0, as written at 0.5, more hits at every step up, a wide range' do
    levels = [0.01, 0.25, 0.5, 0.75, 1.0]
    beats.each do |e|
      per_bar = levels.map { |en| [3, 4, 5].sum { |sd| c = e.call(seed: sd, energy: en); (0...7).sum { |cy| hits(c, cy).length } } / 21.0 }
      per_bar.each_cons(2) { |a, b| expect(b).to be > a, "#{e.name}: #{levels.zip(per_bar.map { |x| x.round(1) }).to_h}" }
      expect(per_bar.last / per_bar.first).to be >= 2.2, "#{e.name}: #{per_bar.map { |x| x.round(1) }}"
      # near 0 only the anchors play: the same hits for every seed
      # (the law scales probabilities by 2 x energy: at 0.01 a written 0.5
      # still plays once in a hundred bars; at 0.001, once in a thousand)
      low = [3, 4, 5].map { |sd| c = e.call(seed: sd, energy: 0.001); (0...7).flat_map { |cy| hits(c, cy).map { |h| [cy, *h] } } }
      common = low.reduce(:&)
      low.each { |l| expect((l - common).length).to be <= 2, "#{e.name}: #{(l - common).inspect} beyond the anchors near 0" }
      # 0.5 plays the rows as written (the default)
      expect((0...8).map { |cy| hits(e.call(seed: 3), cy) }).to eq((0...8).map { |cy| hits(e.call(seed: 3, energy: 0.5), cy) })
      # energy changes hits, never their velocities
      a = e.call(seed: 3, energy: 0.3).events_for(2).to_h { |x| [[x.start, x.value], x.velocity] }
      b = e.call(seed: 3, energy: 0.9).events_for(2).to_h { |x| [[x.start, x.value], x.velocity] }
      a.each { |k, v| expect(b[k]).to eq(v), "#{e.name}: the velocity of #{k.inspect} moved with energy" }
    end
  end

  it 'plays a sensible number of hits per bar per role, and the backbeat where its genre puts it' do
    beats.each do |e|
      [0.1, 0.5, 1.0].each do |en|
        c = e.call(seed: 4, energy: en)
        7.times do |cycle| # (bars before the fill)
          h = hits(c, cycle)
          per = h.group_by { |_, k| role_of(k) }.transform_values(&:length)
          expect(per[:kick]).to be_between(1, 6), "#{e.name} #{en} bar #{cycle + 1}: #{per}"
          expect(per.values.max).to be <= 16
          expect(h.length).to be_between(3, 40), "#{e.name} #{en} bar #{cycle + 1}: #{per}"
          next if e.name == :techno || e.name == :house
          back = e.name == :halftime ? [8] : [4, 12]
          back.each { |s| expect(h).to include([s, roles.note(:snare)]), "#{e.name} #{en} bar #{cycle + 1}" }
        end
      end
    end
  end

  it 'fills in the last bar of each 8-bar phrase, in its second half, more at higher energy' do
    beats.reject { |e| e.name == :techno }.each do |e|
      drums = [roles.note(:snare), roles.note(:low_floor_tom), roles.note(:low_tom), roles.note(:mid_tom)]
      # snare and tom hits in a bar's second half (steps 8..15), and before it
      late = ->(c, bar) { hits(c, bar).count { |st, k| st >= 8 && drums.include?(k) } }
      early = ->(c, bar) { hits(c, bar).count { |st, k| st < 8 && drums.include?(k) } }
      lo = e.call(seed: 5, energy: 0.5)
      hi = e.call(seed: 5, energy: 1.0)
      phrases = 0...4
      fill = phrases.sum { |p| late.(hi, 8 * p + 7) } / 4.0
      groove = phrases.sum { |p| (0...7).sum { |b| late.(hi, 8 * p + b) } } / 28.0
      expect(fill).to be >= groove + 1.5, "#{e.name}: #{fill} fill hits against #{groove.round(2)} in other bars' second halves"
      expect(phrases.sum { |p| early.(hi, 8 * p + 7) } / 4.0).to be <= phrases.sum { |p| (0...7).sum { |b| early.(hi, 8 * p + b) } } / 28.0 + 1.0, e.name.to_s
      calm = phrases.sum { |p| late.(lo, 8 * p + 7) } / 4.0
      expect(fill).to be > calm, e.name.to_s
    end
  end

  it 'gives the same bars for the same values (and a seed picks another)' do
    beats.each do |e|
      a = e.call(seed: 7, energy: 0.8)
      b = e.call(seed: 7, energy: 0.8)
      expect((0...8).map { |c| hits(a, c) }).to eq((0...8).map { |c| hits(b, c) })
      expect((0...8).map { |c| hits(e.call(seed: 8, energy: 0.8), c) }).not_to eq((0...8).map { |c| hits(a, c) })
    end
  end

  it 'swings its odd steps with the swing knob' do
    rock = MB::Sound::L.gen.beat.rock
    straight = rock.call(seed: 3, energy: 1.0, swing: 0.5).events_for(0).map(&:start)
    swung = rock.call(seed: 3, energy: 1.0, swing: 0.75).events_for(0).map(&:start)
    expect(swung.sort).not_to eq(straight.sort)
    expect(straight.map { |s| (s * 16).denominator }.uniq).to eq([1])
  end

  it 'prints, saves, and loads as L.gen.beat.<name>(...), in graph and set documents' do
    io = MB::Sound::GraphIO
    beats.each do |e|
      c = e.call(seed: 3, energy: 0.8)
      call = "L.gen.beat.#{e.name}(seed: 3, energy: 0.8)"
      expect(c.to_ruby).to eq(call)
      doc = io.dump(MB::Sound.tr909(c))
      expect(doc).to include(call)
      expect(io.load(doc).to_ruby).to include(call)
    end
    s = MB::Sound::Session.new(realtime: false)
    begin
      MB::Sound::Session.with_context(session: s) {
        MB::Sound.track(:drums, :tr909)
        MB::Sound.scene(:a, drums: MB::Sound::L.gen.beat.rock(seed: 9))
      }
      text = io.dump(s.arrangement, name: 'g')
      expect(text).to include('L.gen.beat.rock(seed: 9)', 'knob :"drums/energy"', 'knob :"drums/swing", (0.5..0.75).at(0.5)')
      s2 = MB::Sound::Session.new(realtime: false)
      begin
        MB::Sound::Session.with_context(session: s2) { io.load(text) }
        # (without the saved: stamps: two saves a second apart differ there;
        # fixes-16, spec_hygiene_spec)
        expect(io.dump(s2.arrangement, name: 'g').sub(/saved: "[^"]*"/, '')).to eq(text.sub(/saved: "[^"]*"/, ''))
      ensure
        s2.close
      end
    ensure
      s.close
      MB::Sound.rewind
    end
  end

  it 'renders on the 909 and on a kit with the acoustic layout, every role landing on a key the kit plays' do
    dir = File.dirname(tmp_path('fonts/x'))
    FileUtils.mkdir_p(dir)
    SF2Writer.drum_kit(File.join(dir, 'Black_Pearl_Spec.sf2'), keys: 35..61, name: 'Black Pearl')
    MB::Sound::Sampler::FontPath.only = [dir]
    kit = MB::Sound.sf2('Black_Pearl_Spec', preset: [0, 0])
    plays = ->(k) { kit.regions.any? { |r| k.between?(*r.keys) } }
    beats.each do |e|
      c = e.call(seed: 3, energy: 1.0)
      written = (0...8).flat_map { |cy| hits(c, cy).map(&:last) }.uniq
      written.each do |k|
        expect(plays.(k)).to eq(true), "#{e.name}: #{role_of(k)} (#{k}) plays nothing on the acoustic layout (#{kit.drum_map.remap[k].inspect})"
        expect(MB::Sound::Drums::TR909::GM_MAP.values.flatten).to include(k), "#{e.name}: #{role_of(k)} (#{k}) on the 909"
      end
      MB::Sound.bpm(120)
      peak = c.sampler(kit, voices: 8).multi_sample(800, 30).abs.max
      expect(peak).to be > 0.01, e.name.to_s
    end
    one = MB::Sound.tr909(MB::Sound::L.gen.beat.rock(seed: 3)).multi_sample(800, 30)
    expect(one.abs.max).to be > 0.01
  ensure
    MB::Sound.rewind
  end
end

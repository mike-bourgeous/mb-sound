RSpec.describe(MB::Sound::Genre, :aggregate_failures) do
  # (knobs, racks, and players made here join the default Session; see
  # spec/support/session_guard.rb)
  after { MB::Sound::Session.existing&.close }

  let(:genre) { MB::Sound::Genre }

  # Evaluates +code+ inside MB::Sound, where note names resolve.
  def in_sound(code)
    MB::Sound.module_eval(code)
  end

  describe 'the shipped templates' do
    # ux-fix-1 (maintainer: "follow the pump"): bus ducks keyed by :sidechain
    it "keys dnb's :hall duck from the template's sidechain: the kick, or the pump" do
      bundle = MB::Sound.stereo(1.constant, 1.constant)
      expect(genre[:dnb].bus_chain(:hall, bundle).to_ruby).to include('.duck(:drums, only: :kick, amount: -6.db, release: 1.n8)')
      pumped = genre[:dnb].with { sidechain :pump, :pump }
      expect(pumped.bus_chain(:hall, MB::Sound.stereo(1.constant, 1.constant)).to_ruby).to include('.duck(:pump, amount: -6.db, release: 1.n8)')
    end

    # ux-fix-1 item 3: :ambient's key was :yo, which wasn't a scale
    it "builds every template's key as a scale" do
      genre.names.each do |name|
        t = MB::Sound.genre(name)
        next unless t.key

        expect { t.scale }.not_to raise_error, "#{name}: #{t.key.inspect}"
        expect(t.scale).to be_a(MB::Sound::Scale)
      end
      expect(MB::Sound.genre(:ambient).scale.notes(MB::Sound::D4..MB::Sound::C5).map(&:name)).to eq(%w[D4 E4 G4 A4 B4])
    end

    it 'lists the panel genres and the stubs' do
      expect(genre.names).to include(:dnb, :jungle, :ambient, :funk, :house, :techno)
    end

    MB::Sound::Genre.names.each do |name|
      it "builds #{name} and prints it back as Ruby that builds an equal template" do
        t = genre[name]
        expect(t).to be_a(MB::Sound::Genre::Template)
        expect(t).to be_frozen
        code = t.to_ruby
        expect(code).not_to include('FIXME')
        expect(code).to start_with("Genre.template #{name.inspect}")
        expect(in_sound(code)).to eq(t)
        expect(t.tempo_range).to cover(t.tempo)
        expect(t.tips).not_to be_empty
        expect(t.inspect).to include("genre #{name.inspect}", 'BPM')
      end

      it "gives every #{name} form section a scene whose tracks are roles" do
        t = genre[name]
        t.form.sections.each_value do |s|
          values = t.scene(s.scene || s.name)
          tracks = values.keys - MB::Sound::Genre::SCENE_OPTIONS - t.knobs.keys
          expect(tracks - t.roles.keys).to eq([])
          tracks.each { |k| expect(values[k]).to be_a(MB::Sound::Sequence::Clip).or be_a(MB::Sound::Sequence::Kit).or be_nil.or be_a(Symbol) }
        end
      end
    end

    it 'keeps the persona songs\' numbers' do
      dnb = genre[:dnb]
      expect(dnb.tempo).to eq(174)
      expect(dnb.form.steps.map(&:first)).to eq([:intro, :build, :drop, :breakdown, :pullup, :drop2, :outro])
      expect(dnb.form.steps.map { |n, _| dnb.form.sections[n].length }.first(3).sum).to eq(72)
      expect(dnb.kits[:drop][:kick].events.map(&:start)).to eq([0, 5/8r]) # the two-step
      expect(dnb.roles[:bass].patch).to eq(:dnb_reese)
      expect(dnb.mix.true_peak.to_db).to be_within(1e-9).of(-0.5)

      expect(genre[:jungle].tempo).to eq(165)
      expect(genre[:ambient].clips[:bowl_a].length).to eq(197/40r) # 19.7 s at 60 BPM
      expect(genre[:ambient].clips[:bowl_a].to_ruby).to end_with('.clocked(19.7.seconds)') # (its own clock: 19.7 s at any tempo)
      expect(genre[:ambient].roles.values_at(:rain, :wind).map(&:to)).to eq([:weather, :weather])
      expect(genre[:ambient].buses[:weather].steps).to eq([[:hiss, [], {}]])
      expect(genre[:house].sidechain).to eq([:drums, :kick])
      expect(genre[:techno].buses.keys).to eq([:rumble, :echo])
      expect(genre[:house].form.bars).to eq(136) # (Munro: 16, 16, 16, 32, 8, 32, 16)
      expect(genre[:funk].scenes[:keys]).to eq({ beat: :beat, bass: :bass, keys: :keys })
      expect(genre[:funk].scale).to be_a(MB::Sound::Scale)
    end
  end

  describe 'generated forms (G4)' do
    MB::Sound::Genre.names.each do |name|
      it "writes #{name}'s form from its generator: the same sections, lengths per occurrence, fills kept, another form per seed" do
        t = genre[name]
        g = t.generator
        expect(g).not_to be_nil
        v = t.generative
        expect(v.form).to be_generative
        passes = v.form.plan(seed: 0, bar_length: t.bar_length).first(300)
        # Finite songs (the source ends or the generator's count)
        expect(passes.length).to be < 300
        expect(passes.map(&:section) - t.scenes.keys).to eq([])
        passes.each do |p|
          spec = g.bars.fetch(p.section) { t.form.sections[p.section].length }
          allowed = spec.is_a?(Range) || spec.is_a?(Array) ? spec.to_a : [spec]
          expect(allowed).to include(p.length), "#{p.section} #{p.length} not in #{spec.inspect}"
        end
        # Fills of the written form's sections carry over
        t.form.sections.each_value do |sec|
          expect(v.form.sections[sec.name]&.fill).to eq(sec.fill) if sec.fill && v.form.sections.key?(sec.name)
        end
        expect(v.form.phrase_fills).to eq(t.form.phrase_fills)
        others = (1..6).map { |sd| t.generative(seed: sd).form.plan(seed: 0, bar_length: t.bar_length).first(300).map { |p| [p.section, p.length] } }
        expect(others.uniq.length).to be > 2
        # The template prints its generator and comes back equal
        expect(t.to_ruby).to include("  generator #{g.source.to_ruby}")
        # The generated copy's form prints back as a flow that builds again
        again = in_sound(v.form.to_ruby.sub('flow do', 'MB::Sound::Form.build do'))
        expect(again).to eq(v.form)
      end
    end

    it 'plays the ambient template forever, its key walking under the moods (genre(:ambient).endless)' do
      t = genre[:ambient]
      e = t.endless
      plan = e.form.plan(seed: 0)
      expect(plan.first(500).length).to eq(500) # (no end)
      expect(plan.first(500).map(&:section).tally.keys).to contain_exactly(:emerge, :drift, :bloom, :hush, :tide, :dissolve)
      # The walking material plays where the scenes played :drone, :motif, :harp
      expect(e.scenes[:bloom]).to include(drone: :drone_walk, motif: :motif_walk, harp: :harp_walk)
      expect(t.scenes[:bloom]).to include(drone: :drone, motif: :motif, harp: :harp)
      # The drone follows the key: one root per 16 bars, D, G, A, or E
      roots = (0...24).map { |k| t.clips[:drone_walk].events_for(2 * k).map(&:value).uniq }
      expect(roots.flatten.uniq - [38, 31, 33, 40]).to eq([]) # (D2, G1, A1, E2)
      expect(roots.flatten.uniq.length).to be > 1
      expect(t.generative.form.plan(seed: 0).first(100).length).to eq(12)
    end

    it 'checks generators: sources, scenes, lengths, and swaps' do
      expect { genre.template(:x) { like :dnb; generator :nope } }.to raise_error(ArgumentError, /generator needs a markov/)
      expect { genre.template(:x) { like :dnb; generator markov(intro: { dropp: 1 }, dropp: { intro: 1 }, seed: 1), bars: { dropp: 8 } } }
        .to raise_error(ArgumentError, /generator section :dropp has no scene :dropp.*Did you mean\?\s+:drop/m)
      expect { genre.template(:x) { like :dnb; generator markov(intro: { drop: 1 }, drop: { intro: 1 }, seed: 1), use: { riff: :rif } } }
        .to raise_error(ArgumentError, /use: names :rif, which is no kit or clip/)
      expect { genre[:funk].with { generator nil }.generative }.to raise_error(ArgumentError, /has no generator/)
    end
  end

  describe 'composing' do
    it 'overrides fields with keywords and parts with a builder block' do
      t = MB::Sound.genre(:dnb, tempo: 172)
      expect(t.tempo).to eq(172)
      expect(t.roles).to eq(genre[:dnb].roles)

      t2 = in_sound('genre(:dnb) { tempo 170; role :bass, :jungle_reese, level: -2.db; without roles: [:pluck], scenes: [] }')
      expect(t2.tempo).to eq(170)
      expect(t2.roles[:bass].patch).to eq(:jungle_reese)
      expect(t2.roles[:bass].level.to_db).to be_within(1e-9).of(-2)
      expect(t2.roles).not_to have_key(:pluck)
      expect(t2.to_ruby).to include('role :bass, :jungle_reese, level: -2.db')
      expect(genre[:dnb].roles[:bass].patch).to eq(:dnb_reese)
    end

    it 'defines new templates from others with like' do
      after_cleanup = -> { genre.instance_variable_get(:@definitions).delete(:spec_roller); genre.instance_variable_get(:@built).delete(:spec_roller) }
      genre.define(:spec_roller, 'Roller') { like :dnb; tempo 172; master nil; master :limit, ceiling: -1.db }
      t = genre[:spec_roller]
      expect(t.title).to eq('Roller')
      expect(t.form).to eq(genre[:dnb].form)
      expect(t.mix.master).to eq([[:limit, [], { ceiling: -1.db }]])
      expect(in_sound(t.to_ruby)).to eq(t)
    ensure
      after_cleanup&.call
    end

    it 'builds layered scenes for a looper' do
      t = in_sound(<<~RUBY)
        Genre.template(:spec_loop) do
          tempo 90
          flow { a 2; b 2 }
          clip :x, seq(C3).n4.loop
          role :a, :tr808
          role :b, :tr808
          layers a: :x, b: :x
        end
      RUBY
      expect(t.scenes).to eq({ a: { a: :x }, b: { a: :x, b: :x } })
    end

    it 'shortens the form by a power of two, at least a bar a section, with fills and bars: params' do
      t = genre[:dnb]
      s = t.short(60)
      lengths = s.form.sections.transform_values(&:length)
      expect(lengths).to eq({ intro: 8, build: 2, drop: 8, breakdown: 4, pullup: 1, drop2: 8, outro: 8 })
      expect(s.form.sections[:build].fill.length).to eq(1)
      expect(s.form.sections[:breakdown].fill.length).to eq(2)
      expect(s.form.phrase_fills.first.every).to eq(4)
      expect(s.roles[:riser].params[:bars]).to eq(1)
      expect(s.seconds).to be_within(10).of(60)
      expect(t.short(10_000)).to equal(t)
    end
  end

  describe 'checks' do
    def build(&block)
      genre.template(:spec_bad, &block)
    end

    it 'suggests builder methods for typos' do
      expect { build { tempo 120; flow { a 1 }; scnee :a } }.to raise_error(NoMethodError, /scene/)
    end

    it 'raises for scenes naming unknown roles or material, sections without scenes, and odd tempos' do
      expect { build { tempo 120; flow { a 1 }; scene :a, bas: :x; role :bass, :tr808 } }.to raise_error(ArgumentError, /bas.*bass/m)
      expect { build { tempo 120; flow { a 1 }; role :bass, :tr808; scene :a, bass: :nope } }.to raise_error(ArgumentError, /no kit or clip/)
      expect { build { tempo 120; flow { a 1; b 1 }; scene :a } }.to raise_error(ArgumentError, /section :b has no scene/)
      expect { build { tempo 200, range: 100..140; flow { a 1 }; scene :a } }.to raise_error(ArgumentError, /outside its range/)
      expect { build { tempo 120; flow { a 1 }; scene :a; role :x, :tr808, duck: -6.db } }.to raise_error(ArgumentError, /no sidechain/)
      expect { build { tempo 120; flow { a 1 }; scene :a; role :x, :tr808, filter: :cut } }.to raise_error(ArgumentError, /no knob/)
      expect { build { flow { a 1 }; scene :a } }.to raise_error(ArgumentError, /needs a tempo/)
      expect { build { tempo 120; flow { a 1 }; scene :a; role :x, :tr808, params: { cutoff: :cutt } } }.to raise_error(ArgumentError, /param cutoff: names :cutt, which is no knob/)
      expect { build { tempo 120; flow { a 1 }; scene :a; role :x, :tr808, params: { cutoff: 'x' } } }.to raise_error(ArgumentError, /numbers or knob names/)
      expect { genre[:nope] }.to raise_error(ArgumentError, /No genre :nope/)
    end
  end

  describe 'mix targets' do
    it 'reports loudness and true peak against the targets' do
      mix = genre[:dnb].mix
      result = Struct.new(:integrated, :true_peak).new(-9.2, -0.3)
      expect(mix.report(result)).to eq(['loudness -9.2 LUFS (target -10..-8: on target)', 'true peak -0.30 dBTP (ceiling -0.5: over)'])
      expect(mix.report(result.class.new(-12.0, -1.0)).first).to include('quiet')
      expect(mix.report(result.class.new(-7.0, -1.0)).first).to include('loud')
      expect(mix.summary).to include('-10..-8 LUFS', 'mono below 120 Hz', 'master filter -> club')
    end

    it 'reports the side below 120 Hz (or mono_below) against the mid' do
      t = 48000
      lo = Numo::SFloat.new(t).seq.map { |i| Math.sin(2 * Math::PI * 50 * i / 48000.0) }
      hi = Numo::SFloat.new(t).seq.map { |i| Math.sin(2 * Math::PI * 1000 * i / 48000.0) }
      result = Struct.new(:integrated, :true_peak).new(-7.0, -1.0)
      mono = [lo + hi, lo - hi]  # side only above 120 Hz
      wide = [lo + hi, -lo + hi] # all of the lows in the side
      expect(genre[:dnb].mix.report(result, mono).last).to match(/\Aside below 120 Hz -\d\d+\.\d dB re mid \(mono_below 120: mono\)\z/)
      expect(genre[:dnb].mix.report(result, wide).last).to match(/side below 120 Hz \d+\.\d dB re mid \(mono_below 120: not mono\)/)
      expect(genre[:ambient].mix.report(result, mono).last).to include('(no mono_below)')
      expect(genre[:jungle].mix.report(result, mono).last).to start_with('side below 150 Hz')
      expect(genre[:dnb].mix.report(result, [lo]).length).to eq(2)
    end

    it 'uses mono_below only for club and vinyl targets' do
      expect(genre.names.select { |n| genre[n].mix.mono_below }).to match_array([:dnb, :jungle, :house, :techno])
    end
  end

  describe 'playing' do
    include PatchHelpers # (band_share, seconds)

    it 'sets up tracks, knobs, and scenes, and plays the form from presets and tr808' do
      path = tmp_path('genre.flac')
      t = genre[:funk].short(20)
      MB::Sound.render(path, bars: 3, tail: false) do
        t.play
        expect(MB::Sound::Session.current.arrangement.tracks.keys).to match_array(t.roles.keys)
        expect(MB::Sound::Session.current.arrangement.scenes.keys).to match_array(t.scenes.keys)
        expect(MB::Sound.transport.bpm).to eq(96)
      end
      data = MB::Sound.read(path)
      peak = data.map { |c| c.abs.max }.max
      expect(peak).to be_between(0.05, 0.9)
      expect(data[0].length).to be_within(48).of((3 * 4 * 60 / 96.0 * 48000).round)
    end

    it 'sets up buses and routes, and saves them in a set document that loads to the same text' do
      new_session = -> {
        MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), channels: 2,
                               transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      }
      a = new_session.()
      b = new_session.()
      t = genre[:dnb].short
      text = MB::Sound::Session.with_context(session: a) { t.setup; MB::Sound::GraphIO.dump(a.arrangement, name: 'dnb') }
      expect(a.bus_names).to eq([:hall])
      expect(a.route_definitions[:drums]).to eq({ to: nil, send: { hall: -24.db.to_f } })
      expect(a.route_definitions[:bass][:send]).to eq({ hall: -20.db.to_f })
      expect(a.route_definitions).not_to have_key(:sub)
      expect(text).to include('bus(:hall) { |sig|', '.duck(:drums, only: :kick, amount: -6.db, release: 1.n8)')
      expect(text).to include('track(:drums, send: { hall: -24.db })')
      # (breakdown: the hats-only kit keeps a silent kick row for the ducks)
      expect(text).to match(/kick: grid\(16, kick: "\.{16}"\)\[:kick\]\.loop\(align: :launch\)/)
      MB::Sound::GraphIO.load(text, session: b)
      expect(b.route_definitions).to eq(a.route_definitions)
      again = MB::Sound::GraphIO.dump(b.arrangement, name: 'dnb')
      expect(again.sub(/saved: "[^"]*"/, '')).to eq(text.sub(/saved: "[^"]*"/, ''))
    ensure
      a&.close
      b&.close
    end

    it 'chops the jungle break through the sampler: slices of breakbeat(:jungle) with pitch marks' do
      t = genre[:jungle]
      chop = t.clips[:chop_a]
      expect(chop.instrument).to be_a(MB::Sound::Sample::Slices)
      expect(chop.instrument.sample.file).to end_with('jungle_breaks.mbg/assets/jungle_record.flac')
      expect(chop.events.map(&:pitch).compact.uniq.sort).to eq([3, 5, 6]) # (+3: 138.75 BPM to 165; [:g, 2], [:s, 3])
      expect(chop.to_ruby).to start_with('breakbeat(:jungle).slices(32).name(k: 0..1')
      expect(t.roles[:breaks].patch).to eq(:breaks)
      expect(t.to_ruby).not_to include('Note.new')
    end

    it 'lets template knobs drive preset params and puts mono_below first in the master chain' do
      MB::Sound.knob(:cut, 600, range: 150..8000, curve: :exp)
      bass = genre[:dnb].patch(:bass, genre[:dnb].clips[:riff])
      expect(bass.to_ruby).to include('lp4(knob(:cut)')
      master = MB::Sound::Genre.master_chain(MB::Sound.stereo(1.constant, 1.constant).mono_below(120), genre[:jungle].mix.master)
      expect(master.to_ruby).to include('mono_below(120).compress(')
    end

    it 'filters, levels, and ducks a role under the drums track\'s kick voice' do
      t = genre[:dnb]
      clip = t.clips[:riff]
      MB::Sound.knob(:cut, 2400, range: 150..8000, curve: :exp)
      node = t.patch(:sub, clip)
      expect(node.to_ruby).to include('duck(:drums, only: :kick, amount: -12.db')
      expect { t.patch(:nope, clip) }.to raise_error(ArgumentError, /No role :nope/)
      expect { MB::Sound::Genre.build_patch(:no_such_patch_x, clip) }.to raise_error(ArgumentError, /No preset or method/)
    end

    it 'keys the ducks from a trigger line instead (dnb\'s ghost-kick pump option): a trigger track under every scene' do
      t = genre[:dnb].with { sidechain :pump, :pump }
      expect(t.sidechain).to eq([:pump, nil, :pump, nil])
      expect(t.trigger_track).to eq(:pump)
      expect(in_sound(t.to_ruby)).to eq(t)
      expect(t.to_ruby).to include('  sidechain :pump, :pump')
      t.scenes.each do |name, values|
        next if values[:others] == :keep
        expect(t.scene(name)[:pump]).to equal(t.clips[:pump])
      end
      expect(t.scene(:riser)).not_to have_key(:pump)
      MB::Sound.knob(:cut, 2400, range: 150..8000, curve: :exp)
      expect(t.patch(:sub, t.clips[:riff]).to_ruby).to include('duck(:pump, amount: -12.db')

      # A clip given to sidechain joins the clips; a scene can rest the line
      off = genre[:dnb].with {
        sidechain :pump, grid(16, 'x...').loop, shape: :impulse
        scene :breakdown, drums: :breakdown, pad: :chords, pump: :off
      }
      expect(off.clips[:pump]).not_to equal(genre[:dnb].clips[:pump])
      expect(off.scene(:breakdown)[:pump]).to eq(:off)
      expect(off.to_ruby).to include('sidechain :pump, :pump, shape: :impulse')

      s = MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 2, sleep: false), channels: 2,
                                 transport: MB::Sound::Sequence::Transport.new(bpm: 120))
      MB::Sound::Session.with_context(session: s) do
        t.short.setup
        expect(s.trigger_tracks).to eq([:pump])
        expect(s.arrangement.tracks[:pump].trigger).to eq(true)
        expect(s.arrangement.scenes[:drop].values[:pump]).to equal(t.clips[:pump])
      end
    ensure
      s&.close
    end

    it 'checks trigger lines: names unlike roles, knobs, and buses, and lines that are clips' do
      expect { genre[:dnb].with { sidechain :bass, :pump } }.to raise_error(ArgumentError, /trigger track :bass is named like a role/)
      expect { genre[:dnb].with { sidechain :pump, :nope } }.to raise_error(ArgumentError, /trigger line :nope is no clip/)
      expect { genre[:dnb].with { sidechain :pump, :pump, shape: :wobble } }.to raise_error(ArgumentError, /shape:/)
      expect { genre[:dnb].with { sidechain :pump, :pump, only: :kick } }.to raise_error(ArgumentError, /only:/)
    end

    it 'rolls the techno bass between the kicks: a short sub with a noise tick, ducked by the kick voice' do
      t = genre[:techno]
      expect(t.roles[:bass].patch).to eq(:roller)
      expect(t.roles[:bass].duck).to eq(-4.db)
      expect(t.roles[:bass].level).to eq(2.db)
      expect(t.sidechain).to eq([:drums, :kick])
      MB::Sound.knob(:cut, 400, range: 150..6000, curve: :exp)

      # The roller alone: stereo, its tick above 1 kHz, its low end mono
      path = tmp_path('roller.flac')
      MB::Sound.render(path, bars: 1, tail: false) do
        MB::Sound.bpm 132
        MB::Sound.bg :bass, MB::Sound::Genre::Patches.roller(t.clips[:bass]), fade: 0
      end
      l, r = MB::Sound.read(path)
      expect(l).not_to eq(r) # (the room)
      expect(band_share(l.dup, 1000, 8000)).to be > 0.002 # (a short tick: 0.34% of the power)
      side = l - r
      expect(band_share(side.dup, 0, 120) * (side**2).sum).to be < (l**2).sum * 1e-4

      # Ducked: the bass is quieter right after each kick than with no duck
      plain = t.with(roles: t.roles.merge(bass: t.roles[:bass].with(duck: nil)))
      level = ->(tt) {
        p2 = tmp_path("roller_#{tt.equal?(t) ? 'duck' : 'plain'}.flac")
        MB::Sound.render(p2, bars: 1, tail: false) do
          MB::Sound.bpm 132
          # (the drums play muted: a source something reads keeps feeding it)
          MB::Sound.bg :drums, tt.patch(:drums, tt.kits[:peak]), fade: 0
          MB::Sound.mute :drums
          MB::Sound.bg :bass, tt.patch(:bass, tt.clips[:bass]), fade: 0
        end
        x = MB::Sound.read(p2)[0]
        beat = 60.0 / 132
        (0...4).sum { |b| (seconds(x, b * beat + beat / 4, b * beat + beat / 2)**2).sum }
      }
      expect(10 * Math.log10(level.(t) / level.(plain))).to be < -3
    end

    it 'tames the techno stab, with the heavy drive as an option, and masters techno with the club preset (two limiters)' do
      t = genre[:techno]
      expect(t.roles[:stab].patch).to eq(:stab)
      expect(t.mix.master).to eq([[:club, [], {}]])

      clip = MB::Sound.seq(MB::Sound::F3).n2
      # Clipping a stab lowpassed at 240 Hz (its -3 dB point at the patch's
      # resonance 0.25 is 326 Hz with lp4's musical tuning, like the hardware
      # tuning's 300 Hz) makes harmonics above 1 kHz: the heavy drive (the
      # Reese's) has 6 dB more there than the default (8.5)
      high_share = ->(drive) {
        MB::Sound.seed(5)
        node = MB::Sound::Genre::Patches.stab(clip, cutoff: 240, drive: drive)
        x = Numo::DFloat.cast(Numo::SFloat.hstack(Array.new(24) { node.outputs.map { |o| o.sample(800).dup }[0] })[4800..])
        f = Numo::Pocketfft.rfft(x).abs**2
        10 * Math.log10(f[(1000 * x.length / 48000.0).round..].sum / f.sum)
      }
      expect(high_share.(1.0) - high_share.(0.1)).to be > 6
      expect { MB::Sound::Genre::Patches.stab(clip) }.not_to raise_error
    end
  end
end

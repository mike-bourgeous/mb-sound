RSpec.describe(MB::Sound::Genre, :aggregate_failures) do
  let(:genre) { MB::Sound::Genre }

  # Evaluates +code+ inside MB::Sound, where note names resolve.
  def in_sound(code)
    MB::Sound.module_eval(code)
  end

  describe 'the shipped templates' do
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
      expect(genre[:ambient].buses[:weather].steps).to eq([[:ambient_tape, [], { wear: :wear }]])
      expect(genre[:house].sidechain).to eq([:drums, :kick])
      expect(genre[:techno].buses.keys).to eq([:rumble, :echo])
      expect(genre[:house].form.bars).to eq(136) # (Munro: 16, 16, 16, 32, 8, 32, 16)
      expect(genre[:funk].scenes[:keys]).to eq({ beat: :beat, bass: :bass, keys: :keys })
      expect(genre[:funk].scale).to be_a(MB::Sound::Scale)
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

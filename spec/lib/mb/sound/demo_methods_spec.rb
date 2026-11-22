RSpec.describe(MB::Sound::DemoMethods) do
  # (its own transport: the set sets the tempo and meter of the Session's transport)
  let(:session) { MB::Sound::Session.new(realtime: false, output: MB::Sound::NullOutput.new(channels: 1, sleep: false), channels: 1, transport: MB::Sound::Sequence::Transport.new(bpm: 120)) }

  after { session.close }

  def within(&block)
    MB::Sound::Session.with_context(session: session, &block)
  end

  it 'loads the Night Bus set paused at bar 1, saying what to try, and returns it again' do
    doc = nil
    expect { doc = within { MB::Sound.demo } }.to output(/demo :night_bus.*paused at bar 1.*tracks  drums sub bass.*scenes  intro groove.*Try:.*go :groove/m).to_stdout
    expect(doc.kind).to eq(:set)
    expect(doc.form).to be_a(MB::Sound::Form)
    expect(session.players).to be_empty
    expect(session.transport.position).to eq(0)
    expect(session.arrangement.tracks.keys).to include(:drums, :hook, :pad)
    expect(within { MB::Sound.demo }).to equal(doc)

    within { MB::Sound.go(:drop) }
    20.times { session.process_buffer(800) }
    expect(session.players.keys).to include(:drums, :hook)
  end

  it 'loads Tunnel Vision with its buses, sends, and kick-keyed ducks' do
    doc = nil
    expect { doc = within { MB::Sound.demo(:tunnel_vision) } }.to output(/demo :tunnel_vision.*paused at bar 1.*tracks  pad pluck drums/m).to_stdout
    expect(session.bus_names).to eq(%i[hall echo])
    routes = session.route_definitions
    expect(routes[:pluck][:send]).to eq({ echo: :space, hall: 0.25 })
    expect(routes[:drums][:send][:hall]).to be_within(1e-12).of(-24.db.to_f)
    expect(routes).not_to have_key(:sub)
    expect(doc.form.steps.map(&:first)).to start_with(:intro, :build, :drop)

    within { MB::Sound.go(:drop) }
    20.times { session.process_buffer(800) }
    expect(session.players.keys).to include(:drums, :reese, :sub)
  end

  it 'stops what plays and loads paused at bar 1' do
    within { MB::Sound.bg(:hum, 110.hz.at(0.1), on: :now) }
    session.process_buffer(800)
    expect { within { MB::Sound.demo(:night_bus) } }.to output(/paused at bar 1/).to_stdout
    expect(session.players).to be_empty
    expect(session.transport.position).to eq(0)
  end

  # fixes-15 (the maintainer, 2026-11-18: "A new demo should replace the
  # entire previous demo"): Night Bus then Tunnel Vision raised a
  # NoMethodError, then a name clash (Night Bus's knob :echo, Tunnel
  # Vision's bus :echo)
  it 'replaces the demo before it, playing or not, and undo puts it back' do
    expect { within { MB::Sound.demo(:night_bus) } }.to output(/paused at bar 1/).to_stdout
    within { MB::Sound.go(:drop) }
    10.times { session.process_buffer(800) }
    expect(session.players.keys).to include(:drums, :hook)
    night = session.arrangement

    expect { within { MB::Sound.demo(:tunnel_vision) } }.to output(
      /demo :tunnel_vision.*paused at bar 1\n  replaced demo :night_bus \(12 tracks, 12 scenes, 5 knobs, a master chain, and a flow\) \(undo puts it back\)/
    ).to_stdout
    expect(session.players).to be_empty
    expect(session.transport.position).to eq(0)
    expect(session.arrangement.tracks.keys).to eq(%i[pad pluck drums reese sub neuro boom riser])
    expect(session.knobs.keys).to eq(%i[cut grit space air lift])
    expect(session.bus_names).to eq(%i[hall echo])
    expect(session.knobs[:cut].spec.range).to eq(150.0..8000.0)

    within { MB::Sound.undo(on: :now) }
    4.times { session.process_buffer(800) }
    expect(session.arrangement).to equal(night)
    expect(session.knobs.keys).to eq(%i[cut space echo air morph])
    expect(session.bus_names).to eq([])
    expect(session.players.keys).to include(:drums, :hook) # (its players back, on: :now)
    expect(within { MB::Sound.demo }.path).to end_with('night_bus.mbg.rb')

    within { MB::Sound.redo!(on: :now) }
    4.times { session.process_buffer(800) }
    expect(session.arrangement.tracks.keys).to start_with(:pad, :pluck)
    expect(session.bus_names).to eq(%i[hall echo])
  end

  it 'suggests names for unknown demos and lists the demos' do
    expect { within { MB::Sound.demo(:night_buss) } }.to raise_error(ArgumentError, /No demo :night_buss.*night_bus/)
    expect { MB::Sound.demos }.to output(/:night_bus +"Night Bus: Last Stop".*:tunnel_vision +"Tunnel Vision"/m).to_stdout
  end

  # fixes-15 (the maintainer's 2026-11-16 note "cannot load tunnel vision"):
  # loading a demo again kept a NoMethodError from its Hz knobs
  it 'loads the same demo again, its knobs back at their defaults' do
    expect { within { MB::Sound.demo(:tunnel_vision) } }.to output(/paused at bar 1/).to_stdout
    within { MB::Sound.turn(:cut, 5000.hz) }
    session.process_buffer(800)
    expect { within { MB::Sound.demo(:tunnel_vision) } }.to output(/paused at bar 1/).to_stdout
    session.process_buffer(800)
    expect(session.knobs[:cut].value).to eq(2400.0)
    expect(session.knobs[:cut].spec.range).to eq(150.0..8000.0)
  end

  it 'reports a bug while loading as one line naming where it was raised' do
    bug = NoMethodError.new("undefined method 'to_f' for an instance of MB::Sound::Pitch")
    bug.set_backtrace(["#{File.expand_path('../../../../lib/mb/sound/graph_node/knob.rb', __dir__)}:176:in 'clamp'"])
    allow(MB::Sound::GraphIO).to receive(:load).and_raise(bug)
    expect { within { MB::Sound.demo(:tunnel_vision) } }.to raise_error(MB::Sound::GraphIO::LoadError) { |e|
      expect(e.message).to match(%r{\Ademo :tunnel_vision didn't load .*NoMethodError: undefined method 'to_f'.* at lib/mb/sound/graph_node/knob.rb:176, a bug in mb-sound\z})
      expect(e.cause).to equal(bug)
      expect(MB::Sound::ErrorFormat.console(e, color: false).lines.length).to eq(1)
    }

    # (an error mb-sound raises on purpose stays as it is)
    allow(MB::Sound::GraphIO).to receive(:load).and_raise(MB::Sound::GraphIO::LoadError.new('x.mbg.rb:3: no such thing'))
    expect { within { MB::Sound.demo(:tunnel_vision) } }.to raise_error(MB::Sound::GraphIO::LoadError, 'x.mbg.rb:3: no such thing')
  end

  it 'finds every demo\'s set document, plain or a bundle' do
    MB::Sound::DemoMethods::DEMOS.each_key do |name|
      file = MB::Sound::DemoMethods.demo_file(name)
      expect(File.file?(file)).to eq(true), "#{name}: #{file}"
      expect(MB::Sound::GraphIO.parse(file).kind).to eq(:set)
    end
  end

  it 'lists the demos on its help page' do
    page = MB::Sound::ColorPolicy.strip(MB::Sound.help(:demos).to_s)
    expect(page).to include('A demo set to explore')
    MB::Sound::DemoMethods::DEMOS.each_key { |name| expect(page).to match(/^  demo #{Regexp.escape(name.inspect)} +\S/) }
  end

  # The class guard of fixes-17 (a merge train's console run, 2026-11-22:
  # `demo :n109` then `start` printed an ArgumentError for every section
  # from the warm-up's rehearsal, which only runs live, with YJIT, on a
  # realtime Session): every demo loaded and started as the console does
  # it (live mode, a realtime Session on a virtual clock, the warm-up and
  # its rehearsal), then launched scene by scene, warns of nothing.  The
  # slow tier plays the first 8 bars, the everyday run 2.
  describe 'every demo, started as the console starts it' do
    before { allow(MB::Sound::JIT).to receive(:compiling?).and_return(true) } # (the rehearsal runs only with YJIT)

    after do
      MB::Sound.live = false
      @live&.close
      MB::Sound.rewind
    end

    # Lets +session+ (a virtual clock) play +seconds+ in steps of four
    # buffers, each after the scheduler has run what its lookahead handed
    # it, as a machine that renders instantly would (an unpaced virtual
    # clock outruns the scheduler's scene builds, and every section then
    # lands late with a LateBlock warning, which isn't what the console
    # does).
    def paced(session, seconds)
      sched = session.instance_variable_get(:@scheduler)
      step = 4 * session.buffer_size.to_f / session.sample_rate
      (seconds / step).ceil.times do
        MB::Sound::Internal.wait_audio(session, step)
        deadline = MB::U.clock_now + 60
        until (q = sched.instance_variable_get(:@queue)).nil? || (q.empty? && sched.instance_variable_get(:@running).nil?)
          raise 'the scheduler ran one block for over 60 s' if MB::U.clock_now > deadline
          Thread.pass
        end
      end
    end

    MB::Sound::DemoMethods::DEMOS.each_key do |name|
      it "starts #{name.inspect} and launches each of its scenes with no error or warning" do
        out = MB::Sound::NullOutput.new(channels: 2, sleep: :virtual, buffer_size: 800)
        @live = MB::Sound::Session.new(output: out, realtime: true, channels: 2, buffer_size: 800, transport: MB::Sound::Sequence::Transport.new(bpm: 120))
        MB::Sound.live = true
        bars = [2, *slow_tier([8], keep: 0)].max
        status = nil
        expect {
          expect {
            MB::Sound::Session.with_context(session: @live) do
              MB::Sound.demo(name)
              status = MB::Sound.start
              bar = @live.transport.bar_length * 240r / @live.transport.bpm
              paced(@live, (bars * bar).to_f)
              @live.arrangement.scenes.each_key do |scene|
                MB::Sound.go(scene)
                paced(@live, (1.25r * bar).to_f)
              end
            end
          }.not_to output.to_stderr
        }.to output(/demo #{name.inspect}.*Warmed up \d+ tracks and \d+ sections/m).to_stdout
        expect(status.state).to eq(:started)
        expect(@live.arrangement.rehearsal).to be > 0
        expect(@live.players).not_to be_empty
      end
    end
  end

  it 'is not taken by Pry or another MB::Sound method' do
    require 'pry'
    expect(Pry::Commands.keys.map(&:to_s)).not_to include('demo', 'demos')
    expect(MB::Sound.method(:demo).owner).to eq(MB::Sound::DemoMethods)
    expect(MB::Sound.method(:demos).owner).to eq(MB::Sound::DemoMethods)
  end
end

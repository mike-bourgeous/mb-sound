require 'weakref'

RSpec.describe(MB::Sound::ExitClose) do
  # Builds a Synth played by a realtime Session, returning WeakRefs to
  # both.
  def weak_synth_in_session(close:)
    session = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sample_rate: 48000, sleep: false), realtime: true, buffer_size: 800)
    synth = MB::Sound::Synth.new(MB::Sound.seq(MB::Sound::C3, MB::Sound::E3).n4.loop, voices: 2) { |v| v.hz.sine.at(0.2) * v.amp_env }
    session.add(synth, name: :leak)
    expect(described_class.registered?(session)).to eq(true)
    session.close if close
    [WeakRef.new(synth), WeakRef.new(session)]
  end

  def weak_registered(klass)
    o = klass.new(:dropped)
    described_class.register(o)
    WeakRef.new(o)
  end

  # How many of +refs+ survive a full GC.  A few dropped objects may stay
  # on the machine stack (conservative scanning), so specs make ten and
  # allow three, like the plan installation spec.
  def alive(refs)
    2.times { GC.start(full_mark: true, immediate_sweep: true) }
    refs.count(&:weakref_alive?)
  end

  it 'lets closed realtime Sessions and their graphs be garbage collected' do
    # Each Session's at_exit { close } block once kept it, and every graph
    # it played, alive until exit
    refs = 10.times.map { weak_synth_in_session(close: true) }
    expect(alive(refs.map(&:first))).to be <= 3
    expect(alive(refs.map(&:last))).to be <= 3
  end

  it 'forgets a Session when it closes' do
    s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sample_rate: 48000, sleep: false), realtime: true)
    s.ensure_running
    expect(described_class.registered?(s)).to eq(true)
    s.close
    expect(described_class.registered?(s)).to eq(false)
  end

  it 'holds registered objects weakly and closes the live ones latest first' do
    closed = []
    klass = Class.new { define_method(:initialize) { |n| @n = n }; define_method(:close) { closed << @n } }
    a = klass.new(:a)
    b = klass.new(:b)
    weak = 10.times.map { weak_registered(klass) }
    described_class.register(a)
    described_class.register(b)
    expect(alive(weak)).to be <= 3

    expect(described_class.objects & [a, b]).to eq([b, a])
    (described_class.objects & [a, b]).each(&:close)
    expect(closed).to eq([:b, :a])
  ensure
    described_class.unregister(a) if a
    described_class.unregister(b) if b
  end

  it 'is the only way library code closes things at exit' do
    # A block given to at_exit is a GC root: whatever it refers to lives
    # until the process exits.  Register objects with ExitClose instead.
    # Allowed: blocks that refer only to module-level state.
    allowed = {
      'lib/mb/sound/exit_close.rb' => 'the one hook; holds objects weakly',
      'lib/mb/sound/ui.rb' => 'stops the UI module\'s own band and tiles (module instance variables, not captured objects)',
    }
    root = File.expand_path('../../../..', __dir__)
    found = Dir[File.join(root, 'lib/**/*.rb')].select { |f|
      File.read(f).lines.any? { |l| l.sub(/#.*/, '').match?(/\bat_exit\s*(\{|do\b)/) }
    }.map { |f| f.delete_prefix("#{root}/") }
    expect(found - allowed.keys).to eq([])
  end
end

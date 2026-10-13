# Guards the GraphNode DSL against readers that shadow it: a node class
# defining (say) a +filter+ reader made `lp4(800).filter(:highpass, ...)`
# raise instead of adding a filter (research-api-surface P1, fixed
# 2026-10-13).  Node classes keep their internals in instance variables or
# under names that aren't DSL methods; a class may still define a DSL name
# if the method calls super or is listed in ALLOWED with the reason.
RSpec.describe('GraphNode DSL shadowing', :aggregate_failures) do
  # Deliberate overrides of DSL names, by the class that defines them.
  ALLOWED = {
    'MB::Sound::GraphNode::Knob#get_sampler' => 'a new Knob::Reader per consumer instead of a Tee (the Session advances knobs once per span)',
    'MB::Sound::GraphNode::NodeSequence#and_then' => 'appends to the same sequence instead of nesting NodeSequences',
    'MB::Sound::Pitch#freq' => 'a Pitch is a frequency: its Hz as a node (the DSL converts note numbers to Hz)',
    'MB::Sound::Note#freq' => 'the note\'s Hz in the current tuning (the DSL would read the sine as a note number)',
    'MB::Sound::Notes::NotePitch#freq' => 'the keyboard\'s Hz node (glide, bend, vibrato)',
    'MB::Sound::Pitch#tone' => 'a Tone at this pitch (the DSL would use the sine as a frequency)',
    'MB::Sound::Notes::NotePitch#tone' => 'a KeyedTone at the played pitch',
    'MB::Sound::Pitch#wavetable' => 'a wavetable oscillator at this pitch (Tone#wavetable)',
    'MB::Sound::Tone#wavetable' => 'sets the oscillator\'s waveform to a table (the DSL reads a table at this signal\'s phase)',
    'MB::Sound::Pitch#at' => 'a sine Tone at this pitch and amplitude (Tone#at)',
  }.freeze

  def dsl_names
    MB::Sound::GraphNode.included_modules
      .select { |m| m.name&.start_with?('MB::Sound::GraphNode::') && m.name.end_with?('Methods') }
      .flat_map { |m| m.public_instance_methods(false) }.uniq -
      %i[sample sample_rate sample_rate= sources to_s inspect]
  end

  # Skips recorders (anonymous modules from GraphNode::Recipe) to the method
  # that does the work.
  def real_method(um)
    um = um.super_method while um.owner.name.nil? && um.super_method
    um
  end

  def calls_super?(um)
    RubyVM::InstructionSequence.of(um)&.disasm.to_s.include?('invokesuper')
  end

  it 'finds no GraphNode class whose own methods (public or private) shadow a DSL method' do
    classes = ObjectSpace.each_object(Class).select { |c| c.name&.start_with?('MB::') && c.include?(MB::Sound::GraphNode) }
    expect(classes.length).to be > 90

    names = dsl_names
    expect(names.length).to be > 100

    found = {}
    classes.each do |c|
      names.each do |name|
        next unless c.method_defined?(name) || c.private_method_defined?(name)

        um = real_method(c.instance_method(name))
        owner = um.owner.name.to_s
        next if owner.empty? || owner == 'MB::Sound::GraphNode' || owner.include?('ChannelDispatch')
        next if owner.start_with?('MB::Sound::GraphNode::') && owner.end_with?('Methods')
        next if calls_super?(um)

        found["#{owner}##{name}"] ||= um.source_location&.join(':')
      end
    end

    unexpected = found.reject { |k, _| ALLOWED.key?(k) }
    expect(unexpected).to eq({}), "Rename these readers (or keep the value in an instance variable), or list them in ALLOWED:\n" +
      unexpected.map { |k, at| "  #{k} (#{at})" }.join("\n")
    expect(ALLOWED.keys - found.keys).to eq([]) # stale entries
  end

  describe 'chains that used to hit a reader' do
    it 'adds a filter after a four-pole filter' do
      node = 220.hz.ramp.lp4(800).filter(:highpass, cutoff: 100)
      expect(node).to respond_to(:sample)
      expect(node.sample(64).length).to eq(64)
      expect(220.hz.ramp.lp4(800).kernel_filter).to be_a(MB::Sound::Filter::FourPole)
    end

    it 'adds a reverb after one reverb output' do
      a, b = 220.hz.ramp, 330.hz.ramp
      node = [a, b].reverb(:hall).outputs[0].reverb(:plate)
      expect(node).to be_a(MB::Sound::GraphNode::Reverb)
      expect(node.outputs[0].sample(64).length).to eq(64)
    end

    it 'reaches the stereo width method from a Tone and a Formant' do
      expect { 220.hz.sine.width(0.5) }.to raise_error(ArgumentError, /width needs a multichannel node/)
      expect { 220.hz.ramp.formant(:a).width(0.5) }.to raise_error(ArgumentError, /width needs a multichannel node/)
      expect(100.hz.pwm(0.2).square.pwm_width).to eq(0.2)
    end

    it 'tells sync from softsync with soft_sync?' do
      expect(100.hz.ramp.softsync(ratio: 2).soft_sync?).to eq(true)
      expect(100.hz.ramp.sync(ratio: 2).soft_sync?).to eq(false)
    end

    it 'splits a Tee branch again' do
      a, b = 220.hz.ramp.tee(2)[0].tee(2)
      expect(a).to be_a(MB::Sound::GraphNode::Tee::Branch)
      expect(a.owner_tee).to equal(b.owner_tee)
      expect(a.sample(16)).to eq(b.sample(16))
    end

    it 'gives an envelope and an SQ-80 time scale as seconds' do
      expect(MB::Sound.adsr(0.1, 0.1, 0.5, 0.2).seconds).to be_a(MB::Sound::Length::Seconds)
      ts = MB::Sound::SQ80::TimeScale.new(0.5, 1.constant, :velocity, 1.0)
      expect(ts.seconds).to be_a(MB::Sound::Length::Seconds)
      expect(ts.time_seconds).to eq(0.5)
    end

    it 'delays a multitap tap again and reads silence as seconds' do
      taps = 220.hz.ramp.multitap(0.001, 0.002)
      node = taps[0].delay(0.001)
      expect(node).to respond_to(:sample)
      expect(node.sample(64).length).to eq(64)
      expect(MB::Sound.silence(0.1).seconds).to be_a(MB::Sound::Length::Seconds)
    end

    it 'converts a resonator as note numbers with freq' do
      expect(1.constant.ping(100, decay: 0.3).freq).to respond_to(:sample)
    end
  end
end

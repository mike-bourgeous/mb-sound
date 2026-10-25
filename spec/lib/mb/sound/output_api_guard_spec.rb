# Outputs that subclass another output must keep its API's meaning: a
# subclass method with an API name changes what Sessions read every buffer
# (alloc-2/fuzz-fixes-1, 2026-10-25: CaptureOutput#channels returned the
# captured audio, hstacking everything captured so far each time a Session
# read the channel count, which made a bounce's render quadratic).  Every
# API method an output subclass defines must call super, or be listed here
# with the reason it keeps the meaning (omnibus13).
RSpec.describe('output API guard') do
  # What Session, render, and the scripts read from an output.
  API = %i[channels buffer_size sample_rate write close closed? latency end_stream release_writer frames_written].freeze

  # [class name, method] => reason
  ALLOWED = {}.freeze

  def output_classes
    roots = [MB::Sound::NullOutput, MB::Sound::IOOutput, MB::Sound::DeviceOutput, MB::Sound::BackgroundOutput]
    # (named classes only: not the stand-in below)
    ObjectSpace.each_object(Class).select { |c| c.name && roots.any? { |r| c < r } && (Object.const_get(c.name) rescue nil).equal?(c) }
  end

  def calls_super?(klass, name)
    m = klass.instance_method(name)
    RubyVM::InstructionSequence.of(m)&.disasm.to_s.include?('invokesuper')
  end

  it 'finds the output subclasses' do
    expect(output_classes).to include(MB::Sound::Sampler::CaptureOutput, MB::Sound::Structure::Capture, MB::Sound::FFMPEGOutput)
  end

  def shadowing(classes)
    classes.flat_map { |c|
      API.filter_map { |name|
        next unless c.instance_methods(false).include?(name) || c.private_instance_methods(false).include?(name)
        next if c.superclass.method_defined?(name) == false # (the class introduces it)
        next if calls_super?(c, name) || ALLOWED.key?([c.name, name])

        "#{c.name}##{name} (#{c.instance_method(name).source_location&.join(':')})"
      }
    }
  end

  it 'keeps the output API in subclasses (calling super or listed with a reason)' do
    bad = shadowing(output_classes)
    expect(bad).to eq([]), "output subclasses redefining API methods without super:\n#{bad.join("\n")}"
  end

  it 'would have caught CaptureOutput#channels' do
    stand_in = Class.new(MB::Sound::NullOutput) do
      def self.name = 'StandIn'
      def channels = @bufs
      def write(data) = super
    end
    expect(shadowing([stand_in])).to contain_exactly(a_string_starting_with('StandIn#channels'))
  end

  it 'gives the channel count, buffer size, and rate as numbers that stay the same between writes' do
    output_classes.select { |c| c <= MB::Sound::NullOutput }.each do |c|
      o = c.new(channels: 2, sample_rate: 48000, buffer_size: 800)
      o.write([Numo::SFloat.zeros(800), Numo::SFloat.zeros(800)]) rescue nil
      expect(o.channels).to eq(2), c.name
      expect(o.buffer_size).to eq(800), c.name
      expect(o.sample_rate).to eq(48000), c.name
      before = GC.stat(:total_allocated_objects)
      10.times { o.channels; o.buffer_size; o.sample_rate }
      expect(GC.stat(:total_allocated_objects) - before).to be < 5, "#{c.name}: reading the API allocates"
    ensure
      o&.close
    end
  end
end

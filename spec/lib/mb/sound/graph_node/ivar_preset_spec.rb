RSpec.describe(MB::Sound::GraphNode::IvarPreset) do
  let(:preset) { MB::Sound::GraphNode::IvarPreset }

  it 'is prepended to every class that includes GraphNode' do
    classes = ObjectSpace.each_object(Class).select { |c| c < MB::Sound::GraphNode && c.name }
    expect(classes.length).to be > 50
    expect(classes.reject { |c| c.ancestors.include?(preset::Init) }).to be_empty
  end

  it 'sets the declared variables before the constructor runs, in a fixed order' do
    tone = 440.hz.sine
    expect(tone.instance_variables.first(3)).to eq([:@node_type_name, :@graph_node_name, :@named])
    expect(tone.graph_node_name).to eq(nil)
    expect(tone.named?).to eq(false)

    # Naming and planning later don't add variables
    before = tone.instance_variables
    tone.named('x')
    expect(tone.instance_variables).to eq(before)
  end

  it 'reaches classes through modules that include GraphNode, and leaves variables a subclass set alone' do
    mod = Module.new { include MB::Sound::GraphNode }
    base = Class.new do
      include mod

      def initialize
        @own = 1
      end
    end
    sub = Class.new(base) do
      def initialize
        @node_type_name = 'early'
        super
      end
    end

    expect(base.ancestors).to include(preset::Init)
    obj = sub.new
    expect(obj.instance_variable_get(:@node_type_name)).to eq('early')
    expect(obj.instance_variables).to include(:@graph_recipe, :@plan_region, :@own)
    expect(obj.instance_variables.last).to eq(:@own)
  end

  it "includes the declarations of a class's other modules" do
    expect(preset.ivars_for(MB::Sound::Tone)).to include(:@ports, :@frame_count)
    expect(preset.ivars_for(MB::Sound::GraphNode::Multiplier)).to include(:@arithmetic_views)
    expect(preset.ivars_for(MB::Sound::GraphNode::Constant)).not_to include(:@ports)
  end

  # (replay-save-1: GraphNode::Dynamics, a Channels subclass, reached 8
  # shape variations from lazily set recipe and naming variables)
  it 'gives channel bundles and their subclasses the lazily set variables as nil' do
    stereo = 220.hz.saw.pan(0.2)
    dyn = 220.hz.saw.stereo.compress(threshold: -20.db)
    [stereo, dyn].each do |b|
      expect(b).to be_a(MB::Sound::GraphNode::Channels)
      expect(b.instance_variables).to include(*preset.ivars_for(MB::Sound::GraphNode))
    end
    expect(dyn).to be_a(MB::Sound::GraphNode::Dynamics)
  end
end

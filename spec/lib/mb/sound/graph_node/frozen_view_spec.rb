require 'prism'

RSpec.describe(MB::Sound::GraphNode::FrozenView) do
  # A source that returns one reused buffer, holding a new constant value
  # each buffer (a steady-looking input whose contents change).
  let(:stepper_class) do
    Class.new do
      include MB::Sound::GraphNode
      include MB::Sound::GraphNode::SampleRateHelper

      def initialize(values)
        @values = values
        @i = 0
        @buf = nil
        @sample_rate = 48000.0
      end

      def sample(count)
        return nil if @i >= @values.length

        @buf = Numo::SFloat.zeros(count) if @buf.nil? || @buf.length != count
        @buf.fill(@values[@i])
        @i += 1
        @buf
      end

      def sources
        {}
      end
    end
  end

  describe '#of' do
    let(:views) { described_class.new }

    it 'reuses one frozen view of the same buffer, with a new generation each time' do
      buf = Numo::SFloat[1, 2, 3]
      a = views.of(buf)
      ga = described_class.generation(a)
      b = views.of(buf)
      expect(b).to equal(a)
      expect(b).to be_frozen
      expect(described_class.generation(b)).not_to eq(ga)
      buf[0] = 5
      expect(b[0]).to eq(5)
    end

    it 'keeps views of two alternating buffers (multi-output nodes)' do
      a = Numo::SFloat[1, 2]
      b = Numo::SFloat[3, 4]
      va = views.of(a)
      vb = views.of(b)
      expect(views.of(a)).to equal(va)
      expect(views.of(b)).to equal(vb)
      expect(va).not_to equal(vb)
    end

    it 'makes a new view for a third buffer or another length' do
      a = Numo::SFloat[1, 2]
      va = views.of(a)
      views.of(Numo::SFloat[3, 4])
      views.of(Numo::SFloat[5, 6])
      expect(views.of(a)).not_to equal(va)
    end

    it 'gives generation 0 to frozen buffers it never handed out' do
      expect(described_class.generation(Numo::SFloat[1].freeze)).to eq(0)
    end
  end

  describe described_class::Key do
    let(:key) { described_class.new }

    it 'matches the same frozen buffer with the same generation only' do
      views = MB::Sound::GraphNode::FrozenView.new
      buf = Numo::SFloat[1, 2]
      v = views.of(buf)
      key.set(v)
      expect(key.match?(v)).to eq(true)
      views.of(buf)
      expect(key.match?(v)).to eq(false)
    end

    it 'matches a never-reused frozen buffer by identity' do
      c = Numo::SFloat[1, 2].freeze
      key.set(c)
      expect(key.match?(c)).to eq(true)
      expect(key.match?(Numo::SFloat[1, 2].freeze)).to eq(false)
    end

    it 'never matches unfrozen buffers' do
      b = Numo::SFloat[1, 2]
      key.set(b)
      expect(key.match?(b)).to eq(false)
    end
  end

  # Steady-input caches behind a Tee: the Tee's reused view changes
  # contents every buffer here, so a cache keyed on identity alone would
  # repeat the first buffer.
  describe 'steady-input caches behind a Tee' do
    let(:values) { [0.1, 0.4, 0.7, 0.2, 0.9] }

    def run(node, count = 16)
      out = []
      while (b = node.sample(count))
        out << b.to_a.dup
      end
      out
    end

    def lockstep(node, other, count = 16)
      out = []
      loop do
        buf = node.sample(count)
        other.sample(count)
        break if buf.nil?
        out << buf.to_a.dup
      end
      out
    end

    it 'CurveShaper (aease) follows a changing input' do
      src = stepper_class.new(values)
      a, b = src.tee
      got = lockstep(a.aease(:smoothstep), b)
      ref = run(stepper_class.new(values).aease(:smoothstep))
      expect(got).to eq(ref)
      expect(got.map(&:first).uniq.length).to eq(values.length)
    end

    it 'Length scaling follows a changing input' do
      src = stepper_class.new(values)
      a, b = src.tee
      len = MB::Sound::Length::Source.new(a)
      got = []
      while (s = len.samples(16, 48000))
        b.sample(16)
        got << s.to_a.dup
      end
      expect(got.map(&:first)).to eq(values.map { |v| (Numo::SFloat[v] * 48000)[0] })
    end

    it 'shares the Tee view with one object per branch per buffer' do
      src = stepper_class.new(values)
      a, b = src.tee
      x = a.sample(16)
      b.sample(16)
      y = a.sample(16)
      b.sample(16)
      expect(y).to equal(x)
      expect(y[0]).to be_within(1e-7).of(values[1])
    end
  end

  # Guard: caches must key frozen buffers on their generation (Key, or
  # FrozenView.generation), never on identity alone.  Flags every method in
  # lib/ that calls #equal? and also calls #frozen? or touches a
  # steady/quiet/fitted/scaled_from instance variable, unless listed in
  # +allowed+ with a reason.
  describe 'guard: no cache keyed on a frozen buffer identity alone' do
    allowed = {
      'circular_buffer.rb#peek' => 'compares its own reused view target, not an input buffer',
      'curve.rb#map!' => 'checks that the scratch buffer is not the input (aliasing), not a cache',
      'filter/delay.rb#process' => 'compares with the :end marker Symbol',
      'graph_node/recipe.rb#note' => 'recipe bookkeeping, not buffers',
      'midi/clip_source.rb#read_events' => 'compares clips and tempo Rationals, not buffers',
      'plan/installation.rb#watch' => 'compares graph nodes, not buffers',
      'plan/loop.rb#same_value?' => 'compares generations too (FrozenView.generation)',
      'session/racks.rb#used' => 'compares racks, not buffers',
      'synth.rb#initialize' => 'compares Notes objects, not buffers',
    }.freeze

    it 'finds no other method' do
      root = File.expand_path('../../../../../lib/mb/sound', __dir__)
      found = []
      Dir[File.join(root, '**/*.rb')].sort.each do |f|
        next if f.end_with?('graph_node/frozen_view.rb')

        rel = f.delete_prefix("#{root}/")
        stack = [Prism.parse_file(f).value]
        until stack.empty?
          n = stack.pop
          next unless n

          if n.is_a?(Prism::DefNode)
            names = []
            q = [n]
            until q.empty?
              m = q.pop
              next unless m

              names << m.name if m.is_a?(Prism::CallNode)
              if (m.is_a?(Prism::InstanceVariableReadNode) || m.is_a?(Prism::InstanceVariableWriteNode)) &&
                  m.name.to_s =~ /steady|quiet|fitted|scaled_from/
                names << :cache_ivar
              end
              q.concat(m.compact_child_nodes)
            end
            if names.include?(:equal?) && (names.include?(:frozen?) || names.include?(:cache_ivar))
              found << "#{rel}##{n.name}"
            end
          end
          stack.concat(n.compact_child_nodes)
        end
      end

      unexpected = found - allowed.keys
      expect(unexpected).to be_empty, "methods comparing buffers by identity next to frozen?/steady caches " \
        "(key on FrozenView::Key or FrozenView.generation, or list them in ALLOWED with a reason): #{unexpected.join(', ')}"
      expect(allowed.keys - found).to be_empty, "stale allowed entries: #{(allowed.keys - found).join(', ')}"
    end
  end
end

require 'shellwords'

RSpec.describe('MB::Sound::FastRecipe', :aggregate_failures) do
  let(:fast) { MB::Sound::FastRecipe }

  it 'loads when the GC runs at every allocation' do
    so = File.expand_path('../../../../lib/mb/sound/fast_recipe.so', __dir__)
    code = 'GC.stress = true; require ARGV[0]; GC.stress = false; p MB::Sound::FastRecipe.respond_to?(:frame_binding)'
    out = `ruby -e #{code.shellescape} #{so.shellescape} 2>&1`

    expect($?).to be_success, out
    expect(out.lines.last.to_s.strip).to eq('true'), out
  end

  describe '.frame_binding' do
    it "returns the running block's Binding, which sees locals assigned later" do
      captured = nil
      blk = proc { |x|
        a = x * 2
        captured = fast.frame_binding(RubyVM::InstructionSequence.of(blk))
        c = a + 1
        [a, c]
      }
      expect(blk.call(5)).to eq([10, 11])
      expect(captured).to be_a(Binding)
      expect(captured.local_variables).to include(:x, :a, :c)
      expect(captured.local_variable_get(:c)).to eq(11)
    end

    it 'finds the innermost frame running the block from deeper calls' do
      found = nil
      helper = ->(iseq) { found = fast.frame_binding(iseq) }
      outer = proc { |depth|
        mine = depth
        if depth < 2
          outer.call(depth + 1)
        else
          helper.call(RubyVM::InstructionSequence.of(outer))
        end
        mine
      }
      outer.call(0)
      expect(found.local_variable_get(:mine)).to eq(2)
    end

    it 'returns nil when no frame runs the code' do
      blk = proc { 1 }
      expect(fast.frame_binding(RubyVM::InstructionSequence.of(blk))).to be_nil
    end

    it 'survives the GC running at every allocation' do
      blk = proc { |x| y = x + 1; GC.stress = true; b = fast.frame_binding(RubyVM::InstructionSequence.of(blk)); GC.stress = false; [b, y] }
      b, y = blk.call(1)
      expect(b.local_variable_get(:y)).to eq(y)
    ensure
      GC.stress = false
    end
  end
end

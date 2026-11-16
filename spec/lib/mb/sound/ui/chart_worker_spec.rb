require_relative '../../../../support/ui_helpers'

RSpec.describe(MB::Sound::UI::ChartWorker) do
  let(:plot) { MB::Sound::Plot }
  let(:cells) { MB::Term::Cells }

  def chart(n)
    plot.waveform(Numo::SFloat.new(64).seq.map { |v| Math.sin(v * n / 10.0) }, range: -1.0..1.0)
  end

  def text(c) = c.to_text(:none)

  after { @cw&.close }

  it 'draws a new chart on its thread, showing the last one drawn meanwhile, and the same picture as drawing it here' do
    @cw = described_class.new
    was = MB::Sound::UI::PatchRender.inline
    MB::Sound::UI::PatchRender.inline = false
    a = @cw.draw(:a, 40, 8, :scope, cells) { chart(1) } # (nothing drawn at this size: drawn at once)
    expect(text(a)).to eq(text(described_class.render({}, 40, 8, :scope, cells, chart(1))))
    gate = Queue.new
    first = @cw.draw(:b, 40, 8, :scope, cells) { gate.pop; chart(2) }
    expect(first).to equal(a) # (b is built on the thread)
    expect(@cw).to be_pending
    expect(@cw.thread.priority).to eq(-3)
    gate << true
    expect(wait_until { !@cw.pending? }).to eq(true)
    b = @cw.draw(:b, 40, 8, :scope, cells) { raise 'built again' }
    expect(text(b)).to eq(text(described_class.render({}, 40, 8, :scope, cells, chart(2))))
    expect(@cw.draw(:c, 30, 8, :scope, cells) { nil }).to be_nil # (another size: at once; no chart: nil)
  ensure
    MB::Sound::UI::PatchRender.inline = was
  end

  it 'draws at once with PatchRender.inline (specs, captures)' do
    @cw = described_class.new
    was = MB::Sound::UI::PatchRender.inline
    MB::Sound::UI::PatchRender.inline = true
    @cw.draw(:a, 20, 4, :scope, cells) { chart(1) }
    b = @cw.draw(:b, 20, 4, :scope, cells) { chart(3) }
    expect(text(b)).to eq(text(described_class.render({}, 20, 4, :scope, cells, chart(3))))
    expect(@cw.thread).to be_nil
  ensure
    MB::Sound::UI::PatchRender.inline = was
  end
end

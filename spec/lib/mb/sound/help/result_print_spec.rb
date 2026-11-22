require 'mb/sound/help'
require 'pry'

# Console results print cut at Help.result_lines (followups-1; the
# maintainer, 2026-11-21: "default pry output should not be to inspect the
# full ruby object"): Pry's own printer, a dim line saying how to see the
# rest, `_` untouched, and help pages still shown as pages.
RSpec.describe(MB::Sound::Help::PagePrinter) do
  let(:out) { StringIO.new }
  let(:pry) { Pry.new(output: out, color: false, pager: false) }
  let(:printer) { described_class.new(Pry::ColorPrinter.method(:default)) }

  # An object whose default inspect lists thousands of lines
  let(:big) do
    o = Object.new
    o.instance_variable_set(:@records, Array.new(3000) { |i| [i, i * 2, i * 3, 'x' * 40] })
    o
  end

  it 'prints a short result as Pry does' do
    printer.call(pry.output, [1, 2, 3], pry)
    expect(out.string).to eq("=> [1, 2, 3]\n")
  end

  it 'cuts a long result at result_lines lines and says how to see it all' do
    printer.call(pry.output, big, pry)
    lines = out.string.lines
    expect(lines.length).to eq(MB::Sound::Help.result_lines + 1)
    expect(lines.first).to start_with('=> #<Object')
    expect(lines.last).to include('cut at 30 lines', 'pp _; nil')
  end

  it 'prints everything with result_lines nil, and leaves another printer alone' do
    was = MB::Sound::Help.result_lines
    MB::Sound::Help.result_lines = nil
    printer.call(pry.output, big, pry)
    expect(out.string.lines.length).to be > 3000
  ensure
    MB::Sound::Help.result_lines = was
  end

  it 'passes results to a printer set before it' do
    seen = nil
    p2 = described_class.new(->(_o, v, _p) { seen = v })
    p2.call(pry.output, big, pry)
    expect(seen).to equal(big)
    expect(out.string).to eq('')
  end

  it 'keeps the whole value in _ at the console' do
    pry.config.print = printer
    pry.eval('x = Array.new(500) { |i| [i] * 8 }')
    expect(out.string.lines.length).to eq(31)
    expect(pry.last_result.length).to eq(500)
    pry.eval('_.length')
    expect(out.string).to include('=> 500')
  end
end

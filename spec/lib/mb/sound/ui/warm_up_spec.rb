# The warm-ups the console runs before anything plays (YJIT compiles the
# painter, UI.warm_up, and the console's line path, UI.warm_up_console;
# tuner-fixes-1: the maintainer's "Entering numbers in Pry caused the music
# to lose its step ... on the first couple").  Specs run without YJIT, so
# the console's warm-up is checked with JIT.compiling? stubbed: it types its
# lines through a Pry of its own and leaves no trace (take, histories, line
# counter).
RSpec.describe('MB::Sound::UI.warm_up_console', :aggregate_failures) do
  let(:ui) { MB::Sound::UI }

  after { ui.instance_variable_set(:@console_warmed, nil) }

  it 'does nothing without YJIT' do
    ui.instance_variable_set(:@console_warmed, nil)
    expect(ui.warm_up_console).to be_nil
  end

  it 'evaluates its lines in a Pry of its own, leaving the take, the histories, and the line counter as they were' do
    require 'pry'
    require 'reline'
    ui.instance_variable_set(:@console_warmed, nil)
    allow(MB::Sound::JIT).to receive(:compiling?).and_return(true)
    take = MB::Sound::Take.current
    lines = take.lines.length
    reline = Reline::HISTORY.length
    counter = Pry.current_line
    save = Pry.config.history_save
    history = Pry.config.history
    seen = []
    hook = ->(code, _pry) { seen << [code.strip, MB::Sound::Take.current.equal?(take)] }
    Pry.config.hooks.add_hook(:before_eval, :warm_up_spec, hook)
    begin
      secs = ui.warm_up_console(rounds: 1, lines: %w[5 :a])
    ensure
      Pry.config.hooks.delete_hook(:before_eval, :warm_up_spec)
    end
    expect(secs).to be_a(Float).and(be < 5)
    expect(seen).to eq([['5', false], [':a', false]]) # (the console's hooks ran, a throwaway take current)
    expect(MB::Sound::Take.current).to equal(take)
    expect(take.lines.length).to eq(lines)
    expect(Reline::HISTORY.length).to eq(reline)
    expect(Pry.current_line).to eq(counter)
    expect(Pry.config.history_save).to eq(save)
    expect(Pry.config.history).to equal(history)
    expect(ui.warm_up_console).to be_nil # (once per process)
  end
end

require_relative '../../../../support/ui_helpers'

# The oscillator preview's sweep (ux-notes-2): every SOURCE oscillator row
# of every shipped instrument preset renders one cycle (finite samples,
# one period at the oscillator's frequency) or says why it can't.
# SWEEP_REPORT=1 prints each row.
RSpec.describe(MB::Sound::UI::ToneCycle, :aggregate_failures) do
  let(:ui) { MB::Sound::UI }
  let(:tc) { MB::Sound::UI::ToneCycle }
  let(:pr) { MB::Sound::UI::PatchRender }

  TONE_CYCLE_PRESETS = MB::Sound::Library.index.entries(kind: :instrument).select { |e| e.location.to_s.include?('/presets/') }.map(&:name)

  # Reasons an oscillator row may give instead of a cycle (the render
  # pane's too: a voice there is no copy of).
  TONE_CYCLE_REASONS = /no recorded call to copy|outside the voice|no synth voice to copy|shared with the live graph/

  # Every GM drum note, so kits' voices play too.
  TONE_CYCLE_NOTES = MB::Sound.seq(*(35..81).to_a).n16.loop

  after { MB::Sound.rewind }

  it 'renders a cycle for every oscillator row of every shipped instrument preset', render_budget: { seconds: 200, reason: 'one copy of every shipped preset voice' } do
    expect(TONE_CYCLE_PRESETS.length).to be >= 30
    rendered = 0
    TONE_CYCLE_PRESETS.each do |name|
      s = MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false)
      begin
        MB::Sound::Session.with_context(session: s) do
          MB::Sound.instance_exec(name) { |n| track(:t) { |c| preset n, midi: c } }
          MB::Sound.bg(:t, TONE_CYCLE_NOTES)
        end
        4.times { s.process_buffer }
        poll = ui::Poll.new(s)
        ui::Inspect.target = { track: :t, node: nil }
        src = poll.call([:inspect, :render]).first.render_source
        poll.close
        input = s.instance_variable_get(:@players).values.find { |p| p.name == :t }.input
        walked = ui::Inspect.walk(ui::Inspect.roots(input))
        rows = walked[:nodes].each_index.select { |i| walked[:nodes][i].section == :source && walked[:objects][i].is_a?(MB::Sound::Tone) }
        knobs = s.knobs.map { |n, k| [n, k.value, k.spec] }
        cache = {}
        rows.each do |i|
          tone = walked[:objects][i]
          label = "#{name} #{walked[:nodes][i].label}"
          job = tc::Job.new(seq: i, key: [i], source: src, input: pr.input(src, 0.5), knobs: knobs, tone: tc.key_of(tone))
          r = tc.render(job, cache: cache)
          if r.error
            puts "SWEEP #{label}: #{r.error}" if ENV['SWEEP_REPORT']
            expect(r.error).to match(TONE_CYCLE_REASONS), label
            next
          end
          rendered += 1
          puts "SWEEP #{label}: #{r.frequency.round(1)} Hz #{r.frames} #{r.ms} ms" if ENV['SWEEP_REPORT']
          expect(r.cycle.length).to be > 1, label
          expect(r.cycle.isfinite.all?).to eq(true), label
          want = r.noise ? tc::NOISE_FRAMES : r.partial ? (tc::MAX_SECONDS * r.rate).round : (r.rate / r.frequency).ceil + 1
          expect(r.frames).to eq(want), label
        end
        cache[:copies]&.each_value(&:close)
        cache[:scopes]&.each_value(&:close)
      ensure
        s.close
        ui::Inspect.target = nil
      end
    end
    expect(rendered).to be >= 30
  end
end

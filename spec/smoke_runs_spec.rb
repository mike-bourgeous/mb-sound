require 'shellwords'

RSpec.describe(SmokeRuns) do
  let(:runs) { SmokeRuns.new(tmp_path('runs'), jobs: 3) }

  it 'runs commands side by side, each with its own output and status' do
    runs.add(:a, 'echo a; echo err >&2')
    # b and c print the times they start and end, so the overlap of their
    # runs proves they ran at once, whatever the load (a bound on the wall
    # time failed on three merge trains: 0.58 and 0.68 s against 0.55)
    runs.add(:b, 'date +%s.%N; sleep 0.3; date +%s.%N; exit 3')
    runs.add(:c, 'date +%s.%N; sleep 0.3; date +%s.%N; echo c')
    runs.start(%i[a b c])
    a, sa = runs.take(:a)
    b, sb = runs.take(:b)
    c, sc = runs.take(:c)
    b_start, b_end = b.lines.map { |l| Rational(l.chomp) }
    c_start, c_end = c.lines.first(2).map { |l| Rational(l.chomp) }
    expect(c_start).to be < b_end # (b and c at once)
    expect(b_start).to be < c_end
    expect(a).to eq("a\nerr\n")
    expect(sa).to be_success
    expect(sb.exitstatus).to eq(3)
    expect([c.lines.last, sc.success?]).to eq(["c\n", true])
    runs.stop
  end

  it 'runs one command at a time with one job (so the overlap above means side by side)' do
    one = SmokeRuns.new(tmp_path('one'), jobs: 1)
    one.add(:b, 'date +%s.%N; sleep 0.05; date +%s.%N')
    one.add(:c, 'date +%s.%N')
    one.start(%i[b c])
    one.stop # (both on the one thread: a #take before it starts a run would run it at once)
    _, b_end = one.take(:b).first.lines.map { |l| Rational(l.chomp) }
    expect(Rational(one.take(:c).first.chomp)).to be >= b_end
  end

  it 'runs a command nothing started when its example takes it, with its env' do
    runs.add(:d, 'echo $SMOKE_X', env: { 'SMOKE_X' => 'yes' })
    expect(runs.take(:d).first).to eq("yes\n")
  end

  it "hands a run's warnings to the example that takes it" do
    code = 'Warning.warn("smoke runs spec warning\n")'
    runs.add(:w, "ruby -e #{code.shellescape}")
    runs.start([:w])
    expect(WarningGuard.take_subprocess).to eq([]) # (in the run's own directory until taken)
    runs.take(:w)
    expect(WarningGuard.take_subprocess.map(&:message)).to eq(["smoke runs spec warning\n"])
  end

  it 'refuses a key added twice' do
    runs.add(:a, 'true')
    expect { runs.add(:a, 'true') }.to raise_error(ArgumentError, /added twice/)
  end
end

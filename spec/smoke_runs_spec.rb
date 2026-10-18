require 'shellwords'

RSpec.describe(SmokeRuns) do
  let(:runs) { SmokeRuns.new(tmp_path('runs'), jobs: 3) }

  it 'runs commands side by side, each with its own output and status' do
    runs.add(:a, 'echo a; echo err >&2')
    runs.add(:b, 'sleep 0.3; exit 3')
    runs.add(:c, 'sleep 0.3; echo c')
    t = MB::U.clock_now
    runs.start(%i[a b c])
    a, sa = runs.take(:a)
    _, sb = runs.take(:b)
    c, sc = runs.take(:c)
    expect(MB::U.clock_now - t).to be < 0.55 # (b and c at once)
    expect(a).to eq("a\nerr\n")
    expect(sa).to be_success
    expect(sb.exitstatus).to eq(3)
    expect([c, sc.success?]).to eq(["c\n", true])
    runs.stop
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

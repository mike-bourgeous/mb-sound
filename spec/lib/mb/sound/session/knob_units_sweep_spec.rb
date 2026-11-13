# Typed values on every shipped preset knob (sd-ux-fixes-1, the review's #1:
# `turn :"bass/cutoff", 3000.hz` on a preset's plain-number cutoff followed
# the Pitch as a 3 kHz sine, limited to the knob's bottom, silently).  Each
# presets/ document's params become track knobs the way a track makes them
# (Arrangement::TrackKnobs.knob_for); a unit value of the knob's implied unit
# (Param.implied_unit: Hz for a cutoff, seconds for a decay) lands at its
# number, and one the knob can't read is refused with nothing changed.
RSpec.describe('typed values on shipped preset knobs', :aggregate_failures) do
  let(:session) { MB::Sound::Session.new(output: MB::Sound::NullOutput.new(channels: 2, sleep: false), realtime: false) }

  after { session.close }

  UNIT_PRESET_FILES = begin
    root = File.expand_path('../../../../../presets', __dir__)
    (Dir[File.join(root, '*.mbg.rb')] + Dir[File.join(root, '*.mbg', '*.mbg.rb')]).sort
  end

  # A value inside +range+ away from its ends (the geometric middle for
  # positive ranges, else the middle).
  def inside(range)
    lo, hi = range.begin.to_f, range.end.to_f
    v = lo > 0 ? Math.sqrt(lo * hi) : (lo + hi) / 2
    v.round(6)
  end

  it 'lands a typed unit value where intended on every preset knob, and refuses the rest' do
    counts = Hash.new(0)
    MB::Sound::Session.with_context(session: session) do
      UNIT_PRESET_FILES.each_with_index do |f, i|
        MB::Sound::GraphIO.parse(f).declarations.each_value do |param|
          k = MB::Sound::Arrangement::TrackKnobs.knob_for(session, :"t#{i}", param) or next
          where = "#{File.basename(f)} #{param.name}"
          target = inside(k.spec.range)
          before = k.value
          case MB::Sound::Param.implied_unit(k.spec, k.name)
          when 'Hz'
            session.turn(k.name, target.hz, smooth: 0)
            counts[:hz] += 1
          when 's'
            session.turn(k.name, target.seconds, smooth: 0)
            counts[:seconds] += 1
          else
            expect { session.turn(k.name, 440.hz) }.to raise_error(MB::Sound::Param::Error, /holds plain numbers .* not a frequency; .*nothing was changed/), where
            session.process_buffer
            expect(k.value).to eq(before), where
            expect(k.state_at(session.frame).first).not_to eq(:follow), where
            counts[:refused] += 1
            next
          end
          session.process_buffer
          expect(k.value).to be_within(1e-6 * target.abs + 1e-9).of(target), where
          expect(k.state_at(session.frame).first).not_to eq(:follow), where
        end
      end
    end
    expect(counts[:hz]).to be >= 15
    expect(counts[:seconds]).to be >= 20
    expect(counts[:refused]).to be >= 40
  end

  it 'reads other lengths as seconds on a seconds knob, and follows a typed value only when follow: asks' do
    MB::Sound::Session.with_context(session: session) do
      cut = MB::Sound.knob(:"u/cutoff", 2400.0, range: 20.0..20000.0, curve: :exp)
      decay = MB::Sound.knob(:"u/decay", 0.3, range: 0.01..4.0, curve: :exp)
      MB::Sound.turn(:"u/decay", 4800.samples, smooth: 0)
      session.process_buffer
      expect(decay.value).to be_within(1e-9).of(0.1)
      MB::Sound.turn(:"u/decay", 250.ms, smooth: 0)
      session.process_buffer
      expect(decay.value).to be_within(1e-9).of(0.25)
      expect { MB::Sound.turn(:"u/decay", 3000.hz) }.to raise_error(MB::Sound::Param::Error, /holds seconds \(0\.01\.\.4\), not a frequency/)

      MB::Sound.turn(:"u/cutoff", follow: 3.hz)
      session.process_buffer
      expect(cut.state_at(session.frame).first).to eq(:follow)
    end
  end

  it 'refuses live with a warning, changing nothing, and turns several knobs with typed values' do
    MB::Sound::Session.with_context(session: session) do
      level = MB::Sound.knob(:"u/amount", 0.5)
      cut = MB::Sound.knob(:"u/cutoff", 2400.0, range: 20.0..20000.0, curve: :exp)
      live = MB::Sound.live?
      MB::Sound.live = true
      expect { expect(MB::Sound.turn(:"u/amount", 300.hz)).to be_nil }.to output(/holds plain numbers \(0\.\.1\), not a frequency/).to_stderr
      session.process_buffer
      expect(level.value).to eq(0.5)

      session.turn_knobs({ :"u/cutoff" => 3000.hz })
      session.process_buffer
      expect(cut.value).to eq(3000.0)
    ensure
      MB::Sound.live = live
    end
  end
end

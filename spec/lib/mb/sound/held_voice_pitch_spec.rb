# Held-voice pitch across content jumps (tracker-2): a sampler voice still
# sounding when its track's content jumps (a scene launch, a clip swap, a
# seek) keeps the pitch of its own note-on.  A jump chases held values
# (Notes::Number follows the note at the new position, MIDI::Source#chase);
# sampler voices used to read that chased number for their playback rate,
# so a ringing sample (a one-shot, a tracker channel's looping sample, a kit
# hit) was retuned by the key difference: +7 semitones here, the sample
# numbers' difference in tracker sets.  A property sweep (in
# QuickSelection::ALWAYS): every voice kind and every jump kind.
#
# A seek inside a note that sounded before it resumes that note (one-shot
# voices start its sample where an uninterrupted run would be, regions-1;
# Notes#resume), so after the seek the voice plays the resumed note at its
# own pitch; with +resume: false+ the old sample rings on at its pitch.
RSpec.describe('held voice pitch across content jumps', :aggregate_failures) do
  let(:m) { MB::Sound }
  let(:seq) { MB::Sound::Sequence }
  let(:sr) { 48_000 }
  let(:sessions) { [] }

  after { sessions.each(&:close) }

  def session
    m::Session.new(
      master_gain: 1, output: m::NullOutput.new(channels: 2, sleep: false), transport: seq::Transport.new(bpm: 120),
      channels: 2, buffer_size: 800, realtime: false, raise_errors: true
    ).tap { |s| sessions << s }
  end

  def sine(hz, seconds: 4)
    data = Numo::SFloat.new(sr * seconds).seq.map { |i| Math.sin(2 * Math::PI * hz * i / sr) * 0.5 }
    m::Sample.new(data, sample_rate: sr, root: 60, name: "sine #{hz}")
  end

  def clip(start, key, pitch: nil)
    seq::Clip.new([seq::Event.new(start: start, length: 1/16r, value: key, velocity: 0.8, pitch: pitch)], length: 1r, loop: true, align: :launch)
  end

  # Voice kinds: [instrument, the track's patch, key of the held note, key
  # of the other clip's note, the other note's pitch (Hz) where a seek
  # resumes it]; every sample is a 220 Hz sine at note 60.
  def voices
    melodic = m::Sampler::Instrument.new(name: 'melodic') { |i| i.region(sine(220), keys: 0..127) }
    kit = m::Sampler::Instrument.new(name: 'kit') { |i|
      i.region(sine(220), keys: 36, keytrack: 0)
      i.region(sine(220), keys: 38, keytrack: 0)
    }
    fifth = 220 * 2**(7 / 12.0)
    {
      melodic: [proc { |c| c.sampler(melodic) }, 60, 67, fifth],
      melodic_no_resume: [proc { |c| c.sampler(melodic, resume: false) }, 60, 67, 220],
      kit: [proc { |c| c.sampler(kit) }, 36, 38, 220],
      tracker_lanes: [proc { |c| c.sampler(kit, lanes: true) }, 36, 38, 220],
      tracker_lanes_melodic: [proc { |c| c.sampler(melodic, lanes: true) }, 60, 67, fifth],
      tracker_lanes_no_resume: [proc { |c| c.sampler(melodic, lanes: true, resume: false) }, 60, 67, 220],
    }
  end

  # Jump kinds: each a block run at the jump (frame 24 000) with the other
  # clip +b+.
  JUMPS = {
    scene: ->(b) { MB::Sound.go(:b, at: :now) },
    swap: ->(b) { MB::Sound.swap(:t, b, at: :now) },
    seek: ->(_b) { MB::Sound.seek(2, 2) },
  }.freeze

  # The strongest frequency (Hz, 2 Hz bins) of +x+ from +from+ for half a
  # second.
  def peak_hz(x, from)
    s = MB::Sound.real_fft(x[from...(from + sr / 2)]).abs
    (s[1..].max_index + 1) * 2
  end

  it 'keeps a sampler voice at its note-on pitch through every jump' do
    voices.each do |kind, (patch, held, other, resumed)|
      JUMPS.each do |jump, run|
        s = session
        a = clip(0r, held)
        # (the seek lands in the held clip's second bar, after its note of
        # the other key: the chase finds that note)
        a = seq::Clip.new([seq::Event.new(start: 0r, length: 1/16r, value: held, velocity: 0.8),
                           seq::Event.new(start: 1r, length: 1/16r, value: other, velocity: 0.8)], length: 2r, loop: true, align: :launch) if jump == :seek
        b = clip(3/4r, other)
        m::Session.with_context(session: s) {
          m.track(:t, &patch)
          m.scene(:a, t: a)
          m.scene(:b, t: b)
          m.go(:a, at: :now)
        }
        bufs = Array.new(60) { |k|
          m::Session.with_context(session: s) { run.(b) } if k == 30
          s.process_buffer(800)[0].dup
        }
        x = SpecBuffers.join(bufs)
        before = peak_hz(x, 0)
        expect(before).to be_within(2).of(220), "#{kind}: plays 220 Hz before the jump (got #{before})"
        if jump == :seek
          expect(peak_hz(x, 24_000)).to be_within(2).of(resumed), "#{kind} voice through a #{jump}: resumes the other note (or keeps its pitch)"
        else
          expect(peak_hz(x, 24_000)).to eq(before), "#{kind} voice through a #{jump}: keeps its pitch"
        end
        s.close
      end
    end
  end
end

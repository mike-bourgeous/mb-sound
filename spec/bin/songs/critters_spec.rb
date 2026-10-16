RSpec.describe('bin/songs/critters.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/critters.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'scratches the mouse\'s feet only in brief bursts as it darts (textures-6)' do
    squeaks_only = -> {
      MB::Sound.with_seed(4) {
        MB::Sound.next_seed # (the ticks' dust draws its seed first)
        MB::Sound.critter_squeaks(MB::Sound.dust(0.8, range: 0.5..1, min_gap: 600.ms)) * 0.05
      }
    }

    # Standing still, and walking back and forth at up to 1.26 m/s: no ticks
    still = MB::Sound.with_seed(4) { MB::Sound.critter_mouse(0.5.constant, 1.constant, 0.constant) }
    expect(render_patch(still, 3)).to eq(render_patch(squeaks_only.(), 3))
    walking = MB::Sound.with_seed(4) { MB::Sound.critter_mouse(0.4.hz.lfo.sine.at(0.5), 1.constant, 0.constant) }
    expect(render_patch(walking, 3)).to eq(render_patch(squeaks_only.(), 3))

    # Darting back and forth at up to 3 m/s: ticks only while faster than
    # 1.5 m/s (near the sine's zero crossings, 1.25 s apart)
    darting = MB::Sound.with_seed(4) { MB::Sound.critter_mouse(0.4.hz.lfo.sine.at(1.2), 1.constant, 0.constant) }
    ticks = render_patch(darting, 5)[0] - render_patch(squeaks_only.(), 5)[0]
    expect(rms_db(seconds(ticks, 0, 5))).to be > -60 # (the ticks alone; critters plays the mouse 28 dB up)
    # Silent around the turns (x = +-1.2 at 0.625 s, 1.875 s, ...): the
    # speed is 3 m/s times the sine of the phase from the turn, under 1.5
    # within 30 degrees (1/12 cycle, 0.21 s) either side (the bandpass
    # rings a little after the last tick)
    [0.625, 1.875, 3.125, 4.375].each do |turn|
      expect(rms_db(seconds(ticks, turn - 0.15, turn + 0.18))).to be < -150
      expect(rms_db(seconds(ticks, turn - 0.6, turn - 0.3))).to be > -70
    end
  end

  it 'stops the mouse now and then: x and y share one clock' do
    MB::Sound.seed(3)
    x, y, = MB::Sound.critter_mouse_path
    vx, vy = MB::Sound.critter_velocity([x, y])
    speed = render_patch((vx * vx + vy * vy) ** 0.5, 12)[0][4800..]
    expect(speed.lt(0.05).count).to be > speed.length * 0.1 # (round 4: 1.5%)
    expect(speed.max).to be < 5 # m/s (round 4: over 100 at jittered elastic steps)
  end

  it 'smooths the doppler (textures-5; 1.5 Hz since textures-6): the darts swoop instead of warbling' do
    # The pitch of a 1 kHz tone carried by the fly's path, by zero crossings
    # in 50 ms windows
    pitch_range = ->(smooth) {
      MB::Sound.seed(5)
      x, y, z = MB::Sound.critter_fly_path
      out = render_patch(MB::Sound.critter_place(1000.hz.sine, x, y, z, smooth: smooth), 12)[0][48000..]
      pos = out.ge(0)
      ups = (pos[1..] & ~pos[0...-1]).where
      counts = ups.to_a.group_by { |i| i / 2400 }.values.map(&:length)[1...-1]
      counts.max - counts.min # per 50 ms, so 20 Hz each
    }
    raw = pitch_range.(0)
    smooth = pitch_range.(1.5)
    expect(smooth).to be < raw / 2
    expect(smooth).to be > 0 # still a doppler
  end
end

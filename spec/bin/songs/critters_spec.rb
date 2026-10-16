RSpec.describe('bin/songs/critters.rb') do
  before(:all) { require File.expand_path('../../../bin/songs/critters.rb', __dir__) }

  after { MB::Sound.rewind }

  it 'ticks the mouse\'s feet only while it moves (textures-5)' do
    still = MB::Sound.with_seed(4) { MB::Sound.critter_mouse(0.5.constant, 1.constant, 0.constant) }
    # The same squeaks alone (the ticks' dust draws its seed first)
    squeaks = MB::Sound.with_seed(4) {
      MB::Sound.next_seed
      MB::Sound.critter_squeaks(MB::Sound.dust(0.8, range: 0.5..1, min_gap: 600.ms)) * 0.05
    }
    expect(render_patch(still, 3)).to eq(render_patch(squeaks, 3))

    # Running back and forth at about 1.3 m/s: ticks
    squeaks = MB::Sound.with_seed(4) {
      MB::Sound.next_seed
      MB::Sound.critter_squeaks(MB::Sound.dust(0.8, range: 0.5..1, min_gap: 600.ms)) * 0.05
    }
    running = MB::Sound.with_seed(4) { MB::Sound.critter_mouse(0.4.hz.lfo.sine.at(0.5), 1.constant, 0.constant) }
    ticks = render_patch(running, 3)[0] - render_patch(squeaks, 3)[0]
    expect(rms_db(seconds(ticks, 0.5, 3))).to be > -60 # (the ticks alone; critters plays the mouse 28 dB up)
  end

  it 'stops the mouse now and then: x and y share one clock' do
    MB::Sound.seed(3)
    x, y, = MB::Sound.critter_mouse_path
    vx, vy = MB::Sound.critter_velocity([x, y])
    speed = render_patch((vx * vx + vy * vy) ** 0.5, 12)[0][4800..]
    expect(speed.lt(0.05).count).to be > speed.length * 0.1 # (round 4: 1.5%)
    expect(speed.max).to be < 5 # m/s (round 4: over 100 at jittered elastic steps)
  end

  it 'smooths the doppler (textures-5): the darts swoop instead of warbling' do
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
    smooth = pitch_range.(2)
    expect(smooth).to be < raw / 2
    expect(smooth).to be > 0 # still a doppler
  end
end

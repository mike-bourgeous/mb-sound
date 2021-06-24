#!/usr/bin/env ruby
# Plays realtime noise of different colors.

require 'rubygems'
require 'bundler/setup'

require 'pry'
require 'pry-byebug'

$LOAD_PATH << File.expand_path('../lib', __dir__)

require 'mb-sound'

USAGE = "(usage: #{$0} (white|pink|brown|power|wave) [channels default 2] [db_gain default 0])"

class NoiseGenerator
  BINS = 1201
  WINDOW_SIZE = (BINS - 1) * 2
  HOP_SIZE = 800
  GAIN_INCREMENT = 0.25
  SLOPE_INCREMENT = 0.25

  NOISE_COLORS = {
    white: '37',
    pink: '31',
    brown: '33',
    power: '35',
    wave: '34',
  }

  LFO_ADVANCE = Math::PI * 0.001 * HOP_SIZE / 300

  RAND = Random.new

  attr_reader :db_gain, :noise_type, :power_slope, :wave_slope

  def initialize(outstream, db_gain, noise_type)
    @outstream = outstream

    @window = MB::Sound::Window::DoubleHann.new(WINDOW_SIZE)
    @window.force_hop(HOP_SIZE)

    @noise_buffer = Numo::DComplex.zeros(BINS)

    @power_slope = -3.0 # pink noise
    set_noise_type(noise_type)

    @wave_slopes = []
    @lfos = outstream.channels.times.map { make_lfos }

    @target_gain = db_gain
    set_gain(db_gain - 60)
  end

  def make_lfos
    [
      MB::Sound::Oscillator.new(:triangle, frequency: 0.89 + RAND.rand(0.2), phase: RAND.rand(1.5), advance: LFO_ADVANCE),
      MB::Sound::Oscillator.new(:triangle, frequency: 1.1 + RAND.rand(0.2), phase: RAND.rand(1.5) + 1.3, advance: LFO_ADVANCE),
      MB::Sound::Oscillator.new(:triangle, frequency: 1.901 + RAND.rand(0.2), phase: RAND.rand(1.5), range: 0.0..0.6, post_power: 0.55, advance: LFO_ADVANCE),
      MB::Sound::Oscillator.new(:sine, frequency: 1.3153 + RAND.rand(0.2), phase: RAND.rand(1.5) - 1, pre_power: 0.5, advance: LFO_ADVANCE),
      MB::Sound::Oscillator.new(:sine, frequency: 0.788 + RAND.rand(0.2), phase: RAND.rand(1.5) + 4.25, pre_power: 0.7, range: -0.5..0.5, advance: LFO_ADVANCE),
      MB::Sound::Oscillator.new(:sine, frequency: 2.02 + RAND.rand(0.2), phase: RAND.rand(1.5) - 2, range: -0.5..0.5, advance: LFO_ADVANCE),
      MB::Sound::Oscillator.new(:triangle, frequency: 0.7554 + RAND.rand(0.2), phase: RAND.rand(1.5) + 0.5, pre_power: 0.75, advance: LFO_ADVANCE),
      MB::Sound::Oscillator.new(:triangle, frequency: 0.45 + RAND.rand(0.2), phase: RAND.rand(1.5) + 3, pre_power: 0.8, advance: LFO_ADVANCE),
    ]
  end

  def set_gain(db_gain)
    @db_gain = db_gain
    @linear_gain = db_gain.db
  end

  def set_noise_type(noise_type)
    noise_type = noise_type.to_sym
    @noise_type = noise_type
  end

  def handle_input
    begin
      c = STDIN.read_nonblock(1)
    rescue IO::EAGAINWaitReadable
      c = nil
    end

    case c
    when 'q', 'Q', "\x03", "\x04", "\x11" # exit
      @run = false
      @target_gain = -60

    when 'p'
      set_noise_type(:pink)

    when 'w'
      set_noise_type(:white)

    when 'b'
      set_noise_type(:brown)

    when '!'
      set_noise_type(:power)

    when '~'
      set_noise_type(:wave)

    when '>'
      @power_slope += SLOPE_INCREMENT
      set_noise_type(:power)

    when '<'
      @power_slope -= SLOPE_INCREMENT
      set_noise_type(:power)

    when '+', '='
      @target_gain = @db_gain + GAIN_INCREMENT

    when '-'
      @target_gain = @db_gain - GAIN_INCREMENT
    end
  end
  
  def show_status
    msg = "\r\e[#{NOISE_COLORS[@noise_type]}m#{@noise_type}"
    msg << " #{@power_slope.round(3)}dB/Oct" if @noise_type == :power
    msg << " #{@wave_slopes.map { |s| s.round(3).to_s.ljust(7) }.join(' ')} dB/Oct" if @noise_type == :wave
    msg << " \e[36m#{@db_gain.round(3)}dB"
    msg << "\e[0m\e[K\r"
    STDOUT.write(msg)
    STDOUT.flush
  end

  def generate_noise(channel)
    case @noise_type
    when :white
      MB::Sound::Noise.spectral_white_noise(BINS)

    when :pink
      MB::Sound::Noise.spectral_pink_noise(BINS)

    when :brown
      MB::Sound::Noise.spectral_brown_noise(BINS)

    when :power
      MB::Sound::Noise.spectral_power_noise(BINS, @power_slope, 2.0, buffer: @noise_buffer)

    when :wave
      @wave_slopes[channel] = @lfos[channel].map(&:sample).sum - 6.0
      MB::Sound::Noise.spectral_power_noise(BINS, @wave_slopes[channel], 2.0, buffer: @noise_buffer)

    else
      raise "Invalid noise type #{@noise_type}"
    end
  end

  def run
    puts " \e[1mq\e[0m - \e[35mQuit\e[0m"
    puts " \e[1mp\e[0m - \e[35mSwitch to pink noise\e[0m"
    puts " \e[1mw\e[0m - \e[35mSwitch to white noise\e[0m"
    puts " \e[1mb\e[0m - \e[35mSwitch to brown noise\e[0m"
    puts " \e[1m!\e[0m - \e[35mSwitch to power noise\e[0m"
    puts " \e[1m~\e[0m - \e[35mSwitch to wave noise\e[0m"
    puts " \e[1m>\e[0m - \e[35mIncrease power noise slope (-3dB == pink)\e[0m"
    puts " \e[1m<\e[0m - \e[35mDecrease power noise slope (-6dB == brown)\e[0m"
    puts " \e[1m+\e[0m - \e[35mIncrease output gain\e[0m"
    puts " \e[1m-\e[0m - \e[35mDecrease output gain\e[0m"
    puts

    `stty raw opost -echo`

    counter = 0
    @run = true
    MB::Sound.synthesize_window(@outstream, @window) do
      handle_input if @run

      show_status if counter % 10 == 0
      counter += 1

      if @target_gain < @db_gain
        set_gain(@db_gain - [@db_gain - @target_gain, 0.25].min)
      elsif @target_gain > @db_gain
        set_gain(@db_gain + [@target_gain - @db_gain, 0.25].min)
      elsif !@run
        break
      end

      @outstream.channels.times.map { |c|
        generate_noise(c) * @linear_gain
      }
    end

    puts "\n\e[1mGoodbye\e[0m\e[K\n"
  ensure
    `stty sane`
  end
end

noise_type = ARGV[0] || 'brown'
raise "Missing noise type #{USAGE}" unless noise_type.is_a?(String) && !noise_type.empty?

channels = ARGV[1]&.to_i || 2
raise "Invalid number of channels #{USAGE}" if channels < 1

gain = ARGV[2]&.to_f || 0

output = MB::Sound.output(rate: 48000, channels: channels)
generator = NoiseGenerator.new(output, gain, noise_type)

puts "\e[1;33m#{USAGE}\e[0m\n\n"
generator.run

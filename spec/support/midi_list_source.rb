# A MIDI Source for specs that plays a fixed list of Events (with times in
# content seconds), counting how often it is read.
class MIDIListSource
  include MB::Sound::MIDI::Source

  # The number of #read_events calls.
  attr_reader :reads

  # +realtime: true+ makes it stand in for live input (see
  # MB::Sound::MIDI::Source#realtime_input?).
  def initialize(*events, realtime: false)
    @realtime = realtime
    @events = events.flatten.each_with_index.sort_by { |e, idx| [e.time, idx] }.map(&:first)
    @offset = 0r
    @reads = 0
  end

  def realtime_input?
    @realtime
  end

  def ended?
    position - @offset > (@events.last&.time || 0)
  end

  def music_end
    @offset + (@events.last&.time || 0)
  end

  private

  def seek_to(time)
    @offset = position - time
  end

  def read_events(from, to)
    @reads += 1
    @events.filter_map { |e|
      t = e.time + @offset
      e.at(t) if t >= from && t < to
    }
  end
end
